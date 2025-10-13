// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Base_Test} from "lib/AEGIS_DFM/test/revamped/Base_Test.sol";
import {VipHook} from "src/VipHook.sol";
import {FullRangeLiquidityManager} from "aegis-dfm/FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "aegis-dfm/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "aegis-dfm/TruncGeoOracleMulti.sol";
import {DynamicFeeManager} from "aegis-dfm/DynamicFeeManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";

contract SpotProxyDeployTest is Base_Test {
    function testVipHookImplementationAndProxyMining() public {
        Hooks.Permissions memory perms = Hooks.Permissions({
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
        });

        uint256 currentNonce = vm.getNonce(owner);
        address policyAddr = vm.computeCreateAddress(owner, currentNonce);
        address oracleAddr = vm.computeCreateAddress(owner, currentNonce + 1);
        address feeAddr = vm.computeCreateAddress(owner, currentNonce + 2);
        address liquidityAddr = vm.computeCreateAddress(owner, currentNonce + 3);
        console.log("precomputed addresses");
        console.log("  policy      :", policyAddr);
        console.log("  oracle      :", oracleAddr);
        console.log("  fee manager :", feeAddr);
        console.log("  liquidity   :", liquidityAddr);

        (address logicAddress, bytes32 logicSalt) = HookMiner.find(
            owner,
            permissionsToFlags(perms),
            type(VipHook).creationCode,
            abi.encode(manager, liquidityAddr, policyAddr, oracleAddr, feeAddr, address(0))
        );
        console.log("mined logic   :", logicAddress, "salt:", uint256(logicSalt));

        bytes memory initData = abi.encodeWithSelector(VipHook.init.selector, owner, address(0), bytes32(0));

        (address proxyAddress, bytes32 proxySalt) = HookMiner.find(
            owner,
            permissionsToFlags(perms),
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(logicAddress, owner, initData)
        );
        console.log("mined proxy   :", proxyAddress, "salt:", uint256(proxySalt));

        vm.startPrank(owner);
        PoolPolicyManager policy = new PoolPolicyManager(owner, 1_000_000);
        require(address(policy) == policyAddr, "policy addr mismatch");
        console.log("deployed policy      :", address(policy));

        TruncGeoOracleMulti oracle = new TruncGeoOracleMulti(manager, policy, proxyAddress, owner);
        require(address(oracle) == oracleAddr, "oracle addr mismatch");
        console.log("deployed oracle      :", address(oracle));

        DynamicFeeManager feeManager = new DynamicFeeManager(owner, policy, address(oracle), proxyAddress);
        require(address(feeManager) == feeAddr, "fee manager addr mismatch");
        console.log("deployed fee manager :", address(feeManager));

        FullRangeLiquidityManager liquidityManager = new FullRangeLiquidityManager(
            manager,
            PositionManager(payable(address(lpm))),
            oracle,
            proxyAddress
        );
        require(address(liquidityManager) == liquidityAddr, "liquidity manager addr mismatch");
        console.log("deployed liquidity   :", address(liquidityManager));

        VipHook vipLogic = new VipHook{salt: logicSalt}(
            manager,
            liquidityManager,
            policy,
            oracle,
            feeManager,
            address(0)
        );
        require(address(vipLogic) == logicAddress, "logic addr mismatch");
        console.log("deployed logic       :", address(vipLogic));

        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy{salt: proxySalt}(address(vipLogic), owner, initData);
        vm.stopPrank();

        assertEq(address(proxy), proxyAddress, "proxy addr mismatch");
        console.log("deployed proxy       :", address(proxy));
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 implValue = vm.load(address(proxy), implSlot);
        assertEq(address(uint160(uint256(implValue))), address(vipLogic), "implementation slot mismatch");

        assertEq(liquidityManager.authorizedHookAddress(), proxyAddress, "FRLM wiring mismatch");
        assertEq(feeManager.authorizedHook(), proxyAddress, "DFM wiring mismatch");
        assertEq(oracle.hook(), proxyAddress, "oracle hook mismatch");
        console.log("FRLM.authorizedHookAddress :", liquidityManager.authorizedHookAddress());
        console.log("DFM.authorizedHook         :", feeManager.authorizedHook());
        console.log("Oracle.hook                :", oracle.hook());
        console.log("authorizations OK");

        vm.prank(owner);
        policy.setAuthorizedHook(proxyAddress);
        assertEq(policy.authorizedHook(), proxyAddress, "policy authorized hook mismatch");
        console.log("PolicyManager.authorizedHook:", policy.authorizedHook());
        console.log("policy authorized hook set");

        // verify proxy-facing getters reflect deployed dependencies
        VipHook proxied = VipHook(address(proxy));
        assertEq(proxied.owner(), owner, "proxy owner mismatch");
        assertEq(proxied.brevisRequest(), address(0), "brevis request mismatch");
        assertEq(address(proxied.liquidityManager()), address(liquidityManager), "liquidity manager mismatch");
        assertEq(address(proxied.policyManager()), address(policy), "policy manager mismatch");
        assertEq(address(proxied.truncGeoOracle()), address(oracle), "oracle mismatch");
        assertEq(address(proxied.dynamicFeeManager()), address(feeManager), "fee manager mismatch");
        console.log("proxied getters verified");
    }
}
