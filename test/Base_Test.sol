// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// - - - v4 core src deps - - -

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

// - - - v4 periphery src deps - - -

import {PositionManager} from "v4-periphery/PositionManager.sol";
import {V4Quoter} from "v4-periphery/lens/V4Quoter.sol";
import {PositionDescriptor} from "v4-periphery/PositionDescriptor.sol";

import {Deploy, IV4Quoter} from "../lib/v4-periphery/test/shared/Deploy.sol";

// - - - v4-periphery - - -

import {PosmTestSetup} from "../lib/v4-periphery/test/shared/PosmTestSetup.sol";
import {PositionConfig} from "../lib/v4-periphery/test/shared/PositionConfig.sol";
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";

// - - - solmate - - -

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// Import project contracts

import {VipDFMHook} from "src/VipDFMHook.sol";
import {FullRangeLiquidityManager} from "aegis-dfm/FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "aegis-dfm/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "aegis-dfm/TruncGeoOracleMulti.sol";
import {DynamicFeeManager} from "aegis-dfm/DynamicFeeManager.sol";

// - - - local test helpers - - -

import {MainUtils} from "./utils/MainUtils.sol";

abstract contract Base_Test is PosmTestSetup, MainUtils {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint256 constant MIN_REINVEST_AMOUNT = 1e4;

    /// @dev Constant for the minimum locked liquidity per position
    uint256 constant MIN_LOCKED_LIQUIDITY = 1000;

    /// @notice Cooldown period between reinvestments (default: 1 day)
    uint256 constant REINVEST_COOLDOWN = 1 days;

    uint24 constant DEFAULT_MANUAL_FEE = 3_000; // 0.3%

    // Test accounts
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    // v4 periphery
    IV4Quoter quoter;

    // Contract instances
    PoolPolicyManager policyManager;
    TruncGeoOracleMulti oracle;
    DynamicFeeManager feeManager;
    FullRangeLiquidityManager liquidityManager;
    VipDFMHook vipHook;

    // Brevis integration
    address brevisRequest = makeAddr("brevisRequest");
    bytes32 vkHash = keccak256("testVkHash");

    // Test variables
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public virtual {
        // Use PosmTestSetup to deploy core infrastructure
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployPosmHookSavesDelta(); // Deploy the hook that saves deltas for testing
        deployAndApprovePosm(manager); // This deploys PositionManager with proper setup
        quoter = Deploy.v4Quoter(address(manager), hex"00");

        // Create the policy manager with proper parameters
        vm.startPrank(owner);
        // Constructor(governance, dailyBudget, minTradingFee, maxTradingFee)
        policyManager = new PoolPolicyManager(owner, 1_000_000);
        vm.stopPrank();

        // Get the current nonce after all PosmTestSetup deployments
        // PosmTestSetup deploys: PoolManager, 8 routers, 2 tokens, HookSavesDelta, 
        // Permit2, WETH, PositionDescriptor, Proxy, PositionManager, V4Quoter = 18 contracts
        uint256 currentNonce = vm.getNonce(owner);
        uint256 adjustedNonce = currentNonce + 18; // Account for the 18 contracts from PosmTestSetup

        // Define the permissions for VipDFMHook (same as Spot)
        uint160 vipHookFlags = permissionsToFlags(
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );

        // Predict addresses for dependencies to construct VipDFMHook creation code for mining
        uint256 nonceOwnerBefore = vm.getNonce(owner);
        address predictedOracle = vm.computeCreateAddress(owner, nonceOwnerBefore);
        address predictedFeeManager = vm.computeCreateAddress(owner, nonceOwnerBefore + 1);
        address predictedLiquidityManager = vm.computeCreateAddress(owner, nonceOwnerBefore + 2);

        // Find a CREATE2 salt and hook address that matches permissions with final constructor args
        (address minedHookAddress, bytes32 salt) = HookMiner.find(
            owner,
            vipHookFlags,
            type(VipDFMHook).creationCode,
            abi.encode(
                manager,
                predictedLiquidityManager,
                policyManager,
                TruncGeoOracleMulti(predictedOracle),
                DynamicFeeManager(predictedFeeManager),
                brevisRequest
            )
        );

        vm.startPrank(owner);
        // Deploy dependencies wired to the mined hook address in the same order as predicted
        oracle = new TruncGeoOracleMulti(manager, policyManager, minedHookAddress, owner);
        feeManager = new DynamicFeeManager(owner, policyManager, address(oracle), minedHookAddress);
        liquidityManager = new FullRangeLiquidityManager(
            manager,
            PositionManager(payable(address(lpm))),
            oracle,
            minedHookAddress
        );

        // Now deploy the VipDFMHook at the mined address using CREATE2 with the same constructor args
        vipHook = new VipDFMHook{salt: salt}(manager, liquidityManager, policyManager, oracle, feeManager, brevisRequest);
        vm.stopPrank();

        // No init call; constructor already set owner and brevis request

        // Set the authorized hook in policy manager so VipDFMHook can call initializeBaseFeeBounds
        vm.prank(owner);
        policyManager.setAuthorizedHook(address(vipHook));

        // Initialize the pool with the VipDFMHook
        poolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60, // tick spacing
            IHooks(address(vipHook))
        );

        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Set POL share to enable protocol fees (20% of swap fees go to protocol)
        vm.prank(owner);
        policyManager.setPoolPOLShare(poolId, 200_000); // 20% in PPM (parts per million)

        // Fund user accounts using the helper from PosmTestSetup
        seedBalance(user1);
        seedBalance(user2);
        seedBalance(owner);

        // Approve tokens for users
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), type(uint256).max);
        vm.stopPrank();

        // Use the PosmTestSetup approvePosmFor helper to approve for PositionManager
        approvePosmFor(owner);
        vm.stopPrank();

        // Instead of using spot.depositToFRLM, add full range liquidity directly with PositionManager
        // Add initial liquidity via PositionManager directly
        vm.startPrank(owner);

        // Calculate the full range tick boundaries
        int24 minTick = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint256 positionId = lpm.nextTokenId();

        // Create mint params - add much liquidity to the full range position
        // Use the mint helper from PosmTestSetup (LiquidityOperations)
        mint(
            PositionConfig({poolKey: poolKey, tickLower: minTick, tickUpper: maxTick}),
            100000 ether, // liquidity amount
            owner, // recipient
            "" // hookData
        );

        // Verify position was created
        assertGt(positionId, 0, "Position creation failed");

        // Get the position's liquidity to verify it was created with non-zero liquidity
        uint128 liquidity = lpm.getPositionLiquidity(positionId);
        assertGt(liquidity, 0, "Position has no liquidity");
        vm.stopPrank();
    }
}

// Simple test to debug the issue
contract BaseTestDebug is Base_Test {
    function test_debug() public {
        // This test should pass if setup works
        assertEq(address(vipHook), address(vipHook), "Hook address should match itself");
    }
}
