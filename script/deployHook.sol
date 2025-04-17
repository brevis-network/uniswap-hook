pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {VipHook,IPoolManager} from "../src/VipHook.sol";

contract Deploy is Script {
    string public deployConfigPath = string.concat("script/config/sepolia.json");
    function run() public {
        string memory config = vm.readFile(deployConfigPath);
        address pm = stdJson.readAddress(config, ".poolManager");

        vm.startBroadcast();
        // uniswap v4 sepolia poolmgr addr
        VipHook hook = new VipHook(IPoolManager(pm), 0, address(0));
        console.log("Hook impl at ", address(hook));
        vm.stopBroadcast();
    }
}