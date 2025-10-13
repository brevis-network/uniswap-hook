// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract BrevisApp {
    address public brevisRequest;
    uint256 public opChallengeWindow;

    modifier onlyBrevisRequest() {
        require(msg.sender == brevisRequest, "invalid caller");
        _;
    }

    constructor(address _brevisRequest) {
        brevisRequest = _brevisRequest;
        _setOpChallengeWindow(2 ** 256 - 1); // disable usage of op result by default
    }

    function handleProofResult(bytes32 _vkHash, bytes calldata _appCircuitOutput) internal virtual {
        // to be overrided by custom app
    }

    function handleOpProofResult(bytes32 _vkHash, bytes calldata _appCircuitOutput) internal virtual {
        // to be overrided by custom app
    }

    // app contract can implement logics to set opChallengeWindow if needed
    function _setOpChallengeWindow(uint256 _challangeWindow) internal {
        opChallengeWindow = _challangeWindow;
    }

    // app contract can implement logics to update brevisRequest address if needed
    function _setBrevisRequest(address _brevisRequest) internal {
        brevisRequest = _brevisRequest;
    }

    function brevisCallback(bytes32 _appVkHash, bytes calldata _appCircuitOutput) external onlyBrevisRequest {
        handleProofResult(_appVkHash, _appCircuitOutput);
    }

    function brevisBatchCallback(
        bytes32[] calldata _appVkHashes,
        bytes[] calldata _appCircuitOutputs
    ) external onlyBrevisRequest {
        for (uint i = 0; i < _appVkHashes.length; i++) {
            handleProofResult(_appVkHashes[i], _appCircuitOutputs[i]);
        }
    }
}