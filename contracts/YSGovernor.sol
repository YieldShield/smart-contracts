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
    uint48 public constant MIN_GOVERNOR_VOTING_DELAY = 1 days;
    uint48 public constant MAX_GOVERNOR_VOTING_DELAY = 7 days;
    uint32 public constant MIN_GOVERNOR_VOTING_PERIOD = 5 days;
    uint32 public constant MAX_GOVERNOR_VOTING_PERIOD = 30 days;
    uint256 public constant MIN_GOVERNOR_PROPOSAL_THRESHOLD = 10_000 * 10 ** 18;
    uint256 public constant MAX_GOVERNOR_PROPOSAL_THRESHOLD = 100_000 * 10 ** 18;
    uint256 public constant MIN_GOVERNOR_TIMELOCK_DELAY = 2 days;

    bytes4 private constant GET_MIN_DELAY_SELECTOR = bytes4(keccak256("getMinDelay()"));
    bytes4 private constant GET_ROLE_MEMBER_COUNT_SELECTOR = bytes4(keccak256("getRoleMemberCount(bytes32)"));
    bytes4 private constant GET_ROLE_MEMBER_SELECTOR = bytes4(keccak256("getRoleMember(bytes32,uint256)"));
    bytes32 private constant DEFAULT_ADMIN_ROLE_VALUE = 0x00;
    bytes32 private constant PROPOSER_ROLE_VALUE = keccak256("PROPOSER_ROLE");
    bytes32 private constant EXECUTOR_ROLE_VALUE = keccak256("EXECUTOR_ROLE");
    bytes32 private constant CANCELLER_ROLE_VALUE = keccak256("CANCELLER_ROLE");

    error GovernorVotingDelayOutOfRange(uint48 provided, uint48 minimum, uint48 maximum);
    error GovernorVotingPeriodOutOfRange(uint32 provided, uint32 minimum, uint32 maximum);
    error GovernorProposalThresholdOutOfRange(uint256 provided, uint256 minimum, uint256 maximum);
    error GovernorInvalidTimelock(address candidate);
    error GovernorTimelockDelayTooShort(address candidate, uint256 provided, uint256 minimum);
    error GovernorTimelockInvalidRole(
        address candidate, bytes32 role, address expectedMember, address actualMember, uint256 memberCount
    );

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

    function setVotingDelay(uint48 newVotingDelay) public override onlyGovernance {
        if (newVotingDelay < MIN_GOVERNOR_VOTING_DELAY || newVotingDelay > MAX_GOVERNOR_VOTING_DELAY) {
            revert GovernorVotingDelayOutOfRange(newVotingDelay, MIN_GOVERNOR_VOTING_DELAY, MAX_GOVERNOR_VOTING_DELAY);
        }
        _setVotingDelay(newVotingDelay);
    }

    function setVotingPeriod(uint32 newVotingPeriod) public override onlyGovernance {
        if (newVotingPeriod < MIN_GOVERNOR_VOTING_PERIOD || newVotingPeriod > MAX_GOVERNOR_VOTING_PERIOD) {
            revert GovernorVotingPeriodOutOfRange(
                newVotingPeriod, MIN_GOVERNOR_VOTING_PERIOD, MAX_GOVERNOR_VOTING_PERIOD
            );
        }
        _setVotingPeriod(newVotingPeriod);
    }

    function setProposalThreshold(uint256 newProposalThreshold) public override onlyGovernance {
        if (
            newProposalThreshold < MIN_GOVERNOR_PROPOSAL_THRESHOLD
                || newProposalThreshold > MAX_GOVERNOR_PROPOSAL_THRESHOLD
        ) {
            revert GovernorProposalThresholdOutOfRange(
                newProposalThreshold, MIN_GOVERNOR_PROPOSAL_THRESHOLD, MAX_GOVERNOR_PROPOSAL_THRESHOLD
            );
        }
        _setProposalThreshold(newProposalThreshold);
    }

    function updateTimelock(TimelockController newTimelock) public override {
        _validateReplacementTimelock(newTimelock);
        super.updateTimelock(newTimelock);
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

    function _validateReplacementTimelock(TimelockController newTimelock) internal view {
        address candidate = address(newTimelock);
        if (candidate == address(0) || candidate.code.length == 0) revert GovernorInvalidTimelock(candidate);

        (bool success, bytes memory data) = candidate.staticcall(abi.encodeWithSelector(GET_MIN_DELAY_SELECTOR));
        if (!success || data.length < 32) revert GovernorInvalidTimelock(candidate);
        uint256 minDelay = abi.decode(data, (uint256));
        if (!_isLocalDevelopmentChain() && minDelay < MIN_GOVERNOR_TIMELOCK_DELAY) {
            revert GovernorTimelockDelayTooShort(candidate, minDelay, MIN_GOVERNOR_TIMELOCK_DELAY);
        }

        _requireSoleRoleMember(candidate, DEFAULT_ADMIN_ROLE_VALUE, candidate);
        _requireSoleRoleMember(candidate, PROPOSER_ROLE_VALUE, address(this));
        _requireSoleRoleMember(candidate, EXECUTOR_ROLE_VALUE, address(this));
        _requireSoleRoleMember(candidate, CANCELLER_ROLE_VALUE, address(this));
    }

    function _requireSoleRoleMember(address candidate, bytes32 role, address expectedMember) internal view {
        (bool success, bytes memory data) =
            candidate.staticcall(abi.encodeWithSelector(GET_ROLE_MEMBER_COUNT_SELECTOR, role));
        if (!success || data.length < 32) revert GovernorInvalidTimelock(candidate);
        uint256 memberCount = abi.decode(data, (uint256));

        address actualMember = address(0);
        if (memberCount == 1) {
            (success, data) = candidate.staticcall(abi.encodeWithSelector(GET_ROLE_MEMBER_SELECTOR, role, uint256(0)));
            if (!success || data.length < 32) revert GovernorInvalidTimelock(candidate);
            actualMember = abi.decode(data, (address));
        }

        if (memberCount != 1 || actualMember != expectedMember) {
            revert GovernorTimelockInvalidRole(candidate, role, expectedMember, actualMember, memberCount);
        }
    }

    function _isLocalDevelopmentChain() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }
}
