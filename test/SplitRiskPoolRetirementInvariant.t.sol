// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { ProtectorCommissionEscrow } from "../contracts/ProtectorCommissionEscrow.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IProtectorReceiptNFT } from "../contracts/interfaces/IProtectorReceiptNFT.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";

contract RetirementInvariantBlockingToken is MockERC20 {
    error RecipientBlocked(address recipient);

    mapping(address => bool) public recipientBlocked;

    constructor() MockERC20("Retirement Blocking Token", "RBLOCK") { }

    function setRecipientBlocked(address recipient, bool blocked) external onlyOwner {
        recipientBlocked[recipient] = blocked;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && recipientBlocked[to]) revert RecipientBlocked(to);
        super._update(from, to, amount);
    }
}

/// @notice Stateful handler for one normal expired-epoch settlement and one escrowed settlement.
contract SplitRiskPoolRetirementHandler is Test {
    struct CallMetrics {
        uint256 attempts;
        uint256 preconditionSkips;
        uint256 successes;
        uint256 unexpectedReverts;
    }

    SplitRiskPool public settlementPool;
    SplitRiskPool public escrowPool;
    MockERC20 public settlementToken;
    RetirementInvariantBlockingToken public escrowToken;
    ProtectorReceiptNFT public settlementReceipt;
    address public settlementBeneficiary;
    address public settlementAlternateBeneficiary;
    address public escrowBeneficiary;
    uint256 public settlementTokenId;
    uint256 public escrowTokenId;
    address public commissionEscrow;
    uint256 public ghostSettledAmount;
    uint256 public ghostExpiredReceiptTransfers;
    uint256 public ghostEscrowedAmount;
    uint256 public ghostEscrowClaimedAmount;

    mapping(bytes4 => CallMetrics) public callMetrics;

    constructor(
        SplitRiskPool settlementPool_,
        SplitRiskPool escrowPool_,
        MockERC20 settlementToken_,
        RetirementInvariantBlockingToken escrowToken_,
        address settlementBeneficiary_,
        address settlementAlternateBeneficiary_,
        address escrowBeneficiary_,
        uint256 settlementTokenId_,
        uint256 escrowTokenId_
    ) {
        settlementPool = settlementPool_;
        escrowPool = escrowPool_;
        settlementToken = settlementToken_;
        escrowToken = escrowToken_;
        settlementBeneficiary = settlementBeneficiary_;
        settlementAlternateBeneficiary = settlementAlternateBeneficiary_;
        escrowBeneficiary = escrowBeneficiary_;
        settlementTokenId = settlementTokenId_;
        escrowTokenId = escrowTokenId_;
        settlementReceipt = ProtectorReceiptNFT(settlementPool_.protectorReceiptNFT());
    }

    function settleExpiredPosition() external {
        CallMetrics storage metrics = callMetrics[this.settleExpiredPosition.selector];
        metrics.attempts++;
        if (settlementPool.protectorEpochPositionSettled(settlementTokenId)) {
            metrics.preconditionSkips++;
            return;
        }

        uint256 claimableBefore = settlementPool.getClaimableCommission(settlementTokenId);
        uint256 reserveBefore = settlementPool.getReservedFees();
        IProtectorReceiptNFT.ProtectorPosition memory pos = settlementReceipt.getPosition(settlementTokenId);
        uint256 unlockTime = uint256(pos.depositTime) + settlementReceipt.transferLockPeriod();
        if (block.timestamp < unlockTime) vm.warp(unlockTime);
        vm.prank(settlementBeneficiary);
        try settlementReceipt.transferFrom(settlementBeneficiary, settlementAlternateBeneficiary, settlementTokenId) {
            settlementBeneficiary = settlementAlternateBeneficiary;
            ghostExpiredReceiptTransfers++;
        } catch {
            metrics.unexpectedReverts++;
            return;
        }
        if (
            settlementPool.getClaimableCommission(settlementTokenId) != claimableBefore
                || settlementPool.getReservedFees() != reserveBefore
        ) {
            metrics.unexpectedReverts++;
            return;
        }

        uint256 beneficiaryBalanceBefore = settlementToken.balanceOf(settlementAlternateBeneficiary);
        try settlementPool.settleExpiredProtectorPosition(settlementTokenId) {
            ghostSettledAmount += settlementToken.balanceOf(settlementAlternateBeneficiary) - beneficiaryBalanceBefore;
            metrics.successes++;
        } catch {
            metrics.unexpectedReverts++;
        }
    }

    function escrowExpiredCommission() external {
        CallMetrics storage metrics = callMetrics[this.escrowExpiredCommission.selector];
        metrics.attempts++;
        if (commissionEscrow != address(0) || escrowPool.protectorEpochPositionSettled(escrowTokenId)) {
            metrics.preconditionSkips++;
            return;
        }

        try escrowPool.escrowExpiredProtectorCommission(escrowTokenId) returns (address escrow, uint256 amount) {
            commissionEscrow = escrow;
            ghostEscrowedAmount = amount;
            metrics.successes++;
        } catch {
            metrics.unexpectedReverts++;
        }
    }

    function claimEscrow() external {
        CallMetrics storage metrics = callMetrics[this.claimEscrow.selector];
        metrics.attempts++;
        address escrow = commissionEscrow;
        if (escrow == address(0) || escrowToken.balanceOf(escrow) == 0) {
            metrics.preconditionSkips++;
            return;
        }

        escrowToken.setRecipientBlocked(escrowBeneficiary, false);
        vm.prank(escrowBeneficiary);
        try ProtectorCommissionEscrow(escrow).claim() returns (uint256 received) {
            ghostEscrowClaimedAmount += received;
            metrics.successes++;
        } catch {
            metrics.unexpectedReverts++;
        }
    }
}

/// @notice Exercises retirement-only paths separately from the live-pool economic state machine.
contract SplitRiskPoolRetirementInvariantTest is Test, FactoryProxyTestBase {
    SplitRiskPoolFactory public factory;
    SplitRiskPool public settlementPool;
    SplitRiskPool public escrowPool;
    SplitRiskPoolRetirementHandler public handler;
    MockERC20 public settlementToken;
    RetirementInvariantBlockingToken public escrowToken;
    MockERC20 public backingToken;
    MockOracle public oracle;
    CompositeOracle public compositeOracle;

    address public governance;
    address public settlementBeneficiary = address(0xA11CE);
    address public settlementAlternateBeneficiary = address(0xA12CE);
    address public escrowBeneficiary = address(0xB0B);
    address public settlementShielded = address(0x51E1D);
    address public escrowShielded = address(0xE5C0);
    uint256 public settlementLiability;
    uint256 public escrowLiability;
    bool public requireRandomReachability;

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));
        settlementToken = new MockERC20("Settlement Token", "SETTLE");
        escrowToken = new RetirementInvariantBlockingToken();
        backingToken = new MockERC20("Retirement Backing", "RBACK");
        oracle = new MockOracle();
        oracle.setPrice(address(settlementToken), 1e8);
        oracle.setPrice(address(escrowToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        compositeOracle = new CompositeOracle();
        SplitRiskPool implementation = new SplitRiskPool();
        factory = _deployFactory(address(this), governance, address(implementation));
        compositeOracle.transferOwnership(address(factory));
        factory.setCompositeOracle(address(compositeOracle));
        factory.setDefaultProtocolFeeRecipient(address(0xFEE));
        factory.setCompositeOracleAuthorizedCaller(address(this), true);
        vm.prank(governance);
        factory.setMinimumCreationBondUsd(0);

        factory.addTokenInitial(
            address(settlementToken), "Settlement Token", "SETTLE", address(oracle), address(0), 10_000, true
        );
        factory.addTokenInitial(
            address(escrowToken), "Retirement Blocking Token", "RBLOCK", address(oracle), address(0), 10_000, true
        );
        factory.addTokenInitial(
            address(backingToken), "Retirement Backing", "RBACK", address(oracle), address(0), 10_000, true
        );
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);

        settlementPool = SplitRiskPool(
            payable(factory.createPool(
                    address(settlementToken), "SETTLE", address(backingToken), "RBACK", 500, 200, 10_000, 0
                ))
        );
        escrowPool = SplitRiskPool(
            payable(factory.createPool(
                    address(escrowToken), "RBLOCK", address(backingToken), "RBACK", 500, 200, 10_000, 0
                ))
        );

        uint256 settlementTokenId =
            _expireProtectorEpoch(settlementPool, settlementToken, settlementBeneficiary, settlementShielded);
        uint256 escrowTokenId = _expireProtectorEpoch(escrowPool, escrowToken, escrowBeneficiary, escrowShielded);
        escrowToken.setRecipientBlocked(escrowBeneficiary, true);

        settlementLiability = settlementPool.getReservedFees();
        escrowLiability = escrowPool.getReservedFees();
        assertGt(settlementLiability, 0, "settlement fixture must reserve expired commission");
        assertGt(escrowLiability, 0, "escrow fixture must reserve expired commission");

        handler = new SplitRiskPoolRetirementHandler(
            settlementPool,
            escrowPool,
            settlementToken,
            escrowToken,
            settlementBeneficiary,
            settlementAlternateBeneficiary,
            escrowBeneficiary,
            settlementTokenId,
            escrowTokenId
        );
        escrowToken.transferOwnership(address(handler));
        requireRandomReachability = vm.envOr("INVARIANT_REQUIRE_RANDOM_REACHABILITY", false);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = SplitRiskPoolRetirementHandler.settleExpiredPosition.selector;
        selectors[1] = SplitRiskPoolRetirementHandler.escrowExpiredCommission.selector;
        selectors[2] = SplitRiskPoolRetirementHandler.claimEscrow.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function _expireProtectorEpoch(SplitRiskPool pool, MockERC20 shieldedToken, address protector, address shielded)
        internal
        returns (uint256 protectorTokenId)
    {
        uint256 amount = 100e18;
        backingToken.mint(protector, amount);
        vm.startPrank(protector);
        backingToken.approve(address(pool), amount);
        protectorTokenId = pool.depositBackingAsset(address(backingToken), amount, 0);
        vm.stopPrank();

        shieldedToken.mint(shielded, amount);
        vm.startPrank(shielded);
        shieldedToken.approve(address(pool), amount);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), amount, 0);
        (,,,,, uint256 minimumPoolTime,,,,) = pool.poolConfig();
        vm.warp(block.timestamp + minimumPoolTime + 1);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);
        vm.stopPrank();
    }

    function invariant_expiredSettlementConservesBeneficiaryValue() public view {
        assertEq(
            settlementToken.balanceOf(address(settlementPool)) + settlementToken.balanceOf(settlementBeneficiary)
                + settlementToken.balanceOf(settlementAlternateBeneficiary),
            settlementLiability,
            "expired settlement value must stay in the pool or reach the NFT owner"
        );
        assertEq(
            handler.ghostSettledAmount() + settlementPool.getReservedFees(),
            settlementLiability,
            "settled amount plus remaining reserve must equal the original liability"
        );
    }

    function invariant_expiredReceiptTransferPrecedesSettlement() public view {
        if (handler.ghostSettledAmount() != 0) {
            assertEq(handler.ghostExpiredReceiptTransfers(), 1, "expired receipt must transfer before settlement");
            assertEq(
                handler.settlementBeneficiary(),
                settlementAlternateBeneficiary,
                "settlement must track the transferred receipt owner"
            );
        }
    }

    function invariant_escrowClaimConservesBeneficiaryValue() public view {
        address escrow = handler.commissionEscrow();
        uint256 escrowBalance = escrow == address(0) ? 0 : escrowToken.balanceOf(escrow);
        assertEq(
            escrowToken.balanceOf(address(escrowPool)) + escrowBalance + escrowToken.balanceOf(escrowBeneficiary),
            escrowLiability,
            "escrowed commission must stay in the pool, escrow, or beneficiary wallet"
        );
        assertEq(
            handler.ghostEscrowClaimedAmount() + escrowBalance + escrowPool.getReservedFees(),
            escrowLiability,
            "claimed, escrowed, and reserved commission must conserve the original liability"
        );
    }

    function invariant_escrowPinsOriginalBeneficiary() public view {
        address escrow = handler.commissionEscrow();
        if (escrow != address(0)) {
            assertEq(ProtectorCommissionEscrow(escrow).beneficiary(), escrowBeneficiary);
            assertEq(address(ProtectorCommissionEscrow(escrow).token()), address(escrowToken));
            assertEq(handler.ghostEscrowedAmount(), escrowLiability);
        }
    }

    function afterInvariant() public view {
        _assertNoUnexpectedReverts(SplitRiskPoolRetirementHandler.settleExpiredPosition.selector);
        _assertNoUnexpectedReverts(SplitRiskPoolRetirementHandler.escrowExpiredCommission.selector);
        _assertNoUnexpectedReverts(SplitRiskPoolRetirementHandler.claimEscrow.selector);

        if (requireRandomReachability) {
            _assertReached(SplitRiskPoolRetirementHandler.settleExpiredPosition.selector);
            _assertReached(SplitRiskPoolRetirementHandler.escrowExpiredCommission.selector);
            _assertReached(SplitRiskPoolRetirementHandler.claimEscrow.selector);
        }
    }

    function _assertNoUnexpectedReverts(bytes4 selector) internal view {
        (,,, uint256 unexpectedReverts) = handler.callMetrics(selector);
        assertEq(unexpectedReverts, 0, "modeled retirement action reverted unexpectedly");
    }

    function _assertReached(bytes4 selector) internal view {
        (uint256 attempts,, uint256 successes,) = handler.callMetrics(selector);
        assertGt(attempts, 0, "retirement action was never attempted");
        assertGt(successes, 0, "retirement action never reached its success path");
    }

    function test_retirementPathsAreReachable() public {
        handler.settleExpiredPosition();
        handler.escrowExpiredCommission();
        handler.claimEscrow();

        _assertReached(SplitRiskPoolRetirementHandler.settleExpiredPosition.selector);
        _assertReached(SplitRiskPoolRetirementHandler.escrowExpiredCommission.selector);
        _assertReached(SplitRiskPoolRetirementHandler.claimEscrow.selector);
        assertEq(handler.ghostSettledAmount(), settlementLiability);
        assertEq(handler.ghostExpiredReceiptTransfers(), 1);
        assertEq(handler.ghostEscrowedAmount(), escrowLiability);
        assertEq(handler.ghostEscrowClaimedAmount(), escrowLiability);
    }
}
