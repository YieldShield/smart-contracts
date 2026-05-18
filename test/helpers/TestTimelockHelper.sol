// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { YSTimelockController } from "../../contracts/governance/YSTimelockController.sol";

abstract contract TestTimelockHelper {
    /// @dev Deploys a timelock that already satisfies the H-8 invariant: the
    ///      only DEFAULT_ADMIN_ROLE holder is the timelock itself. This means
    ///      tests cannot reach back to grant arbitrary roles via the admin
    ///      account; use schedule/execute through the timelock instead.
    function _deployTestTimelock(
        address /* admin */
    )
        internal
        returns (TimelockController timelock)
    {
        address[] memory emptyAccounts = new address[](0);
        // Deploy with `address(this)` (the caller test contract) as the
        // bootstrap admin, then immediately renounce so the helper returns
        // a timelock whose only admin is itself.
        YSTimelockController ts = new YSTimelockController(1 days, emptyAccounts, emptyAccounts, address(this));
        ts.renounceRole(ts.DEFAULT_ADMIN_ROLE(), address(this));
        timelock = TimelockController(payable(address(ts)));
    }
}
