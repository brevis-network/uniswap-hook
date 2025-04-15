// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// create2 deploy TransparentUpgradeableProxy of OpenZeppelin 4.7
contract Deployer {
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hookAddress)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)))))
        );
    }
}