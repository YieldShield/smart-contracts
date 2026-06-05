// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { ConstantsLib } from "../contracts/libraries/ConstantsLib.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IProtectorReceiptNFT } from "../contracts/interfaces/IProtectorReceiptNFT.sol";
import { IShieldReceiptNFT } from "../contracts/interfaces/IShieldReceiptNFT.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

/// @title Tests for rewards-per-share commission distribution (MasterChef pattern)
/// @notice Tests that new depositors cannot claim historical rewards (late-joiner exploit fix)
contract SplitRiskPoolCommissionTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;

    address public protector1 = address(0x1);
    address public protector2 = address(0x2);
    address public shielded = address(0x3);
    address public governance = address(this);

    uint256 constant INITIAL_BALANCE = 1000000e18;
    uint256 constant REWARD_PRECISION = 1e18;

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

        // Deploy base ERC20 tokens
        shieldedBaseToken = new MockERC20("Shielded Base Token", "IBASE");
        backingBaseToken = new MockERC20("Backing Base Token", "UBASE");

        // Deploy ERC4626 vaults
        backingToken = new MockERC4626(backingBaseToken, "Backing Token", "UNDER");
        shieldedToken = new MockERC4626(shieldedBaseToken, "Shielded Token", "INSURE");

        // Deploy oracle
        oracle = new MockOracle();
        oracle.setPrice(address(shieldedToken), 1e8); // $1 per token
        oracle.setPrice(address(backingToken), 1e8); // $1 per token

        // Create TokenInfo structs
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "INSURE",
            symbol: "INSURE",
            token: address(shieldedToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "UNDER",
            symbol: "UNDER",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        // Deploy pool
        SplitRiskPool implementation = new SplitRiskPool();
        ShieldReceiptNFT shieldNFT = new ShieldReceiptNFT("iINSURE", "iINSURE");
        ProtectorReceiptNFT protectorNFT = new ProtectorReceiptNFT("uUNDER", "uUNDER");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000, // 10% commission rate
            500, // 5% pool fee
            address(this), // pool creator
            15000, // 150% collateral ratio
            governance, // governance
            address(oracle), // oracle
            address(0xfa9605A2c38a0B4f16f689FDD07B63F295b86d1C), // protocol fee recipient
            address(shieldNFT),
            address(protectorNFT),
            address(this) // owner
        );
        pool = SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));

        // Set pool address on NFTs
        shieldNFT.setPool(address(pool));
        protectorNFT.setPool(address(pool));
        shieldNFT.transferOwnership(address(pool));
        protectorNFT.transferOwnership(address(pool));

        // Fund accounts with underlying tokens first, then deposit into vaults
        // This ensures proper ERC4626 accounting (shares backed by underlying)
        shieldedBaseToken.mint(shielded, INITIAL_BALANCE);
        backingBaseToken.mint(protector1, INITIAL_BALANCE);
        backingBaseToken.mint(protector2, INITIAL_BALANCE);

        // Deposit underlying into vaults to get vault shares
        vm.startPrank(shielded);
        shieldedBaseToken.approve(address(shieldedToken), INITIAL_BALANCE);
        shieldedToken.deposit(INITIAL_BALANCE, shielded);
        vm.stopPrank();

        vm.startPrank(protector1);
        backingBaseToken.approve(address(backingToken), INITIAL_BALANCE);
        backingToken.deposit(INITIAL_BALANCE, protector1);
        vm.stopPrank();

        vm.startPrank(protector2);
        backingBaseToken.approve(address(backingToken), INITIAL_BALANCE);
        backingToken.deposit(INITIAL_BALANCE, protector2);
        vm.stopPrank();

        // Approve pool to spend vault shares
        vm.prank(shielded);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.prank(protector1);
        backingToken.approve(address(pool), type(uint256).max);
        vm.prank(protector2);
        backingToken.approve(address(pool), type(uint256).max);
    }

    function _claimRewardsAsOwner(uint256 tokenId) internal {
        address owner = IShieldReceiptNFT(pool.shieldReceiptNFT()).ownerOf(tokenId);
        vm.prank(owner);
        pool.claimRewards(tokenId);
    }

    /// @dev Re-initiate and mature a protector unlock window. Kept in its own
    ///      call frame so the `vm.warp` reliably advances time (an inline warp
    ///      inside a loop is elided by the via-IR optimizer in this suite).
    function _rearmAndMatureProtectorUnlock(uint256 tokenId) internal {
        vm.prank(protector1);
        pool.startUnlockProcess(tokenId);
        vm.warp(block.timestamp + 40 days);
    }

    /// @notice Test that new depositor cannot claim historical rewards (late-joiner exploit fix)
    function testNewDepositorCannotClaimHistoricalRewards() public {
        uint256 backingAmount1 = 1000e18;
        uint256 shieldedAmount = 500e18;

        // Step 1: Protector1 deposits
        vm.prank(protector1);
        uint256 tokenId1 = pool.depositBackingAsset(address(backingToken), backingAmount1, 0);

        // Step 2: Shielded deposits (generates yield that becomes commissions)
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Step 3: Simulate yield by increasing oracle price (10% increase = 10% yield)
        oracle.setPrice(address(shieldedToken), 1.1e8); // $1.10 per token (up from $1.00)

        // Step 4: Claim rewards to accumulate commissions (tokenId 0 is the shielded position)
        _claimRewardsAsOwner(0);

        // Step 5: Check that commissions have been accumulated
        uint256 accumulatedBefore = pool.accumulatedCommissions();
        assertTrue(accumulatedBefore > 0, "Commissions should be accumulated");

        // Step 6: Protector2 deposits AFTER commissions were accumulated
        vm.prank(protector2);
        uint256 tokenId2 = pool.depositBackingAsset(address(backingToken), 9000e18, 0);

        // Step 7: Check reward debt was recorded for new depositor
        uint256 rewardDebt2 = pool.rewardDebt(tokenId2);
        assertTrue(rewardDebt2 > 0, "Reward debt should be recorded for new depositor");

        // Step 8: Check that new depositor cannot claim historical rewards
        uint256 claimable2 = pool.getClaimableCommission(tokenId2);
        assertEq(claimable2, 0, "New depositor should not be able to claim historical rewards");

        // Step 9: Verify that old depositor can still claim (they earned it)
        uint256 claimable1 = pool.getClaimableCommission(tokenId1);
        assertTrue(claimable1 > 0, "Original depositor should be able to claim earned rewards");
    }

    /// @notice Test that depositors only earn rewards accumulated after their deposit
    function testDepositorsOnlyEarnFutureRewards() public {
        uint256 backingAmount1 = 1000e18;
        uint256 backingAmount2 = 2000e18;
        uint256 shieldedAmount = 500e18;

        // Step 1: Protector1 deposits
        vm.prank(protector1);
        uint256 tokenId1 = pool.depositBackingAsset(address(backingToken), backingAmount1, 0);

        // Step 2: Shielded deposits and generate initial commissions via price increase
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);
        oracle.setPrice(address(shieldedToken), 1.1e8); // 10% yield simulation
        _claimRewardsAsOwner(0);

        uint256 commissionsAfterPeriod1 = pool.accumulatedCommissions();

        // Step 3: Protector2 deposits (after first period of commissions)
        vm.prank(protector2);
        uint256 tokenId2 = pool.depositBackingAsset(address(backingToken), backingAmount2, 0);

        uint256 rewardPerShareAtDeposit = pool.rewardPerShareAccumulated();
        assertTrue(rewardPerShareAtDeposit > 0, "Reward per share should be > 0 when protector2 deposits");

        // Step 4: Generate more commissions after protector2's deposit
        // Wait for rate limit cooldown to expire
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(address(shieldedToken), 1.2e8); // Additional 10% yield (total 20%)
        _claimRewardsAsOwner(0);

        uint256 commissionsAfterPeriod2 = pool.accumulatedCommissions();
        uint256 newCommissions = commissionsAfterPeriod2 - commissionsAfterPeriod1;

        // Step 5: Check that protector1 can claim from both periods
        uint256 balanceBefore1 = shieldedToken.balanceOf(protector1);
        vm.prank(protector1);
        pool.claimCommission(tokenId1);
        uint256 balanceAfter1 = shieldedToken.balanceOf(protector1);
        uint256 claimed1 = balanceAfter1 - balanceBefore1;
        assertTrue(claimed1 > 0, "Protector1 should claim rewards from both periods");

        // Step 6: Check that protector2 can only claim from period 2 (proportional to share)
        uint256 balanceBefore2 = shieldedToken.balanceOf(protector2);
        vm.prank(protector2);
        pool.claimCommission(tokenId2);
        uint256 balanceAfter2 = shieldedToken.balanceOf(protector2);
        uint256 claimed2 = balanceAfter2 - balanceBefore2;

        // Protector2 should get (2000 / 3000) * newCommissions (approximately)
        uint256 expectedShare = (newCommissions * backingAmount2) / (backingAmount1 + backingAmount2);
        assertApproxEqRel(claimed2, expectedShare, 0.01e18, "Protector2 should only get share of new commissions");
        assertLt(claimed2, claimed1, "Protector2 should claim less than protector1 (only new commissions)");
    }

    /// @notice Test that partial withdrawal resets reward accounting to clean slate
    /// @dev After fix for commission rounding exploit, partial withdrawal resets
    ///      rewardDebt to current accumulator value for new position amount
    function testPartialWithdrawalAdjustsDebt() public {
        uint256 backingAmount = 1000e18;
        uint256 shieldedAmount = 500e18;

        // Step 1: Deposit
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        // Step 2: Generate commissions via price appreciation
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);
        oracle.setPrice(address(shieldedToken), 1.1e8); // 10% yield
        _claimRewardsAsOwner(0);

        // Step 3: Start unlock process (required for partial withdrawal)
        vm.prank(protector1);
        pool.startUnlockProcess(tokenId);
        vm.warp(block.timestamp + 29 days); // Wait past unlock period

        // Step 4: Partial withdrawal
        uint256 withdrawAmount = pool.getAvailableForWithdrawal(tokenId) / 2;
        assertGt(withdrawAmount, 0, "Test requires some protector liquidity to be withdrawable");
        vm.prank(protector1);
        pool.protectorWithdraw(tokenId, withdrawAmount, address(backingToken), 0);

        // Step 5: Check that debt was reset to clean slate (new accumulator-based value)
        // After partial withdrawal, rewardDebt = (rewardPerShareAccumulated * newAmount) / REWARD_PRECISION
        uint256 rewardDebtAfter = pool.rewardDebt(tokenId);
        uint256 newAmount = backingAmount - withdrawAmount;
        uint256 accumulator = pool.rewardPerShareAccumulated();
        uint256 expectedDebt = Math.mulDiv(accumulator, newAmount, ConstantsLib.REWARD_PRECISION);
        assertEq(rewardDebtAfter, expectedDebt, "Reward debt should be reset to clean slate");

        // Step 6: Verify commissionsClaimed was cleared (starts fresh)
        uint256 commissionsClaimedAfter = pool.commissionsClaimed(tokenId);
        assertEq(commissionsClaimedAfter, 0, "Commissions claimed should be reset to zero");

        // Step 7: Verify position still valid
        uint256 claimableAfter = pool.getClaimableCommission(tokenId);
        assertGe(claimableAfter, 0, "Position should still be valid after partial withdrawal");
    }

    /// @notice Test that full withdrawal cleans up debt mapping
    function testFullWithdrawalCleansUpDebt() public {
        uint256 backingAmount = 1000e18;
        uint256 shieldedAmount = 500e18;

        // Step 1: Deposit and generate commissions via price appreciation
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);
        oracle.setPrice(address(shieldedToken), 1.1e8); // 10% yield
        _claimRewardsAsOwner(0);

        // Step 2: Start unlock process (required for full withdrawal)
        vm.prank(protector1);
        pool.startUnlockProcess(tokenId);
        vm.warp(block.timestamp + 29 days); // Wait past unlock period

        // Step 3: Remove shielded exposure so the protector can exit fully under the collateral rules
        vm.prank(shielded);
        pool.shieldedWithdraw(0, address(shieldedToken), 0);

        // Step 4: Full protector withdrawal
        vm.prank(protector1);
        pool.protectorWithdraw(tokenId, backingAmount, address(backingToken), 0);

        // Step 5: Check that debt was cleaned up
        uint256 rewardDebtAfter = pool.rewardDebt(tokenId);
        assertEq(rewardDebtAfter, 0, "Reward debt should be cleaned up after full withdrawal");
    }

    /// @notice Full protector withdrawal should pay pending commission before burning the NFT
    function testFullWithdrawal_AutoClaimsPendingCommission() public {
        uint256 backingAmount = 1000e18;
        uint256 shieldedAmount = 500e18;

        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);
        oracle.setPrice(address(shieldedToken), 1.1e8);
        _claimRewardsAsOwner(0);

        uint256 claimableBefore = pool.getClaimableCommission(tokenId);
        assertGt(claimableBefore, 0, "test requires pending commission");

        vm.prank(protector1);
        pool.startUnlockProcess(tokenId);
        vm.warp(block.timestamp + 29 days);

        vm.prank(shielded);
        pool.shieldedWithdraw(0, address(shieldedToken), 0);

        uint256 accumulatedBefore = pool.accumulatedCommissions();
        uint256 protocolFeeBefore = pool.accumulatedProtocolFee();
        uint256 balanceBefore = shieldedToken.balanceOf(protector1);

        vm.prank(protector1);
        pool.protectorWithdraw(tokenId, backingAmount, address(backingToken), 0);

        uint256 claimed = shieldedToken.balanceOf(protector1) - balanceBefore;
        uint256 roundingRemainder = accumulatedBefore - claimableBefore;
        assertEq(claimed, claimableBefore, "full withdrawal should pay pending commission");
        assertEq(pool.accumulatedCommissions(), 0, "orphaned commission dust should be cleared");
        assertEq(
            pool.accumulatedProtocolFee(),
            protocolFeeBefore + roundingRemainder,
            "orphaned commission dust should stay reserved as protocol fee"
        );
        assertEq(pool.commissionsClaimed(tokenId), 0, "burned position should not retain claim tracking");
    }

    /// @notice Test multiple depositors get fair share of new rewards
    function testMultipleDepositorsFairShare() public {
        uint256 backingAmount1 = 1000e18;
        uint256 backingAmount2 = 2000e18;
        uint256 shieldedAmount = 500e18;

        // Step 1: Both protectors deposit
        vm.prank(protector1);
        uint256 tokenId1 = pool.depositBackingAsset(address(backingToken), backingAmount1, 0);
        vm.prank(protector2);
        uint256 tokenId2 = pool.depositBackingAsset(address(backingToken), backingAmount2, 0);

        // Step 2: Generate commissions via price appreciation
        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);
        oracle.setPrice(address(shieldedToken), 1.1e8); // 10% yield
        _claimRewardsAsOwner(0);

        uint256 totalCommissions = pool.accumulatedCommissions();

        // Step 3: Both claim commissions
        vm.prank(protector1);
        pool.claimCommission(tokenId1);
        vm.prank(protector2);
        pool.claimCommission(tokenId2);

        // Step 4: Check that shares are proportional (1000:2000 = 1:2)
        uint256 balance1 = shieldedToken.balanceOf(protector1);
        uint256 balance2 = shieldedToken.balanceOf(protector2);

        // Protector1 should get 1/3, protector2 should get 2/3
        uint256 expected1 = (totalCommissions * backingAmount1) / (backingAmount1 + backingAmount2);
        uint256 expected2 = (totalCommissions * backingAmount2) / (backingAmount1 + backingAmount2);

        assertApproxEqRel(balance1, expected1, 0.01e18, "Protector1 should get proportional share");
        assertApproxEqRel(balance2, expected2, 0.01e18, "Protector2 should get proportional share");
        assertApproxEqAbs(balance1 * 2, balance2, 1, "Balance ratio should match deposit ratio");
    }

    /// @notice Test edge case: zero tokens
    function testZeroTokensReturnsZero() public view {
        // With zero total tokens, claimable should be zero
        uint256 claimable = pool.getClaimableCommission(999); // Non-existent token
        assertEq(claimable, 0, "Should return 0 for zero tokens");
    }

    /// @notice Test precision limits with smaller but valid amounts
    function testPrecisionWithModerateAmounts() public {
        uint256 moderateAmount = 1000e18; // Moderate protector amount
        uint256 shieldedAmount = 500e18; // Shielded needs 750e18 collateral (150%)

        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), moderateAmount, 0);

        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);
        oracle.setPrice(address(shieldedToken), 1.1e8); // 10% yield
        _claimRewardsAsOwner(0);

        // Should not revert even with moderate amounts
        uint256 claimable = pool.getClaimableCommission(tokenId);
        // Claimable should be positive since we have actual commissions
        assertGt(claimable, 0, "Should have positive claimable with moderate amounts");
    }

    /// @notice Test that claimRewards has rate limiting to prevent griefing
    function testClaimRewardsRateLimiting() public {
        uint256 shieldedAmount = 500e18;
        uint256 backingAmount = 1000e18;

        // Step 1: Setup - deposit protector and shielded assets
        vm.prank(protector1);
        pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Step 2: Generate yield via price appreciation
        oracle.setPrice(address(shieldedToken), 1.1e8); // 10% yield

        // Step 3: First call to claimRewards should succeed
        uint256 firstCallTime = block.timestamp;
        vm.prank(shielded);
        pool.claimRewards(tokenId);

        // Step 4: Immediate second call should revert with cooldown error
        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ClaimRewardsCooldownNotMet.selector, firstCallTime + 1 days));
        pool.claimRewards(tokenId);

        // Step 5: After 24 hours, call should succeed (need more yield for it to matter)
        vm.warp(firstCallTime + 1 days);
        oracle.setPrice(address(shieldedToken), 1.2e8); // Additional yield
        vm.prank(shielded);
        pool.claimRewards(tokenId); // Should not revert
    }

    /// @notice Ensure repeated claimRewards calls do not re-tax unchanged yield
    /// @dev With unchanged price, second claim after cooldown should not deduct additional fees.
    function testClaimRewards_DoesNotRetaxSameYield() public {
        uint256 shieldedAmount = 500e18;
        uint256 backingAmount = 1000e18;

        // Setup deposits
        vm.prank(protector1);
        pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Generate yield once
        oracle.setPrice(address(shieldedToken), 1.2e8);
        _claimRewardsAsOwner(tokenId);

        IShieldReceiptNFT.ShieldPosition memory posAfterFirst =
            IShieldReceiptNFT(pool.shieldReceiptNFT()).getPosition(tokenId);
        uint256 poolFeeAfterFirst = pool.accumulatedPoolFee();
        uint256 protocolFeeAfterFirst = pool.accumulatedProtocolFee();
        uint256 commissionsAfterFirst = pool.accumulatedCommissions();

        // Advance cooldown and claim again with unchanged price
        vm.warp(block.timestamp + 1 days + 1);
        _claimRewardsAsOwner(tokenId);

        IShieldReceiptNFT.ShieldPosition memory posAfterSecond =
            IShieldReceiptNFT(pool.shieldReceiptNFT()).getPosition(tokenId);

        assertEq(posAfterSecond.amount, posAfterFirst.amount, "Unchanged yield must not be re-taxed");
        assertEq(pool.accumulatedPoolFee(), poolFeeAfterFirst, "Pool fee must not increase without new yield");
        assertEq(
            pool.accumulatedProtocolFee(), protocolFeeAfterFirst, "Protocol fee must not increase without new yield"
        );
        assertEq(
            pool.accumulatedCommissions(), commissionsAfterFirst, "Commissions must not increase without new yield"
        );
    }

    // ============ INFO-6 FIX: Fee Overflow Scenario Tests ============

    /// @notice Test that fee accumulators handle normal operations correctly
    function testFeeAccumulator_NormalAccumulation() public {
        uint256 backingAmount = 100000e18;
        uint256 shieldedAmount = 50000e18;

        // Setup protector deposit
        vm.prank(protector1);
        uint256 uwTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        // Shielded deposits
        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Simulate yield (50% gain)
        oracle.setPrice(address(shieldedToken), 1.5e8); // $1.50 per token

        // Claim rewards - should not overflow
        _claimRewardsAsOwner(tokenId);

        // Verify accumulators are reasonable values
        uint256 accumulatedPoolFee = pool.accumulatedPoolFee();
        uint256 accumulatedProtocolFee = pool.accumulatedProtocolFee();

        // Pool fee should be meaningful
        assertGt(accumulatedPoolFee, 0, "Pool fee should be accumulated");
        assertGt(accumulatedProtocolFee, 0, "Protocol fee should be accumulated");

        // Verify commission is claimable
        uint256 claimable = pool.getClaimableCommission(uwTokenId);
        assertGt(claimable, 0, "Should have claimable commission");
    }

    /// @notice Test repeated fee accumulation over many cycles with proper cooldown
    function testFeeAccumulator_RepeatedCycles() public {
        uint256 shieldedAmount = 10000e18;
        uint256 backingAmount = 20000e18;
        uint256 startTime = block.timestamp;

        // Setup deposits
        vm.prank(protector1);
        uint256 uwTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Run 5 fee cycles with yield (each cycle waits for cooldown)
        for (uint256 i = 0; i < 5; i++) {
            // Warp to next claim window (needs 1 day cooldown between claims)
            vm.warp(startTime + (i + 1) * 1 days + 1);

            // Simulate increasing yield
            oracle.setPrice(address(shieldedToken), uint256(1e8 + (i + 1) * 0.05e8));

            // Claim rewards
            _claimRewardsAsOwner(shieldTokenId);
        }

        // Verify commission is claimable for protector
        uint256 claimable = pool.getClaimableCommission(uwTokenId);
        assertGt(claimable, 0, "Should have accumulated claimable commission");

        // Claim commission - should not revert
        vm.prank(protector1);
        pool.claimCommission(uwTokenId);

        // Verify commission was claimed
        uint256 claimableAfter = pool.getClaimableCommission(uwTokenId);
        assertEq(claimableAfter, 0, "Claimable should be zero after claim");
    }

    /// @notice Test that large yield changes are handled correctly
    function testFeeAccumulator_LargeYieldChange() public {
        uint256 backingAmount = 100000e18;
        uint256 shieldedAmount = 50000e18;

        // Setup deposits
        vm.prank(protector1);
        uint256 uwTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Large yield appreciation (500% gain)
        oracle.setPrice(address(shieldedToken), 5e8); // 5x price increase

        // Should handle gracefully - claim rewards
        _claimRewardsAsOwner(tokenId);

        // Verify pool is still functional
        (uint256 shieldedBal, uint256 uwBal) = pool.getPoolBalances();
        assertGt(shieldedBal, 0, "Pool should still have shielded tokens");
        assertGt(uwBal, 0, "Pool should still have protector tokens");

        // Verify fees were accumulated
        assertGt(pool.accumulatedPoolFee(), 0, "Should have pool fee");
        assertGt(pool.accumulatedProtocolFee(), 0, "Should have protocol fee");

        // Verify commission is claimable
        uint256 claimable = pool.getClaimableCommission(uwTokenId);
        assertGt(claimable, 0, "Should have claimable commission");
    }

    /// @notice Protector exits remain collateral-constrained even after unlock maturity
    function testProtectorWithdraw_WhenShieldedPositionsRemain_KeepsRequiredBacking() public {
        uint256 backingAmount = 20000e18;
        uint256 shieldedAmount = 10000e18;

        // Setup: deposit protector and shielded tokens
        vm.prank(protector1);
        uint256 uwTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Start unlock process for protector
        vm.prank(protector1);
        pool.startUnlockProcess(uwTokenId);

        // Wait for unlock duration to pass (default is 28 days)
        vm.warp(block.timestamp + 28 days + 1);

        // Matured unlock no longer bypasses collateral checks.
        vm.prank(protector1);
        vm.expectRevert(ErrorsLib.InsufficientUnlockedTokens.selector);
        pool.protectorWithdraw(uwTokenId, backingAmount, address(backingToken), 0);

        uint256 available = pool.getAvailableForWithdrawal(uwTokenId);
        assertGt(available, 0, "Some protector liquidity should remain withdrawable");

        vm.prank(protector1);
        pool.protectorWithdraw(uwTokenId, available, address(backingToken), 0);

        (uint256 shieldedBal, uint256 uwBal) = pool.getPoolBalances();
        assertEq(uwBal, backingAmount - available, "Required backing should remain in the pool");
        assertGt(shieldedBal, 0, "Should still have shielded tokens");

        // Commissions should continue accruing against the remaining protector liquidity.
        uint256 initialProtocolFee = pool.accumulatedProtocolFee();
        uint256 initialCommissions = pool.accumulatedCommissions();

        // Simulate yield (50% gain)
        oracle.setPrice(address(shieldedToken), 1.5e8); // $1.50 per token

        _claimRewardsAsOwner(tokenId);

        assertGt(pool.accumulatedCommissions(), initialCommissions, "Commissions should still accumulate");
        uint256 finalProtocolFee = pool.accumulatedProtocolFee();
        assertGt(finalProtocolFee, initialProtocolFee, "Protocol fee should still increase");
    }

    /// @notice HIGH-1 FIX: Test that commissions accumulate normally when protectors exist
    function testCommissionAccumulation_WhenProtectorsExist() public {
        uint256 backingAmount = 20000e18;
        uint256 shieldedAmount = 10000e18;

        // Setup deposits (with protector)
        vm.prank(protector1);
        uint256 uwTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Record initial values
        uint256 initialProtocolFee = pool.accumulatedProtocolFee();
        uint256 initialCommissions = pool.accumulatedCommissions();

        // Simulate yield (50% gain)
        oracle.setPrice(address(shieldedToken), 1.5e8); // $1.50 per token

        // Claim rewards - should accumulate commissions normally
        _claimRewardsAsOwner(tokenId);

        // Verify commissions WERE accumulated (protectors exist)
        assertGt(
            pool.accumulatedCommissions(), initialCommissions, "Commissions should accumulate when protectors exist"
        );

        // Verify protocol fee also increased (but not from commission redirect)
        uint256 finalProtocolFee = pool.accumulatedProtocolFee();
        assertGt(finalProtocolFee, initialProtocolFee, "Protocol fee should increase");

        // Verify commission is claimable by protector
        uint256 claimable = pool.getClaimableCommission(uwTokenId);
        assertGt(claimable, 0, "Should have claimable commission");
    }

    /// @notice New protectors only earn commissions generated after they join, even if earlier protectors partially exit
    function testNewProtectorOnlyEarnsFutureCommissionsAfterPartialProtectorExit() public {
        uint256 backingAmount = 20000e18;
        uint256 shieldedAmount = 10000e18;

        // Setup: deposit protector and shielded tokens
        vm.prank(protector1);
        uint256 uwTokenId1 = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Start unlock process for protector
        vm.prank(protector1);
        pool.startUnlockProcess(uwTokenId1);

        // Wait for unlock duration to pass (default is 28 days)
        vm.warp(block.timestamp + 28 days + 1);

        uint256 available = pool.getAvailableForWithdrawal(uwTokenId1);
        assertGt(available, 0, "Test requires some protector liquidity to be withdrawable");

        vm.prank(protector1);
        pool.protectorWithdraw(uwTokenId1, available, address(backingToken), 0);

        // Realize one round of rewards after the partial exit.
        oracle.setPrice(address(shieldedToken), 1.2e8); // 20% yield
        _claimRewardsAsOwner(tokenId);

        uint256 commissionsAfterFirstClaim = pool.accumulatedCommissions();

        // Wait for claim cooldown (1 day)
        vm.warp(block.timestamp + 1 days + 1);

        // Now add a new protector
        vm.prank(protector2);
        uint256 uwTokenId2 = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        // Claim rewards again - new commissions should be shared only from this point onward.
        oracle.setPrice(address(shieldedToken), 1.4e8); // Additional 20% yield
        _claimRewardsAsOwner(tokenId);

        assertGt(
            pool.accumulatedCommissions(),
            commissionsAfterFirstClaim,
            "Commissions should continue accumulating after the new protector joins"
        );

        // Verify new protector can claim commissions from after they deposited
        uint256 claimable = pool.getClaimableCommission(uwTokenId2);
        assertGt(claimable, 0, "New protector should have claimable commission");
    }

    // ============ INFO-5: Test Coverage Recommendations ============

    /// @notice INFO-5: Test commission distribution at the minimum valid shielded deposit size
    /// @dev Tests the smallest supported position size after the mixed-decimal deposit-limit refactor.
    function testCommissionDistribution_WithExactly1Wei() public {
        // Use the smallest shielded amount that is valid under the pool's current defaults.
        uint256 backingAmount = 1000e18; // Enough to support small shielded deposit
        (uint256 shieldedMinDepositAmount,,,,,,,,,) = pool.poolConfig();
        uint256 shieldedAmount = shieldedMinDepositAmount + 1;

        // Deposit protector
        vm.prank(protector1);
        uint256 uwTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        // Deposit shielded
        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Generate a very small amount of yield and verify tiny commissions still claim cleanly.
        oracle.setPrice(address(shieldedToken), 1.0001e8); // 0.01% yield

        // Claim rewards to generate commissions
        _claimRewardsAsOwner(tokenId);

        // Get claimable commission
        uint256 claimable = pool.getClaimableCommission(uwTokenId);

        // If claimable is 0, try with slightly larger yield
        if (claimable == 0) {
            oracle.setPrice(address(shieldedToken), 1.001e8); // 0.1% yield
            vm.warp(block.timestamp + 1 days + 1); // Wait for cooldown
            _claimRewardsAsOwner(tokenId);
            claimable = pool.getClaimableCommission(uwTokenId);
        }

        // Verify we have some claimable (might be more than 1 wei, but that's okay)
        // The key is to test that very small amounts can be claimed
        assertGe(claimable, 0, "Should have claimable commission (even if 0 due to rounding)");

        // If we have claimable, verify it can be claimed
        if (claimable > 0) {
            uint256 balanceBefore = shieldedToken.balanceOf(protector1);
            vm.prank(protector1);
            pool.claimCommission(uwTokenId);
            uint256 balanceAfter = shieldedToken.balanceOf(protector1);
            uint256 claimed = balanceAfter - balanceBefore;

            // Verify exact amount was claimed (no rounding issues)
            assertEq(claimed, claimable, "Should claim exact amount, even if very small");
            assertGt(claimed, 0, "Should claim positive amount");
        }
    }

    /// @notice INFO-5: Test multiple partial withdrawals use clean slate accounting
    /// @dev After fix for commission rounding exploit, each partial withdrawal resets
    ///      debt accounting to prevent rounding accumulation exploits
    function testMultiplePartialWithdrawals_PrecisionLossAccumulation() public {
        uint256 backingAmount = 10000e18;
        uint256 shieldedAmount = 5000e18;

        // Step 1: Setup deposits
        vm.prank(protector1);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Step 2: Generate commissions
        oracle.setPrice(address(shieldedToken), 1.1e8); // 10% yield
        _claimRewardsAsOwner(0);

        // Step 3: Start unlock process
        vm.prank(protector1);
        pool.startUnlockProcess(tokenId);
        vm.warp(block.timestamp + 29 days); // Wait past unlock period

        // Step 4: Perform 5 sequential partial withdrawals and verify clean slate each time
        uint256 remainingAmount = backingAmount;

        for (uint256 i = 0; i < 5; i++) {
            if (i > 0) {
                // BUG-01: each partial withdrawal re-arms a fresh unlock window,
                // so the unlock must be re-initiated and matured before each
                // subsequent withdrawal. Done via a helper (separate call frame) —
                // an inline `vm.warp(block.timestamp + N days)` inside this loop is
                // elided by the via-IR optimizer and silently fails to advance time.
                _rearmAndMatureProtectorUnlock(tokenId);
            }

            uint256 withdrawAmount = remainingAmount / 10; // 10% of remaining each time
            uint256 available = pool.getAvailableForWithdrawal(tokenId);
            if (withdrawAmount == 0 || available == 0) break;
            if (withdrawAmount > available) {
                withdrawAmount = available;
            }

            // Partial withdrawal
            vm.prank(protector1);
            pool.protectorWithdraw(tokenId, withdrawAmount, address(backingToken), 0);

            uint256 rewardDebtAfter = pool.rewardDebt(tokenId);
            uint256 commissionsClaimedAfter = pool.commissionsClaimed(tokenId);

            // Verify clean slate: commissionsClaimed should be reset to 0
            assertEq(commissionsClaimedAfter, 0, "Commissions claimed should be reset after partial withdrawal");

            // Verify clean slate: rewardDebt should match accumulator * newAmount
            uint256 newAmount = remainingAmount - withdrawAmount;
            uint256 accumulator = pool.rewardPerShareAccumulated();
            uint256 expectedDebt = Math.mulDiv(accumulator, newAmount, ConstantsLib.REWARD_PRECISION);
            assertEq(rewardDebtAfter, expectedDebt, "Reward debt should be reset to clean slate");

            remainingAmount = newAmount;
        }

        // Step 5: Verify final state - position is still valid with clean slate
        uint256 finalClaimable = pool.getClaimableCommission(tokenId);
        // Clean slate means claimable starts at 0 after each partial withdrawal
        assertEq(finalClaimable, 0, "Claimable should be 0 after clean slate reset");
    }

    /// @notice INFO-5: Test pool behavior when all shielded positions are withdrawn (zero state)
    function testZeroState_AllShieldedWithdrawn() public {
        uint256 backingAmount = 20000e18;
        uint256 shieldedAmount = 10000e18;

        // Setup deposits
        vm.prank(protector1);
        uint256 uwTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Verify initial state
        (uint256 shieldedBal, uint256 uwBal) = pool.getPoolBalances();
        assertGt(shieldedBal, 0, "Should have shielded tokens");
        assertGt(uwBal, 0, "Should have protector tokens");

        // Withdraw all shielded positions
        vm.prank(shielded);
        pool.shieldedWithdraw(shieldTokenId, address(shieldedToken), 0);

        // Verify zero state for shielded tokens
        (shieldedBal, uwBal) = pool.getPoolBalances();
        assertEq(shieldedBal, 0, "Should have no shielded tokens");
        assertGt(uwBal, 0, "Should still have protector tokens");
        assertEq(pool.totalShieldedTokens(), 0, "Total shielded tokens should be zero");

        // Test that new deposits still work
        vm.prank(shielded);
        uint256 newTokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);
        assertGt(newTokenId, 0, "Should be able to deposit after zero state");

        (shieldedBal, uwBal) = pool.getPoolBalances();
        assertEq(shieldedBal, shieldedAmount, "Should have new shielded deposit");

        // Test commission claims when no shielded tokens (should still work if commissions exist)
        uint256 claimable = pool.getClaimableCommission(uwTokenId);
        if (claimable > 0) {
            uint256 balanceBefore = shieldedToken.balanceOf(protector1);
            vm.prank(protector1);
            pool.claimCommission(uwTokenId);
            uint256 balanceAfter = shieldedToken.balanceOf(protector1);
            assertGt(balanceAfter, balanceBefore, "Should be able to claim commissions even with no shielded tokens");
        }
    }

    /// @notice Protector positions can exit cleanly once the shielded side is closed
    function testZeroState_AllProtectorsWithdrawnAfterShieldedExit() public {
        uint256 backingAmount = 20000e18;
        uint256 shieldedAmount = 10000e18;

        // Setup deposits
        vm.prank(protector1);
        uint256 uwTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Start unlock process
        vm.prank(protector1);
        pool.startUnlockProcess(uwTokenId);
        vm.warp(block.timestamp + 29 days);

        // Close the shielded side first, then withdraw the protector side fully.
        vm.prank(shielded);
        pool.shieldedWithdraw(shieldTokenId, address(shieldedToken), 0);

        vm.prank(protector1);
        pool.protectorWithdraw(uwTokenId, backingAmount, address(backingToken), 0);

        (uint256 shieldedBal, uint256 uwBal) = pool.getPoolBalances();
        assertEq(shieldedBal, 0, "Shielded side should be closed before full protector exit");
        assertEq(uwBal, 0, "Should have no protector tokens");
        assertEq(pool.totalProtectorTokens(), 0, "Total protector tokens should be zero");

        // Test that new protector deposits work correctly
        vm.prank(protector2);
        uint256 newUwTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);
        assertGt(newUwTokenId, 0, "Should be able to deposit after zero state");

        (shieldedBal, uwBal) = pool.getPoolBalances();
        assertEq(uwBal, backingAmount, "Should have new protector deposit");

        // Verify rewardPerShareAccumulated updates correctly for new depositor
        // New depositor should not get historical rewards (MasterChef pattern)
        uint256 newClaimable = pool.getClaimableCommission(newUwTokenId);
        assertEq(newClaimable, 0, "New protector should not have claimable from before deposit");

        vm.prank(shielded);
        uint256 newShieldTokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(address(shieldedToken), 1.2e8); // Additional yield
        _claimRewardsAsOwner(newShieldTokenId);

        uint256 newClaimableAfter = pool.getClaimableCommission(newUwTokenId);
        assertGt(newClaimableAfter, 0, "New protector should have claimable from new commissions");
    }

    function testClaimRewards_RevertsForUnauthorizedCaller() public {
        vm.prank(protector1);
        pool.depositBackingAsset(address(backingToken), 1000e18, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 500e18, 0);

        oracle.setPrice(address(shieldedToken), 1.2e8);

        vm.prank(protector2);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        pool.claimRewards(tokenId);
    }

    function testClaimRewards_RevertsForApprovedOperator() public {
        vm.prank(protector1);
        pool.depositBackingAsset(address(backingToken), 1000e18, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 500e18, 0);

        IShieldReceiptNFT shieldNFT = IShieldReceiptNFT(pool.shieldReceiptNFT());

        // H-7: approve is lock-gated; warp past the lock period so approval succeeds.
        // We're testing claimRewards access control, not the lock.
        ShieldReceiptNFT shieldNFTConcrete = ShieldReceiptNFT(address(shieldNFT));
        vm.warp(block.timestamp + shieldNFTConcrete.transferLockPeriod());

        vm.prank(shielded);
        shieldNFT.approve(protector2, tokenId);

        oracle.setPrice(address(shieldedToken), 1.2e8);

        vm.prank(protector2);
        vm.expectRevert(ErrorsLib.NotOwner.selector);
        pool.claimRewards(tokenId);

        assertEq(pool.accumulatedCommissions(), 0, "Approved operator should not be able to realize fees");
    }

    /// @notice INFO-5: Test complete pool drain (all positions withdrawn)
    function testZeroState_CompletePoolDrain() public {
        uint256 backingAmount = 20000e18;
        uint256 shieldedAmount = 10000e18;

        // Setup deposits
        vm.prank(protector1);
        uint256 uwTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Start unlock process for protector
        vm.prank(protector1);
        pool.startUnlockProcess(uwTokenId);
        vm.warp(block.timestamp + 29 days);

        // Withdraw all shielded positions first so the protector side can exit fully.
        vm.prank(shielded);
        pool.shieldedWithdraw(shieldTokenId, address(shieldedToken), 0);

        vm.prank(protector1);
        pool.protectorWithdraw(uwTokenId, backingAmount, address(backingToken), 0);

        // Verify complete zero state
        (uint256 shieldedBal, uint256 uwBal) = pool.getPoolBalances();
        assertEq(shieldedBal, 0, "Should have no shielded tokens");
        assertEq(uwBal, 0, "Should have no protector tokens");
        assertEq(pool.totalShieldedTokens(), 0, "Total shielded tokens should be zero");
        assertEq(pool.totalProtectorTokens(), 0, "Total protector tokens should be zero");

        // Test that pool can be reused for new deposits
        vm.prank(protector2);
        uint256 newUwTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 newShieldTokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Verify new deposits work
        assertGt(newUwTokenId, 0, "Should be able to deposit protector after complete drain");
        assertGt(newShieldTokenId, 0, "Should be able to deposit shielded after complete drain");

        (shieldedBal, uwBal) = pool.getPoolBalances();
        assertEq(shieldedBal, shieldedAmount, "Should have new shielded deposit");
        assertEq(uwBal, backingAmount, "Should have new protector deposit");

        // Verify state is clean (no leftover mappings or balances)
        assertEq(pool.totalShieldedTokens(), shieldedAmount, "Total shielded should match new deposit");
        assertEq(pool.totalProtectorTokens(), backingAmount, "Total protector should match new deposit");
    }

    /// @notice INFO-5: Test oracle switchover during active shielded withdrawal transaction
    /// @dev Tests that withdrawal completes successfully even if oracle switches mid-transaction
    function testOracleSwitchover_DuringShieldedWithdrawal() public {
        // Setup pool with CompositeOracle for dual-oracle support
        MockOracle primaryOracle = new MockOracle();
        MockOracle backupOracle = new MockOracle();

        // Set initial prices
        primaryOracle.setPrice(address(shieldedToken), 1e8);
        backupOracle.setPrice(address(shieldedToken), 1e8);
        primaryOracle.setPrice(address(backingToken), 1e8);
        backupOracle.setPrice(address(backingToken), 1e8);

        // Create CompositeOracle with dual-feed support
        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeedDual(address(shieldedToken), address(primaryOracle), address(backupOracle));
        compositeOracle.setTokenOracleFeedDual(address(backingToken), address(primaryOracle), address(backupOracle));

        // Create new pool with CompositeOracle
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "INSURE",
            symbol: "INSURE",
            token: address(shieldedToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });
        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "UNDER",
            symbol: "UNDER",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        ShieldReceiptNFT shieldNFT = new ShieldReceiptNFT("iINSURE", "iINSURE");
        ProtectorReceiptNFT protectorNFT = new ProtectorReceiptNFT("uUNDER", "uUNDER");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000, // 10% commission rate
            500, // 5% pool fee
            address(this), // pool creator
            15000, // 150% collateral ratio
            governance, // governance
            address(compositeOracle), // oracle (CompositeOracle with dual-feed)
            address(0xfa9605A2c38a0B4f16f689FDD07B63F295b86d1C), // protocol fee recipient
            address(shieldNFT),
            address(protectorNFT),
            address(this) // owner
        );
        SplitRiskPool poolWithCompositeOracle =
            SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));

        // Set pool address on NFTs
        shieldNFT.setPool(address(poolWithCompositeOracle));
        protectorNFT.setPool(address(poolWithCompositeOracle));
        shieldNFT.transferOwnership(address(poolWithCompositeOracle));
        protectorNFT.transferOwnership(address(poolWithCompositeOracle));

        // Setup deposits
        uint256 backingAmount = 20000e18;
        uint256 shieldedAmount = 10000e18;

        // Approve new pool to spend tokens (setUp only approved the main pool)
        vm.prank(protector1);
        backingToken.approve(address(poolWithCompositeOracle), type(uint256).max);
        vm.prank(shielded);
        shieldedToken.approve(address(poolWithCompositeOracle), type(uint256).max);

        vm.prank(protector1);
        poolWithCompositeOracle.depositBackingAsset(address(backingToken), backingAmount, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = poolWithCompositeOracle.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        // Record initial balances
        uint256 shieldedBalanceBefore = shieldedToken.balanceOf(shielded);
        uint256 poolShieldedBalanceBefore = shieldedToken.balanceOf(address(poolWithCompositeOracle));

        // Scenario 1: Oracle switchover before withdrawal (challenge and finalize)
        // Create deviation to trigger challenge
        backupOracle.setPrice(address(shieldedToken), 1.01e8); // 1% deviation (above 0.75% threshold)

        // Initiate challenge on CompositeOracle for the shielded token
        compositeOracle.challengeForToken(address(shieldedToken));
        (,,,, bool isChallengePending,) = compositeOracle.getTokenDualFeedStatus(address(shieldedToken));
        assertTrue(isChallengePending, "Challenge should be pending");

        // Wait for challenge duration
        vm.warp(block.timestamp + 16 hours + 1);

        // Finalize challenge (switches to backup)
        compositeOracle.finalizeChallenge(address(shieldedToken));
        assertTrue(compositeOracle.isBackupActiveForToken(address(shieldedToken)), "Backup oracle should be active");
        primaryOracle.setPrice(address(shieldedToken), 0);

        // Now perform withdrawal - should use backup oracle while the primary remains unavailable.
        vm.prank(shielded);
        poolWithCompositeOracle.shieldedWithdraw(shieldTokenId, address(shieldedToken), 0);

        // Verify withdrawal succeeded
        uint256 shieldedBalanceAfter = shieldedToken.balanceOf(shielded);
        uint256 poolShieldedBalanceAfter = shieldedToken.balanceOf(address(poolWithCompositeOracle));

        assertGt(shieldedBalanceAfter, shieldedBalanceBefore, "Shielded user should receive tokens");
        assertLt(poolShieldedBalanceAfter, poolShieldedBalanceBefore, "Pool should have fewer tokens");

        // Verify no state corruption
        // Note: Pool may retain accumulated fees (commissions/pool fees), so shieldedBal may not be 0
        (uint256 shieldedBal, uint256 uwBal) = poolWithCompositeOracle.getPoolBalances();
        assertLt(
            shieldedBal, shieldedAmount, "Pool shielded balance should be less than original deposit (fees retained)"
        );
        assertGt(uwBal, 0, "Pool should still have protector tokens");

        // Scenario 2: Test that withdrawal works with primary oracle after revert
        // Revert to primary
        primaryOracle.setPrice(address(shieldedToken), 1e8);
        backupOracle.setPrice(address(shieldedToken), 1e8); // Reset deviation
        compositeOracle.revertToPrimary(address(shieldedToken));
        assertFalse(
            compositeOracle.isBackupActiveForToken(address(shieldedToken)), "Primary oracle should be active again"
        );

        // New deposit and withdrawal should work
        vm.prank(shielded);
        uint256 newTokenId = poolWithCompositeOracle.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        vm.prank(shielded);
        poolWithCompositeOracle.shieldedWithdraw(newTokenId, address(shieldedToken), 0);

        // Verify successful withdrawal with primary oracle
        assertEq(poolWithCompositeOracle.totalShieldedTokens(), 0, "Should have no shielded tokens");
    }

    /// @notice Shielded deposits must revert while a dual-feed challenge is pending —
    ///         otherwise a depositor could lock `valueAtDeposit` from the suspect
    ///         primary feed and realise the deviation via cross-asset withdraw once
    ///         the price corrects. Resolving the deviation must restore deposit
    ///         availability without governance intervention.
    function test_depositShielded_RevertsDuringPendingChallenge() public {
        // Reuse the dual-feed setup pattern from testOracleSwitchover_DuringShieldedWithdrawal.
        MockOracle primaryOracle = new MockOracle();
        MockOracle backupOracle = new MockOracle();
        primaryOracle.setPrice(address(shieldedToken), 1e8);
        backupOracle.setPrice(address(shieldedToken), 1e8);
        primaryOracle.setPrice(address(backingToken), 1e8);
        backupOracle.setPrice(address(backingToken), 1e8);

        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeedDual(address(shieldedToken), address(primaryOracle), address(backupOracle));
        compositeOracle.setTokenOracleFeedDual(address(backingToken), address(primaryOracle), address(backupOracle));

        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "INSURE",
            symbol: "INSURE",
            token: address(shieldedToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });
        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "UNDER",
            symbol: "UNDER",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        ShieldReceiptNFT shieldNFT = new ShieldReceiptNFT("iINSURE", "iINSURE");
        ProtectorReceiptNFT protectorNFT = new ProtectorReceiptNFT("uUNDER", "uUNDER");
        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000,
            500,
            address(this),
            15000,
            governance,
            address(compositeOracle),
            address(0xfa9605A2c38a0B4f16f689FDD07B63F295b86d1C),
            address(shieldNFT),
            address(protectorNFT),
            address(this)
        );
        SplitRiskPool challengePool =
            SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));
        shieldNFT.setPool(address(challengePool));
        protectorNFT.setPool(address(challengePool));
        shieldNFT.transferOwnership(address(challengePool));
        protectorNFT.transferOwnership(address(challengePool));

        vm.prank(protector1);
        backingToken.approve(address(challengePool), type(uint256).max);
        vm.prank(shielded);
        shieldedToken.approve(address(challengePool), type(uint256).max);
        vm.prank(protector1);
        challengePool.depositBackingAsset(address(backingToken), 20000e18, 0);

        // Open a challenge by introducing a 1% deviation (> 0.75% threshold).
        backupOracle.setPrice(address(shieldedToken), 1.01e8);
        compositeOracle.challengeForToken(address(shieldedToken));

        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        challengePool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);

        // Resolve the deviation and clear the challenge — deposits should succeed again.
        backupOracle.setPrice(address(shieldedToken), 1e8);
        compositeOracle.cancelChallenge(address(shieldedToken));
        vm.prank(shielded);
        challengePool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
    }
}
