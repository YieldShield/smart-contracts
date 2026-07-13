// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";

abstract contract ForkTestHelper is Test {
    error ForkRpcUrlRequired(string envName);

    function _forkUrlOrSkip(string memory envName, string memory networkName) internal returns (string memory) {
        bool required = vm.envOr("FORK_TESTS_REQUIRED", false);
        bool enabled = vm.envOr("FORK_TESTS_ENABLED", required);
        if (!enabled) {
            vm.skip(true, string.concat(networkName, " fork tests not enabled"));
            return "";
        }

        string memory forkUrl = vm.envOr(envName, string(""));
        if (bytes(forkUrl).length != 0) {
            return forkUrl;
        }

        if (required) {
            revert ForkRpcUrlRequired(envName);
        }

        vm.skip(true, string.concat(networkName, " fork RPC not configured"));
        return "";
    }
}
