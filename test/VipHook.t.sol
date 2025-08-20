// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {VipHook} from "src/VipHook.sol";
import {VipDiscountMap} from "src/VipDiscountMap.sol";
import {BrevisApp} from "src/BrevisApp.sol";
import {BaseHook} from "src/BaseHook.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

contract VipHookTest is Test {
    using CurrencyLibrary for Currency;

    VipHook internal hook;
    address internal poolManagerAddr;
    address internal brevisRequest;
    uint24 internal origFee;

    function setUp() public {
        poolManagerAddr = address(0xABCD);
        brevisRequest = address(0xBEEF);
        origFee = 100_000; // 10%

        hook = new VipHook(IPoolManager(poolManagerAddr), origFee, brevisRequest);
    }

    function _dummyPoolKey() internal view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: hook
        });
    }

    function test_getFee_noDiscount_returnsOrig() public {
        address user = address(0x1234);
        uint24 fee = hook.getFee(user);
        assertEq(fee, origFee, "fee should equal orig when no discount");
    }

    function test_brevisCallback_updatesDiscounts_and_getFeeReflects() public {
        // prepare a vk hash and whitelist it
        bytes32 vk = keccak256("vk");
        hook.addVkHash(vk);

        // build Brevis circuit output: epoch(4 bytes) | [address(20) | discount(2)]*
        address user = address(0xCAFE);
        uint16 discount = 5_000; // 50%

        bytes memory output = bytes.concat(
            bytes4(uint32(1)),
            bytes20(user),
            bytes2(discount)
        );

        // call as brevisRequest
        vm.prank(brevisRequest);
        hook.brevisCallback(vk, output);

        uint24 fee = hook.getFee(user);
        // expected fee = origFee * (10000 - discount) / 10000
        uint24 expected = uint24(uint256(origFee) * (10000 - discount) / 10000);
        assertEq(fee, expected, "discounted fee mismatch");
    }

    function test_afterInitialize_reverts_onNonDynamicFee() public {
        // same as _dummyPoolKey but fee not dynamic
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: uint24(3_000),
            tickSpacing: 10,
            hooks: hook
        });

        // must be called by poolManager
        vm.prank(poolManagerAddr);
        vm.expectRevert(VipHook.NotDynamicFee.selector);
        hook.afterInitialize(address(this), key, 0, 0);
    }

    function test_beforeSwap_returnsOverrideFlag_andDiscountedFee() public {
        // whitelist vk and set discount via brevisCallback
        bytes32 vk = keccak256("vk2");
        hook.addVkHash(vk);

        address user = address(0xB0B);
        uint16 discount = 2_000; // 20%
        bytes memory output = bytes.concat(bytes4(uint32(2)), bytes20(user), bytes2(discount));
        vm.prank(brevisRequest);
        hook.brevisCallback(vk, output);

        // construct dummy key and params
        PoolKey memory key = _dummyPoolKey();
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(1e18),
            sqrtPriceLimitX96: uint160(0)
        });

        // call as poolManager with tx.origin set to user
        vm.prank(poolManagerAddr, user);
        (bytes4 sel, BeforeSwapDelta d, uint24 feeWithFlag) = hook.beforeSwap(address(this), key, params, "");
        // silence unused var warnings
        sel; d;

        assertTrue(LPFeeLibrary.isOverride(feeWithFlag), "override flag should be set");
        uint24 fee = LPFeeLibrary.removeOverrideFlag(feeWithFlag);

        uint24 expected = uint24(uint256(origFee) * (10000 - discount) / 10000);
        assertEq(fee, expected, "discounted fee mismatch");
    }
}


