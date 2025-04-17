pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BrevisFee} from "../src/BrevisFeeVault.sol";

contract Deploy is Script {
    function run() public {
        vm.startBroadcast();
        BrevisFee fee = new BrevisFee();
        console.log("BrevisFee at ", address(fee));
        vm.stopBroadcast();
    }
}