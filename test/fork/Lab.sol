// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Test-only stand-in for "vault + pool controller" during Phase 1 experiments. It deliberately has a generic
///      `exec`: the experiments measure what FWA and Checks allow, not what our protocol should permit. Production
///      contracts never get a generic call.
contract Lab {
    address public immutable tester;

    constructor() {
        tester = msg.sender;
    }

    function exec(address target, bytes calldata data) external payable returns (bytes memory out) {
        require(msg.sender == tester, "Lab: tester only");
        bool ok;
        (ok, out) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(out, 32), mload(out))
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
