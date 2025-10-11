pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";

import {VipHook} from "src/VipHook.sol";
import {PoolPolicyManager} from "aegis-dfm/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "aegis-dfm/TruncGeoOracleMulti.sol";
import {DynamicFeeManager} from "aegis-dfm/DynamicFeeManager.sol";
import {FullRangeLiquidityManager} from "aegis-dfm/FullRangeLiquidityManager.sol";
import {IFullRangeLiquidityManager} from "aegis-dfm/interfaces/IFullRangeLiquidityManager.sol";
import {IDynamicFeeManager} from "aegis-dfm/interfaces/IDynamicFeeManager.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract Deploy is Script {
    address constant CREATE2_FACTORY_ADDR = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    string public deployConfigPath = string.concat("script/config/sepolia.json");

    struct HookDeployConfig {
        address poolManager;
        address positionManager;
        address brevisRequest;
        address owner;
        uint256 dailyBudget;
        bytes32 initialVkHash;
    }

    struct DeploymentResult {
        address policyManager;
        address oracle;
        address feeManager;
        address liquidityManager;
        address vipHook;
        address proxy;
        bytes32 salt;
    }

    function run() public {
        string memory raw = vm.readFile(deployConfigPath);
        HookDeployConfig memory cfg;
        cfg.poolManager = vm.parseJsonAddress(raw, ".poolManager");
        cfg.positionManager = vm.parseJsonAddress(raw, ".positionManager");
        cfg.brevisRequest = vm.parseJsonAddress(raw, ".brevisRequest");
        cfg.owner = vm.parseJsonAddress(raw, ".owner");
        cfg.dailyBudget = vm.parseJsonUint(raw, ".dailyBudget");
        cfg.initialVkHash = vm.parseJsonBytes32(raw, ".initialVkHash");

        console.log("=== VipHook Deployment ===");
        console.log("PoolManager     :", cfg.poolManager);
        console.log("PositionManager :", cfg.positionManager);
        console.log("BrevisRequest   :", cfg.brevisRequest);
        console.log("Daily Budget    :", cfg.dailyBudget);

        vm.startBroadcast();
        DeploymentResult memory deployed = _deploy(cfg);
        vm.stopBroadcast();

        console.log("=== Deployment Complete ===");
        console.log("PoolPolicyManager      :", deployed.policyManager);
        console.log("TruncGeoOracleMulti    :", deployed.oracle);
        console.log("DynamicFeeManager      :", deployed.feeManager);
        console.log("FullRangeLiquidityMgr  :", deployed.liquidityManager);
        console.log("VipHook implementation :", deployed.vipHook);
        console.log("VipHook proxy          :", deployed.proxy);
        console.log("Proxy salt             :", vm.toString(deployed.salt));
    }

    function _deploy(HookDeployConfig memory cfg) internal returns (DeploymentResult memory deployed) {
        address deployer = msg.sender;
        address owner = cfg.owner == address(0) ? deployer : cfg.owner;
        uint256 nonce = vm.getNonce(deployer);

        address policyManagerAddress = vm.computeCreateAddress(deployer, nonce);
        address oracleAddress = vm.computeCreateAddress(deployer, nonce + 1);
        address feeManagerAddress = vm.computeCreateAddress(deployer, nonce + 2);
        address liquidityManagerAddress = vm.computeCreateAddress(deployer, nonce + 3);

        console.log("Precomputed PolicyManager   :", policyManagerAddress);
        console.log("Precomputed Oracle          :", oracleAddress);
        console.log("Precomputed FeeManager      :", feeManagerAddress);
        console.log("Precomputed LiquidityManager:", liquidityManagerAddress);

        uint160 flags = _vipHookFlags();
        (address vipHookLogicAddress, bytes32 logicSalt) = HookMiner.find(
            CREATE2_FACTORY_ADDR,
            flags,
            type(VipHook).creationCode,
            abi.encode(
                IPoolManager(cfg.poolManager),
                liquidityManagerAddress,
                policyManagerAddress,
                oracleAddress,
                feeManagerAddress,
                cfg.brevisRequest
            )
        );

        console.log("Mined VipHook logic    :", vipHookLogicAddress);
        console.log("Logic salt             :", vm.toString(logicSalt));

        bytes memory initData =
            abi.encodeWithSelector(VipHook.init.selector, owner, cfg.brevisRequest, cfg.initialVkHash);
        (address proxyAddress, bytes32 proxySalt) = HookMiner.find(
            CREATE2_FACTORY_ADDR,
            flags,
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(vipHookLogicAddress, deployer, initData)
        );

        console.log("Mined VipHook proxy    :", proxyAddress);
        console.log("Proxy salt             :", vm.toString(proxySalt));

        PoolPolicyManager policyManager = new PoolPolicyManager(deployer, cfg.dailyBudget);
        require(address(policyManager) == policyManagerAddress, "PoolPolicyManager address mismatch");
        console.log("PoolPolicyManager deployed");

        TruncGeoOracleMulti oracle =
            new TruncGeoOracleMulti(IPoolManager(cfg.poolManager), policyManager, proxyAddress, deployer);
        require(address(oracle) == oracleAddress, "Oracle address mismatch");
        console.log("TruncGeoOracleMulti deployed");

        DynamicFeeManager feeManager =
            new DynamicFeeManager(deployer, policyManager, address(oracle), proxyAddress);
        require(address(feeManager) == feeManagerAddress, "DynamicFeeManager address mismatch");
        console.log("DynamicFeeManager deployed");

        FullRangeLiquidityManager liquidityManager = new FullRangeLiquidityManager(
            IPoolManager(cfg.poolManager),
            PositionManager(payable(cfg.positionManager)),
            oracle,
            proxyAddress
        );
        require(address(liquidityManager) == liquidityManagerAddress, "LiquidityManager address mismatch");
        console.log("FullRangeLiquidityManager deployed");

        VipHook hook = new VipHook{salt: logicSalt}(
            IPoolManager(cfg.poolManager),
            liquidityManager,
            policyManager,
            oracle,
            feeManager,
            cfg.brevisRequest
        );
        require(address(hook) == vipHookLogicAddress, "VipHook logic address mismatch");
        console.log("VipHook deployed");

        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy{salt: proxySalt}(address(hook), deployer, initData);
        require(address(proxy) == proxyAddress, "Proxy address mismatch");
        console.log("Transparent proxy deployed");

        policyManager.setAuthorizedHook(proxyAddress);
        console.log("VipHook proxy authorized in PoolPolicyManager");

        require(policyManager.authorizedHook() == proxyAddress, "policy authorized hook mismatch");
        require(liquidityManager.authorizedHookAddress() == proxyAddress, "liquidity manager hook mismatch");

        deployed = DeploymentResult({
            policyManager: address(policyManager),
            oracle: address(oracle),
            feeManager: address(feeManager),
            liquidityManager: address(liquidityManager),
            vipHook: address(hook),
            proxy: proxyAddress,
            salt: proxySalt
        });
    }

    function _vipHookFlags() internal pure returns (uint160) {
        return Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }
}
