pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/VipHook.sol";

contract Deploy is Script {
    string public deployConfigPath = string.concat("script/config/sepolia.json");
    function run() public {
        string memory config = vm.readFile(deployConfigPath);
        address pm = stdJson.readAddress(config, ".poolManager");
        address liqmgr = stdJson.readAddress(config, ".liquidityManager");
        address policyMgr = stdJson.readAddress(config, ".policyManager");
        address oracle = stdJson.readAddress(config, ".oracle");
        address dynFeeMgr = stdJson.readAddress(config, ".dynamicFeeManager");


        vm.startBroadcast();
        // uniswap v4 sepolia poolmgr addr
        VipHook hook = new VipHook(IPoolManager(pm), IFullRangeLiquidityManager(liqmgr), PoolPolicyManager(policyMgr), TruncGeoOracleMulti(oracle), IDynamicFeeManager(dynFeeMgr), address(0));
        console.log("Hook impl at ", address(hook));
        vm.stopBroadcast();
    }
}