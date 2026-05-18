// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { Governor } from "@openzeppelin/contracts/governance/Governor.sol";
import { GovernorCountingSimple } from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import { GovernorSettings } from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import { GovernorVotes } from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import { GovernorTimelockControl } from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title YSGovernor
/// @author David Hawig
/// @notice YieldShield governance contract for protocol parameter management
contract YSGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /// @notice Minimum absolute quorum in votes (10,000 YS tokens)
    /// @dev Prevents governance capture when total supply is low
    uint256 public constant MIN_QUORUM_VOTES = 10_000 * 10 ** 18;

    constructor(IVotes _token, TimelockController _timelock)
        Governor("YSGovernor")
        GovernorSettings(
            86400, // initialVotingDelay (seconds) - 1 day
            432000, // initialVotingPeriod (seconds) - 5 days
            // M-15: raise propose threshold from 1k to 10k YS (1% of supply).
            // Makes flash-loan-propose prohibitively expensive if YS ever gets
            // listed on a lending market with a flash-loan path.
            10_000 * 10 ** 18
        )
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4) // 4% quorum
        GovernorTimelockControl(_timelock)
    { }

    /// @notice Returns the quorum for a given timepoint, enforcing a minimum floor
    /// @dev Uses the greater of the percentage-based quorum and the absolute minimum
    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        uint256 fractionQuorum = super.quorum(timepoint);
        return fractionQuorum > MIN_QUORUM_VOTES ? fractionQuorum : MIN_QUORUM_VOTES;
    }

    // Required overrides for multiple inheritance conflicts
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }
}
