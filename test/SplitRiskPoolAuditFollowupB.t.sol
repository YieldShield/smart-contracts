// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { ConstantsLib } from "../contracts/libraries/ConstantsLib.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { IShieldReceiptNFT } from "../contracts/interfaces/IShieldReceiptNFT.sol";
import { ISplitRiskPoolFactory } from "../contracts/interfaces/ISplitRiskPoolFactory.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

/// @dev Minimal factory stand-in whose `tokenRequiresStrictProtectedPrice`
///      always reverts. The pool's initialize-time staticcall against this
///      address must therefore fail closed.
contract FailingStrictProbeFactory {
    function splitRiskPoolImplementation() external pure returns (address) {
        return address(0x1234);
    }

    function tokenRequiresStrictProtectedPrice(address) external pure returns (bool) {
        revert("probe failed");
    }
}

/// @title Audit follow-up B (2026-05-19): focused tests for fixes B4-B9
/// @notice Each test pins one of the six follow-up findings:
///         B4 commission overflow reverts, B5 whenNotPaused fee paths,
///         B6 same-asset withdraw also gates BACKING challenge, B7
///         _getShieldedSpotPrice internalises challenge guard, B8
///         governance backstop on setPoolFeeRecipient, B9 fail-closed
///         strict-pricing probe handling.
contract SplitRiskPoolAuditFollowupBTest is Test, TestTimelockHelper {
    using stdStorage for StdStorage;

    SplitRiskPool internal pool;
    MockERC4626 internal shieldedToken;
    MockERC4626 internal backingToken;
    MockOracle internal primaryOracle;
    MockOracle internal backupOracle;
    CompositeOracle internal compositeOracle;

    address internal poolCreator = address(0xC0FFEE);
    address internal protocolFeeRecipient = address(0xFEE);
    address internal protector = address(0xA11CE);
    address internal shielded = address(0xB0B);
    address internal governance;

    ShieldReceiptNFT internal shieldNFT;
    ProtectorReceiptNFT internal protectorNFT;

    bytes4 private constant ENFORCED_PAUSE = bytes4(keccak256("EnforcedPause()"));

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

        MockERC20 shieldedBase = new MockERC20("Shielded Base", "SB");
        MockERC20 backingBase = new MockERC20("Backing Base", "BB");
        shieldedToken = new MockERC4626(shieldedBase, "Shielded Vault", "svTOKEN");
        backingToken = new MockERC4626(backingBase, "Backing Vault", "bvTOKEN");

        primaryOracle = new MockOracle();
        backupOracle = new MockOracle();
        primaryOracle.setPrice(address(shieldedToken), 1e8);
        backupOracle.setPrice(address(shieldedToken), 1e8);
        primaryOracle.setPrice(address(backingToken), 1e8);
        backupOracle.setPrice(address(backingToken), 1e8);

        compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeedDual(address(shieldedToken), address(primaryOracle), address(backupOracle));
        compositeOracle.setTokenOracleFeedDual(address(backingToken), address(primaryOracle), address(backupOracle));

        pool = _deployPool(address(compositeOracle), address(this));

        shieldedToken.mintShares(shielded, 1_000_000e18);
        backingToken.mintShares(protector, 1_000_000e18);

        vm.prank(shielded);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.prank(protector);
        backingToken.approve(address(pool), type(uint256).max);
    }

    // ----------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------

    function _deployPool(address oracleAddr, address initialOwner) internal returns (SplitRiskPool deployedPool) {
        TokenWhitelistLib.TokenInfo memory shieldedInfo = TokenWhitelistLib.TokenInfo({
            name: "SHIELD",
            symbol: "SHIELD",
            token: address(shieldedToken),
            primaryOracleFeed: oracleAddr,
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });
        TokenWhitelistLib.TokenInfo memory backingInfo = TokenWhitelistLib.TokenInfo({
            name: "BACK",
            symbol: "BACK",
            token: address(backingToken),
            primaryOracleFeed: oracleAddr,
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        shieldNFT = new ShieldReceiptNFT("sSHIELD", "sSHIELD");
        protectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedInfo,
            backingInfo,
            1000, // commission rate
            500, // pool fee
            poolCreator,
            15000, // collateral ratio
            governance,
            oracleAddr,
            protocolFeeRecipient,
            address(shieldNFT),
            address(protectorNFT),
            initialOwner
        );

        deployedPool = SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));
        shieldNFT.setPool(address(deployedPool));
        protectorNFT.setPool(address(deployedPool));
        shieldNFT.transferOwnership(address(deployedPool));
        protectorNFT.transferOwnership(address(deployedPool));
    }

    function _seedPositions() internal returns (uint256 protectorTokenId, uint256 shieldTokenId) {
        vm.prank(protector);
        protectorTokenId = pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        vm.prank(shielded);
        shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 1_000e18, 0);
    }

    function _updateConfig(uint256 protocolFee, address recipient) internal {
        vm.prank(governance);
        pool.updatePoolConfig(
            1e18,
            1_000_000e18,
            1e18,
            1_000_000e18,
            1_000_000e8,
            1 days,
            28 days,
            protocolFee,
            recipient,
            address(compositeOracle)
        );
    }

    // ----------------------------------------------------------------------
    // B4: commission overflow → revert, not silent zero
    // ----------------------------------------------------------------------

    /// @notice claimRewards must revert when the commission accumulator is
    ///         already saturated and a new commission would overflow it.
    ///         Previously the bucket silently emitted FeeDropped and the
    ///         position's feeValueBaselineUsd advanced past the un-extracted
    ///         yield, permanently forgiving that commission.
    function test_B4_claimRewards_RevertsOnCommissionAccumulatorOverflow() public {
        (, uint256 shieldTokenId) = _seedPositions();

        // Saturate the commission bucket up to MAX_SAFE_ACCUMULATION so any
        // further commission would overflow the cap.
        stdstore.target(address(pool)).sig("accumulatedCommissions()").checked_write(ConstantsLib.MAX_SAFE_ACCUMULATION);

        // Move the shielded price up — this generates yield, which forces a
        // non-zero commissionAmount when claimRewards runs.
        primaryOracle.setPrice(address(shieldedToken), 1.1e8);
        backupOracle.setPrice(address(shieldedToken), 1.1e8);

        vm.warp(block.timestamp + 1 days + 1);

        uint256 baselineBefore = pool.feeValueBaselineUsd(shieldTokenId);
        uint256 commissionsBefore = pool.accumulatedCommissions();

        vm.prank(shielded);
        // Don't pin the exact revert args (commissionAmount depends on yield
        // rounding) — just confirm we get RewardAccumulationIncomplete, not
        // a silent success.
        vm.expectRevert();
        pool.claimRewards(shieldTokenId);

        // Baseline must NOT have advanced — that was the original bug.
        assertEq(
            pool.feeValueBaselineUsd(shieldTokenId), baselineBefore, "feeValueBaselineUsd must not advance on revert"
        );
        assertEq(pool.accumulatedCommissions(), commissionsBefore, "commissions must not have changed");
    }

    function test_B4_claimRewards_CarriesSubPrecisionProtectorRewardDust() public {
        (uint256 protectorTokenId, uint256 shieldTokenId) = _seedPositions();

        stdstore.target(address(pool)).sig("totalProtectorShares()").checked_write(type(uint128).max);
        primaryOracle.setPrice(address(shieldedToken), 1.1e8);
        backupOracle.setPrice(address(shieldedToken), 1.1e8);

        IShieldReceiptNFT.ShieldPosition memory positionBefore =
            IShieldReceiptNFT(pool.shieldReceiptNFT()).getPosition(shieldTokenId);
        uint256 rewardPerShareBefore = pool.rewardPerShareAccumulated();
        uint256 commissionsBefore = pool.accumulatedCommissions();
        uint256 reserveBefore = pool.currentEpochCommissionReserve();

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(shielded);
        pool.claimRewards(shieldTokenId);

        IShieldReceiptNFT.ShieldPosition memory positionAfter =
            IShieldReceiptNFT(pool.shieldReceiptNFT()).getPosition(shieldTokenId);
        uint256 carriedDust = pool.pendingProtectorRewardDust();
        assertGt(carriedDust, 0, "sub-precision commission must be carried");
        assertLt(positionAfter.amount, positionBefore.amount, "fees must still be collected");
        assertEq(pool.rewardPerShareAccumulated(), rewardPerShareBefore, "dust is not distributable yet");
        assertEq(pool.accumulatedCommissions(), commissionsBefore + carriedDust, "dust must stay reserved");
        assertEq(pool.currentEpochCommissionReserve(), reserveBefore + carriedDust, "dust tracks current epoch");

        stdstore.target(address(pool)).sig("totalProtectorShares()").checked_write(2_000e18);
        uint256 balanceBefore = shieldedToken.balanceOf(protector);

        vm.prank(protector);
        pool.claimCommission(protectorTokenId);

        uint256 received = shieldedToken.balanceOf(protector) - balanceBefore;
        uint256 pendingRemainder = pool.pendingProtectorRewardDust();
        assertGt(pool.rewardPerShareAccumulated(), rewardPerShareBefore, "reward accumulator must advance");
        assertGt(received, 0, "protector receives carried dust");
        assertLe(received, carriedDust, "protector cannot receive more than carried dust");
        assertEq(pendingRemainder, carriedDust - received, "reward-per-share remainder stays pending");
        assertEq(pool.accumulatedCommissions(), pendingRemainder, "rounding remainder stays reserved");
    }

    function test_B4_depositBackingRedirectsPendingDustBeforeMintingNewShares() public {
        (, uint256 shieldTokenId) = _seedPositions();

        stdstore.target(address(pool)).sig("totalProtectorShares()").checked_write(type(uint128).max);
        primaryOracle.setPrice(address(shieldedToken), 1.1e8);
        backupOracle.setPrice(address(shieldedToken), 1.1e8);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(shielded);
        pool.claimRewards(shieldTokenId);

        uint256 carriedDust = pool.pendingProtectorRewardDust();
        assertGt(carriedDust, 0, "test setup must create pending dust");

        address newProtector = address(0xCAFE);
        backingToken.mintShares(newProtector, 100e18);
        vm.prank(newProtector);
        backingToken.approve(address(pool), type(uint256).max);

        uint256 protocolFeeBefore = pool.accumulatedProtocolFee();
        uint256 commissionsBefore = pool.accumulatedCommissions();

        vm.prank(newProtector);
        pool.depositBackingAsset(address(backingToken), 100e18, 0);

        assertEq(pool.pendingProtectorRewardDust(), 0, "pending dust must be cleared before share mint");
        assertEq(pool.accumulatedProtocolFee(), protocolFeeBefore + carriedDust, "dust redirects to protocol");
        assertEq(pool.accumulatedCommissions(), commissionsBefore - carriedDust, "dust is no longer protector-reserved");
    }

    function test_B4_pendingDustRedirectDoesNotCreateUnbackedProtocolFees() public {
        _seedPositions();

        stdstore.target(address(pool)).sig("pendingProtectorRewardDust()").checked_write(uint256(1));
        stdstore.target(address(pool)).sig("accumulatedCommissions()").checked_write(uint256(0));
        stdstore.target(address(pool)).sig("currentEpochCommissionReserve()").checked_write(uint256(0));

        address newProtector = address(0xCAFE);
        backingToken.mintShares(newProtector, 100e18);
        vm.prank(newProtector);
        backingToken.approve(address(pool), type(uint256).max);

        uint256 protocolFeeBefore = pool.accumulatedProtocolFee();

        vm.prank(newProtector);
        pool.depositBackingAsset(address(backingToken), 100e18, 0);

        assertEq(pool.pendingProtectorRewardDust(), 0, "stale dust must be cleared before share mint");
        assertEq(pool.accumulatedProtocolFee(), protocolFeeBefore, "unbacked dust cannot become protocol fees");
        assertEq(pool.accumulatedCommissions(), 0, "commission reserve must stay flat");
    }

    function test_B4_claimRewards_RevertsWhenNoProtectorRedirectCannotFitProtocolBucket() public {
        (, uint256 shieldTokenId) = _seedPositions();
        _updateConfig(0, protocolFeeRecipient);

        stdstore.target(address(pool)).sig("totalProtectorShares()").checked_write(uint256(0));
        stdstore.target(address(pool)).sig("totalProtectorTokens()").checked_write(uint256(0));
        stdstore.target(address(pool)).sig("accumulatedProtocolFee()").checked_write(ConstantsLib.MAX_SAFE_ACCUMULATION);

        primaryOracle.setPrice(address(shieldedToken), 1.1e8);
        backupOracle.setPrice(address(shieldedToken), 1.1e8);
        vm.warp(block.timestamp + 1 days + 1);

        uint256 baselineBefore = pool.feeValueBaselineUsd(shieldTokenId);
        uint256 protocolFeeBefore = pool.accumulatedProtocolFee();

        vm.prank(shielded);
        vm.expectRevert();
        pool.claimRewards(shieldTokenId);

        assertEq(pool.feeValueBaselineUsd(shieldTokenId), baselineBefore, "baseline must not advance");
        assertEq(pool.accumulatedProtocolFee(), protocolFeeBefore, "protocol bucket must not change");
    }

    function test_B4_sameAssetWithdraw_RevertsAtomicallyOnCommissionAccumulatorOverflow() public {
        (, uint256 shieldTokenId) = _seedPositions();
        stdstore.target(address(pool)).sig("accumulatedCommissions()").checked_write(ConstantsLib.MAX_SAFE_ACCUMULATION);
        primaryOracle.setPrice(address(shieldedToken), 1.1e8);
        backupOracle.setPrice(address(shieldedToken), 1.1e8);

        IShieldReceiptNFT.ShieldPosition memory positionBefore =
            IShieldReceiptNFT(pool.shieldReceiptNFT()).getPosition(shieldTokenId);
        uint256 baselineBefore = pool.feeValueBaselineUsd(shieldTokenId);
        uint256 totalShieldedBefore = pool.totalShieldedTokens();
        uint256 totalValueBefore = pool.totalValueAtDeposit();
        uint256 totalCollateralBefore = pool.totalShieldCollateralAmount();
        uint256 commissionsBefore = pool.accumulatedCommissions();

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(shielded);
        vm.expectRevert();
        pool.shieldedWithdraw(shieldTokenId, address(shieldedToken), 0);

        IShieldReceiptNFT.ShieldPosition memory positionAfter =
            IShieldReceiptNFT(pool.shieldReceiptNFT()).getPosition(shieldTokenId);
        assertEq(shieldNFT.ownerOf(shieldTokenId), shielded, "NFT ownership must remain");
        assertEq(positionAfter.amount, positionBefore.amount, "position amount must not change");
        assertEq(positionAfter.valueAtDeposit, positionBefore.valueAtDeposit, "position value must not change");
        assertEq(positionAfter.collateralAmount, positionBefore.collateralAmount, "position collateral must not change");
        assertEq(pool.feeValueBaselineUsd(shieldTokenId), baselineBefore, "baseline must not advance");
        assertEq(pool.totalShieldedTokens(), totalShieldedBefore, "total shielded must not change");
        assertEq(pool.totalValueAtDeposit(), totalValueBefore, "total value must not change");
        assertEq(pool.totalShieldCollateralAmount(), totalCollateralBefore, "collateral total must not change");
        assertEq(pool.accumulatedCommissions(), commissionsBefore, "commissions must not change");
    }

    function test_B4_partialWithdraw_RevertsAtomicallyOnCommissionAccumulatorOverflow() public {
        (, uint256 shieldTokenId) = _seedPositions();
        stdstore.target(address(pool)).sig("accumulatedCommissions()").checked_write(ConstantsLib.MAX_SAFE_ACCUMULATION);
        primaryOracle.setPrice(address(shieldedToken), 1.1e8);
        backupOracle.setPrice(address(shieldedToken), 1.1e8);

        IShieldReceiptNFT.ShieldPosition memory positionBefore =
            IShieldReceiptNFT(pool.shieldReceiptNFT()).getPosition(shieldTokenId);
        uint256 nextTokenIdBefore = shieldNFT.nextTokenId();
        uint256 baselineBefore = pool.feeValueBaselineUsd(shieldTokenId);
        uint256 totalShieldedBefore = pool.totalShieldedTokens();
        uint256 totalValueBefore = pool.totalValueAtDeposit();
        uint256 totalCollateralBefore = pool.totalShieldCollateralAmount();
        uint256 commissionsBefore = pool.accumulatedCommissions();

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(shielded);
        vm.expectRevert();
        pool.partialWithdrawShielded(shieldTokenId, 100e18, address(shieldedToken), 0);

        IShieldReceiptNFT.ShieldPosition memory positionAfter =
            IShieldReceiptNFT(pool.shieldReceiptNFT()).getPosition(shieldTokenId);
        assertEq(shieldNFT.ownerOf(shieldTokenId), shielded, "old NFT ownership must remain");
        assertEq(shieldNFT.nextTokenId(), nextTokenIdBefore, "no replacement NFT should mint");
        assertEq(positionAfter.amount, positionBefore.amount, "position amount must not change");
        assertEq(positionAfter.valueAtDeposit, positionBefore.valueAtDeposit, "position value must not change");
        assertEq(positionAfter.collateralAmount, positionBefore.collateralAmount, "position collateral must not change");
        assertEq(pool.feeValueBaselineUsd(shieldTokenId), baselineBefore, "baseline must not advance");
        assertEq(pool.totalShieldedTokens(), totalShieldedBefore, "total shielded must not change");
        assertEq(pool.totalValueAtDeposit(), totalValueBefore, "total value must not change");
        assertEq(pool.totalShieldCollateralAmount(), totalCollateralBefore, "collateral total must not change");
        assertEq(pool.accumulatedCommissions(), commissionsBefore, "commissions must not change");
    }

    // ----------------------------------------------------------------------
    // B5: whenNotPaused on fee-extraction paths
    // ----------------------------------------------------------------------

    function test_B5_payPoolFee_RevertsWhenPaused() public {
        _seedPositions();

        vm.prank(governance);
        pool.pause();

        vm.prank(poolCreator);
        vm.expectRevert(ENFORCED_PAUSE);
        pool.payPoolFee();
    }

    function test_B5_payProtocolFee_RevertsWhenPaused() public {
        _seedPositions();

        vm.prank(governance);
        pool.pause();

        vm.prank(protocolFeeRecipient);
        vm.expectRevert(ENFORCED_PAUSE);
        pool.payProtocolFee();
    }

    function test_claimCommission_StaysCallableWhenPaused() public {
        // Pass-3 audit follow-up: B4 made commission-bucket overflow revert
        // with `RewardAccumulationIncomplete`, and `_tryCalculateAndAccumulateFees`
        // does not catch that revert. Once `accumulatedCommissions` saturates,
        // every fee-accruing withdrawal reverts until the bucket is drained —
        // and `claimCommission` is the ONLY drain path. Pause must therefore
        // NOT block `claimCommission`, otherwise a saturated+paused pool
        // traps every user exit. Companion `payPoolFee`, `payProtocolFee`,
        // and `claimRewards` remain pause-gated since they are user/operator
        // value-extraction surfaces unrelated to the drain mechanic.
        (uint256 protectorTokenId,) = _seedPositions();

        vm.prank(governance);
        pool.pause();

        vm.prank(protector);
        pool.claimCommission(protectorTokenId); // must not revert
    }

    function test_B5_claimRewards_RevertsWhenPaused() public {
        (, uint256 shieldTokenId) = _seedPositions();

        vm.prank(governance);
        pool.pause();

        vm.prank(shielded);
        vm.expectRevert(ENFORCED_PAUSE);
        pool.claimRewards(shieldTokenId);
    }

    // ----------------------------------------------------------------------
    // B6: same-asset shielded withdraw also gates BACKING_TOKEN challenge
    // ----------------------------------------------------------------------

    function test_B6_sameAssetWithdraw_RevertsOnBackingChallenge() public {
        (, uint256 shieldTokenId) = _seedPositions();

        // Trigger a backing-token dual-feed challenge: deviation across feeds
        // crosses threshold, then explicit challenge.
        backupOracle.setPrice(address(backingToken), 2e8);
        compositeOracle.challengeForToken(address(backingToken));

        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(backingToken)));
        pool.shieldedWithdraw(shieldTokenId, address(shieldedToken), 0);
    }

    function test_B6_partialWithdraw_RevertsOnBackingChallenge() public {
        (, uint256 shieldTokenId) = _seedPositions();

        backupOracle.setPrice(address(backingToken), 2e8);
        compositeOracle.challengeForToken(address(backingToken));

        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(backingToken)));
        pool.partialWithdrawShielded(shieldTokenId, 100e18, address(shieldedToken), 0);
    }

    // ----------------------------------------------------------------------
    // B7: _getShieldedSpotPrice internalises challenge guard
    // ----------------------------------------------------------------------

    /// @notice Any caller of `_getShieldedSpotPrice` must now see a revert
    ///         when the shielded leg is challengeable, even if the caller
    ///         itself didn't gate. Backing-asset deposits use the spot
    ///         fallback path in `_validateDeposit`; the test uses a deviation
    ///         (challengeable, not yet challenged) to also exercise the
    ///         `_hasOracleChallengeablePrice` half of the guard.
    function test_B7_getShieldedSpotPrice_RevertsOnShieldedChallengeable() public {
        // First seed a backing position so the deposit path is reachable.
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 1_000e18, 0);

        // Push the primary shielded feed off the backup — this makes the
        // shielded leg challengeable. We don't formally challenge so we
        // exercise the second half of the guard.
        primaryOracle.setPrice(address(shieldedToken), 2e8);

        vm.prank(protector);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        pool.depositBackingAsset(address(backingToken), 1_000e18, 0);
    }

    // ----------------------------------------------------------------------
    // B8: M-14 governance backstop on setPoolFeeRecipient
    // ----------------------------------------------------------------------

    function test_B8_setPoolFeeRecipient_GovernanceTimelockCanRotate() public {
        address newRecipient = address(0xD00D);

        vm.prank(governance);
        pool.setPoolFeeRecipient(newRecipient);

        assertEq(pool.poolFeeRecipient(), newRecipient, "governance must be able to rotate fee recipient");
    }

    function test_B8_setPoolFeeRecipient_PoolCreatorStillCanRotate() public {
        address newRecipient = address(0xBEEF);

        vm.prank(poolCreator);
        pool.setPoolFeeRecipient(newRecipient);

        assertEq(pool.poolFeeRecipient(), newRecipient, "POOL_CREATOR must still be able to rotate fee recipient");
    }

    function test_B8_setPoolFeeRecipient_UnauthorizedReverts() public {
        address attacker = address(0xBAD);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AccessControlDenied.selector, attacker, "setPoolFeeRecipient"));
        pool.setPoolFeeRecipient(address(0xCAFE));
    }

    function test_B8_setPoolFeeRecipient_RevertsForPoolItself() public {
        vm.prank(poolCreator);
        vm.expectRevert(ErrorsLib.InvalidProtocolFeeRecipient.selector);
        pool.setPoolFeeRecipient(address(pool));
    }

    function test_B8_updatePoolConfig_RevertsWhenProtocolFeeRecipientIsPoolItself() public {
        vm.expectRevert(ErrorsLib.InvalidProtocolFeeRecipient.selector);
        _updateConfig(100, address(pool));
    }

    // ----------------------------------------------------------------------
    // B9: H-5 init-time fail-closed strict-pricing probe failure
    // ----------------------------------------------------------------------

    /// @notice When a contract factory's `tokenRequiresStrictProtectedPrice`
    ///         staticcall reverts at init time, the pool must fail closed
    ///         instead of pinning the snapshot to false.
    function test_B9_initRevertsWhenContractFactoryStrictPricingProbeFails() public {
        FailingStrictProbeFactory failingFactory = new FailingStrictProbeFactory();

        TokenWhitelistLib.TokenInfo memory shieldedInfo = TokenWhitelistLib.TokenInfo({
            name: "SHIELD",
            symbol: "SHIELD",
            token: address(shieldedToken),
            primaryOracleFeed: address(compositeOracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });
        TokenWhitelistLib.TokenInfo memory backingInfo = TokenWhitelistLib.TokenInfo({
            name: "BACK",
            symbol: "BACK",
            token: address(backingToken),
            primaryOracleFeed: address(compositeOracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        ShieldReceiptNFT freshShieldNFT = new ShieldReceiptNFT("sSHIELD", "sSHIELD");
        ProtectorReceiptNFT freshProtectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedInfo,
            backingInfo,
            1000,
            500,
            poolCreator,
            15000,
            governance,
            address(compositeOracle),
            protocolFeeRecipient,
            address(freshShieldNFT),
            address(freshProtectorNFT),
            address(failingFactory) // initialOwner — also the staticcall target
        );

        vm.expectRevert(ErrorsLib.InvalidAssetAddress.selector);
        new ERC1967Proxy(address(implementation), initData);
    }
}
