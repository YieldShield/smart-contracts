// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { YSToken } from "../contracts/YSToken.sol";
import { YSGovernor } from "../contracts/YSGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { YSTimelockController } from "../contracts/governance/YSTimelockController.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { ProtocolAccessControlUpgradeable } from "../contracts/base/ProtocolAccessControlUpgradeable.sol";
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

    function test_BurnCannotReduceSupplyBelowGovernanceQuorumFloor() public {
        ysToken.burn(ysToken.INITIAL_SUPPLY() - ysToken.MIN_GOVERNANCE_SUPPLY() - 1);
        assertEq(ysToken.totalSupply(), ysToken.MIN_GOVERNANCE_SUPPLY() + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                YSToken.BurnWouldReduceSupplyBelowGovernanceQuorum.selector,
                ysToken.MIN_GOVERNANCE_SUPPLY(),
                ysToken.MIN_GOVERNANCE_SUPPLY()
            )
        );
        ysToken.burn(1);
    }

    function test_BurnDownToExactlyQuorumFloorReverts() public {
        ysToken.burn(ysToken.INITIAL_SUPPLY() - ysToken.MIN_GOVERNANCE_SUPPLY() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                YSToken.BurnWouldReduceSupplyBelowGovernanceQuorum.selector,
                ysToken.MIN_GOVERNANCE_SUPPLY(),
                ysToken.MIN_GOVERNANCE_SUPPLY()
            )
        );
        ysToken.burn(1);
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

contract FakeTimelockWithDelay {
    function getMinDelay() external pure returns (uint256) {
        return 1 days;
    }
}

contract FakeSelfAdminTimelock {
    function getMinDelay() external pure returns (uint256) {
        return 1 days;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return role == bytes32(0) && account == address(this);
    }
}

contract MutableGovernanceTimelock {
    mapping(bytes32 => mapping(address => bool)) private _roles;
    mapping(bytes32 => address[]) private _roleMembers;
    uint256 private _minDelay;

    bytes32 private constant DEFAULT_ADMIN_ROLE_VALUE = 0x00;
    bytes32 private constant PROPOSER_ROLE_VALUE = keccak256("PROPOSER_ROLE");
    bytes32 private constant EXECUTOR_ROLE_VALUE = keccak256("EXECUTOR_ROLE");
    bytes32 private constant CANCELLER_ROLE_VALUE = keccak256("CANCELLER_ROLE");

    constructor(uint256 minDelay, address[] memory extraAdmins) {
        _minDelay = minDelay;
        _setAdmin(address(this), true);
        _setRole(PROPOSER_ROLE_VALUE, msg.sender, true);
        _setRole(EXECUTOR_ROLE_VALUE, msg.sender, true);
        _setRole(CANCELLER_ROLE_VALUE, msg.sender, true);

        uint256 extraAdminCount = extraAdmins.length;
        for (uint256 i = 0; i < extraAdminCount; i++) {
            _setAdmin(extraAdmins[i], true);
        }
    }

    function getMinDelay() external view returns (uint256) {
        return _minDelay;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function setMinDelay(uint256 newMinDelay) external {
        _minDelay = newMinDelay;
    }

    function setDefaultAdmin(address account, bool enabled) external {
        _setAdmin(account, enabled);
    }

    function _setAdmin(address account, bool enabled) internal {
        _setRole(DEFAULT_ADMIN_ROLE_VALUE, account, enabled);
    }

    function _setRole(bytes32 role, address account, bool enabled) internal {
        if (enabled && !_roles[role][account]) {
            _roleMembers[role].push(account);
        } else if (!enabled && _roles[role][account]) {
            address[] storage members = _roleMembers[role];
            for (uint256 i = 0; i < members.length; i++) {
                if (members[i] == account) {
                    members[i] = members[members.length - 1];
                    members.pop();
                    break;
                }
            }
        }
        _roles[role][account] = enabled;
    }

    function getRoleMemberCount(bytes32 role) external view returns (uint256) {
        return _roleMembers[role].length;
    }

    function getRoleMember(bytes32 role, uint256 index) external view returns (address) {
        return _roleMembers[role][index];
    }
}

contract AlternateMutableGovernanceTimelock is MutableGovernanceTimelock {
    constructor(uint256 minDelay, address[] memory extraAdmins) MutableGovernanceTimelock(minDelay, extraAdmins) { }

    function alternateImplementationMarker() external pure returns (bool) {
        return true;
    }
}

contract ProtocolAccessControlHarness is ProtocolAccessControlUpgradeable {
    function initializeHarness(address initialOwner, address governanceTimelock_) external initializer {
        __ProtocolAccessControl_init(initialOwner, governanceTimelock_);
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
    uint256 constant TIMELOCK_DELAY = 2 days;

    function setUp() public {
        deployer = address(this);

        // 1. Deploy token
        ysToken = new YSToken(deployer);

        // 2. Deploy timelock (proposers & executors set after governor deploy)
        address[] memory emptyAddrs = new address[](0);
        timelock = TimelockController(
            payable(address(new YSTimelockController(TIMELOCK_DELAY, emptyAddrs, emptyAddrs, deployer)))
        );

        // 3. Deploy governor
        governor = new YSGovernor(IVotes(address(ysToken)), timelock, deployer);

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

    function _queueGovernorCall(bytes memory callData, string memory description)
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
    {
        targets = new address[](1);
        targets[0] = address(governor);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = callData;

        vm.prank(voter1);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        uint256 endTs = _passProposal(proposalId);
        descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);
        vm.warp(endTs + TIMELOCK_DELAY + 1);
    }

    function _deployGovernorControlledTimelock(uint256 delay)
        internal
        returns (TimelockController replacementTimelock)
    {
        address[] memory emptyAddrs = new address[](0);
        replacementTimelock =
            TimelockController(payable(address(new YSTimelockController(delay, emptyAddrs, emptyAddrs, deployer))));
        replacementTimelock.grantRole(replacementTimelock.PROPOSER_ROLE(), address(governor));
        replacementTimelock.grantRole(replacementTimelock.EXECUTOR_ROLE(), address(governor));
        replacementTimelock.grantRole(replacementTimelock.CANCELLER_ROLE(), address(governor));
        replacementTimelock.renounceRole(replacementTimelock.DEFAULT_ADMIN_ROLE(), deployer);
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
        assertEq(governor.proposalThreshold(), 10_000e18);
    }

    function test_GovernorSettingsRejectVotingDelayBelowFloor() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) = _queueGovernorCall(
            abi.encodeWithSelector(YSGovernor.setVotingDelay.selector, uint48(VOTING_DELAY - 1)),
            "Reject short voting delay"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                YSGovernor.GovernorVotingDelayOutOfRange.selector,
                uint48(VOTING_DELAY - 1),
                governor.MIN_GOVERNOR_VOTING_DELAY(),
                governor.MAX_GOVERNOR_VOTING_DELAY()
            )
        );
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_GovernorSettingsRejectVotingPeriodBelowFloor() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) = _queueGovernorCall(
            abi.encodeWithSelector(YSGovernor.setVotingPeriod.selector, uint32(VOTING_PERIOD - 1)),
            "Reject short voting period"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                YSGovernor.GovernorVotingPeriodOutOfRange.selector,
                uint32(VOTING_PERIOD - 1),
                governor.MIN_GOVERNOR_VOTING_PERIOD(),
                governor.MAX_GOVERNOR_VOTING_PERIOD()
            )
        );
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_GovernorSettingsRejectProposalThresholdBelowFloor() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) = _queueGovernorCall(
            abi.encodeWithSelector(YSGovernor.setProposalThreshold.selector, 9_999e18), "Reject low proposal threshold"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                YSGovernor.GovernorProposalThresholdOutOfRange.selector,
                9_999e18,
                governor.MIN_GOVERNOR_PROPOSAL_THRESHOLD(),
                governor.MAX_GOVERNOR_PROPOSAL_THRESHOLD()
            )
        );
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_GovernorSettingsAllowQuorumNumeratorBounds() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) = _queueGovernorCall(
            abi.encodeWithSelector(YSGovernor.updateQuorumNumerator.selector, 2), "Allow minimum quorum numerator"
        );
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(governor.quorumNumerator(), 2);

        (targets, values, calldatas, descriptionHash) = _queueGovernorCall(
            abi.encodeWithSelector(YSGovernor.updateQuorumNumerator.selector, 20), "Allow maximum quorum numerator"
        );
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(governor.quorumNumerator(), 20);
    }

    function test_GovernorSettingsRejectQuorumNumeratorOutsideBounds() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) = _queueGovernorCall(
            abi.encodeWithSelector(YSGovernor.updateQuorumNumerator.selector, 1), "Reject low quorum numerator"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                YSGovernor.GovernorQuorumNumeratorOutOfRange.selector,
                1,
                governor.MIN_GOVERNOR_QUORUM_NUMERATOR(),
                governor.MAX_GOVERNOR_QUORUM_NUMERATOR()
            )
        );
        governor.execute(targets, values, calldatas, descriptionHash);

        (targets, values, calldatas, descriptionHash) = _queueGovernorCall(
            abi.encodeWithSelector(YSGovernor.updateQuorumNumerator.selector, 100), "Reject high quorum numerator"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                YSGovernor.GovernorQuorumNumeratorOutOfRange.selector,
                100,
                governor.MIN_GOVERNOR_QUORUM_NUMERATOR(),
                governor.MAX_GOVERNOR_QUORUM_NUMERATOR()
            )
        );
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_UpdateTimelockRejectsShortPublicDelay() public {
        TimelockController replacementTimelock = _deployGovernorControlledTimelock(0);
        vm.chainId(1);
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) = _queueGovernorCall(
            abi.encodeWithSelector(YSGovernor.updateTimelock.selector, replacementTimelock),
            "Reject zero delay timelock"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                YSGovernor.GovernorTimelockDelayTooShort.selector,
                address(replacementTimelock),
                0,
                governor.MIN_GOVERNOR_TIMELOCK_DELAY()
            )
        );
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_UpdateTimelockRejectsShapeCompatibleDifferentImplementation() public {
        address[] memory noExtraAdmins = new address[](0);
        vm.prank(address(governor));
        MutableGovernanceTimelock fakeTimelock = new MutableGovernanceTimelock(TIMELOCK_DELAY, noExtraAdmins);

        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash) = _queueGovernorCall(
            abi.encodeWithSelector(
                YSGovernor.updateTimelock.selector, TimelockController(payable(address(fakeTimelock)))
            ),
            "Reject fake timelock implementation"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                YSGovernor.GovernorTimelockImplementationMismatch.selector,
                address(fakeTimelock),
                address(timelock).codehash,
                address(fakeTimelock).codehash
            )
        );
        governor.execute(targets, values, calldatas, descriptionHash);
    }

    function test_QuorumPercent() public view {
        // 4% of 1M total supply = 40,000 tokens
        assertEq(governor.quorum(block.timestamp - 1), 40_000e18);
    }

    function test_ProposalNeedsQueuing() public {
        (uint256 proposalId,,,) = _propose("Test queuing");
        assertTrue(governor.proposalNeedsQueuing(proposalId));
    }

    function test_SetGovernanceTimelock_RevertsForOwnerBypass() public {
        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImpl));
        address[] memory emptyAddrs = new address[](0);
        TimelockController replacementTimelock = TimelockController(
            payable(address(new YSTimelockController(TIMELOCK_DELAY, emptyAddrs, emptyAddrs, deployer)))
        );

        vm.expectRevert(
            abi.encodeWithSelector(ProtocolAccessControlUpgradeable.UnauthorizedGovernance.selector, deployer)
        );
        factory.setGovernanceTimelock(address(replacementTimelock));
    }

    function test_DeployerBootstrapAdminIsRenounced() public view {
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function test_TimelockHasSoleSelfAdmin() public view {
        YSTimelockController ysTimelock = YSTimelockController(payable(address(timelock)));

        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertEq(ysTimelock.getRoleMemberCount(ysTimelock.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(ysTimelock.getRoleMember(ysTimelock.DEFAULT_ADMIN_ROLE(), 0), address(timelock));
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
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImpl));

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

    function test_SetGovernanceTimelock_RevertsForEOA() public {
        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImpl));
        address eoaCandidate = address(0xCAFE);

        vm.expectRevert(
            abi.encodeWithSelector(ProtocolAccessControlUpgradeable.InvalidGovernanceTimelock.selector, eoaCandidate)
        );
        vm.prank(address(timelock));
        factory.setGovernanceTimelock(eoaCandidate);
    }

    function test_SetGovernanceTimelock_RevertsForContractWithoutTimelockInterface() public {
        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImpl));

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.InvalidGovernanceTimelock.selector, address(ysToken)
            )
        );
        vm.prank(address(timelock));
        factory.setGovernanceTimelock(address(ysToken));
    }

    function test_SetGovernanceTimelock_RevertsForFakeTimelockWithoutSelfAdmin() public {
        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImpl));
        FakeTimelockWithDelay fakeTimelock = new FakeTimelockWithDelay();

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.InvalidGovernanceTimelock.selector, address(fakeTimelock)
            )
        );
        vm.prank(address(timelock));
        factory.setGovernanceTimelock(address(fakeTimelock));
    }

    function test_SetGovernanceTimelock_RevertsForDifferentImplementation() public {
        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImpl));
        FakeSelfAdminTimelock fakeTimelock = new FakeSelfAdminTimelock();

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.InvalidGovernanceTimelock.selector, address(fakeTimelock)
            )
        );
        vm.prank(address(timelock));
        factory.setGovernanceTimelock(address(fakeTimelock));
    }

    function test_Initialize_RevertsForEOAGovernanceTimelock() public {
        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory implementation = new SplitRiskPoolFactory();
        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPoolFactory.initialize.selector, deployer, address(0xCAFE), address(poolImpl)
        );

        vm.expectRevert(
            abi.encodeWithSelector(ProtocolAccessControlUpgradeable.InvalidGovernanceTimelock.selector, address(0xCAFE))
        );
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertsForPublicTimelockBelowMinimumDelay() public {
        vm.chainId(421614);

        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory implementation = new SplitRiskPoolFactory();
        address[] memory noExtraAdmins = new address[](0);
        MutableGovernanceTimelock shortDelayTimelock = new MutableGovernanceTimelock(12 hours, noExtraAdmins);
        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPoolFactory.initialize.selector, deployer, address(shortDelayTimelock), address(poolImpl)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.GovernanceTimelockDelayTooShort.selector,
                address(shortDelayTimelock),
                12 hours
            )
        );
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_Initialize_RevertsForPublicTimelockRetainingOwnerAdmin() public {
        vm.chainId(421614);

        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory implementation = new SplitRiskPoolFactory();
        address[] memory emptyAddrs = new address[](0);
        TimelockController unsafeTimelock =
            TimelockController(payable(address(new YSTimelockController(2 days, emptyAddrs, emptyAddrs, deployer))));
        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPoolFactory.initialize.selector, deployer, address(unsafeTimelock), address(poolImpl)
        );

        // H-8: the enumeration check fires first when there is more than one
        // DEFAULT_ADMIN_ROLE member on the candidate (timelock + deployer = 2).
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.GovernanceTimelockHasExtraAdmins.selector,
                address(unsafeTimelock),
                uint256(2)
            )
        );
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_SetGovernanceTimelock_RevertsForZeroDelayTimelock() public {
        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImpl));
        address[] memory emptyAddrs = new address[](0);
        TimelockController zeroDelayTimelock =
            TimelockController(payable(address(new YSTimelockController(0, emptyAddrs, emptyAddrs, deployer))));

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.GovernanceTimelockDelayTooShort.selector, address(zeroDelayTimelock), 0
            )
        );
        vm.prank(address(timelock));
        factory.setGovernanceTimelock(address(zeroDelayTimelock));
    }

    function test_SetGovernanceTimelock_CannotGrantPriorGovernanceDefaultAdmin() public {
        vm.chainId(421614);

        address[] memory emptyAddrs = new address[](0);
        TimelockController unsafeTimelock =
            TimelockController(payable(address(new YSTimelockController(2 days, emptyAddrs, emptyAddrs, deployer))));
        bytes32 defaultAdminRole = unsafeTimelock.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(YSTimelockController.DefaultAdminMustBeTimelock.selector, address(timelock))
        );
        unsafeTimelock.grantRole(defaultAdminRole, address(timelock));
    }

    function test_SetGovernanceTimelock_RevertsForExtraOperationalRoleMembers() public {
        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImpl));

        address attacker = address(0xBAD);
        address[] memory proposers = new address[](2);
        proposers[0] = address(governor);
        proposers[1] = attacker;
        address[] memory executors = new address[](1);
        executors[0] = address(governor);
        TimelockController unsafeTimelock = TimelockController(
            payable(address(new YSTimelockController(TIMELOCK_DELAY, proposers, executors, deployer)))
        );
        unsafeTimelock.renounceRole(unsafeTimelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.GovernanceTimelockInvalidRoleMemberCount.selector,
                address(unsafeTimelock),
                unsafeTimelock.PROPOSER_ROLE(),
                uint256(2)
            )
        );
        vm.prank(address(timelock));
        factory.setGovernanceTimelock(address(unsafeTimelock));
    }

    function test_SetGovernanceTimelock_RevertsWhenOperationalControllerChanges() public {
        SplitRiskPool poolImpl = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImpl));

        address attacker = address(0xBAD);
        address[] memory proposers = new address[](1);
        proposers[0] = attacker;
        address[] memory executors = new address[](1);
        executors[0] = attacker;
        TimelockController unsafeTimelock = TimelockController(
            payable(address(new YSTimelockController(TIMELOCK_DELAY, proposers, executors, deployer)))
        );
        unsafeTimelock.renounceRole(unsafeTimelock.DEFAULT_ADMIN_ROLE(), deployer);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.GovernanceTimelockRoleMemberMismatch.selector,
                address(unsafeTimelock),
                unsafeTimelock.PROPOSER_ROLE(),
                address(governor),
                attacker
            )
        );
        vm.prank(address(timelock));
        factory.setGovernanceTimelock(address(unsafeTimelock));
    }

    function test_YSTimelockConstructor_RevertsBelowPublicFloor() public {
        vm.chainId(421614);

        address[] memory emptyAddrs = new address[](0);
        vm.expectRevert(
            abi.encodeWithSelector(YSTimelockController.PublicTimelockDelayTooShort.selector, 1 days, 2 days)
        );
        new YSTimelockController(1 days, emptyAddrs, emptyAddrs, deployer);
    }

    function test_YSTimelockUpdateDelay_RevertsBelowPublicFloor() public {
        vm.chainId(421614);

        address[] memory emptyAddrs = new address[](0);
        YSTimelockController publicTimelock = new YSTimelockController(2 days, emptyAddrs, emptyAddrs, deployer);

        vm.expectRevert(
            abi.encodeWithSelector(YSTimelockController.PublicTimelockDelayTooShort.selector, 1 days, 2 days)
        );
        vm.prank(address(publicTimelock));
        publicTimelock.updateDelay(1 days);
    }

    function test_YSTimelockConstructor_RevertsAbovePublicCeiling() public {
        address[] memory emptyAddrs = new address[](0);
        vm.expectRevert(
            abi.encodeWithSelector(YSTimelockController.PublicTimelockDelayTooLong.selector, 30 days + 1, 30 days)
        );
        new YSTimelockController(30 days + 1, emptyAddrs, emptyAddrs, deployer);
    }

    function test_YSTimelockUpdateDelay_RevertsAbovePublicCeiling() public {
        address[] memory emptyAddrs = new address[](0);
        YSTimelockController publicTimelock = new YSTimelockController(2 days, emptyAddrs, emptyAddrs, deployer);

        vm.expectRevert(
            abi.encodeWithSelector(YSTimelockController.PublicTimelockDelayTooLong.selector, 30 days + 1, 30 days)
        );
        vm.prank(address(publicTimelock));
        publicTimelock.updateDelay(30 days + 1);
    }

    function test_YSTimelockUpdateDelay_AllowsPublicCeiling() public {
        address[] memory emptyAddrs = new address[](0);
        YSTimelockController publicTimelock = new YSTimelockController(2 days, emptyAddrs, emptyAddrs, deployer);

        vm.prank(address(publicTimelock));
        publicTimelock.updateDelay(30 days);

        assertEq(publicTimelock.getMinDelay(), 30 days);
    }

    function test_YSTimelockUpdateDelay_AllowsShortLocalDelay() public {
        address[] memory emptyAddrs = new address[](0);
        YSTimelockController localTimelock = new YSTimelockController(1 days, emptyAddrs, emptyAddrs, deployer);

        vm.prank(address(localTimelock));
        localTimelock.updateDelay(1 hours);

        assertEq(localTimelock.getMinDelay(), 1 hours);
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

contract ProtocolAccessControlUpgradeableTest is Test {
    function test_InitializeRejectsGovernanceTimelockAboveCeiling() public {
        address[] memory noExtraAdmins = new address[](0);
        MutableGovernanceTimelock currentGovernance = new MutableGovernanceTimelock(30 days + 1, noExtraAdmins);
        ProtocolAccessControlHarness harness = new ProtocolAccessControlHarness();

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.GovernanceTimelockDelayTooLong.selector,
                address(currentGovernance),
                30 days + 1,
                30 days
            )
        );
        harness.initializeHarness(address(this), address(currentGovernance));
    }

    function test_GovernanceTimelockRotationRejectsDifferentImplementation() public {
        address[] memory noExtraAdmins = new address[](0);
        MutableGovernanceTimelock currentGovernance = new MutableGovernanceTimelock(2 days, noExtraAdmins);
        AlternateMutableGovernanceTimelock replacementGovernance =
            new AlternateMutableGovernanceTimelock(2 days, noExtraAdmins);
        ProtocolAccessControlHarness harness = new ProtocolAccessControlHarness();
        harness.initializeHarness(address(this), address(currentGovernance));

        assertNotEq(address(currentGovernance).codehash, address(replacementGovernance).codehash);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.GovernanceTimelockImplementationMismatch.selector,
                address(replacementGovernance),
                address(currentGovernance).codehash,
                address(replacementGovernance).codehash
            )
        );
        vm.prank(address(currentGovernance));
        harness.setGovernanceTimelock(address(replacementGovernance));
    }

    function test_GovernanceTimelockRotationRejectsDelayAboveCeiling() public {
        address[] memory noExtraAdmins = new address[](0);
        MutableGovernanceTimelock currentGovernance = new MutableGovernanceTimelock(2 days, noExtraAdmins);
        MutableGovernanceTimelock replacementGovernance = new MutableGovernanceTimelock(30 days + 1, noExtraAdmins);
        ProtocolAccessControlHarness harness = new ProtocolAccessControlHarness();
        harness.initializeHarness(address(this), address(currentGovernance));

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.GovernanceTimelockDelayTooLong.selector,
                address(replacementGovernance),
                30 days + 1,
                30 days
            )
        );
        vm.prank(address(currentGovernance));
        harness.setGovernanceTimelock(address(replacementGovernance));
    }

    function test_GovernanceTimelockRotationAllowsSameImplementation() public {
        address[] memory noExtraAdmins = new address[](0);
        MutableGovernanceTimelock currentGovernance = new MutableGovernanceTimelock(2 days, noExtraAdmins);
        MutableGovernanceTimelock replacementGovernance = new MutableGovernanceTimelock(2 days, noExtraAdmins);
        ProtocolAccessControlHarness harness = new ProtocolAccessControlHarness();
        harness.initializeHarness(address(this), address(currentGovernance));

        assertEq(address(currentGovernance).codehash, address(replacementGovernance).codehash);

        vm.prank(address(currentGovernance));
        harness.setGovernanceTimelock(address(replacementGovernance));

        vm.prank(address(replacementGovernance));
        harness.acceptGovernanceTimelock();

        assertEq(harness.governanceTimelock(), address(replacementGovernance));
    }

    function test_AcceptGovernanceTimelock_RevalidatesPendingImplementation() public {
        address[] memory noExtraAdmins = new address[](0);
        MutableGovernanceTimelock currentGovernance = new MutableGovernanceTimelock(2 days, noExtraAdmins);
        MutableGovernanceTimelock replacementGovernance = new MutableGovernanceTimelock(2 days, noExtraAdmins);
        AlternateMutableGovernanceTimelock alternateImplementation =
            new AlternateMutableGovernanceTimelock(2 days, noExtraAdmins);
        ProtocolAccessControlHarness harness = new ProtocolAccessControlHarness();
        harness.initializeHarness(address(this), address(currentGovernance));

        vm.prank(address(currentGovernance));
        harness.setGovernanceTimelock(address(replacementGovernance));

        vm.etch(address(replacementGovernance), address(alternateImplementation).code);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.GovernanceTimelockImplementationMismatch.selector,
                address(replacementGovernance),
                address(currentGovernance).codehash,
                address(replacementGovernance).codehash
            )
        );
        vm.prank(address(replacementGovernance));
        harness.acceptGovernanceTimelock();
    }

    function test_AcceptGovernanceTimelock_RevalidatesPendingDelayOnPublicChains() public {
        vm.chainId(421614);

        address[] memory noExtraAdmins = new address[](0);
        MutableGovernanceTimelock currentGovernance = new MutableGovernanceTimelock(2 days, noExtraAdmins);
        MutableGovernanceTimelock replacementGovernance = new MutableGovernanceTimelock(2 days, noExtraAdmins);
        ProtocolAccessControlHarness harness = new ProtocolAccessControlHarness();
        harness.initializeHarness(address(this), address(currentGovernance));

        vm.prank(address(currentGovernance));
        harness.setGovernanceTimelock(address(replacementGovernance));

        replacementGovernance.setMinDelay(0);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.GovernanceTimelockDelayTooShort.selector,
                address(replacementGovernance),
                0
            )
        );
        vm.prank(address(replacementGovernance));
        harness.acceptGovernanceTimelock();
    }

    function test_AcceptGovernanceTimelock_RevalidatesPendingOwnerAdminOnPublicChains() public {
        vm.chainId(421614);

        address[] memory noExtraAdmins = new address[](0);
        MutableGovernanceTimelock currentGovernance = new MutableGovernanceTimelock(2 days, noExtraAdmins);
        MutableGovernanceTimelock replacementGovernance = new MutableGovernanceTimelock(2 days, noExtraAdmins);
        ProtocolAccessControlHarness harness = new ProtocolAccessControlHarness();
        harness.initializeHarness(address(this), address(currentGovernance));

        vm.prank(address(currentGovernance));
        harness.setGovernanceTimelock(address(replacementGovernance));

        replacementGovernance.setDefaultAdmin(address(this), true);

        // H-8: enumeration catches the extra admin first.
        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolAccessControlUpgradeable.GovernanceTimelockHasExtraAdmins.selector,
                address(replacementGovernance),
                uint256(2)
            )
        );
        vm.prank(address(replacementGovernance));
        harness.acceptGovernanceTimelock();
    }
}
