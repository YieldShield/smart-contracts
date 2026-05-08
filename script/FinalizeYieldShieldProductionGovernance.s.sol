// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { console } from "forge-std/console.sol";
import { YSToken } from "../contracts/YSToken.sol";
import { YSGovernor } from "../contracts/YSGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @notice Finalizes the production governance bootstrap once proposer voting power is live.
 * @dev Run this script from the bootstrap holder account after self-delegating enough YS
 *      to satisfy the governor proposal threshold.
 */
contract FinalizeYieldShieldProductionGovernance is ScaffoldETHDeploy {
    error BootstrapClockNotAdvanced(uint48 currentTimepoint);
    error BootstrapHolderVotesBelowThreshold(uint256 votes, uint256 threshold);
    error BootstrapHolderVotesBelowQuorum(uint256 votes, uint256 quorum);
    error BootstrapHolderMissingAdmin(address bootstrapHolder);
    error BootstrapFinalizerMustBeHolder(address broadcaster, address bootstrapHolder);
    error GovernorMissingTimelockRole(bytes32 role, address governor);
    error TimelockMissingSelfAdmin(address timelock);

    function getBootstrapProposalVotes(address bootstrapHolder, address ysTokenAddr, address governorAddr)
        public
        view
        returns (uint256 proposalVotes, uint256 proposalThreshold, uint256 quorumVotes, uint48 proposalTimepoint)
    {
        YSToken ysToken = YSToken(ysTokenAddr);
        YSGovernor governor = YSGovernor(payable(governorAddr));

        proposalThreshold = governor.proposalThreshold();
        uint48 currentTimepoint = governor.clock();
        if (currentTimepoint == 0) {
            revert BootstrapClockNotAdvanced(currentTimepoint);
        }

        proposalTimepoint = currentTimepoint - 1;
        proposalVotes = ysToken.getPastVotes(bootstrapHolder, proposalTimepoint);
        quorumVotes = governor.quorum(proposalTimepoint);
    }

    function run() external ScaffoldEthDeployerRunner {
        address bootstrapHolder = vm.envAddress("YS_PRODUCTION_BOOTSTRAP_HOLDER");
        if (deployer != bootstrapHolder) {
            revert BootstrapFinalizerMustBeHolder(deployer, bootstrapHolder);
        }

        address ysTokenAddr = vm.envAddress("YS_TOKEN_ADDRESS");
        address payable governorAddr = payable(vm.envAddress("YS_GOVERNOR_ADDRESS"));
        address timelockAddr = vm.envAddress("YS_TIMELOCK_ADDRESS");

        (uint256 bootstrapProposalVotes, uint256 proposalThreshold, uint256 quorumVotes, uint48 proposalTimepoint) =
            getBootstrapProposalVotes(bootstrapHolder, ysTokenAddr, governorAddr);
        TimelockController timelock = TimelockController(payable(timelockAddr));

        if (bootstrapProposalVotes < proposalThreshold) {
            revert BootstrapHolderVotesBelowThreshold(bootstrapProposalVotes, proposalThreshold);
        }
        if (bootstrapProposalVotes < quorumVotes) {
            revert BootstrapHolderVotesBelowQuorum(bootstrapProposalVotes, quorumVotes);
        }
        if (!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), bootstrapHolder)) {
            revert BootstrapHolderMissingAdmin(bootstrapHolder);
        }
        if (!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), timelockAddr)) {
            revert TimelockMissingSelfAdmin(timelockAddr);
        }
        _requireGovernorRole(timelock, timelock.PROPOSER_ROLE(), governorAddr);
        _requireGovernorRole(timelock, timelock.EXECUTOR_ROLE(), governorAddr);
        _requireGovernorRole(timelock, timelock.CANCELLER_ROLE(), governorAddr);

        console.log("Bootstrap proposal snapshot:", uint256(proposalTimepoint));
        console.log("Bootstrap proposer votes:", bootstrapProposalVotes / 1e18, "YS");
        console.log("Proposal threshold:", proposalThreshold / 1e18, "YS");
        console.log("Quorum:", quorumVotes / 1e18, "YS");
        console.log("Renouncing bootstrap timelock admin for:", bootstrapHolder);

        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), bootstrapHolder);
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), bootstrapHolder), "Bootstrap admin not cleared");

        deployments.push(Deployment("YSToken", ysTokenAddr));
        deployments.push(Deployment("TimelockController", timelockAddr));
        deployments.push(Deployment("YSGovernor", governorAddr));
    }

    function _requireGovernorRole(TimelockController timelock, bytes32 role, address governorAddr) internal view {
        if (!timelock.hasRole(role, governorAddr)) {
            revert GovernorMissingTimelockRole(role, governorAddr);
        }
    }
}
