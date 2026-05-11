// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { YSToken } from "../contracts/YSToken.sol";
import { YSGovernor } from "../contracts/YSGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { FinalizeYieldShieldProductionGovernance } from "../script/FinalizeYieldShieldProductionGovernance.s.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";

contract DeploymentSecurityTest is Test, FactoryProxyTestBase {
    uint256 internal constant TIMELOCK_DELAY = 2 days;

    address internal deployer = address(this);
    address internal bootstrapHolder = address(0xB0057);
    address internal dummyPyth = address(0x1234);

    function test_ProductionBootstrap_AssignsSupplyAndClearsExternalAdmins() public {
        (YSToken ysToken, TimelockController timelock, YSGovernor governor) = _deployGovernance();

        assertEq(ysToken.balanceOf(bootstrapHolder), ysToken.INITIAL_SUPPLY());
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), bootstrapHolder));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
    }

    function test_ProductionBootstrap_CanReachProposalThresholdAfterDelegation() public {
        (YSToken ysToken,, YSGovernor governor) = _deployGovernance();

        vm.prank(bootstrapHolder);
        ysToken.delegate(bootstrapHolder);
        vm.warp(block.timestamp + 1);

        assertGe(ysToken.getVotes(bootstrapHolder), governor.proposalThreshold());
    }

    function test_ProductionBootstrap_FinalizerRequiresPastVotesCheckpoint() public {
        (YSToken ysToken,, YSGovernor governor) = _deployGovernance();
        FinalizeYieldShieldProductionGovernance finalizer = new FinalizeYieldShieldProductionGovernance();

        vm.prank(bootstrapHolder);
        ysToken.delegate(bootstrapHolder);

        assertGe(ysToken.getVotes(bootstrapHolder), governor.proposalThreshold());

        (uint256 proposalVotes, uint256 proposalThreshold,,) =
            finalizer.getBootstrapProposalVotes(bootstrapHolder, address(ysToken), address(governor));

        assertLt(proposalVotes, proposalThreshold, "finalizer should wait for a past-vote checkpoint");
    }

    function test_ProductionBootstrap_AdminCanBeRenouncedAfterPastVotesCheckpoint() public {
        (YSToken ysToken, TimelockController timelock, YSGovernor governor) = _deployGovernanceWithBootstrapAdmin();
        FinalizeYieldShieldProductionGovernance finalizer = new FinalizeYieldShieldProductionGovernance();

        vm.prank(bootstrapHolder);
        ysToken.delegate(bootstrapHolder);
        vm.warp(block.timestamp + 1);

        (uint256 proposalVotes, uint256 proposalThreshold, uint256 quorumVotes,) =
            finalizer.getBootstrapProposalVotes(bootstrapHolder, address(ysToken), address(governor));
        assertGe(proposalVotes, proposalThreshold, "finalizer should only proceed once past votes are live");
        assertGe(proposalVotes, quorumVotes, "finalizer should only proceed once quorum votes are live");

        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        vm.prank(bootstrapHolder);
        timelock.renounceRole(adminRole, bootstrapHolder);

        assertFalse(timelock.hasRole(adminRole, bootstrapHolder));
    }

    function test_ProductionBootstrap_BurnCannotReduceBelowQuorumVotingPower() public {
        (YSToken ysToken,, YSGovernor governor) = _deployGovernanceWithBootstrapAdmin();
        uint256 belowQuorumSupply = ysToken.MIN_GOVERNANCE_SUPPLY() - 1;
        uint256 burnAmount = ysToken.INITIAL_SUPPLY() - belowQuorumSupply;

        vm.prank(bootstrapHolder);
        vm.expectRevert(
            abi.encodeWithSelector(
                YSToken.BurnWouldReduceSupplyBelowGovernanceQuorum.selector,
                belowQuorumSupply,
                ysToken.MIN_GOVERNANCE_SUPPLY()
            )
        );
        ysToken.burn(burnAmount);

        assertLt(governor.proposalThreshold(), ysToken.MIN_GOVERNANCE_SUPPLY());
    }

    function test_ProductionProtocol_TransfersOwnershipToTimelock() public {
        (, TimelockController timelock,) = _deployGovernance();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImplementation));

        factory.setCompositeOracle(address(compositeOracle));
        factory.setDefaultProtocolFeeRecipient(address(timelock));
        compositeOracle.setAuthorizedCaller(address(factory), true);

        factory.transferOwnership(address(timelock));
        compositeOracle.transferOwnership(address(timelock));
        pythOracle.transferOwnership(address(timelock));
        erc4626OracleFeed.transferOwnership(address(timelock));

        assertEq(factory.owner(), address(timelock));
        assertEq(compositeOracle.owner(), address(timelock));
        assertEq(pythOracle.owner(), address(timelock));
        assertEq(erc4626OracleFeed.owner(), address(timelock));
    }

    function test_LegacySepoliaTimelockAdmin_RemediationClearsOpenRolesAndDeployerAdmin() public {
        address[] memory openAccounts = new address[](1);
        openAccounts[0] = address(0);
        TimelockController timelock = new TimelockController(120, openAccounts, openAccounts, deployer);
        address governor = address(0xC0FFEE);

        timelock.grantRole(timelock.PROPOSER_ROLE(), governor);
        timelock.grantRole(timelock.EXECUTOR_ROLE(), governor);
        timelock.grantRole(timelock.CANCELLER_ROLE(), governor);

        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(0)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));

        timelock.revokeRole(timelock.PROPOSER_ROLE(), address(0));
        timelock.revokeRole(timelock.EXECUTOR_ROLE(), address(0));
        timelock.revokeRole(timelock.CANCELLER_ROLE(), address(0));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), address(0)));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), governor));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), governor));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), governor));
    }

    function _deployGovernance() internal returns (YSToken ysToken, TimelockController timelock, YSGovernor governor) {
        address[] memory emptyAccounts = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, emptyAccounts, emptyAccounts, deployer);
        ysToken = new YSToken(bootstrapHolder);
        governor = new YSGovernor(IVotes(address(ysToken)), timelock);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _deployGovernanceWithBootstrapAdmin()
        internal
        returns (YSToken ysToken, TimelockController timelock, YSGovernor governor)
    {
        address[] memory emptyAccounts = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, emptyAccounts, emptyAccounts, deployer);
        ysToken = new YSToken(bootstrapHolder);
        governor = new YSGovernor(IVotes(address(ysToken)), timelock);

        timelock.grantRole(timelock.DEFAULT_ADMIN_ROLE(), bootstrapHolder);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
    }
}
