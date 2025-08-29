// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "forge-std/StdStorage.sol";

// Import our VipDFMHook contract with Brevis integration
import {VipDFMHook} from "../src/VipDFMHook.sol";

// Import V4 dependencies
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// Import test utilities
import {Base_Test} from "./Base_Test.sol";

contract VipDFMTest is Base_Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Test data for VIP discounts
    bytes32 public vkHash1 = keccak256("vk1");
    bytes32 public vkHash2 = keccak256("vk2");

    function setUp() public override {
        super.setUp();
        
        // Add VK hashes for testing as the hook owner
        address hookOwner = vipHook.owner();
        vm.startPrank(hookOwner);
        vipHook.addVkHash(vkHash1);
        vipHook.addVkHash(vkHash2);
        vm.stopPrank();
    }
    
    function test_vipDiscount_OnlyOwnerCanManageVkHashes() public {
        // Test that only the owner can manage VK hashes
        address nonOwner = makeAddr("nonOwner");
        bytes32 newVkHash = keccak256("newVkHash");
        
        // Should fail when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        vipHook.addVkHash(newVkHash);
        
        // Should succeed when called by owner
        address hookOwner = vipHook.owner();
        vm.prank(hookOwner);
        vipHook.addVkHash(newVkHash);
    }

    function test_vipDiscount_OnlyOwnerCanSetBrevisRequest() public {
        // Test that only the owner can set Brevis request address
        address nonOwner = makeAddr("nonOwner");
        address newBrevisRequest = makeAddr("newBrevisRequest");
        
        // Should fail when called by non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        vipHook.setBrevisRequest(newBrevisRequest);
        
        // Should succeed when called by owner
        address hookOwner = vipHook.owner();
        vm.prank(hookOwner);
        vipHook.setBrevisRequest(newBrevisRequest);
    }

    function _fundUser(address user, uint256 amount) internal {
        // Fund user with tokens
        MockERC20(Currency.unwrap(currency0)).mint(user, amount);
        MockERC20(Currency.unwrap(currency1)).mint(user, amount);
        
        // Approve tokens for swap router
        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _getBaseDynamicFee() internal view returns (uint24) {
        // Get the base dynamic fee from the fee manager
        (uint256 baseRaw, uint256 surgeRaw) = feeManager.getFeeState(poolId);
        uint24 base = uint24(baseRaw);
        uint24 surge = uint24(surgeRaw);
        return base + surge;
    }

    function _encodeBrevisOutput(uint256 requestId, address user, uint16 discount) internal pure returns (bytes memory) {
        // Encode Brevis output: epoch (4 bytes) | user (20 bytes) | discount (2 bytes)
        return bytes.concat(bytes4(uint32(requestId)), bytes20(user), bytes2(discount));
    }
}