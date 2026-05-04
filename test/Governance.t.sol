// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { YSToken } from "../contracts/YSToken.sol";
import { YSGovernor } from "../contracts/YSGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";

// ============================================================
// YSToken Tests
// ============================================================

contract YSTokenTest is Test {
    YSToken public ysToken;
    address public deployer;
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    function setUp() public {
        deployer = address(this);
        ysToken = new YSToken(deployer);
    }

    function test_InitialSupply() public view {
        assertEq(ysToken.totalSupply(), 1_000_000e18);
        assertEq(ysToken.balanceOf(deployer), 1_000_000e18);
    }

    function test_Name_Symbol() public view {
        assertEq(ysToken.name(), "YieldShield");
        assertEq(ysToken.symbol(), "YS");
    }

    function test_ClockMode() public view {
        assertEq(ysToken.CLOCK_MODE(), "mode=timestamp");
    }

    function test_Clock() public view {
        assertEq(ysToken.clock(), uint48(block.timestamp));
    }

    function test_FixedSupply_HasNoMintFunction() public {
        (bool success,) = address(ysToken).call(abi.encodeWithSignature("mint(address,uint256)", user1, 1000e18));
        assertFalse(success);
        assertEq(ysToken.totalSupply(), 1_000_000e18);
    }

    function test_FixedSupply_HasNoOwnerBurnFromFunction() public {
        ysToken.transfer(user1, 1000e18);

        (bool success,) = address(ysToken).call(abi.encodeWithSignature("burnFrom(address,uint256)", user1, 500e18));
        assertFalse(success);
        assertEq(ysToken.balanceOf(user1), 1000e18);
    }

    function test_Burn() public {
        ysToken.burn(500e18);
        assertEq(ysToken.balanceOf(deployer), 999_500e18);
    }

    function test_Delegation() public {
        ysToken.delegate(deployer);
        vm.warp(block.timestamp + 1);
        assertEq(ysToken.getVotes(deployer), 1_000_000e18);
    }

    function test_DelegateToOther() public {
        ysToken.delegate(user1);
        vm.warp(block.timestamp + 1);
        assertEq(ysToken.getVotes(user1), 1_000_000e18);
        assertEq(ysToken.getVotes(deployer), 0);
    }

    function test_TransferUpdatesVotingPower() public {
        ysToken.delegate(deployer);
        ysToken.transfer(user1, 200_000e18);
        vm.prank(user1);
        ysToken.delegate(user1);
        vm.warp(block.timestamp + 1);
        assertEq(ysToken.getVotes(deployer), 800_000e18);
        assertEq(ysToken.getVotes(user1), 200_000e18);
    }
}

// ============================================================
// YSGovernor Tests
// ============================================================

contract YSGovernorTest is Test, FactoryProxyTestBase {
    YSToken public ysToken;
    TimelockController public timelock;
    YSGovernor public governor;

    address public deployer;
    address public voter1 = address(0x1); // 500k YS (above threshold)
    address public voter2 = address(0x2); // 400k YS
    address public nonVoter = address(0x3); // 100 YS (below threshold)

    uint256 constant VOTING_DELAY = 86_400; // 1 day
    uint256 constant VOTING_PERIOD = 432_000; // 5 days
    uint256 constant TIMELOCK_DELAY = 1 days;

    function setUp() public {
        deployer = address(this);

        // 1. Deploy token
        ysToken = new YSToken(deployer);

        // 2. Deploy timelock (proposers & executors set after governor deploy)
        address[] memory emptyAddrs = new address[](0);
        timelock = new TimelockController(TIMELOCK_DELAY, emptyAddrs, emptyAddrs, deployer);

        // 3. Deploy governor
        governor = new YSGovernor(IVotes(address(ysToken)), timelock);

        // 4. Grant governor roles on timelock
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        // 5. Distribute tokens
        ysToken.transfer(voter1, 500_000e18);
        ysToken.transfer(voter2, 400_000e18);
        ysToken.transfer(nonVoter, 100e18);
        // deployer keeps ~99,900 tokens

        // 6. Self-delegate to create voting power
        ysToken.delegate(deployer);
        vm.prank(voter1);
        ysToken.delegate(voter1);
        vm.prank(voter2);
        ysToken.delegate(voter2);
        vm.prank(nonVoter);
        ysToken.delegate(nonVoter);

        // 7. Advance 1 second so checkpoints are recorded
        vm.warp(block.timestamp + 1);
    }

    // ---- Helpers ----

    function _propose(string memory description)
        internal
        returns (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(timelock); // innocuous target
        values = new uint256[](1);
        values[0] = 0;
        calldatas = new bytes[](1);
        calldatas[0] = ""; // no-op

        vm.prank(voter1);
        proposalId = governor.propose(targets, values, calldatas, description);
    }

    function _passProposal(uint256 proposalId) internal returns (uint256 endTimestamp) {
        // Skip voting delay
        uint256 t1 = block.timestamp + VOTING_DELAY + 1;
        vm.warp(t1);

        // Vote
        vm.prank(voter1);
        governor.castVote(proposalId, 1); // For
        vm.prank(voter2);
        governor.castVote(proposalId, 1); // For

        // Skip voting period
        endTimestamp = t1 + VOTING_PERIOD + 1;
        vm.warp(endTimestamp);
    }

    // ---- Configuration tests ----

    function test_GovernorName() public view {
        assertEq(governor.name(), "YSGovernor");
    }

    function test_VotingDelay() public view {
        assertEq(governor.votingDelay(), VOTING_DELAY);
    }

    function test_VotingPeriod() public view {
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
    }

    function test_ProposalThreshold() public view {
        assertEq(governor.proposalThreshold(), 1000e18);
    }

    function test_QuorumPercent() public view {
        // 4% of 1M total supply = 40,000 tokens
        assertEq(governor.quorum(block.timestamp - 1), 40_000e18);
    }

    function test_ProposalNeedsQueuing() public {
        (uint256 proposalId,,,) = _propose("Test queuing");
        assertTrue(governor.proposalNeedsQueuing(proposalId));
    }

    function test_DeployerBootstrapAdminIsRenounced() public view {
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function test_GovernorHasRequiredTimelockRoles() public view {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
    }

    // ---- Proposal lifecycle tests ----

    function test_Propose_Success() public {
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(voter1); // has 500k YS, threshold is 1000
        uint256 proposalId = governor.propose(targets, values, calldatas, "Test proposal");
        assertTrue(proposalId > 0);
    }

    function test_Propose_BelowThreshold() public {
        address[] memory targets = new address[](1);
        targets[0] = address(timelock);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = "";

        vm.prank(nonVoter); // has 100 YS, threshold is 1000
        vm.expectRevert();
        governor.propose(targets, values, calldatas, "Should fail");
    }

    function test_FullLifecycle_VoteAndPass() public {
        // Use absolute timestamps to avoid block.timestamp caching issues
        uint256 t0 = block.timestamp;

        // 1. Propose
        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _propose("Full lifecycle test");

        // 2. Wait voting delay
        uint256 t1 = t0 + VOTING_DELAY + 1;
        vm.warp(t1);

        // 3. Cast votes (For)
        vm.prank(voter1);
        governor.castVote(proposalId, 1);
        vm.prank(voter2);
        governor.castVote(proposalId, 1);

        // 4. Wait voting period
        uint256 t2 = t1 + VOTING_PERIOD + 1;
        vm.warp(t2);

        // 5. Verify succeeded
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

        // 6. Queue
        governor.queue(targets, values, calldatas, keccak256("Full lifecycle test"));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Queued));

        // 7. Wait timelock delay
        uint256 t3 = t2 + TIMELOCK_DELAY + 1;
        vm.warp(t3);

        // 8. Execute
        governor.execute(targets, values, calldatas, keccak256("Full lifecycle test"));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
    }

    function test_VoteAndFail_QuorumNotMet() public {
        (uint256 proposalId,,,) = _propose("Quorum fail test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Only nonVoter votes (100 YS, quorum is 40,000)
        vm.prank(nonVoter);
        governor.castVote(proposalId, 1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_VoteAgainst_Defeated() public {
        (uint256 proposalId,,,) = _propose("Against vote test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // voter1 votes For (500k), voter2 votes Against (400k)
        // deployer votes Against (~99.9k) → 499.9k against > 500k for? No.
        // Let's have both voter1 and voter2 vote against
        vm.prank(voter1);
        governor.castVote(proposalId, 0); // Against
        vm.prank(voter2);
        governor.castVote(proposalId, 0); // Against

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_Cancel() public {
        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _propose("Cancel test");

        vm.prank(voter1);
        governor.cancel(targets, values, calldatas, keccak256("Cancel test"));

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_Execute_ChangesFactoryParam() public {
        // Deploy a factory with the timelock as governance
        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, deployer, address(poolImpl));

        // Set governance timelock on the factory (two-step transfer)
        factory.setGovernanceTimelock(address(timelock));
        vm.prank(address(timelock));
        factory.acceptGovernanceTimelock();

        address newRecipient = address(0xBEEF);

        // Build proposal to call factory.setDefaultProtocolFeeRecipient via timelock
        address[] memory targets = new address[](1);
        targets[0] = address(factory);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] =
            abi.encodeWithSelector(SplitRiskPoolFactory.setDefaultProtocolFeeRecipient.selector, newRecipient);

        string memory desc = "Set fee recipient";

        vm.prank(voter1);
        uint256 proposalId = governor.propose(targets, values, calldatas, desc);

        // Pass the proposal
        uint256 endTs = _passProposal(proposalId);

        // Queue
        governor.queue(targets, values, calldatas, keccak256(bytes(desc)));

        // Wait timelock
        vm.warp(endTs + TIMELOCK_DELAY + 1);

        // Execute
        governor.execute(targets, values, calldatas, keccak256(bytes(desc)));

        // Verify the factory was updated
        assertEq(factory.defaultProtocolFeeRecipient(), newRecipient);
    }

    function test_Execute_RevertsWithoutQueue() public {
        (uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas) =
            _propose("No queue test");

        _passProposal(proposalId);

        // Try to execute without queueing first
        vm.expectRevert();
        governor.execute(targets, values, calldatas, keccak256("No queue test"));
    }

    function test_Executor_IsTimelock() public view {
        // The _executor() function is internal, but we can verify that
        // the timelock address is correct by checking the governor's timelock
        assertEq(address(governor.timelock()), address(timelock));
    }
}
