// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {BaseHook} from "./BaseHook.sol";
import {VipDiscountMap} from "./VipDiscountMap.sol";
import {BrevisApp} from "./BrevisApp.sol";
import {Ownable} from "./Ownable.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

// discounted trading fees for VIPs
contract VipHook is BaseHook, VipDiscountMap, BrevisApp, Ownable {
    using LPFeeLibrary for uint24;

    /**
     * @dev The hook was attempted to be initialized with a non-dynamic fee.
     */
    error NotDynamicFee();

    event FeeUpdated(uint24 fee);
    event BrevisReqUpdated(address addr);
    event VkHashAdded(bytes32 vkhash);
    event VkHashRemoved(bytes32 vkhash);

    // need this to proper tracking "user"
    event TxOrigin(address indexed addr); // index field to save zk parsinig cost

    // supported vkhash
    mapping(bytes32 => bool) public vkmap;

    /**
     * @dev Set the `PoolManager` address.
     */
    constructor(IPoolManager _poolManager, uint24 _origFee, address _brevisRequest) BaseHook(_poolManager) BrevisApp(_brevisRequest) {
        origFee = _origFee;
    }

    // called by proxy to properly set storage of proxy contract
    function init(address owner, uint24 _origFee, address _brevisRequest, bytes32 _vkHash) external {
        initOwner(owner); // will fail if not called via delegateCall b/c owner is set in Ownable constructor
        // no need to emit event as it's first set in proxy state
        _setBrevisRequest(_brevisRequest);
        origFee = _origFee;
        vkmap[_vkHash] = true;
    }

    /**
     * @dev Check that the pool key has a dynamic fee.
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        return this.afterInitialize.selector;
    }

    /**
     * @dev Set the fee before the swap is processed using the override fee flag.
     */
    function _beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        uint24 fee = getFee(tx.origin);
        emit TxOrigin(tx.origin);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /**
     * @dev Set the hook permissions, specifically `afterInitialize` and `beforeSwap`.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    // brevisApp interface
    function handleProofResult(bytes32 _vkHash, bytes calldata _appCircuitOutput) internal override {
        require(vkmap[_vkHash], "invalid vk");
        updateBatch(_appCircuitOutput);
    }

    function setFee(uint24 _newfee) external onlyOwner {
        origFee = _newfee;
        emit FeeUpdated(_newfee);
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