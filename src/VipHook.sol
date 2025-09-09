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

contract VipHook is Spot, VipDiscountMap, BrevisApp, Ownable {
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
            uint256 swapFeeAmount = FullMath.mulDiv(absAmount, discountedFee, 1e6);
            uint256 hookFeeAmount = FullMath.mulDiv(swapFeeAmount, protocolFeePPM, 1e6);

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

    // function _afterSwap(
    //     address sender,
    //     PoolKey calldata key,
    //     SwapParams calldata params,
    //     BalanceDelta delta,
    //     bytes calldata
    // ) internal virtual override returns (bytes4, int128) {
    //     PoolId poolId = key.toId();

    //     // NOTE: we do oracle updates this regardless of manual fee setting

    //     // Get pre-swap tick from transient storage
    //     int24 preSwapTick;
    //     assembly {
    //         preSwapTick := tload(add(poolId, 1))
    //     }

    //     // Get current tick after the swap
    //     (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

    //     // Check if tick movement exceeded the cap based on perSwap vs perBlock setting
    //     bool tickWasCapped;
    //     bool perSwapMode = policyManager.getPerSwapMode(poolId);
    //     uint24 maxTicks = truncGeoOracle.maxTicksPerBlock(poolId);
        
    //     if (perSwapMode) {
    //         // perSwap mode: compare tick movement within this single swap
    //         int24 tickMovement = currentTick - preSwapTick;
    //         tickWasCapped = TruncatedOracle.abs(tickMovement) > maxTicks;
    //     } else {
    //         // perBlock mode: compare total tick movement within the current block
    //         // Get the block initial tick from the recorded observation
    //         int24 blockInitialTick = preSwapTick; // Default to pre-swap tick
            
    //         // Access the observation directly from the public mapping
    //         // Get the current index from the oracle state
    //         (uint16 index, uint16 cardinality, uint16 cardinalityNext) = truncGeoOracle.states(poolId);
    //         if (cardinality > 0) {
    //             // Access the observation at the current index
    //             (, int24 prevTick,,,) = truncGeoOracle.observations(poolId, index);
    //             blockInitialTick = prevTick;
    //         }
            
    //         // Compare total block movement
    //         int24 totalBlockMovement = currentTick - blockInitialTick;
    //         tickWasCapped = TruncatedOracle.abs(totalBlockMovement) > maxTicks;
    //     }

    //     // Update cap frequency in the oracle

    //     if(!truncGeoOracle.autoTunePaused(poolId)) {
    //         try truncGeoOracle.updateCapFrequency(poolId, tickWasCapped) {
    //             // Cap frequency updated successfully
    //         } catch Error(string memory reason) {
    //             emit OracleUpdateFailed(poolId, reason);
    //         } catch (bytes memory lowLevelData) {
    //             // Low-level oracle failure
    //             emit OracleUpdateFailed(poolId, "LLOF");
    //         }
    //     }
    //     // Notify Dynamic Fee Manager about the oracle update (with error handling)
    //     try dynamicFeeManager.notifyOracleUpdate(poolId, tickWasCapped) {
    //         // Oracle update notification succeeded
    //     } catch Error(string memory reason) {
    //         emit FeeManagerNotificationFailed(poolId, reason);
    //     } catch (bytes memory lowLevelData) {
    //         // Low-level fee manager failure
    //         emit FeeManagerNotificationFailed(poolId, "LLFM");
    //     }

    //     // Handle exactOut case in afterSwap (params.amountSpecified > 0)
    //     if (params.amountSpecified > 0) {
    //         // Get protocol fee percentage
    //         uint256 protocolFeePPM = policyManager.getPoolPOLShare(poolId);

    //         if (protocolFeePPM > 0) {
    //             // For exactOut, the input token is the unspecified token
    //             bool zeroIsInput = params.zeroForOne;
    //             Currency feeCurrency = zeroIsInput ? key.currency0 : key.currency1;

    //             // Get the actual input amount (should be positive) from the delta
    //             int128 inputAmount = zeroIsInput ? delta.amount0() : delta.amount1();
    //             if (inputAmount > 0) revert Errors.InvalidSwapDelta(); // NOTE: invariant check

    //             // Get the discounted dynamic fee from transient storage
    //             uint24 discountedFee;
    //             assembly {
    //                 discountedFee := tload(poolId)
    //             }

    //             // Calculate hook fee using discounted fee
    //             uint256 absInputAmount = uint256(uint128(-inputAmount));
    //             uint256 swapFeeAmount = FullMath.mulDiv(absInputAmount, discountedFee, 1e6);
    //             uint256 hookFeeAmount = FullMath.mulDiv(swapFeeAmount, protocolFeePPM, 1e6);

    //             if (hookFeeAmount > 0) {
    //                 // Mint fee credit to FRLM
    //                 poolManager.mint(address(liquidityManager), feeCurrency.toId(), hookFeeAmount);

    //                 // Calculate fee amounts for notification
    //                 uint256 fee0 = zeroIsInput ? hookFeeAmount : 0;
    //                 uint256 fee1 = zeroIsInput ? 0 : hookFeeAmount;

    //                 // Emit appropriate event
    //                 if (reinvestmentPaused) {
    //                     emit HookFee(poolId, sender, uint128(fee0), uint128(fee1));
    //                 } else {
    //                     emit HookFeeReinvested(poolId, sender, uint128(fee0), uint128(fee1));
    //                 }
    //                 liquidityManager.notifyFee(key, fee0, fee1);

    //                 // Try to reinvest if not paused (with error handling)
    //                 _tryReinvest(key);

    //                 // Return the fee amount we took
    //                 return (BaseHook.afterSwap.selector, int128(int256(hookFeeAmount)));
    //             }
    //         }
    //     }

    //     // Try to reinvest if not paused (with error handling)
    //     _tryReinvest(key);

    //     return (BaseHook.afterSwap.selector, 0);
    // }

    // - - - Brevis Integration - - -

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