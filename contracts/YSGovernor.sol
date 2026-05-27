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
import { YSTimelockController } from "./governance/YSTimelockController.sol";

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
    error GovernorTimelockImplementationMismatch(address candidate, bytes32 expectedCodehash, bytes32 actualCodehash);
    error GovernorTimelockInvalidRole(
        address candidate, bytes32 role, address expectedMember, address actualMember, uint256 memberCount
    );
    error GovernorTimelockInvalidInitialAdmin(
        address candidate, address expectedBootstrapAdmin, address actualMember, uint256 memberCount
    );
    error GovernorTimelockInvalidInitialController(address candidate, address controller);

    constructor(IVotes _token, TimelockController _timelock, address expectedBootstrapAdmin)
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
    {
        _validateInitialTimelock(_timelock, expectedBootstrapAdmin);
    }

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
        bytes32 expectedCodehash = address(timelock()).codehash;
        if (expectedCodehash != bytes32(0) && candidate.codehash != expectedCodehash) {
            revert GovernorTimelockImplementationMismatch(candidate, expectedCodehash, candidate.codehash);
        }

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

    function _validateInitialTimelock(TimelockController initialTimelock, address expectedBootstrapAdmin)
        internal
        view
    {
        address candidate = address(initialTimelock);
        if (candidate == address(0) || candidate.code.length == 0) revert GovernorInvalidTimelock(candidate);

        bytes32 expectedCodehash = keccak256(type(YSTimelockController).runtimeCode);
        if (candidate.codehash != expectedCodehash) {
            revert GovernorTimelockImplementationMismatch(candidate, expectedCodehash, candidate.codehash);
        }

        (bool success, bytes memory data) = candidate.staticcall(abi.encodeWithSelector(GET_MIN_DELAY_SELECTOR));
        if (!success || data.length < 32) revert GovernorInvalidTimelock(candidate);
        uint256 minDelay = abi.decode(data, (uint256));
        if (!_isLocalDevelopmentChain() && minDelay < MIN_GOVERNOR_TIMELOCK_DELAY) {
            revert GovernorTimelockDelayTooShort(candidate, minDelay, MIN_GOVERNOR_TIMELOCK_DELAY);
        }

        _validateInitialDefaultAdmin(candidate, expectedBootstrapAdmin);
        _validateInitialOperationalRoles(candidate);
    }

    function _validateInitialDefaultAdmin(address candidate, address expectedBootstrapAdmin) internal view {
        uint256 memberCount = _roleMemberCount(candidate, DEFAULT_ADMIN_ROLE_VALUE);
        if (memberCount == 1) {
            address onlyMember = _roleMemberAt(candidate, DEFAULT_ADMIN_ROLE_VALUE, 0);
            if (onlyMember != candidate) {
                revert GovernorTimelockInvalidRole(
                    candidate, DEFAULT_ADMIN_ROLE_VALUE, candidate, onlyMember, memberCount
                );
            }
            return;
        }

        if (memberCount == 2) {
            address firstMember = _roleMemberAt(candidate, DEFAULT_ADMIN_ROLE_VALUE, 0);
            address secondMember = _roleMemberAt(candidate, DEFAULT_ADMIN_ROLE_VALUE, 1);
            bool hasSelfAdmin = firstMember == candidate || secondMember == candidate;
            address bootstrapAdmin = firstMember == candidate ? secondMember : firstMember;
            if (hasSelfAdmin && bootstrapAdmin == expectedBootstrapAdmin) {
                return;
            }
            revert GovernorTimelockInvalidInitialAdmin(candidate, expectedBootstrapAdmin, bootstrapAdmin, memberCount);
        }

        revert GovernorTimelockInvalidInitialAdmin(candidate, expectedBootstrapAdmin, address(0), memberCount);
    }

    function _validateInitialOperationalRoles(address candidate) internal view {
        uint256 proposerCount = _roleMemberCount(candidate, PROPOSER_ROLE_VALUE);
        uint256 executorCount = _roleMemberCount(candidate, EXECUTOR_ROLE_VALUE);
        uint256 cancellerCount = _roleMemberCount(candidate, CANCELLER_ROLE_VALUE);
        if (proposerCount == 0 && executorCount == 0 && cancellerCount == 0) {
            return;
        }
        if (proposerCount != 1 || executorCount != 1 || cancellerCount != 1) {
            revert GovernorTimelockInvalidInitialController(candidate, address(0));
        }

        address controller = _roleMemberAt(candidate, PROPOSER_ROLE_VALUE, 0);
        if (
            controller == address(0) || controller.code.length == 0
                || _roleMemberAt(candidate, EXECUTOR_ROLE_VALUE, 0) != controller
                || _roleMemberAt(candidate, CANCELLER_ROLE_VALUE, 0) != controller
        ) {
            revert GovernorTimelockInvalidInitialController(candidate, controller);
        }
    }

    function _requireSoleRoleMember(address candidate, bytes32 role, address expectedMember) internal view {
        uint256 memberCount = _roleMemberCount(candidate, role);

        address actualMember = address(0);
        if (memberCount == 1) {
            actualMember = _roleMemberAt(candidate, role, 0);
        }

        if (memberCount != 1 || actualMember != expectedMember) {
            revert GovernorTimelockInvalidRole(candidate, role, expectedMember, actualMember, memberCount);
        }
    }

    function _roleMemberCount(address candidate, bytes32 role) internal view returns (uint256 memberCount) {
        (bool success, bytes memory data) =
            candidate.staticcall(abi.encodeWithSelector(GET_ROLE_MEMBER_COUNT_SELECTOR, role));
        if (!success || data.length < 32) revert GovernorInvalidTimelock(candidate);
        memberCount = abi.decode(data, (uint256));
    }

    function _roleMemberAt(address candidate, bytes32 role, uint256 index) internal view returns (address member) {
        (bool success, bytes memory data) =
            candidate.staticcall(abi.encodeWithSelector(GET_ROLE_MEMBER_SELECTOR, role, index));
        if (!success || data.length < 32) revert GovernorInvalidTimelock(candidate);
        member = abi.decode(data, (address));
    }

    function _isLocalDevelopmentChain() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }
}
