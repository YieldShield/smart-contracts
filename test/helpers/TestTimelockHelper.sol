// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

abstract contract TestTimelockHelper {
    function _deployTestTimelock(address admin) internal returns (TimelockController timelock) {
        address[] memory emptyAccounts = new address[](0);
        timelock = new TimelockController(1 days, emptyAccounts, emptyAccounts, admin);
    }
}
