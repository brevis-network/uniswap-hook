// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {VipHook} from "src/VipHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Base_Test} from "test/Base_Test.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

contract ManualVipDiscountTest is Base_Test {
    using CurrencyLibrary for Currency;

    function _findTxOrigin(Vm.Log[] memory logs) internal pure returns (address originAddr) {
        bytes32 topic = keccak256("TxOrigin(address)");
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == topic) {
                return address(uint160(uint256(logs[i].topics[1])));
            }
        }
        return address(0);
    }

    function _extractSwapFee(Vm.Log[] memory logs) internal pure returns (uint24 fee) {
        bytes32 topic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                (,,, , , uint24 feeVal) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return feeVal;
            }
        }
        return 0;
    }

    function _fund(address user, uint256 amount) internal {
        MockERC20(Currency.unwrap(currency0)).mint(user, amount);
        MockERC20(Currency.unwrap(currency1)).mint(user, amount);
        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _discoverFeeDiscountBaseSlot(address hook, address user, uint16 probeValue) internal returns (uint256) {
        // Try candidate base slots 0..15 and see which one affects feeDiscount(user)
        for (uint256 cand = 0; cand < 16; cand++) {
            bytes32 key = keccak256(abi.encode(user, cand));
            // write probe
            vm.store(hook, key, bytes32(uint256(probeValue)));
            // check via getter
            uint16 got = VipHook(hook).feeDiscount(user);
            if (got == probeValue) {
                return cand;
            }
        }
        return type(uint256).max;
    }

    function test_ManualSetDiscountSwapFee() public {
        address user = makeAddr("u");
        _fund(user, 1000e18);
        uint256 swapAmount = 1e18;

        // First swap to capture tx.origin and baseline fee
        vm.recordLogs();
        vm.prank(user, user);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(0)
        );
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        address originAddr = _findTxOrigin(logs1);
        require(originAddr != address(0), "no origin");
        uint24 fee1 = _extractSwapFee(logs1);
        require(fee1 != 0, "no fee1");

        // Discover mapping base slot dynamically
        uint256 baseSlot = _discoverFeeDiscountBaseSlot(address(vipHook), originAddr, 3000);
        require(baseSlot != type(uint256).max, "mapping slot not found");
        // Ensure it's set (already by discover). If needed, rewrite the same value
        bytes32 slot = keccak256(abi.encode(originAddr, baseSlot));
        vm.store(address(vipHook), slot, bytes32(uint256(uint16(3000))));
        assertEq(vipHook.feeDiscount(originAddr), 3000, "discount not set");

        // Second swap should emit lower fee in Swap event
        vm.recordLogs();
        vm.prank(user, user);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(0)
        );
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        uint24 fee2 = _extractSwapFee(logs2);
        require(fee2 != 0, "no fee2");

        // Discounted fee should be lower than baseline
        assertLt(fee2, fee1, "fee not reduced");

        console2.log("Baseline fee:", fee1);
        console2.log("Discounted fee:", fee2);
    }

    function test_MultiUserDifferentDiscountsSwapFee() public {
        // We'll sequentially set four discounts for the actual tx.origin used by the hook
        uint16[4] memory discounts = [uint16(0), uint16(1000), uint16(3000), uint16(5000)];

        address payer = makeAddr("payer");
        _fund(payer, 1000e18);
        uint256 swapAmount = 1e18;

        // Discover tx.origin via a first swap
        vm.recordLogs();
        vm.prank(payer, payer);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(0)
        );
        Vm.Log[] memory warmupLogs = vm.getRecordedLogs();
        address originAddr = _findTxOrigin(warmupLogs);
        require(originAddr != address(0), "no origin");
        uint24 baseFee = _extractSwapFee(warmupLogs);
        require(baseFee != 0, "no base fee");

        // Discover mapping base slot for origin key
        uint256 baseSlot = _discoverFeeDiscountBaseSlot(address(vipHook), originAddr, 777);
        require(baseSlot != type(uint256).max, "mapping slot not found");

        uint24 fees0 = 0; // 0%
        uint24 fees10 = 0; // 10%
        uint24 fees30 = 0; // 30%
        uint24 fees50 = 0; // 50%

        // Now sequentially set discount for the origin and swap to observe fee field
        for (uint i = 0; i < discounts.length; i++) {
            // write mapping
            bytes32 slot = keccak256(abi.encode(originAddr, baseSlot));
            vm.store(address(vipHook), slot, bytes32(uint256(discounts[i])));
            assertEq(vipHook.feeDiscount(originAddr), discounts[i], "discount not set");

            vm.recordLogs();
            vm.prank(payer, payer);
            MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
            swapRouter.swap(
                poolKey,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: int256(swapAmount),
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                abi.encode(0)
            );
            Vm.Log[] memory logsI = vm.getRecordedLogs();
            uint24 feeI = _extractSwapFee(logsI);
            require(feeI != 0, "no fee");

            if (discounts[i] == 0) fees0 = feeI;
            if (discounts[i] == 1000) fees10 = feeI;
            if (discounts[i] == 3000) fees30 = feeI;
            if (discounts[i] == 5000) fees50 = feeI;
        }

        // Assertions
        assertEq(fees0, baseFee, "0% should equal base fee");
        uint24 exp30 = uint24(uint256(baseFee) * 7000 / 10000);
        assertEq(fees30, exp30, "30% discounted fee mismatch");
        uint24 exp50 = uint24(uint256(baseFee) * 5000 / 10000);
        assertEq(fees50, exp50, "50% discounted fee mismatch");
        // 10% monotonic bounds
        assertLe(fees10, baseFee, "10% should be <= base");
        assertGe(fees10, fees50, "10% should be >= 50% fee");
        // overall ordering
        assertLe(fees30, fees10, "30% <= 10%");
        assertLe(fees50, fees30, "50% <= 30%");

        console2.log("Base fee:", baseFee);
        console2.log("0% fee:", fees0);
        console2.log("10% fee:", fees10);
        console2.log("30% fee:", fees30);
        console2.log("50% fee:", fees50);
    }
} 