// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {TransparentUpgradeableProxy} from
    "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// create2 deploy TransparentUpgradeableProxy of OpenZeppelin 4.7
contract Deployer {
    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint256 constant MAX_LOOP = 1e18;
    // emit when new proxy is deployed
    event Deployed(address indexed addr, uint256 indexed salt);

    // start from startSalt, loop until find a valid salt
    function find(uint256 startSalt, uint160 flags, address logic, address admin, bytes memory data)
        public
        view
        returns (address, bytes32)
    {
        flags = flags & ALL_HOOK_MASK; // mask for only the bottom 14 bits
        bytes memory creationCodeWithArgs =
            abi.encodePacked(type(TransparentUpgradeableProxy).creationCode, abi.encode(logic,admin,data));
        address hookAddress;
        for (uint256 salt = startSalt; salt < MAX_LOOP; salt++) {
            hookAddress = computeAddress(address(this), salt, creationCodeWithArgs);

            // if the hook's bottom 14 bits match the desired flags AND the address does not have bytecode, we found a match
            if (uint160(hookAddress) & ALL_HOOK_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(salt));
            }
        }
        revert("HookMiner: could not find salt");
    }

    // deploy proxy and emit address
    function deploy(uint256 salt, address logic, address admin, bytes memory data) external returns (address) {
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy{salt: bytes32(salt)}(logic, admin, data);
        emit Deployed(address(proxy), salt);
        return address(proxy);
    }

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
