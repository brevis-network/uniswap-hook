// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {Base_Test} from "test/Base_Test.sol";
import {VipHook} from "src/VipHook.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

contract GetFeeTest is Base_Test {
    
    // Storage slot for feeDiscount mapping (detected at runtime to avoid brittleness)
    uint256 private feeDiscountSlot;
    
    function setUp() public override {
        super.setUp();
        feeDiscountSlot = _calibrateFeeDiscountSlot();
    }

    function test_GetFee_NoDiscount() public {
        address user = makeAddr("userNoDiscount");
        
        // Get the fee for user with no discount
        uint24 fee = vipHook.getFee(user, poolId);
        
        // Fee should be greater than 0
        assertGt(fee, 0, "Fee should be greater than 0");
        
        console2.log("Fee with no discount:", fee);
    }

    function test_GetFee_WithDiscount() public {
        address user = makeAddr("userWithDiscount");
        uint16 discount = 3000; // 30% discount
        
        // Set discount using storage manipulation
        _setDiscount(user, discount);
        
        // Get fee with no discount (different user)
        address userNoDiscount = makeAddr("userNoDiscount");
        uint24 feeNoDiscount = vipHook.getFee(userNoDiscount, poolId);
        
        // Get fee with discount
        uint24 feeWithDiscount = vipHook.getFee(user, poolId);
        
        // Fee with discount should be less than fee without discount
        assertLt(feeWithDiscount, feeNoDiscount, "Discounted fee should be less");
        
        // Calculate expected discount
        uint256 expectedFee = uint256(feeNoDiscount) * (10000 - discount) / 10000;
        assertEq(feeWithDiscount, uint24(expectedFee), "Fee should match expected discount");
        
        console2.log("Fee without discount:", feeNoDiscount);
        console2.log("Fee with 30% discount:", feeWithDiscount);
        console2.log("Discount amount:", feeNoDiscount - feeWithDiscount);
    }

    function test_GetFee_MultipleDiscountLevels() public {
        // Test multiple discount levels
        uint16[4] memory discounts = [uint16(0), uint16(1000), uint16(5000), uint16(9000)];
        address[4] memory users;
        uint24[4] memory fees;
        
        // Create users and set discounts
        for (uint i = 0; i < discounts.length; i++) {
            users[i] = makeAddr(string.concat("user", vm.toString(i)));
            
            if (discounts[i] > 0) {
                _setDiscount(users[i], discounts[i]);
            }
            
            fees[i] = vipHook.getFee(users[i], poolId);
        }
        
        // Verify fees decrease with higher discounts
        assertGt(fees[0], fees[1], "0% should be > 10%");
        assertGt(fees[1], fees[2], "10% should be > 50%");
        assertGt(fees[2], fees[3], "50% should be > 90%");
        
        console2.log("=== Fee Comparison ===");
        console2.log("0% discount fee:", fees[0]);
        console2.log("10% discount fee:", fees[1]);
        console2.log("50% discount fee:", fees[2]);
        console2.log("90% discount fee:", fees[3]);
    }

    function test_GetFee_MaxDiscount() public {
        address user = makeAddr("vipUser");
        uint16 maxDiscount = 10000; // 100% discount
        
        // Set max discount
        _setDiscount(user, maxDiscount);
        
        // Get fee with max discount
        uint24 fee = vipHook.getFee(user, poolId);
        
        // Fee should be 0 with 100% discount
        assertEq(fee, 0, "Fee should be 0 with 100% discount");
        
        console2.log("Fee with 100% discount:", fee);
    }

    function test_GetFee_WithManualFee() public {
        address user = makeAddr("userManualFee");
        uint16 discount = 2000; // 20% discount
        uint24 manualFee = 5000; // 0.5% manual fee
        
        // Set manual fee for the pool
        vm.prank(owner);
        policyManager.setManualFee(poolId, manualFee);
        
        // Set discount for user
        _setDiscount(user, discount);
        
        // Get fee (should use manual fee with discount)
        uint24 fee = vipHook.getFee(user, poolId);
        
        // Calculate expected fee
        uint256 expectedFee = uint256(manualFee) * (10000 - discount) / 10000;
        assertEq(fee, uint24(expectedFee), "Fee should be manual fee with discount applied");
        
        console2.log("Manual fee:", manualFee);
        console2.log("Discount:", discount);
        console2.log("Final fee:", fee);
        console2.log("Expected fee:", expectedFee);
    }

    function test_GetFee_DifferentUsers() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");
        
        // Set different discounts for different users
        _setDiscount(user1, 1000); // 10%
        _setDiscount(user2, 3000); // 30%
        _setDiscount(user3, 5000); // 50%
        
        uint24 fee1 = vipHook.getFee(user1, poolId);
        uint24 fee2 = vipHook.getFee(user2, poolId);
        uint24 fee3 = vipHook.getFee(user3, poolId);
        
        assertGt(fee1, fee2, "10% discount should have higher fee than 30%");
        assertGt(fee2, fee3, "30% discount should have higher fee than 50%");
        
        console2.log("User1 (10% discount) fee:", fee1);
        console2.log("User2 (30% discount) fee:", fee2);
        console2.log("User3 (50% discount) fee:", fee3);
    }

    function test_GetFee_CompareBaseFeeAndDiscounted() public {
        address regularUser = makeAddr("regularUser");
        address vipUser = makeAddr("vipUser");
        
        // VIP user gets 40% discount
        _setDiscount(vipUser, 4000);
        
        uint24 baseFee = vipHook.getFee(regularUser, poolId);
        uint24 vipFee = vipHook.getFee(vipUser, poolId);
        
        // VIP fee should be 60% of base fee
        uint256 expectedVipFee = uint256(baseFee) * 6000 / 10000;
        assertEq(vipFee, uint24(expectedVipFee), "VIP fee should be 60% of base");
        
        console2.log("Base fee:", baseFee);
        console2.log("VIP fee (40% off):", vipFee);
        console2.log("Savings:", baseFee - vipFee);
    }

    function test_GetFee_FuzzDiscounts(uint16 discount) public {
        // Fuzz test with various discount values
        vm.assume(discount <= 10000); // Max discount is 100%
        
        address user = makeAddr("fuzzUser");
        
        // Set discount
        _setDiscount(user, discount);
        
        // Get base fee (no discount)
        uint24 baseFee = vipHook.getFee(makeAddr("baseUser"), poolId);
        
        // Get discounted fee
        uint24 discountedFee = vipHook.getFee(user, poolId);
        
        // Calculate expected fee
        uint256 expectedFee = uint256(baseFee) * (10000 - discount) / 10000;
        
        assertEq(discountedFee, uint24(expectedFee), "Fuzz: Fee should match expected discount");
        assertLe(discountedFee, baseFee, "Fuzz: Discounted fee should be <= base fee");
    }

    // Helper function to set discount using storage manipulation
    function _setDiscount(address user, uint16 discount) internal {
        bytes32 slot = keccak256(abi.encode(user, feeDiscountSlot));
        vm.store(address(vipHook), slot, bytes32(uint256(discount)));
    }

    // Detect the correct base slot for the feeDiscount mapping by probing storage
    function _calibrateFeeDiscountSlot() internal returns (uint256) {
        address probe = makeAddr("probeUser");
        uint24 baseFee = vipHook.getFee(probe, poolId);
        uint16 testDiscount = 9000; // expect ~10% of base
        uint256 expected = uint256(baseFee) * (10000 - testDiscount) / 10000;

        // Search a bounded range of slots; adjust if storage layout grows significantly
        for (uint256 s = 0; s < 256; s++) {
            bytes32 key = keccak256(abi.encode(probe, s));
            // write
            vm.store(address(vipHook), key, bytes32(uint256(testDiscount)));
            uint24 got = vipHook.getFee(probe, poolId);
            // revert write
            vm.store(address(vipHook), key, bytes32(uint256(0)));
            if (got == uint24(expected)) {
                return s;
            }
        }
        revert("feeDiscount slot not found");
    }
}
