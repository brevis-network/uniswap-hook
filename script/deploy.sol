pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Deployer} from "../src/Deployer.sol";

contract Deploy is Script {
    function run() public {
        vm.startBroadcast();
        Deployer dep = new Deployer();
        console.log("Deployer at ", address(dep));
        vm.stopBroadcast();
    }
}