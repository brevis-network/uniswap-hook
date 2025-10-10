// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {Spot} from "aegis-dfm/Spot.sol";

// - - - V4 Core Deps used in overrides - - -
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

// - - - AEGIS DFM libs - - -
import {TruncatedOracle} from "aegis-dfm/libraries/TruncatedOracle.sol";
import {Math} from "aegis-dfm/libraries/Math.sol";
import {Errors} from "aegis-dfm/errors/Errors.sol";

// - - - Brevis Contracts - - -
import {VipDiscountMap} from "./VipDiscountMap.sol";
import {BrevisApp} from "./BrevisApp.sol";
import {Ownable} from "./Ownable.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IFullRangeLiquidityManager} from "aegis-dfm/interfaces/IFullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "aegis-dfm/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "aegis-dfm/TruncGeoOracleMulti.sol";
import {IDynamicFeeManager} from "aegis-dfm/interfaces/IDynamicFeeManager.sol";

contract VipHook is VipDiscountMap, BrevisApp, Ownable, Spot {
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    // supported Brevis vk hashes
    mapping(bytes32 => bool) public vkmap;

    // Events specific to Brevis admin
    event BrevisReqUpdated(address addr);
    event VkHashAdded(bytes32 vkhash);
    event VkHashRemoved(bytes32 vkhash);
    event TxOrigin(address indexed addr);

    constructor(
        IPoolManager _manager,
        IFullRangeLiquidityManager _liquidityManager,
        PoolPolicyManager _policyManager,
        TruncGeoOracleMulti _oracle,
        IDynamicFeeManager _dynamicFeeManager,
        address _brevisRequest
    ) Spot(_manager, _liquidityManager, _policyManager, _oracle, _dynamicFeeManager) BrevisApp(_brevisRequest) {}

    // called by proxy to properly set storage of proxy contract
    function init(address owner, address _brevisRequest, bytes32 _vkHash) external {
        initOwner(owner);
        _setBrevisRequest(_brevisRequest);
        vkmap[_vkHash] = true;
    }

    // - - - Hook overrides to apply VIP discounts - - -

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        // First check if a manual fee is set for this pool
        PoolId poolId = key.toId();
        (uint24 manualFee, bool hasManualFee) = policyManager.getManualFee(poolId);

        uint24 dynamicFee;

        if (hasManualFee) {
            // Use the manual fee if set
            dynamicFee = manualFee;
        } else {
            // Otherwise get dynamic fee from fee manager
            (uint256 baseRaw, uint256 surgeRaw) = dynamicFeeManager.getFeeState(poolId);
            uint24 base = uint24(baseRaw);
            uint24 surge = uint24(surgeRaw);
            dynamicFee = base + surge; // ppm (1e-6)
        }

        // Apply Brevis discount to the dynamic fee
        uint24 discountedFee = _applyBrevisDiscount(dynamicFee, tx.origin);
        emit TxOrigin(tx.origin);

        // Store discounted fee and pre-swap tick for oracle update in afterSwap
        (, int24 preSwapTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        assembly {
            tstore(poolId, discountedFee)
            tstore(add(poolId, 1), preSwapTick) // use next slot for pre-swap tick
        }

        // Record observation with the pre-swap tick (no capping applied yet)
        try truncGeoOracle.recordObservation(poolId, preSwapTick) {
            // Observation recorded successfully
        } catch Error(string memory reason) {
            emit OracleUpdateFailed(poolId, reason);
        } catch (bytes memory lowLevelData) {
            // Low-level oracle failure
            emit OracleUpdateFailed(poolId, "LLOF");
        }

        // Calculate protocol fee based on policy
        uint256 protocolFeePPM = policyManager.getPoolPOLShare(poolId);

        // Handle exactIn case in beforeSwap
        if (params.amountSpecified < 0 && protocolFeePPM > 0) {
            // exactIn case - we can charge the fee here
            uint256 absAmount = uint256(-params.amountSpecified);
            Currency feeCurrency = params.zeroForOne ? key.currency0 : key.currency1;

            // Calculate hook fee amount using discounted fee
            uint256 swapFeeAmount = FullMath.mulDivRoundingUp(absAmount, discountedFee, 1e6);
            uint256 hookFeeAmount = FullMath.mulDivRoundingUp(swapFeeAmount, protocolFeePPM, 1e6);

            if (hookFeeAmount > 0) {
                // Mint fee to FRLM
                poolManager.mint(address(liquidityManager), feeCurrency.toId(), hookFeeAmount);

                // Calculate amounts for fee notification
                uint256 fee0 = params.zeroForOne ? hookFeeAmount : 0;
                uint256 fee1 = params.zeroForOne ? 0 : hookFeeAmount;

                if (reinvestmentPaused) {
                    emit HookFee(poolId, sender, uint128(fee0), uint128(fee1));
                } else {
                    emit HookFeeReinvested(poolId, sender, uint128(fee0), uint128(fee1));
                }
                liquidityManager.notifyFee(key, fee0, fee1);

                // Create BeforeSwapDelta to account for the tokens we took
                // We're taking tokens from the input, so return positive delta
                int128 deltaSpecified = int128(int256(hookFeeAmount));
                return (
                    BaseHook.beforeSwap.selector,
                    toBeforeSwapDelta(deltaSpecified, 0),
                    Math.setDynamicFeeOverride(discountedFee)
                );
            }
        }

        // If we didn't charge a fee, return zero delta
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, Math.setDynamicFeeOverride(discountedFee));
    }

    // - - - Brevis Integration - - -

    /// @notice Get the fee that would be charged to a specific user in a pool (with discount applied)
    /// @param user The user address to check the fee for
    /// @param poolId The pool ID to get the fee from
    /// @return The fee in parts per million (ppm) that the user would be charged
    function getFee(address user, PoolId poolId) public view returns (uint24) {
        // First check if a manual fee is set for this pool
        (uint24 manualFee, bool hasManualFee) = policyManager.getManualFee(poolId);

        uint24 fee;

        if (hasManualFee) {
            // Use the manual fee if set
            fee = manualFee;
        } else {
            // Otherwise get dynamic fee from fee manager
            (uint256 baseRaw, uint256 surgeRaw) = dynamicFeeManager.getFeeState(poolId);
            uint24 base = uint24(baseRaw);
            uint24 surge = uint24(surgeRaw);
            fee = base + surge; // ppm (1e-6)
        }

        // Apply Brevis discount to the dynamic fee for this user
        return _applyBrevisDiscount(fee, user);
    }

    function _applyBrevisDiscount(uint24 baseFee, address user) internal view returns (uint24) {
        uint16 discount = feeDiscount[user];
        if (discount == 0) {
            return baseFee;
        }
        uint256 discountedFee = uint256(baseFee) * (MAX_DISCOUNT - discount);
        return uint24(discountedFee / MAX_DISCOUNT);
    }

    function handleProofResult(bytes32 _vkHash, bytes calldata _appCircuitOutput) internal override {
        require(vkmap[_vkHash], "invalid vk");
        updateBatch(_appCircuitOutput);
    }

    function addVkHash(bytes32 _vkh) external onlyOwner {
        vkmap[_vkh]=true;
        emit VkHashAdded(_vkh);
    }

    function rmVkHash(bytes32 _vkh) external onlyOwner {
        delete vkmap[_vkh];
        emit VkHashRemoved(_vkh);
    }

    function setBrevisRequest(address _brevisRequest) external onlyOwner {
        _setBrevisRequest(_brevisRequest);
        emit BrevisReqUpdated(_brevisRequest);
    }
} 