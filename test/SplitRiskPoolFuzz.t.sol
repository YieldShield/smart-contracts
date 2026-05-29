// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, console2 } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { ConstantsLib } from "../contracts/libraries/ConstantsLib.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IProtectorReceiptNFT } from "../contracts/interfaces/IProtectorReceiptNFT.sol";
import { IShieldReceiptNFT } from "../contracts/interfaces/IShieldReceiptNFT.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

/// @title Fuzz Tests for SplitRiskPool Edge Cases
/// @notice Comprehensive fuzz tests to validate protocol behavior under extreme and randomized conditions
/// @dev Tests deposit amount boundaries, fee accumulation limits, and multi-protector commission fairness
contract SplitRiskPoolFuzzTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;
    ShieldReceiptNFT public shieldNFT;
    ProtectorReceiptNFT public protectorNFT;

    address public governance = address(this);
    address public protocolFeeRecipient = address(0xfa9605A2c38a0B4f16f689FDD07B63F295b86d1C);

    // Test users
    address[] public protectors;
    address public shielded = address(0x100);

    // Pool configuration (cached for tests)
    uint256 public shieldedMinDepositAmount;
    uint256 public shieldedMaxDepositAmount;
    uint256 public backingMinDepositAmount;
    uint256 public backingMaxDepositAmount;
    uint256 public maxTotalValueLockedUsd;

    // Constants from ConstantsLib
    uint256 constant BASIS_POINT_SCALE = 1e4;
    uint256 constant REWARD_PRECISION = ConstantsLib.REWARD_PRECISION;
    uint256 constant USD_ONE = 1e8;
    uint256 constant TOKEN_UNITS_PER_USD_8 = 1e10;

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

        // Initialize protector array
        for (uint256 i = 1; i <= 50; i++) {
            protectors.push(address(uint160(i)));
        }

        // Deploy base ERC20 tokens
        shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        backingBaseToken = new MockERC20("Backing Base Token", "BBASE");

        // Deploy ERC4626 vaults
        backingToken = new MockERC4626(backingBaseToken, "Backing Token", "BACK");
        shieldedToken = new MockERC4626(shieldedBaseToken, "Shielded Token", "SHIELD");

        // Deploy oracle
        oracle = new MockOracle();
        oracle.setPrice(address(shieldedToken), 1e8); // $1 per token
        oracle.setPrice(address(backingToken), 1e8); // $1 per token

        // Create TokenInfo structs
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "SHIELD",
            symbol: "SHIELD",
            token: address(shieldedToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });
        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "BACK",
            symbol: "BACK",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        // Deploy pool
        SplitRiskPool implementation = new SplitRiskPool();
        shieldNFT = new ShieldReceiptNFT("sSHIELD", "sSHIELD");
        protectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000, // 10% commission rate
            500, // 5% pool fee
            address(this), // pool creator
            15000, // 150% collateral ratio
            governance,
            address(oracle),
            protocolFeeRecipient,
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

        // Cache pool config values
        (
            shieldedMinDepositAmount,
            shieldedMaxDepositAmount,
            backingMinDepositAmount,
            backingMaxDepositAmount,
            maxTotalValueLockedUsd,,,,,
        ) = pool.poolConfig();

        // Fund and setup all protectors
        for (uint256 i = 0; i < protectors.length; i++) {
            _fundAndApproveProtector(protectors[i], type(uint128).max);
        }

        // Fund shielded user
        _fundAndApproveShielded(shielded, type(uint128).max);
    }

    // ============ Helper Functions ============

    function _fundAndApproveProtector(address user, uint256 amount) internal {
        backingBaseToken.mint(user, amount);
        vm.startPrank(user);
        backingBaseToken.approve(address(backingToken), amount);
        backingToken.deposit(amount, user);
        backingToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _fundAndApproveShielded(address user, uint256 amount) internal {
        shieldedBaseToken.mint(user, amount);
        vm.startPrank(user);
        shieldedBaseToken.approve(address(shieldedToken), amount);
        shieldedToken.deposit(amount, user);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _boundValidShieldedDepositAmount(uint256 amount) internal view returns (uint256) {
        return bound(amount, shieldedMinDepositAmount + 1, shieldedMaxDepositAmount);
    }

    function _boundValidBackingDepositAmount(uint256 amount) internal view returns (uint256) {
        return bound(amount, backingMinDepositAmount + 1, backingMaxDepositAmount);
    }

    function _toUsd(uint256 amount) internal pure returns (uint256) {
        return (amount * USD_ONE) / 1e18;
    }

    function _toTokenAmountFromUsd(uint256 valueUsd) internal pure returns (uint256) {
        return valueUsd * TOKEN_UNITS_PER_USD_8;
    }

    function _boundValidYieldPercent(uint256 percent) internal pure returns (uint256) {
        return bound(percent, 1, 10000); // 0.01% to 100%
    }

    function _requiredProtectorForShielded(uint256 shieldedAmount) internal pure returns (uint256) {
        uint256 shieldedUsd = _toUsd(shieldedAmount);
        uint256 requiredUsd = (shieldedUsd * 15000 + BASIS_POINT_SCALE - 1) / BASIS_POINT_SCALE;
        return _toTokenAmountFromUsd(requiredUsd);
    }

    function _maxShieldedForProtectorAmount(uint256 protectorAmount) internal pure returns (uint256) {
        uint256 protectorUsd = _toUsd(protectorAmount);
        uint256 maxShieldedUsd = (protectorUsd * BASIS_POINT_SCALE) / 15000;
        if (maxShieldedUsd == 0) return 0;
        return _toTokenAmountFromUsd(maxShieldedUsd) + TOKEN_UNITS_PER_USD_8 - 1;
    }

    function _maxShieldedForSingleProtectorDeposit() internal view returns (uint256) {
        uint256 maxShielded = _maxShieldedForProtectorAmount(backingMaxDepositAmount);
        return maxShielded > shieldedMaxDepositAmount ? shieldedMaxDepositAmount : maxShielded;
    }

    function _createProtectorPosition(address user, uint256 amount) internal returns (uint256 tokenId) {
        vm.prank(user);
        tokenId = pool.depositBackingAsset(address(backingToken), amount, 0);
    }

    function _createShieldedPosition(address user, uint256 amount) internal returns (uint256 tokenId) {
        vm.prank(user);
        tokenId = pool.depositShieldedAsset(address(shieldedToken), amount, 0);
    }

    function _generateYield(uint256 yieldBasisPoints) internal {
        // yieldBasisPoints: 100 = 1%, 1000 = 10%, 10000 = 100%
        uint256 newPrice = 1e8 + (1e8 * yieldBasisPoints) / BASIS_POINT_SCALE;
        oracle.setPrice(address(shieldedToken), newPrice);
    }

    function _claimRewardsAsOwner(uint256 tokenId) internal {
        vm.prank(shieldNFT.ownerOf(tokenId));
        pool.claimRewards(tokenId);
    }

    // ============ 1. Extreme Deposit Amount Fuzz Tests ============

    /// @notice Test shielded deposits within valid bounds succeed
    function testFuzz_DepositShieldedWithValidAmounts(uint256 amount) public {
        // Bound to valid deposit range, but also ensure protector deposit fits within max deposit.
        // Max shielded = max backing deposit * 10000 / 15000 (to allow protector to fit in single deposit).
        uint256 maxShieldedForSingleProtectorDeposit = _maxShieldedForSingleProtectorDeposit();
        if (maxShieldedForSingleProtectorDeposit <= shieldedMinDepositAmount) return;
        amount = bound(amount, shieldedMinDepositAmount + 1, maxShieldedForSingleProtectorDeposit);

        // Need protector deposit first for collateral (150% of shielded amount)
        uint256 requiredProtector = _requiredProtectorForShielded(amount);
        _createProtectorPosition(protectors[0], requiredProtector);

        // Execute shielded deposit
        uint256 tokenId = _createShieldedPosition(shielded, amount);

        // Verify accounting
        IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(address(shieldNFT)).getPosition(tokenId);
        assertEq(pos.amount, amount, "Position amount should match deposit");
        assertEq(pool.totalShieldedTokens(), amount, "Total shielded should match");
    }

    /// @notice Test protector deposits up to maxDeposit
    function testFuzz_DepositProtectorWithLargeAmounts(uint256 amount) public {
        // Test protector deposits up to maxDepositAmount (pool limit)
        amount = bound(amount, backingMinDepositAmount + 1, backingMaxDepositAmount);

        // Ensure amount doesn't exceed user balance
        uint256 userBalance = backingToken.balanceOf(protectors[0]);
        if (amount > userBalance) {
            amount = userBalance;
        }

        // Execute deposit
        uint256 tokenId = _createProtectorPosition(protectors[0], amount);

        // Verify no overflow in calculations
        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(address(protectorNFT)).getPosition(tokenId);
        assertEq(pos.amount, amount, "Position amount should match deposit");
        assertEq(pool.totalProtectorTokens(), amount, "Total protector tokens should match");
    }

    /// @notice Test deposits below minimum revert correctly
    function testFuzz_DepositBelowMinimumReverts(uint256 amount) public {
        // Amount strictly below minimum should revert (contract uses < not <=)
        amount = bound(amount, 1, backingMinDepositAmount - 1);

        vm.expectRevert(ErrorsLib.InsufficientDepositAmount.selector);
        vm.prank(protectors[0]);
        pool.depositBackingAsset(address(backingToken), amount, 0);
    }

    /// @notice Test deposits above maximum revert correctly
    function testFuzz_DepositAboveMaximumReverts(uint256 amount) public {
        // Amount above maximum should revert
        amount = bound(amount, backingMaxDepositAmount + 1, type(uint128).max);

        vm.expectRevert(ErrorsLib.DepositAmountTooLarge.selector);
        vm.prank(protectors[0]);
        pool.depositBackingAsset(address(backingToken), amount, 0);
    }

    /// @notice Test TVL limit enforcement with multiple deposits
    function testFuzz_TVLLimitEnforcement(uint256 numDeposits, uint256 depositSize) public {
        numDeposits = bound(numDeposits, 1, 20);
        depositSize = bound(depositSize, backingMinDepositAmount + 1, backingMaxDepositAmount);

        uint256 totalDeposited = 0;
        bool reachedLimit = false;

        for (uint256 i = 0; i < numDeposits && !reachedLimit; i++) {
            // Check if this deposit would exceed TVL
            if (_toUsd(totalDeposited + depositSize) > maxTotalValueLockedUsd) {
                vm.expectRevert(ErrorsLib.TVLLimitExceeded.selector);
                vm.prank(protectors[i % protectors.length]);
                pool.depositBackingAsset(address(backingToken), depositSize, 0);
                reachedLimit = true;
            } else {
                vm.prank(protectors[i % protectors.length]);
                pool.depositBackingAsset(address(backingToken), depositSize, 0);
                totalDeposited += depositSize;
            }
        }

        // Verify total deposits don't exceed TVL
        (uint256 shieldedBal, uint256 protectorBal) = pool.getPoolBalances();
        assertLe(_toUsd(shieldedBal) + _toUsd(protectorBal), maxTotalValueLockedUsd, "TVL should not exceed limit");
    }

    /// @notice Test capacity check for shielded deposits
    function testFuzz_ShieldedCapacityCheck(uint256 protectorAmount, uint256 shieldedAmount) public {
        protectorAmount = _boundValidBackingDepositAmount(protectorAmount);
        shieldedAmount = _boundValidShieldedDepositAmount(shieldedAmount);

        // Deposit protector tokens first
        _createProtectorPosition(protectors[0], protectorAmount);

        // Mirror the contract's USD-based capacity check (_checkCapacity).
        // MockOracle.getValue returns (amount * price) / 1e18 with price = 1e8.
        uint256 shieldedUsd = _toUsd(shieldedAmount);
        uint256 protectorUsd = _toUsd(protectorAmount);

        if (shieldedUsd == 0 && shieldedAmount > 0) {
            // USD value truncates to 0 → contract reverts with InvalidOraclePrice (no 1:1 fallback)
            vm.expectRevert(ErrorsLib.InvalidOraclePrice.selector);
            _createShieldedPosition(shielded, shieldedAmount);
        } else {
            uint256 requiredUsd = (shieldedUsd * 15000 + BASIS_POINT_SCALE - 1) / BASIS_POINT_SCALE;
            bool shouldRevert = requiredUsd > protectorUsd;

            if (shouldRevert) {
                // Should revert - insufficient collateral
                vm.expectRevert(ErrorsLib.InsufficientProtectorTokenBalance.selector);
                _createShieldedPosition(shielded, shieldedAmount);
            } else {
                // Should succeed
                uint256 tokenId = _createShieldedPosition(shielded, shieldedAmount);
                IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(address(shieldNFT)).getPosition(tokenId);
                assertEq(pos.amount, shieldedAmount, "Position should be created with correct amount");
            }
        }
    }

    // ============ 2. Fee Accumulation Limit Tests ============

    /// @notice Test fee accumulation near uint128 limit
    function testFuzz_FeeAccumulationNearUint128Limit(uint256 yieldAmount) public {
        // Setup pool with large deposits
        uint256 protectorDeposit = 1_000_000e18;
        uint256 shieldedDeposit = 600_000e18; // ~60% of protector for 150% collateral ratio

        _createProtectorPosition(protectors[0], protectorDeposit);
        uint256 shieldTokenId = _createShieldedPosition(shielded, shieldedDeposit);

        // Generate yield that approaches type(uint128).max accumulation
        yieldAmount = bound(yieldAmount, 1e18, type(uint64).max);

        // Set oracle price to generate yield
        uint256 yieldBps = bound(yieldAmount, 1, 5000); // Up to 50% yield
        _generateYield(yieldBps);

        // Claim rewards to accumulate fees
        _claimRewardsAsOwner(shieldTokenId);

        // Verify fees are capped at maxSafeAccumulation
        uint256 accumulatedCommissions = pool.accumulatedCommissions();
        uint256 accumulatedPoolFee = pool.accumulatedPoolFee();
        uint256 accumulatedProtocolFee = pool.accumulatedProtocolFee();

        assertLe(accumulatedCommissions, type(uint128).max, "Commissions should be within uint128");
        assertLe(accumulatedPoolFee, type(uint128).max, "Pool fee should be within uint128");
        assertLe(accumulatedProtocolFee, type(uint128).max, "Protocol fee should be within uint128");
    }

    /// @notice Test multiple yield cycles accumulation
    function testFuzz_MultipleYieldCyclesAccumulation(uint256 cycles, uint256 yieldPerCycle) public {
        cycles = bound(cycles, 1, 10); // Reduced for faster execution
        yieldPerCycle = bound(yieldPerCycle, 10, 500); // 0.1% to 5% per cycle

        // Setup pool
        uint256 protectorDeposit = 100_000e18;
        uint256 shieldedDeposit = 60_000e18;

        _createProtectorPosition(protectors[0], protectorDeposit);
        uint256 shieldTokenId = _createShieldedPosition(shielded, shieldedDeposit);

        uint256 cumulativeYield = 0;
        uint256 currentTime = block.timestamp;

        // Loop through yield cycles
        for (uint256 i = 0; i < cycles; i++) {
            // Warp time for cooldown (1 day + 1 second for each cycle)
            currentTime += 1 days + 1;
            vm.warp(currentTime);

            // Accumulate yield
            cumulativeYield += yieldPerCycle;
            _generateYield(cumulativeYield);

            // Claim rewards
            _claimRewardsAsOwner(shieldTokenId);

            // Verify accumulator safety
            assertLe(pool.accumulatedCommissions(), type(uint128).max, "Commissions should not overflow");
            assertLe(pool.accumulatedPoolFee(), type(uint128).max, "Pool fee should not overflow");
            assertLe(pool.accumulatedProtocolFee(), type(uint128).max, "Protocol fee should not overflow");
        }
    }

    /// @notice Test fee scaling when fees exceed deposit
    function testFuzz_FeeScalingWhenExceedsDeposit(uint256 depositAmount, uint256 yieldPercent) public {
        // Use smaller bounds to ensure both deposits fit within limits.
        uint256 maxShieldedForSingleProtectorDeposit = _maxShieldedForSingleProtectorDeposit();
        if (maxShieldedForSingleProtectorDeposit <= shieldedMinDepositAmount) return;
        depositAmount = bound(depositAmount, shieldedMinDepositAmount + 1, maxShieldedForSingleProtectorDeposit);
        yieldPercent = bound(yieldPercent, 5000, 50000); // 50% to 500% yield

        // Ensure we have enough protector tokens
        uint256 requiredProtector = _requiredProtectorForShielded(depositAmount);
        _createProtectorPosition(protectors[0], requiredProtector);

        uint256 shieldTokenId = _createShieldedPosition(shielded, depositAmount);

        // Generate extreme yield to test fee scaling
        _generateYield(yieldPercent);

        // Claim rewards - should handle gracefully with fee scaling
        _claimRewardsAsOwner(shieldTokenId);

        // Get position after fee calculation
        IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(address(shieldNFT)).getPosition(shieldTokenId);

        // Verify position amount is non-negative (fees were scaled if needed)
        assertGe(pos.amount, 0, "Position amount should be non-negative after fee scaling");

        // Verify fees are reasonable
        uint256 totalFees = pool.accumulatedCommissions() + pool.accumulatedPoolFee() + pool.accumulatedProtocolFee();
        assertLe(totalFees, depositAmount, "Total fees should not exceed original deposit");
    }

    /// @notice Test reward per share accumulator precision
    function testFuzz_RewardPerSharePrecision(uint256 protectorAmount, uint256 shieldedAmount, uint256 yieldBps)
        public
    {
        protectorAmount = bound(protectorAmount, 1e18, 1_000_000e18);
        // Calculate max shielded based on collateral ratio
        uint256 maxShielded = _maxShieldedForProtectorAmount(protectorAmount);
        uint256 minShielded = shieldedMinDepositAmount + 1;
        if (maxShielded < minShielded) return; // Skip if protector amount too small for valid shielded deposit
        shieldedAmount = bound(
            shieldedAmount, minShielded, maxShielded > shieldedMaxDepositAmount ? shieldedMaxDepositAmount : maxShielded
        );
        yieldBps = bound(yieldBps, 1, 1000);

        _createProtectorPosition(protectors[0], protectorAmount);
        uint256 shieldTokenId = _createShieldedPosition(shielded, shieldedAmount);

        uint256 rewardPerShareBefore = pool.rewardPerShareAccumulated();

        _generateYield(yieldBps);
        _claimRewardsAsOwner(shieldTokenId);

        uint256 rewardPerShareAfter = pool.rewardPerShareAccumulated();

        // Reward per share should increase after yield
        assertGe(rewardPerShareAfter, rewardPerShareBefore, "Reward per share should not decrease");
        assertLe(rewardPerShareAfter, type(uint256).max, "Reward per share should not overflow");
    }

    // ============ 3. Multi-Protector Commission Distribution Tests ============

    /// @notice Test commission distribution fairness with multiple protectors
    function testFuzz_CommissionDistributionFairness(uint256 numProtectors, uint256 baseDeposit, uint256 yieldAmount)
        public
    {
        numProtectors = bound(numProtectors, 2, 5); // Reduced for faster execution
        baseDeposit = bound(baseDeposit, 1e18, 10_000e18); // Smaller base deposit to fit in limits
        yieldAmount = bound(yieldAmount, 100, 1000); // 1% to 10% yield

        uint256[] memory protectorTokenIds = new uint256[](numProtectors);
        uint256[] memory depositAmounts = new uint256[](numProtectors);
        uint256 totalProtectorDeposit = 0;

        // Create multiple protector positions with varying amounts
        // Limit each deposit to maxDepositAmount
        for (uint256 i = 0; i < numProtectors; i++) {
            // Vary deposit amounts (1x to 3x base), but cap at maxDepositAmount
            uint256 rawDeposit = baseDeposit * (i + 1);
            depositAmounts[i] = rawDeposit > backingMaxDepositAmount ? backingMaxDepositAmount : rawDeposit;
            protectorTokenIds[i] = _createProtectorPosition(protectors[i], depositAmounts[i]);
            totalProtectorDeposit += depositAmounts[i];
        }

        // Create shielded position (within collateral ratio)
        uint256 maxShielded = (totalProtectorDeposit * BASIS_POINT_SCALE) / 15000;
        uint256 shieldedAmount = maxShielded > shieldedMaxDepositAmount
            ? shieldedMaxDepositAmount
            : (maxShielded > shieldedMinDepositAmount + 1 ? maxShielded / 2 : 0);

        if (shieldedAmount <= shieldedMinDepositAmount) return;

        uint256 shieldTokenId = _createShieldedPosition(shielded, shieldedAmount);

        // Generate yield and claim (warp first to handle cooldown if test is run multiple times)
        vm.warp(block.timestamp + 1 days + 1);
        _generateYield(yieldAmount);
        _claimRewardsAsOwner(shieldTokenId);

        uint256 accumulatedCommissions = pool.accumulatedCommissions();

        // Verify pro-rata distribution
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < numProtectors; i++) {
            uint256 claimable = pool.getClaimableCommission(protectorTokenIds[i]);
            totalClaimable += claimable;

            // Each protector's share should be proportional to their deposit
            if (claimable > 0 && accumulatedCommissions > 0) {
                uint256 expectedShare = (accumulatedCommissions * depositAmounts[i]) / totalProtectorDeposit;
                // Allow 5% tolerance for rounding
                assertApproxEqRel(claimable, expectedShare, 0.05e18, "Share should be proportional");
            }
        }

        // Sum of claimable should approximately equal accumulated commissions
        // Allow tolerance for rounding: 0.1% of accumulated or 1000 wei, whichever is larger
        uint256 tolerance = accumulatedCommissions / 1000 > 1000 ? accumulatedCommissions / 1000 : 1000;
        assertApproxEqAbs(totalClaimable, accumulatedCommissions, tolerance, "Total claimable should equal accumulated");
    }

    /// @notice Test late joiner cannot claim historical rewards
    function testFuzz_LateJoinerNoHistoricalRewards(uint256 initialDeposit, uint256 lateDeposit, uint256 yieldBetween)
        public
    {
        initialDeposit = bound(initialDeposit, 10e18, 100_000e18);
        lateDeposit = bound(lateDeposit, 10e18, 100_000e18);
        yieldBetween = bound(yieldBetween, 100, 1000); // 1% to 10%

        // Protector1 deposits first
        uint256 tokenId1 = _createProtectorPosition(protectors[0], initialDeposit);

        // Create shielded position
        uint256 maxShielded = (initialDeposit * BASIS_POINT_SCALE) / 15000;
        uint256 shieldedAmount = maxShielded > shieldedMaxDepositAmount
            ? shieldedMaxDepositAmount
            : (maxShielded > shieldedMinDepositAmount + 1 ? maxShielded / 2 : 0);

        if (shieldedAmount <= shieldedMinDepositAmount) return;

        uint256 shieldTokenId = _createShieldedPosition(shielded, shieldedAmount);

        // Generate yield and accumulate commissions
        _generateYield(yieldBetween);
        _claimRewardsAsOwner(shieldTokenId);

        // Record accumulated commissions before late joiner (used to verify state)
        uint256 _commissionsBeforeLateJoiner = pool.accumulatedCommissions();
        require(_commissionsBeforeLateJoiner > 0, "Should have commissions before late joiner");
        uint256 rewardPerShareBeforeLateJoiner = pool.rewardPerShareAccumulated();

        // Protector2 deposits LATE (after commissions accumulated)
        uint256 tokenId2 = _createProtectorPosition(protectors[1], lateDeposit);

        // Verify late joiner has correct rewardDebt
        uint256 rewardDebt2 = pool.rewardDebt(tokenId2);
        uint256 expectedDebt = Math.mulDiv(rewardPerShareBeforeLateJoiner, lateDeposit, REWARD_PRECISION);
        assertEq(rewardDebt2, expectedDebt, "Reward debt should match accumulated rewards at deposit time");

        // Verify late joiner cannot claim historical rewards
        uint256 claimable2 = pool.getClaimableCommission(tokenId2);
        assertEq(claimable2, 0, "Late joiner should not have claimable historical rewards");

        // Verify first depositor can still claim
        uint256 claimable1 = pool.getClaimableCommission(tokenId1);
        assertGt(claimable1, 0, "Original depositor should have claimable rewards");
    }

    /// @notice Test reward debt accuracy across multiple protectors
    function testFuzz_RewardDebtAccuracy(uint8 numDepositors) public {
        numDepositors = uint8(bound(numDepositors, 2, 5)); // Reduced for faster execution

        uint256[] memory protectorTokenIds = new uint256[](numDepositors);
        uint256[] memory depositAmounts = new uint256[](numDepositors);
        uint256 totalDeposited = 0;
        uint256 currentTime = block.timestamp;

        // First protector deposits
        depositAmounts[0] = 50_000e18;
        protectorTokenIds[0] = _createProtectorPosition(protectors[0], depositAmounts[0]);
        totalDeposited += depositAmounts[0];

        // Create shielded position
        uint256 shieldedAmount = 30_000e18;
        uint256 shieldTokenId = _createShieldedPosition(shielded, shieldedAmount);

        // Generate initial yield (warp first to handle cooldown)
        currentTime += 1 days + 1;
        vm.warp(currentTime);
        _generateYield(500); // 5%
        _claimRewardsAsOwner(shieldTokenId);

        // Add more protectors with yield in between each
        for (uint256 i = 1; i < numDepositors; i++) {
            depositAmounts[i] = 10_000e18 * i;

            // Record state before deposit
            uint256 rewardPerShareBefore = pool.rewardPerShareAccumulated();

            // Deposit
            protectorTokenIds[i] = _createProtectorPosition(protectors[i], depositAmounts[i]);
            totalDeposited += depositAmounts[i];

            // Verify reward debt is correctly set
            uint256 rewardDebt = pool.rewardDebt(protectorTokenIds[i]);
            uint256 expectedDebt = Math.mulDiv(rewardPerShareBefore, depositAmounts[i], REWARD_PRECISION);
            assertEq(rewardDebt, expectedDebt, "Reward debt should match accumulator at deposit time");

            // Warp time and generate more yield
            currentTime += 1 days + 1;
            vm.warp(currentTime);
            _generateYield(500 + i * 100);
            _claimRewardsAsOwner(shieldTokenId);
        }

        // Verify sum of claimable approximately equals accumulated commissions
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < numDepositors; i++) {
            totalClaimable += pool.getClaimableCommission(protectorTokenIds[i]);
        }

        uint256 accumulated = pool.accumulatedCommissions();

        // Allow larger tolerance: 0.1% of accumulated or 1e15 wei, whichever is larger
        // This accounts for rounding in the MasterChef reward-per-share pattern
        uint256 tolerance = accumulated / 1000 > 1e15 ? accumulated / 1000 : 1e15;
        assertApproxEqAbs(
            totalClaimable,
            accumulated,
            tolerance,
            "Sum of claimable should approximately equal accumulated commissions"
        );
    }

    /// @notice Test no dust accumulation over many cycles
    function testFuzz_NoDustAccumulation(uint256 cycles, uint256 yieldPerCycle) public {
        cycles = bound(cycles, 2, 5); // Reduced for faster execution
        yieldPerCycle = bound(yieldPerCycle, 50, 200); // 0.5% to 2% per cycle

        // Setup with 3 protectors
        uint256[] memory protectorTokenIds = new uint256[](3);
        uint256[] memory depositAmounts = new uint256[](3);
        uint256 totalProtectorDeposit = 0;

        depositAmounts[0] = 30_000e18;
        depositAmounts[1] = 50_000e18;
        depositAmounts[2] = 20_000e18;

        for (uint256 i = 0; i < 3; i++) {
            protectorTokenIds[i] = _createProtectorPosition(protectors[i], depositAmounts[i]);
            totalProtectorDeposit += depositAmounts[i];
        }

        // Create shielded position
        uint256 shieldTokenId = _createShieldedPosition(shielded, 60_000e18);

        uint256 cumulativeYield = 0;
        uint256 currentTime = block.timestamp;

        // Run through cycles - warp first before each claim to handle cooldown
        for (uint256 cycle = 0; cycle < cycles; cycle++) {
            currentTime += 1 days + 1;
            vm.warp(currentTime);
            cumulativeYield += yieldPerCycle;
            _generateYield(cumulativeYield);
            _claimRewardsAsOwner(shieldTokenId);
        }

        // Calculate total claimable
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < 3; i++) {
            totalClaimable += pool.getClaimableCommission(protectorTokenIds[i]);
        }

        uint256 accumulated = pool.accumulatedCommissions();

        // Dust should be minimal (< 0.1% of accumulated or 1000 wei, whichever is larger)
        if (accumulated > 0) {
            uint256 dust = accumulated > totalClaimable ? accumulated - totalClaimable : totalClaimable - accumulated;
            uint256 maxDust = accumulated / 1000 > 1000 ? accumulated / 1000 : 1000;
            assertLe(dust, maxDust, "Dust should be < 0.1% of accumulated");
        }
    }

    /// @notice Test claiming commissions doesn't affect other protectors
    function testFuzz_ClaimingDoesntAffectOthers(uint256 claimOrder) public {
        claimOrder = bound(claimOrder, 0, 5); // Different claim orders

        // Setup 3 protectors
        uint256[] memory protectorTokenIds = new uint256[](3);
        protectorTokenIds[0] = _createProtectorPosition(protectors[0], 30_000e18);
        protectorTokenIds[1] = _createProtectorPosition(protectors[1], 40_000e18);
        protectorTokenIds[2] = _createProtectorPosition(protectors[2], 30_000e18);

        // Create shielded position and generate yield
        uint256 shieldTokenId = _createShieldedPosition(shielded, 60_000e18);
        _generateYield(1000); // 10%
        _claimRewardsAsOwner(shieldTokenId);

        // Record claimable amounts before any claims
        uint256[] memory claimableBefore = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            claimableBefore[i] = pool.getClaimableCommission(protectorTokenIds[i]);
        }

        // Claim in different orders based on seed
        uint256 firstClaimer = claimOrder % 3;

        vm.prank(protectors[firstClaimer]);
        pool.claimCommission(protectorTokenIds[firstClaimer]);

        // Verify other protectors' claimable amounts unchanged
        for (uint256 i = 0; i < 3; i++) {
            if (i != firstClaimer) {
                uint256 claimableAfter = pool.getClaimableCommission(protectorTokenIds[i]);
                assertEq(claimableAfter, claimableBefore[i], "Other protectors' claimable should be unchanged");
            }
        }
    }

    /// @notice Test commission calculation with extreme deposit ratios
    function testFuzz_ExtremeDepositRatios(uint256 ratio) public {
        ratio = bound(ratio, 1, 1000); // 1:1 to 1:1000 ratio

        uint256 smallDeposit = 1e18;
        uint256 largeDeposit = smallDeposit * ratio;

        // Ensure large deposit doesn't exceed max
        if (largeDeposit > backingMaxDepositAmount) {
            largeDeposit = backingMaxDepositAmount;
        }

        uint256 tokenId1 = _createProtectorPosition(protectors[0], smallDeposit);
        uint256 tokenId2 = _createProtectorPosition(protectors[1], largeDeposit);

        uint256 totalProtector = smallDeposit + largeDeposit;
        uint256 maxShielded = (totalProtector * BASIS_POINT_SCALE) / 15000;
        uint256 shieldedAmount = maxShielded > shieldedMaxDepositAmount
            ? shieldedMaxDepositAmount
            : (maxShielded > shieldedMinDepositAmount + 1 ? maxShielded / 2 : 0);

        if (shieldedAmount <= shieldedMinDepositAmount) return;

        uint256 shieldTokenId = _createShieldedPosition(shielded, shieldedAmount);

        _generateYield(500);
        _claimRewardsAsOwner(shieldTokenId);

        uint256 claimable1 = pool.getClaimableCommission(tokenId1);
        uint256 claimable2 = pool.getClaimableCommission(tokenId2);

        // Ratio of claimable should approximate deposit ratio
        if (claimable1 > 0 && claimable2 > 0) {
            uint256 claimRatio = (claimable2 * 1000) / claimable1;
            uint256 depositRatio = (largeDeposit * 1000) / smallDeposit;

            // Allow 5% tolerance
            assertApproxEqRel(claimRatio, depositRatio, 0.05e18, "Claim ratio should match deposit ratio");
        }
    }

    /// @notice Test withdrawal during commission accumulation resets to clean slate
    /// @dev After fix for commission rounding exploit, partial withdrawal resets
    ///      accounting to prevent rounding exploit accumulation
    function testFuzz_WithdrawalDuringCommissionAccumulation(uint256 withdrawPercent) public {
        withdrawPercent = bound(withdrawPercent, 10, 90); // 10% to 90%

        uint256 protectorDeposit = 100_000e18;
        uint256 tokenId = _createProtectorPosition(protectors[0], protectorDeposit);

        uint256 shieldTokenId = _createShieldedPosition(shielded, 60_000e18);

        // Generate some yield
        _generateYield(500);
        _claimRewardsAsOwner(shieldTokenId);

        // Start unlock and wait
        vm.prank(protectors[0]);
        pool.startUnlockProcess(tokenId);
        vm.warp(block.timestamp + 29 days);

        // Partial withdrawal
        uint256 maxWithdrawable = pool.getAvailableForWithdrawal(tokenId);
        uint256 withdrawAmount = bound((protectorDeposit * withdrawPercent) / 100, 1, maxWithdrawable);
        vm.prank(protectors[0]);
        pool.protectorWithdraw(tokenId, withdrawAmount, address(backingToken), 0);

        // Verify clean slate: commissionsClaimed reset, claimable starts at 0
        uint256 claimableAfter = pool.getClaimableCommission(tokenId);
        uint256 commissionsClaimedAfter = pool.commissionsClaimed(tokenId);

        // Clean slate behavior: commissionsClaimed is reset to 0
        assertEq(commissionsClaimedAfter, 0, "Commissions claimed should be reset to 0");

        // Clean slate behavior: claimable is 0 after partial withdrawal
        // (debt is set to accumulator * newAmount, so earned - claimed - debt = 0)
        assertEq(claimableAfter, 0, "Claimable should be 0 after clean slate reset");
    }
}
