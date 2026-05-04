// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";

contract SplitRiskPoolForkTest is Test {
    function testSepoliaForkInitializes() public {
        string memory forkUrl = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            emit log("Skipping fork test: SEPOLIA_RPC_URL not configured");
            return;
        }

        uint256 forkId = vm.createSelectFork(forkUrl);
        vm.selectFork(forkId);
        assertGt(block.number, 0, "fork should have a positive block height");
    }
}
