// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ForkTestHelper } from "./helpers/ForkTestHelper.sol";

contract SplitRiskPoolForkTest is ForkTestHelper {
    function testSepoliaForkInitializes() public {
        string memory forkUrl = _forkUrlOrSkip("SEPOLIA_RPC_URL", "Sepolia");
        if (bytes(forkUrl).length == 0) {
            return;
        }

        uint256 forkId = vm.createSelectFork(forkUrl);
        vm.selectFork(forkId);
        assertGt(block.number, 0, "fork should have a positive block height");
    }
}
