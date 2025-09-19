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

        // Test exactIn first (positive amountSpecified)
        console2.log("=== Testing exactIn swaps ===");
        
        // First exactIn swap to capture tx.origin and baseline fee
        vm.recordLogs();
        vm.prank(user, user);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(swapAmount), // exactIn (positive)
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(0)
        );
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        address originAddr = _findTxOrigin(logs1);
        require(originAddr != address(0), "no origin");
        uint24 fee1ExactIn = _extractSwapFee(logs1);
        require(fee1ExactIn != 0, "no fee1");

        // Discover mapping base slot dynamically
        uint256 baseSlot = _discoverFeeDiscountBaseSlot(address(vipHook), originAddr, 3000);
        require(baseSlot != type(uint256).max, "mapping slot not found");
        bytes32 slot = keccak256(abi.encode(originAddr, baseSlot));
        vm.store(address(vipHook), slot, bytes32(uint256(uint16(3000))));
        assertEq(vipHook.feeDiscount(originAddr), 3000, "discount not set");

        // Second exactIn swap should emit lower fee
        vm.recordLogs();
        vm.prank(user, user);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(swapAmount), // exactIn (positive)
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(0)
        );
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        uint24 fee2ExactIn = _extractSwapFee(logs2);
        require(fee2ExactIn != 0, "no fee2");

        // Discounted fee should be lower than baseline for exactIn
        assertLt(fee2ExactIn, fee1ExactIn, "exactIn fee not reduced");

        console2.log("ExactIn baseline fee:", fee1ExactIn);
        console2.log("ExactIn discounted fee:", fee2ExactIn);

        // Now test exactOut (negative amountSpecified)
        console2.log("=== Testing exactOut swaps ===");
        
        // Reset discount to 0 for baseline exactOut measurement
        vm.store(address(vipHook), slot, bytes32(uint256(uint16(0))));
        assertEq(vipHook.feeDiscount(originAddr), 0, "discount not reset");

        // First exactOut swap to capture baseline fee
        vm.recordLogs();
        vm.prank(user, user);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount / 2), // exactOut (negative)
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(0)
        );
        Vm.Log[] memory logs3 = vm.getRecordedLogs();
        uint24 fee1ExactOut = _extractSwapFee(logs3);
        require(fee1ExactOut != 0, "no exactOut fee1");

        // Set discount again for exactOut test
        vm.store(address(vipHook), slot, bytes32(uint256(uint16(3000))));
        assertEq(vipHook.feeDiscount(originAddr), 3000, "discount not set for exactOut");

        // Second exactOut swap should emit lower fee
        vm.recordLogs();
        vm.prank(user, user);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount / 2), // exactOut (negative)
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(0)
        );
        Vm.Log[] memory logs4 = vm.getRecordedLogs();
        uint24 fee2ExactOut = _extractSwapFee(logs4);
        require(fee2ExactOut != 0, "no exactOut fee2");

        // Discounted fee should be lower than baseline for exactOut
        assertLt(fee2ExactOut, fee1ExactOut, "exactOut fee not reduced");

        console2.log("ExactOut baseline fee:", fee1ExactOut);
        console2.log("ExactOut discounted fee:", fee2ExactOut);

        // Both exactIn and exactOut should have same discount percentage
        uint256 exactInDiscountPercent = ((fee1ExactIn - fee2ExactIn) * 10000) / fee1ExactIn;
        uint256 exactOutDiscountPercent = ((fee1ExactOut - fee2ExactOut) * 10000) / fee1ExactOut;
        
        console2.log("ExactIn discount %:", exactInDiscountPercent);
        console2.log("ExactOut discount %:", exactOutDiscountPercent);
        
        // Allow small rounding differences (within 1%)
        assertApproxEqRel(exactInDiscountPercent, exactOutDiscountPercent, 0.01e18, "discount percentages should be similar");
    }

    function test_MultiUserDifferentDiscountsSwapFee() public {
        // We'll test discounts for both exactIn and exactOut
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

        // Discover mapping base slot for origin key
        uint256 baseSlot = _discoverFeeDiscountBaseSlot(address(vipHook), originAddr, 777);
        require(baseSlot != type(uint256).max, "mapping slot not found");

        // Test exactIn swaps
        console2.log("=== Testing exactIn multi-user discounts ===");
        uint24[4] memory exactInFees;
        for (uint i = 0; i < discounts.length; i++) {
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
                    amountSpecified: int256(swapAmount), // exactIn
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                abi.encode(0)
            );
            Vm.Log[] memory logsI = vm.getRecordedLogs();
            uint24 feeI = _extractSwapFee(logsI);
            require(feeI != 0, "no exactIn fee");
            exactInFees[i] = feeI;
        }

        // Test exactOut swaps
        console2.log("=== Testing exactOut multi-user discounts ===");
        uint24[4] memory exactOutFees;
        for (uint i = 0; i < discounts.length; i++) {
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
                    amountSpecified: -int256(swapAmount / 2), // exactOut
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                abi.encode(0)
            );
            Vm.Log[] memory logsI = vm.getRecordedLogs();
            uint24 feeI = _extractSwapFee(logsI);
            require(feeI != 0, "no exactOut fee");
            exactOutFees[i] = feeI;
        }

        // Test exactIn fee assertions
        console2.log("ExactIn fees - 0%:", exactInFees[0]);
        console2.log("ExactIn fees - 10%:", exactInFees[1]);
        console2.log("ExactIn fees - 30%:", exactInFees[2]);
        console2.log("ExactIn fees - 50%:", exactInFees[3]);
        
        uint24 exp30ExactIn = uint24(uint256(exactInFees[0]) * 7000 / 10000);
        assertEq(exactInFees[2], exp30ExactIn, "exactIn 30% discounted fee mismatch");
        uint24 exp50ExactIn = uint24(uint256(exactInFees[0]) * 5000 / 10000);
        assertEq(exactInFees[3], exp50ExactIn, "exactIn 50% discounted fee mismatch");
        
        assertLe(exactInFees[1], exactInFees[0], "exactIn 10% should be <= base");
        assertGe(exactInFees[1], exactInFees[3], "exactIn 10% should be >= 50% fee");
        assertLe(exactInFees[2], exactInFees[1], "exactIn 30% <= 10%");
        assertLe(exactInFees[3], exactInFees[2], "exactIn 50% <= 30%");

        // Test exactOut fee assertions
        console2.log("ExactOut fees - 0%:", exactOutFees[0]);
        console2.log("ExactOut fees - 10%:", exactOutFees[1]);
        console2.log("ExactOut fees - 30%:", exactOutFees[2]);
        console2.log("ExactOut fees - 50%:", exactOutFees[3]);
        
        uint24 exp30ExactOut = uint24(uint256(exactOutFees[0]) * 7000 / 10000);
        assertEq(exactOutFees[2], exp30ExactOut, "exactOut 30% discounted fee mismatch");
        uint24 exp50ExactOut = uint24(uint256(exactOutFees[0]) * 5000 / 10000);
        assertEq(exactOutFees[3], exp50ExactOut, "exactOut 50% discounted fee mismatch");
        
        assertLe(exactOutFees[1], exactOutFees[0], "exactOut 10% should be <= base");
        assertGe(exactOutFees[1], exactOutFees[3], "exactOut 10% should be >= 50% fee");
        assertLe(exactOutFees[2], exactOutFees[1], "exactOut 30% <= 10%");
        assertLe(exactOutFees[3], exactOutFees[2], "exactOut 50% <= 30%");

        // Verify that exactIn and exactOut discounts are consistent
        for (uint i = 0; i < discounts.length; i++) {
            if (discounts[i] > 0) {
                uint256 exactInDiscountPercent = ((exactInFees[0] - exactInFees[i]) * 10000) / exactInFees[0];
                uint256 exactOutDiscountPercent = ((exactOutFees[0] - exactOutFees[i]) * 10000) / exactOutFees[0];
                console2.log("Discount", discounts[i]);
                console2.log("ExactIn discount %:", exactInDiscountPercent);
                console2.log("ExactOut discount %:", exactOutDiscountPercent);
                // Allow small rounding differences (within 1%)
                assertApproxEqRel(exactInDiscountPercent, exactOutDiscountPercent, 0.01e18, "discount percentages should be consistent between exactIn/exactOut");
            }
        }
    }
} 