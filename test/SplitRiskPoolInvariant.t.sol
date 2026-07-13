// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test, console2 } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IProtectorReceiptNFT } from "../contracts/interfaces/IProtectorReceiptNFT.sol";
import { IShieldReceiptNFT } from "../contracts/interfaces/IShieldReceiptNFT.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { ConstantsLib } from "../contracts/libraries/ConstantsLib.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";

/// @title Handler Contract for SplitRiskPool Invariant Tests
/// @notice Performs random valid operations on the pool for invariant testing
contract SplitRiskPoolHandler is Test {
    SplitRiskPool public pool;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;
    ShieldReceiptNFT public shieldNFT;
    ProtectorReceiptNFT public protectorNFT;
    address public governance;

    // Track actors and their token IDs
    address[] public protectors;
    address[] public shieldeds;
    mapping(address => uint256[]) public protectorTokenIds;
    mapping(address => uint256[]) public shieldedTokenIds;

    // Ghost variables for tracking expected state
    uint256 public ghost_totalProtectorDeposits;
    uint256 public ghost_totalShieldedDeposits;
    uint256 public ghost_totalProtectorWithdrawals;
    uint256 public ghost_totalShieldedWithdrawals;
    uint256 public ghost_totalCommissionsClaimed;
    uint256 public ghost_totalCrossAssetWithdrawals;
    uint256 public ghost_totalPartialShieldedWithdrawals;
    uint256 public ghost_totalPoolFeesAccrued;
    uint256 public ghost_totalProtocolFeesAccrued;
    uint256 public ghost_totalPoolFeesPaid;
    uint256 public ghost_totalProtocolFeesPaid;

    // Call counters for debugging
    uint256 public calls_depositProtector;
    uint256 public calls_depositShielded;
    uint256 public calls_withdrawProtector;
    uint256 public calls_withdrawShielded;
    uint256 public calls_claimCommission;
    uint256 public calls_claimRewards;
    uint256 public calls_withdrawShieldedCrossAsset;
    uint256 public calls_partialWithdrawShielded;
    uint256 public calls_payPoolFee;
    uint256 public calls_payProtocolFee;
    uint256 public calls_transferShieldNFT;
    uint256 public calls_transferProtectorNFT;
    uint256 public calls_dropPrice;
    uint256 public calls_generateYield;
    uint256 public calls_dropBackingPrice;
    uint256 public calls_increaseBackingPrice;

    struct CallMetrics {
        uint256 attempts;
        uint256 preconditionSkips;
        uint256 successes;
        uint256 unexpectedReverts;
    }

    mapping(bytes4 => CallMetrics) public callMetrics;
    bool public metricsEnabled;
    bool public rewardPerShareEverDecreased;
    bool public tvlLimitViolatedByDeposit;
    bool public receiptTransferAccountingChanged;
    bool public feePayoutRecipientMismatch;
    uint256 public highestRewardPerShareObserved;

    // Pool config
    uint256 public shieldedMinDepositAmount;
    uint256 public shieldedMaxDepositAmount;
    uint256 public backingMinDepositAmount;
    uint256 public backingMaxDepositAmount;
    uint256 internal constant MAX_FUZZ_PRICE = 1_000_000e8;

    constructor(
        SplitRiskPool _pool,
        MockERC4626 _shieldedToken,
        MockERC4626 _backingToken,
        MockERC20 _shieldedBaseToken,
        MockERC20 _backingBaseToken,
        MockOracle _oracle,
        ShieldReceiptNFT _shieldNFT,
        ProtectorReceiptNFT _protectorNFT,
        address _governance
    ) {
        pool = _pool;
        shieldedToken = _shieldedToken;
        backingToken = _backingToken;
        shieldedBaseToken = _shieldedBaseToken;
        backingBaseToken = _backingBaseToken;
        oracle = _oracle;
        shieldNFT = _shieldNFT;
        protectorNFT = _protectorNFT;
        governance = _governance;

        // Cache pool config
        (shieldedMinDepositAmount, shieldedMaxDepositAmount, backingMinDepositAmount, backingMaxDepositAmount,,,,,,) =
            pool.poolConfig();

        // Setup actor addresses (funding happens in test contract)
        for (uint256 i = 1; i <= 5; i++) {
            address prot = address(uint160(i * 1000));
            address sh = address(uint160(i * 2000));
            protectors.push(prot);
            shieldeds.push(sh);
        }

        highestRewardPerShareObserved = pool.rewardPerShareAccumulated();
    }

    modifier tracksRewardPerShare() {
        uint256 beforeValue = pool.rewardPerShareAccumulated();
        uint256 poolFeeBefore = pool.accumulatedPoolFee();
        uint256 protocolFeeBefore = pool.accumulatedProtocolFee();
        _;
        uint256 afterValue = pool.rewardPerShareAccumulated();
        uint256 poolFeeAfter = pool.accumulatedPoolFee();
        uint256 protocolFeeAfter = pool.accumulatedProtocolFee();
        if (afterValue < beforeValue) {
            rewardPerShareEverDecreased = true;
        }
        if (afterValue > highestRewardPerShareObserved) {
            highestRewardPerShareObserved = afterValue;
        }
        if (poolFeeAfter > poolFeeBefore) {
            ghost_totalPoolFeesAccrued += poolFeeAfter - poolFeeBefore;
        }
        if (protocolFeeAfter > protocolFeeBefore) {
            ghost_totalProtocolFeesAccrued += protocolFeeAfter - protocolFeeBefore;
        }
    }

    function _attempt(bytes4 selector) internal {
        if (!metricsEnabled) return;
        callMetrics[selector].attempts++;
    }

    function _skip(bytes4 selector) internal {
        if (!metricsEnabled) return;
        callMetrics[selector].preconditionSkips++;
    }

    function _success(bytes4 selector) internal {
        if (!metricsEnabled) return;
        callMetrics[selector].successes++;
    }

    function _unexpectedRevert(bytes4 selector) internal {
        if (!metricsEnabled) return;
        callMetrics[selector].unexpectedReverts++;
    }

    /// @notice Enable randomized-dispatch metrics after deterministic state seeding.
    /// @dev The invariant target selector excludes this administrative test hook.
    function enableMetrics() external {
        metricsEnabled = true;
    }

    /// @notice Get actor addresses for external funding
    function getProtector(uint256 i) external view returns (address) {
        return protectors[i % protectors.length];
    }

    function getShielded(uint256 i) external view returns (address) {
        return shieldeds[i % shieldeds.length];
    }

    function _toUsd(address token, uint256 amount) internal view returns (uint256) {
        return (amount * oracle.getPrice(token)) / 1e18;
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return numerator == 0 ? 0 : (numerator - 1) / denominator + 1;
    }

    function _recordPostDepositTvl() internal {
        (uint256 shieldedBal, uint256 protectorBal) = pool.getPoolBalances();
        (,,,, uint256 maxTVLUsd,,,,,) = pool.poolConfig();
        uint256 currentTvlUsd =
            _toUsd(address(shieldedToken), shieldedBal) + _toUsd(address(backingToken), protectorBal);
        if (currentTvlUsd > maxTVLUsd) {
            tvlLimitViolatedByDeposit = true;
        }
    }

    // ============ Handler Functions ============

    /// @notice Deposit as protector
    function depositProtector(uint256 actorSeed, uint256 amount) external tracksRewardPerShare {
        _attempt(this.depositProtector.selector);
        address actor = protectors[actorSeed % protectors.length];
        amount = bound(amount, backingMinDepositAmount + 1, backingMaxDepositAmount);

        uint256 balance = backingToken.balanceOf(actor);
        if (balance < amount) {
            _skip(this.depositProtector.selector);
            return;
        }

        // The production deposit path rejects positive token amounts whose USD
        // value truncates to zero. Repeated backing-price drops can otherwise
        // make the handler classify an invalid deposit as modeled-valid.
        if (_toUsd(address(backingToken), amount) == 0) {
            _skip(this.depositProtector.selector);
            return;
        }

        // Check TVL limit
        (uint256 shieldedBal, uint256 protectorBal) = pool.getPoolBalances();
        (,,,, uint256 maxTVLUsd,,,,,) = pool.poolConfig();
        if (
            _toUsd(address(shieldedToken), shieldedBal) + _toUsd(address(backingToken), protectorBal + amount)
                > maxTVLUsd
        ) {
            _skip(this.depositProtector.selector);
            return;
        }

        vm.prank(actor);
        try pool.depositBackingAsset(address(backingToken), amount, 0) returns (uint256 tokenId) {
            protectorTokenIds[actor].push(tokenId);
            ghost_totalProtectorDeposits += amount;
            calls_depositProtector++;
            _recordPostDepositTvl();
            _success(this.depositProtector.selector);
        } catch {
            _unexpectedRevert(this.depositProtector.selector);
        }
    }

    /// @notice Deposit as shielded
    function depositShielded(uint256 actorSeed, uint256 amount) external tracksRewardPerShare {
        _attempt(this.depositShielded.selector);
        address actor = shieldeds[actorSeed % shieldeds.length];
        amount = bound(amount, shieldedMinDepositAmount + 1, shieldedMaxDepositAmount);

        uint256 balance = shieldedToken.balanceOf(actor);
        if (balance < amount) {
            _skip(this.depositShielded.selector);
            return;
        }

        // Check if there's enough protector capacity
        uint256 totalProt = pool.totalProtectorTokens();
        uint256 depositValueUsd = _toUsd(address(shieldedToken), amount);
        // The production deposit path rejects positive token amounts whose USD
        // value truncates to zero. Treat that as an unreachable modeled action,
        // especially after repeated fuzzed price drops drive the oracle to 1.
        if (depositValueUsd == 0) {
            _skip(this.depositShielded.selector);
            return;
        }
        uint256 collateralValueUsd = _ceilDiv(depositValueUsd * pool.COLLATERAL_RATIO(), 1e4);
        uint256 requiredCollateral = _ceilDiv(collateralValueUsd * 1e18, oracle.getPrice(address(backingToken)));
        uint256 requiredTotalProtectorUsd =
            _ceilDiv((pool.totalValueAtDeposit() + depositValueUsd) * pool.COLLATERAL_RATIO(), 1e4);
        if (
            requiredTotalProtectorUsd > _toUsd(address(backingToken), totalProt)
                || pool.totalShieldCollateralAmount() + requiredCollateral > totalProt
        ) {
            _skip(this.depositShielded.selector);
            return;
        }

        // Check TVL limit
        (uint256 shieldedBal, uint256 protectorBal) = pool.getPoolBalances();
        (,,,, uint256 maxTVLUsd,,,,,) = pool.poolConfig();
        if (
            _toUsd(address(shieldedToken), shieldedBal + amount) + _toUsd(address(backingToken), protectorBal)
                > maxTVLUsd
        ) {
            _skip(this.depositShielded.selector);
            return;
        }

        vm.prank(actor);
        try pool.depositShieldedAsset(address(shieldedToken), amount, 0) returns (uint256 tokenId) {
            shieldedTokenIds[actor].push(tokenId);
            ghost_totalShieldedDeposits += amount;
            calls_depositShielded++;
            _recordPostDepositTvl();
            _success(this.depositShielded.selector);
        } catch {
            _unexpectedRevert(this.depositShielded.selector);
        }
    }

    /// @notice Withdraw as protector (requires unlock)
    function withdrawProtector(uint256 actorSeed, uint256 tokenIdSeed, uint256 amount) external tracksRewardPerShare {
        _attempt(this.withdrawProtector.selector);
        address actor = protectors[actorSeed % protectors.length];
        uint256[] storage tokenIds = protectorTokenIds[actor];
        if (tokenIds.length == 0) {
            _skip(this.withdrawProtector.selector);
            return;
        }

        uint256 tokenId = tokenIds[tokenIdSeed % tokenIds.length];

        // Get position info
        IProtectorReceiptNFT.ProtectorPosition memory pos;
        try protectorNFT.getPosition(tokenId) returns (IProtectorReceiptNFT.ProtectorPosition memory p) {
            pos = p;
        } catch {
            _removeTokenId(tokenIds, tokenId);
            _skip(this.withdrawProtector.selector);
            return;
        }

        uint256 positionAmount = pool.getProtectorPositionAmount(tokenId);
        if (positionAmount == 0) {
            _skip(this.withdrawProtector.selector);
            return;
        }

        // Expired share-epoch positions may still expose residual backing through
        // getProtectorPositionAmount, but protectorWithdraw applies only to the
        // active epoch. Availability is the public path-aware discriminator, so
        // check it before attempting to start an unlock on an ineligible receipt.
        uint256 available = pool.getAvailableForWithdrawal(tokenId);
        if (available == 0) {
            _skip(this.withdrawProtector.selector);
            return;
        }

        // Start or renew the unlock when no active request exists. Long random
        // time warps can expire an earlier request while the position remains live.
        if (
            pos.unlockRequestTime == 0
                || block.timestamp > uint256(pos.unlockRequestTime) + ConstantsLib.PROTECTOR_UNLOCK_WINDOW
        ) {
            vm.prank(actor);
            try pool.startUnlockProcess(tokenId) { }
            catch {
                _unexpectedRevert(this.withdrawProtector.selector);
                return;
            }
            pos = protectorNFT.getPosition(tokenId);
        }

        // Warp to the exact executable time, keeping the request inside its
        // seven-day execution window.
        if (pos.unlockRequestTime > block.timestamp) {
            vm.warp(pos.unlockRequestTime);
        }

        amount = bound(amount, 1, available);
        if (amount > positionAmount) amount = positionAmount;
        if (_protectorWithdrawalLeavesDust(tokenId, amount, positionAmount)) {
            if (available < positionAmount) {
                _skip(this.withdrawProtector.selector);
                return;
            }
            amount = positionAmount;
        }
        if (amount == 0) {
            _skip(this.withdrawProtector.selector);
            return;
        }

        vm.prank(actor);
        try pool.protectorWithdraw(tokenId, amount, address(backingToken), 0) {
            ghost_totalProtectorWithdrawals += amount;
            calls_withdrawProtector++;
            _success(this.withdrawProtector.selector);
            if (pool.getProtectorPositionAmount(tokenId) == 0) {
                _removeTokenId(tokenIds, tokenId);
            }
        } catch {
            _unexpectedRevert(this.withdrawProtector.selector);
        }
    }

    function _protectorWithdrawalLeavesDust(uint256 tokenId, uint256 amount, uint256 positionAmount)
        internal
        view
        returns (bool)
    {
        if (amount >= positionAmount) return false;

        uint256 currentTotalShares = pool.totalProtectorShares();
        uint256 currentTotalTokens = pool.totalProtectorTokens();
        uint256 positionShares = pool.protectorShares(tokenId);
        uint256 sharesToBurn = Math.mulDiv(amount, currentTotalShares, currentTotalTokens, Math.Rounding.Ceil);
        if (sharesToBurn > positionShares) sharesToBurn = positionShares;

        uint256 newShares = positionShares - sharesToBurn;
        uint256 newTotalShares = currentTotalShares - sharesToBurn;
        if (newShares == 0 || newTotalShares == 0) return false;

        uint256 newAmount = Math.mulDiv(newShares, currentTotalTokens - amount, newTotalShares);
        return newAmount != 0 && newAmount < backingMinDepositAmount;
    }

    /// @notice Withdraw as shielded
    function withdrawShielded(uint256 actorSeed, uint256 tokenIdSeed) external tracksRewardPerShare {
        _attempt(this.withdrawShielded.selector);
        address actor = shieldeds[actorSeed % shieldeds.length];
        uint256[] storage tokenIds = shieldedTokenIds[actor];
        if (tokenIds.length == 0) {
            _skip(this.withdrawShielded.selector);
            return;
        }

        uint256 tokenId = tokenIds[tokenIdSeed % tokenIds.length];

        // Get position info
        IShieldReceiptNFT.ShieldPosition memory pos;
        try shieldNFT.getPosition(tokenId) returns (IShieldReceiptNFT.ShieldPosition memory p) {
            pos = p;
        } catch {
            _removeTokenId(tokenIds, tokenId);
            _skip(this.withdrawShielded.selector);
            return;
        }

        if (pos.amount == 0) {
            _skip(this.withdrawShielded.selector);
            return;
        }

        vm.prank(actor);
        try pool.shieldedWithdraw(tokenId, address(shieldedToken), 0) {
            ghost_totalShieldedWithdrawals += pos.amount;
            calls_withdrawShielded++;
            _success(this.withdrawShielded.selector);
            _removeTokenId(tokenIds, tokenId);
        } catch {
            _unexpectedRevert(this.withdrawShielded.selector);
        }
    }

    /// @notice Partially withdraw a shield receipt while preserving its randomized owner index.
    function partialWithdrawShielded(uint256 actorSeed, uint256 tokenIdSeed, uint256 amountSeed)
        external
        tracksRewardPerShare
    {
        _attempt(this.partialWithdrawShielded.selector);
        address actor = shieldeds[actorSeed % shieldeds.length];
        uint256[] storage tokenIds = shieldedTokenIds[actor];
        if (tokenIds.length == 0) {
            _skip(this.partialWithdrawShielded.selector);
            return;
        }

        uint256 tokenId = tokenIds[tokenIdSeed % tokenIds.length];
        IShieldReceiptNFT.ShieldPosition memory pos;
        try shieldNFT.getPosition(tokenId) returns (IShieldReceiptNFT.ShieldPosition memory p) {
            pos = p;
        } catch {
            _removeTokenId(tokenIds, tokenId);
            _skip(this.partialWithdrawShielded.selector);
            return;
        }

        uint256 pendingFees = _pendingShieldedFees(tokenId, pos);
        if (pos.amount <= pendingFees + shieldedMinDepositAmount) {
            _skip(this.partialWithdrawShielded.selector);
            return;
        }

        uint256 maxWithdrawal = pos.amount - pendingFees - shieldedMinDepositAmount;
        uint256 withdrawAmount = bound(amountSeed, 1, maxWithdrawal);

        vm.prank(actor);
        try pool.partialWithdrawShielded(tokenId, withdrawAmount, address(shieldedToken), 0) returns (
            uint256 newTokenId
        ) {
            _replaceTokenId(tokenIds, tokenId, newTokenId);
            ghost_totalPartialShieldedWithdrawals += withdrawAmount;
            calls_partialWithdrawShielded++;
            _success(this.partialWithdrawShielded.selector);
        } catch {
            _unexpectedRevert(this.partialWithdrawShielded.selector);
        }
    }

    function _pendingShieldedFees(uint256 tokenId, IShieldReceiptNFT.ShieldPosition memory pos)
        internal
        view
        returns (uint256)
    {
        uint256 currentPrice = oracle.getPrice(address(shieldedToken));
        uint256 currentValue = Math.mulDiv(pos.amount, currentPrice, 1e18);
        uint256 baselineValue = pool.feeValueBaselineUsd(tokenId);
        if (baselineValue == 0 && pos.valueAtDeposit != 0) baselineValue = pos.valueAtDeposit;
        if (currentValue <= baselineValue) return 0;

        uint256 yieldEarnedUsd = currentValue - baselineValue;
        (,,,,,,,, uint96 protocolFee,) = pool.poolConfig();
        uint256 commissionUsd =
            Math.mulDiv(yieldEarnedUsd, pool.COMMISSION_RATE(), ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);
        uint256 poolFeeUsd =
            Math.mulDiv(yieldEarnedUsd, pool.POOL_FEE(), ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);
        uint256 protocolFeeUsd =
            Math.mulDiv(yieldEarnedUsd, protocolFee, ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);
        uint256 totalFees = Math.mulDiv(commissionUsd, 1e18, currentPrice, Math.Rounding.Ceil)
            + Math.mulDiv(poolFeeUsd, 1e18, currentPrice, Math.Rounding.Ceil)
            + Math.mulDiv(protocolFeeUsd, 1e18, currentPrice, Math.Rounding.Ceil);
        return totalFees > pos.amount ? pos.amount : totalFees;
    }

    /// @notice Claim commission as protector
    function claimCommission(uint256 actorSeed, uint256 tokenIdSeed) external tracksRewardPerShare {
        _attempt(this.claimCommission.selector);
        address actor = protectors[actorSeed % protectors.length];
        uint256[] storage tokenIds = protectorTokenIds[actor];
        if (tokenIds.length == 0) {
            _skip(this.claimCommission.selector);
            return;
        }

        uint256 tokenId = tokenIds[tokenIdSeed % tokenIds.length];

        uint256 claimable = pool.getClaimableCommission(tokenId);
        if (claimable == 0) {
            _skip(this.claimCommission.selector);
            return;
        }

        vm.prank(actor);
        try pool.claimCommission(tokenId) {
            ghost_totalCommissionsClaimed += claimable;
            calls_claimCommission++;
            _success(this.claimCommission.selector);
        } catch {
            _unexpectedRevert(this.claimCommission.selector);
        }
    }

    /// @notice Claim rewards to trigger fee accumulation
    function claimRewards(uint256 actorSeed, uint256 tokenIdSeed) external tracksRewardPerShare {
        _attempt(this.claimRewards.selector);
        address actor = shieldeds[actorSeed % shieldeds.length];
        uint256[] storage tokenIds = shieldedTokenIds[actor];
        if (tokenIds.length == 0) {
            _skip(this.claimRewards.selector);
            return;
        }

        uint256 tokenId = tokenIds[tokenIdSeed % tokenIds.length];

        // Warp past cooldown
        uint256 lastClaim = pool.lastClaimRewardsTime(tokenId);
        if (lastClaim > 0 && block.timestamp < lastClaim + 1 days) {
            vm.warp(lastClaim + 1 days + 1);
        }

        vm.prank(actor);
        try pool.claimRewards(tokenId) {
            calls_claimRewards++;
            _success(this.claimRewards.selector);
        } catch {
            _unexpectedRevert(this.claimRewards.selector);
        }
    }

    /// @notice Pay the creator fee bucket through the governance-authorized path.
    function payPoolFee() external tracksRewardPerShare {
        _attempt(this.payPoolFee.selector);
        uint256 amount = pool.accumulatedPoolFee();
        if (amount == 0) {
            _skip(this.payPoolFee.selector);
            return;
        }

        address recipient = pool.poolFeeRecipient();
        if (recipient == address(0)) recipient = pool.POOL_CREATOR();
        uint256 recipientBalanceBefore = shieldedToken.balanceOf(recipient);
        vm.prank(governance);
        try pool.payPoolFee() {
            uint256 recipientBalanceAfter = shieldedToken.balanceOf(recipient);
            if (
                recipientBalanceAfter < recipientBalanceBefore
                    || recipientBalanceAfter - recipientBalanceBefore != amount
            ) {
                feePayoutRecipientMismatch = true;
                _unexpectedRevert(this.payPoolFee.selector);
                return;
            }
            ghost_totalPoolFeesPaid += recipientBalanceAfter - recipientBalanceBefore;
            calls_payPoolFee++;
            _success(this.payPoolFee.selector);
        } catch {
            _unexpectedRevert(this.payPoolFee.selector);
        }
    }

    /// @notice Pay the protocol fee bucket through the governance-authorized path.
    function payProtocolFee() external tracksRewardPerShare {
        _attempt(this.payProtocolFee.selector);
        uint256 amount = pool.accumulatedProtocolFee();
        if (amount == 0) {
            _skip(this.payProtocolFee.selector);
            return;
        }

        (,,,,,,, address recipient,,) = pool.poolConfig();
        uint256 recipientBalanceBefore = shieldedToken.balanceOf(recipient);
        vm.prank(governance);
        try pool.payProtocolFee() {
            uint256 recipientBalanceAfter = shieldedToken.balanceOf(recipient);
            if (
                recipientBalanceAfter < recipientBalanceBefore
                    || recipientBalanceAfter - recipientBalanceBefore != amount
            ) {
                feePayoutRecipientMismatch = true;
                _unexpectedRevert(this.payProtocolFee.selector);
                return;
            }
            ghost_totalProtocolFeesPaid += recipientBalanceAfter - recipientBalanceBefore;
            calls_payProtocolFee++;
            _success(this.payProtocolFee.selector);
        } catch {
            _unexpectedRevert(this.payProtocolFee.selector);
        }
    }

    /// @notice Transfer a live shield receipt between modeled actors.
    function transferShieldNFT(uint256 actorSeed, uint256 tokenIdSeed, uint256 recipientSeed)
        external
        tracksRewardPerShare
    {
        _attempt(this.transferShieldNFT.selector);
        uint256 sourceIndex = actorSeed % shieldeds.length;
        uint256 recipientIndex = recipientSeed % shieldeds.length;
        if (recipientIndex == sourceIndex) recipientIndex = (recipientIndex + 1) % shieldeds.length;
        address source = shieldeds[sourceIndex];
        address recipient = shieldeds[recipientIndex];
        uint256[] storage sourceTokenIds = shieldedTokenIds[source];
        if (sourceTokenIds.length == 0) {
            _skip(this.transferShieldNFT.selector);
            return;
        }

        uint256 tokenId = sourceTokenIds[tokenIdSeed % sourceTokenIds.length];
        IShieldReceiptNFT.ShieldPosition memory pos = shieldNFT.getPosition(tokenId);
        uint256 unlockTime = uint256(pos.depositTime) + shieldNFT.transferLockPeriod();
        if (block.timestamp < unlockTime) vm.warp(unlockTime);
        bytes32 accountingBefore = _shieldReceiptAccountingHash(tokenId);
        vm.prank(source);
        try shieldNFT.transferFrom(source, recipient, tokenId) {
            _removeTokenId(sourceTokenIds, tokenId);
            shieldedTokenIds[recipient].push(tokenId);
            if (accountingBefore != _shieldReceiptAccountingHash(tokenId)) receiptTransferAccountingChanged = true;
            calls_transferShieldNFT++;
            _success(this.transferShieldNFT.selector);
        } catch {
            _unexpectedRevert(this.transferShieldNFT.selector);
        }
    }

    /// @notice Transfer a live protector receipt between modeled actors.
    function transferProtectorNFT(uint256 actorSeed, uint256 tokenIdSeed, uint256 recipientSeed)
        external
        tracksRewardPerShare
    {
        _attempt(this.transferProtectorNFT.selector);
        uint256 sourceIndex = actorSeed % protectors.length;
        uint256 recipientIndex = recipientSeed % protectors.length;
        if (recipientIndex == sourceIndex) recipientIndex = (recipientIndex + 1) % protectors.length;
        address source = protectors[sourceIndex];
        address recipient = protectors[recipientIndex];
        uint256[] storage sourceTokenIds = protectorTokenIds[source];
        if (sourceTokenIds.length == 0) {
            _skip(this.transferProtectorNFT.selector);
            return;
        }

        uint256 tokenId = sourceTokenIds[tokenIdSeed % sourceTokenIds.length];
        IProtectorReceiptNFT.ProtectorPosition memory pos = protectorNFT.getPosition(tokenId);
        uint256 unlockTime = uint256(pos.depositTime) + protectorNFT.transferLockPeriod();
        if (block.timestamp < unlockTime) vm.warp(unlockTime);
        bytes32 accountingBefore = _protectorReceiptAccountingHash(tokenId);
        vm.prank(source);
        try protectorNFT.transferFrom(source, recipient, tokenId) {
            _removeTokenId(sourceTokenIds, tokenId);
            protectorTokenIds[recipient].push(tokenId);
            if (accountingBefore != _protectorReceiptAccountingHash(tokenId)) receiptTransferAccountingChanged = true;
            calls_transferProtectorNFT++;
            _success(this.transferProtectorNFT.selector);
        } catch {
            _unexpectedRevert(this.transferProtectorNFT.selector);
        }
    }

    function _shieldReceiptAccountingHash(uint256 tokenId) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                shieldNFT.getPosition(tokenId),
                pool.feeValueBaselineUsd(tokenId),
                pool.lastClaimRewardsTime(tokenId),
                pool.totalShieldedTokens(),
                pool.totalValueAtDeposit(),
                pool.totalShieldCollateralAmount()
            )
        );
    }

    function _protectorReceiptAccountingHash(uint256 tokenId) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                protectorNFT.getPosition(tokenId),
                pool.protectorShares(tokenId),
                pool.protectorShareEpochs(tokenId),
                pool.rewardDebt(tokenId),
                pool.commissionsClaimed(tokenId),
                pool.totalProtectorTokens(),
                pool.totalProtectorShares()
            )
        );
    }

    /// @notice Withdraw as shielded via cross-asset path (backing token)
    function withdrawShieldedCrossAsset(uint256 actorSeed, uint256 tokenIdSeed) external tracksRewardPerShare {
        _attempt(this.withdrawShieldedCrossAsset.selector);
        address actor = shieldeds[actorSeed % shieldeds.length];
        uint256[] storage tokenIds = shieldedTokenIds[actor];
        if (tokenIds.length == 0) {
            _skip(this.withdrawShieldedCrossAsset.selector);
            return;
        }

        uint256 tokenId = tokenIds[tokenIdSeed % tokenIds.length];

        // Get position info
        IShieldReceiptNFT.ShieldPosition memory pos;
        try shieldNFT.getPosition(tokenId) returns (IShieldReceiptNFT.ShieldPosition memory p) {
            pos = p;
        } catch {
            _removeTokenId(tokenIds, tokenId);
            _skip(this.withdrawShieldedCrossAsset.selector);
            return;
        }

        if (pos.amount == 0) {
            _skip(this.withdrawShieldedCrossAsset.selector);
            return;
        }

        // Warp past minimumPoolTime (cross-asset requires it)
        (,,,,, uint256 minimumPoolTime,,,,) = pool.poolConfig();
        if (block.timestamp < pos.depositTime + minimumPoolTime) {
            vm.warp(pos.depositTime + minimumPoolTime + 1);
        }

        vm.prank(actor);
        try pool.shieldedWithdraw(tokenId, address(backingToken), 0) {
            ghost_totalCrossAssetWithdrawals += pos.amount;
            calls_withdrawShieldedCrossAsset++;
            _success(this.withdrawShieldedCrossAsset.selector);
            _removeTokenId(tokenIds, tokenId);
        } catch {
            _unexpectedRevert(this.withdrawShieldedCrossAsset.selector);
        }
    }

    /// @notice Drop the shielded token price (simulates adverse market move)
    function dropPrice(uint256 dropBps) external tracksRewardPerShare {
        _attempt(this.dropPrice.selector);
        dropBps = bound(dropBps, 0, 5000); // 0% to 50% drop
        if (dropBps == 0) {
            _skip(this.dropPrice.selector);
            return;
        }

        uint256 currentPrice = oracle.getPrice(address(shieldedToken));
        uint256 newPrice = currentPrice - (currentPrice * dropBps) / 1e4;
        if (newPrice == 0) newPrice = 1; // prevent zero price

        oracle.setPrice(address(shieldedToken), newPrice);
        calls_dropPrice++;
        _success(this.dropPrice.selector);
    }

    /// @notice Simulate yield by changing oracle price
    /// @dev Must be called by test contract owner since oracle is owned by test
    function generateYield(uint256 yieldBps) external tracksRewardPerShare {
        _attempt(this.generateYield.selector);
        yieldBps = bound(yieldBps, 0, 5000); // 0% to 50%
        if (yieldBps == 0) {
            _skip(this.generateYield.selector);
            return;
        }

        uint256 currentPrice = oracle.getPrice(address(shieldedToken));
        if (currentPrice >= MAX_FUZZ_PRICE) {
            _skip(this.generateYield.selector);
            return;
        }
        uint256 newPrice = currentPrice + (currentPrice * yieldBps) / 1e4;
        if (newPrice > MAX_FUZZ_PRICE) newPrice = MAX_FUZZ_PRICE;

        oracle.setPrice(address(shieldedToken), newPrice);
        calls_generateYield++;
        _success(this.generateYield.selector);
    }

    /// @notice Drop the backing token price to fuzz collateral cap accounting under FX movement
    function dropBackingPrice(uint256 dropBps) external tracksRewardPerShare {
        _attempt(this.dropBackingPrice.selector);
        dropBps = bound(dropBps, 0, 5000);
        if (dropBps == 0) {
            _skip(this.dropBackingPrice.selector);
            return;
        }

        uint256 currentPrice = oracle.getPrice(address(backingToken));
        uint256 newPrice = currentPrice - (currentPrice * dropBps) / 1e4;
        if (newPrice == 0) newPrice = 1;

        oracle.setPrice(address(backingToken), newPrice);
        calls_dropBackingPrice++;
        _success(this.dropBackingPrice.selector);
    }

    /// @notice Increase the backing token price to fuzz collateral release under favorable movement
    function increaseBackingPrice(uint256 increaseBps) external tracksRewardPerShare {
        _attempt(this.increaseBackingPrice.selector);
        increaseBps = bound(increaseBps, 0, 5000);
        if (increaseBps == 0) {
            _skip(this.increaseBackingPrice.selector);
            return;
        }

        uint256 currentPrice = oracle.getPrice(address(backingToken));
        if (currentPrice >= MAX_FUZZ_PRICE) {
            _skip(this.increaseBackingPrice.selector);
            return;
        }
        uint256 newPrice = currentPrice + (currentPrice * increaseBps) / 1e4;
        if (newPrice > MAX_FUZZ_PRICE) newPrice = MAX_FUZZ_PRICE;

        oracle.setPrice(address(backingToken), newPrice);
        calls_increaseBackingPrice++;
        _success(this.increaseBackingPrice.selector);
    }

    /// @notice Warp time forward
    function warpTime(uint256 seconds_) external tracksRewardPerShare {
        _attempt(this.warpTime.selector);
        seconds_ = bound(seconds_, 0, 30 days);
        vm.warp(block.timestamp + seconds_);
        _success(this.warpTime.selector);
    }

    function _removeTokenId(uint256[] storage tokenIds, uint256 tokenId) internal {
        uint256 length = tokenIds.length;
        for (uint256 i = 0; i < length;) {
            if (tokenIds[i] == tokenId) {
                tokenIds[i] = tokenIds[length - 1];
                tokenIds.pop();
                return;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _replaceTokenId(uint256[] storage tokenIds, uint256 oldTokenId, uint256 newTokenId) internal {
        uint256 length = tokenIds.length;
        for (uint256 i = 0; i < length; ++i) {
            if (tokenIds[i] == oldTokenId) {
                tokenIds[i] = newTokenId;
                return;
            }
        }
    }

    // ============ View Functions ============

    function getProtectorCount() external view returns (uint256) {
        return protectors.length;
    }

    function getShieldedCount() external view returns (uint256) {
        return shieldeds.length;
    }

    function getProtectorTokenIdCount(address actor) external view returns (uint256) {
        return protectorTokenIds[actor].length;
    }

    function getShieldedTokenIdCount(address actor) external view returns (uint256) {
        return shieldedTokenIds[actor].length;
    }
}

/// @title Invariant Tests for SplitRiskPool
/// @notice Tests critical protocol invariants under random operations
contract SplitRiskPoolInvariantTest is Test, FactoryProxyTestBase {
    SplitRiskPool public pool;
    SplitRiskPoolFactory public factory;
    SplitRiskPoolHandler public handler;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;
    CompositeOracle public compositeOracle;
    ShieldReceiptNFT public shieldNFT;
    ProtectorReceiptNFT public protectorNFT;

    address public governance = address(this);
    address public protocolFeeRecipient = address(0xfee);
    bool public requireRandomReachability;

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

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

        compositeOracle = new CompositeOracle();
        SplitRiskPool implementation = new SplitRiskPool();
        factory = _deployFactory(address(this), governance, address(implementation));
        compositeOracle.transferOwnership(address(factory));
        factory.setCompositeOracle(address(compositeOracle));
        factory.setDefaultProtocolFeeRecipient(protocolFeeRecipient);
        factory.setCompositeOracleAuthorizedCaller(address(this), true);
        vm.prank(governance);
        factory.setMinimumCreationBondUsd(0);

        factory.addTokenInitial(address(shieldedToken), "SHIELD", "SHIELD", address(oracle), address(0), 10000, true);
        factory.addTokenInitial(address(backingToken), "BACK", "BACK", address(oracle), address(0), 10000, true);
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);

        address poolAddress =
            factory.createPool(address(shieldedToken), "SHIELD", address(backingToken), "BACK", 1000, 500, 15000, 0);
        pool = SplitRiskPool(payable(poolAddress));
        shieldNFT = ShieldReceiptNFT(pool.shieldReceiptNFT());
        protectorNFT = ProtectorReceiptNFT(pool.protectorReceiptNFT());

        assertEq(pool.POOL_FACTORY(), address(factory), "invariant pool should be factory-created");
        assertTrue(pool.requiresStrictProtectedBackingPrice(), "factory strict-price flag should be pinned");

        // Deploy handler (needs to be done carefully to handle token ownership)
        handler = new SplitRiskPoolHandler(
            pool,
            shieldedToken,
            backingToken,
            shieldedBaseToken,
            backingBaseToken,
            oracle,
            shieldNFT,
            protectorNFT,
            governance
        );
        oracle.transferOwnership(address(handler));

        // Fund the handler's actors from the test contract
        _fundHandlerActors();
        _seedReachableHandlerPaths();
        handler.enableMetrics();
        requireRandomReachability = vm.envOr("INVARIANT_REQUIRE_RANDOM_REACHABILITY", false);

        // Target handler for invariant testing
        targetContract(address(handler));

        // Exclude specific selectors that shouldn't be called randomly
        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = SplitRiskPoolHandler.depositProtector.selector;
        selectors[1] = SplitRiskPoolHandler.depositShielded.selector;
        selectors[2] = SplitRiskPoolHandler.withdrawProtector.selector;
        selectors[3] = SplitRiskPoolHandler.withdrawShielded.selector;
        selectors[4] = SplitRiskPoolHandler.claimCommission.selector;
        selectors[5] = SplitRiskPoolHandler.claimRewards.selector;
        selectors[6] = SplitRiskPoolHandler.generateYield.selector;
        selectors[7] = SplitRiskPoolHandler.warpTime.selector;
        selectors[8] = SplitRiskPoolHandler.withdrawShieldedCrossAsset.selector;
        selectors[9] = SplitRiskPoolHandler.dropPrice.selector;
        selectors[10] = SplitRiskPoolHandler.dropBackingPrice.selector;
        selectors[11] = SplitRiskPoolHandler.increaseBackingPrice.selector;
        selectors[12] = SplitRiskPoolHandler.partialWithdrawShielded.selector;
        selectors[13] = SplitRiskPoolHandler.payPoolFee.selector;
        selectors[14] = SplitRiskPoolHandler.payProtocolFee.selector;
        selectors[15] = SplitRiskPoolHandler.transferShieldNFT.selector;
        selectors[16] = SplitRiskPoolHandler.transferProtectorNFT.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @notice Fund all handler actors with tokens
    function _fundHandlerActors() internal {
        uint256 amount = 10_000_000e18;

        for (uint256 i = 0; i < 5; i++) {
            address prot = handler.getProtector(i);
            address sh = handler.getShielded(i);

            // Fund protector with backing tokens
            backingBaseToken.mint(prot, amount);
            vm.startPrank(prot);
            backingBaseToken.approve(address(backingToken), amount);
            backingToken.deposit(amount, prot);
            backingToken.approve(address(pool), type(uint256).max);
            vm.stopPrank();

            // Fund shielded with shielded tokens
            shieldedBaseToken.mint(sh, amount);
            vm.startPrank(sh);
            shieldedBaseToken.approve(address(shieldedToken), amount);
            shieldedToken.deposit(amount, sh);
            shieldedToken.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Deterministically establish live receipts and exercise every economically
    ///      important handler family once before random dispatch begins. Handler
    ///      metrics remain disabled during seeding so reachability floors can only
    ///      be satisfied by subsequent randomized dispatch.
    function _seedReachableHandlerPaths() internal {
        handler.depositProtector(0, 1_000_000e18);
        handler.depositProtector(1, 1_000_000e18);
        handler.depositShielded(0, 100_000e18);
        handler.depositShielded(1, 100_000e18);
        handler.depositShielded(2, 100_000e18);
        handler.generateYield(1_000);
        handler.claimRewards(0, 0);
        handler.claimCommission(0, 0);
        handler.partialWithdrawShielded(2, 0, 50_000e18);
        handler.transferShieldNFT(2, 0, 3);
        handler.transferProtectorNFT(0, 0, 2);
        handler.payPoolFee();
        handler.payProtocolFee();
        handler.withdrawShielded(0, 0);
        handler.withdrawShieldedCrossAsset(1, 0);
        handler.withdrawProtector(1, 0, 100_000e18);

        assertGt(handler.calls_depositProtector(), 0, "seed protector deposit must execute");
        assertGt(handler.calls_depositShielded(), 0, "seed shield deposit must execute");
        assertGt(handler.calls_claimRewards(), 0, "seed reward claim must execute");
        assertGt(handler.calls_claimCommission(), 0, "seed commission claim must execute");
        assertGt(handler.calls_partialWithdrawShielded(), 0, "seed partial shield exit must execute");
        assertGt(handler.calls_transferShieldNFT(), 0, "seed shield receipt transfer must execute");
        assertGt(handler.calls_transferProtectorNFT(), 0, "seed protector receipt transfer must execute");
        assertGt(handler.calls_payPoolFee(), 0, "seed pool fee payout must execute");
        assertGt(handler.calls_payProtocolFee(), 0, "seed protocol fee payout must execute");
        assertGt(handler.calls_withdrawShielded(), 0, "seed same-asset exit must execute");
        assertGt(handler.calls_withdrawShieldedCrossAsset(), 0, "seed cross-asset exit must execute");
        assertGt(handler.calls_withdrawProtector(), 0, "seed protector exit must execute");
    }

    function test_handlerPriceMutationsUpdateOracle() public {
        uint256 initialPrice = oracle.getPrice(address(shieldedToken));
        uint256 initialYieldCalls = handler.calls_generateYield();
        uint256 initialDropCalls = handler.calls_dropPrice();

        handler.generateYield(1000);
        uint256 higherPrice = oracle.getPrice(address(shieldedToken));
        assertGt(higherPrice, initialPrice, "generateYield should increase the mock price");
        assertEq(
            handler.calls_generateYield(),
            initialYieldCalls + 1,
            "generateYield counter should track successful mutation"
        );

        handler.dropPrice(1000);
        uint256 lowerPrice = oracle.getPrice(address(shieldedToken));
        assertLt(lowerPrice, higherPrice, "dropPrice should decrease the mock price");
        assertEq(handler.calls_dropPrice(), initialDropCalls + 1, "dropPrice counter should track successful mutation");
    }

    function test_seedDoesNotCountTowardsRandomReachabilityMetrics() public view {
        assertTrue(handler.metricsEnabled(), "random-dispatch metrics should be enabled after seeding");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.depositProtector.selector, "protector deposits");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.depositShielded.selector, "shield deposits");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.withdrawProtector.selector, "protector exits");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.withdrawShielded.selector, "same-asset exits");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.withdrawShieldedCrossAsset.selector, "cross-asset exits");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.claimRewards.selector, "reward claims");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.claimCommission.selector, "commission claims");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.generateYield.selector, "positive price movement");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.partialWithdrawShielded.selector, "partial shield exits");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.payPoolFee.selector, "pool fee payouts");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.payProtocolFee.selector, "protocol fee payouts");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.transferShieldNFT.selector, "shield receipt transfers");
        _assertHandlerMetricsEmpty(SplitRiskPoolHandler.transferProtectorNFT.selector, "protector receipt transfers");
    }

    function _assertHandlerMetricsEmpty(bytes4 selector, string memory label) internal view {
        (uint256 attempts, uint256 skips, uint256 successes, uint256 unexpectedReverts) = handler.callMetrics(selector);
        assertEq(attempts, 0, string.concat(label, " seed attempts leaked into randomized metrics"));
        assertEq(skips, 0, string.concat(label, " seed skips leaked into randomized metrics"));
        assertEq(successes, 0, string.concat(label, " seed successes leaked into randomized metrics"));
        assertEq(unexpectedReverts, 0, string.concat(label, " seed reverts leaked into randomized metrics"));
    }

    // ============ Invariant 1: Pool Balance Solvency ============

    /// @notice Pool token balances must always be >= tracked balances
    /// @dev The actual token balance should never be less than what accounting says
    function invariant_poolBalanceSolvency() public view {
        (uint256 shieldedBal, uint256 protectorBal) = pool.getPoolBalances();

        uint256 actualShieldedBal = shieldedToken.balanceOf(address(pool));
        uint256 actualProtectorBal = backingToken.balanceOf(address(pool));

        // Actual balance should be >= tracked balance (could be higher due to direct transfers)
        assertGe(actualShieldedBal, shieldedBal, "Shielded token balance should be >= tracked");
        assertGe(actualProtectorBal, protectorBal, "Protector token balance should be >= tracked");
    }

    // ============ Invariant 2: Fee Accumulator Safety ============

    /// @notice Fee accumulators must never exceed uint128 max
    function invariant_feeAccumulatorsBounded() public view {
        uint256 accumulatedCommissions = pool.accumulatedCommissions();
        uint256 accumulatedPoolFee = pool.accumulatedPoolFee();
        uint256 accumulatedProtocolFee = pool.accumulatedProtocolFee();

        assertLe(accumulatedCommissions, type(uint128).max, "Commissions should be within uint128");
        assertLe(accumulatedPoolFee, type(uint128).max, "Pool fee should be within uint128");
        assertLe(accumulatedProtocolFee, type(uint128).max, "Protocol fee should be within uint128");
    }

    // ============ Invariant 3: Commission Distribution Conservation ============

    /// @notice Total claimable commissions should approximate accumulated commissions
    /// @dev The sum of all claimable commissions should equal accumulatedCommissions
    function invariant_commissionConservation() public view {
        uint256 accumulatedCommissions = pool.accumulatedCommissions();

        // Sum all claimable commissions from all protector positions
        // Use nextTokenId to iterate through all possible token IDs
        uint256 totalClaimable = 0;
        uint256 nextTokenId = protectorNFT.nextTokenId();

        for (uint256 tokenId = 0; tokenId < nextTokenId; tokenId++) {
            // Skip burned tokens (owner will be address(0))
            try protectorNFT.ownerOf(tokenId) returns (address owner) {
                if (owner != address(0)) {
                    totalClaimable += pool.getClaimableCommission(tokenId);
                }
            } catch {
                // Token doesn't exist or was burned
            }
        }

        // Allow tolerance for rounding (0.1% or 1e15, whichever is larger)
        uint256 tolerance = accumulatedCommissions / 1000 > 1e15 ? accumulatedCommissions / 1000 : 1e15;

        // Total claimable should approximately equal accumulated (allow for rounding)
        if (accumulatedCommissions > 0) {
            uint256 diff = totalClaimable > accumulatedCommissions
                ? totalClaimable - accumulatedCommissions
                : accumulatedCommissions - totalClaimable;
            assertLe(diff, tolerance, "Commission distribution should be conserved");
        }
    }

    // ============ Invariant 4: Collateralization Ratio ============

    /// @notice When stored shield collateral caps consume all protector assets, withdrawals should be blocked
    function invariant_collateralizationMaintained() public view {
        uint256 totalProtectorTokens = pool.totalProtectorTokens();
        uint256 collateralCap = pool.totalShieldCollateralAmount();

        if (totalProtectorTokens != 0 && collateralCap != 0) {
            if (collateralCap < totalProtectorTokens) {
                return;
            }

            uint256 nextTokenId = protectorNFT.nextTokenId();
            for (uint256 tokenId = 0; tokenId < nextTokenId; tokenId++) {
                try protectorNFT.ownerOf(tokenId) returns (address owner) {
                    if (owner != address(0)) {
                        uint256 available = pool.getAvailableForWithdrawal(tokenId);
                        assertEq(available, 0, "Available should be 0 when collateral lock consumes the pool");
                    }
                } catch {
                    // Token doesn't exist or was burned
                }
            }
        }
    }

    // ============ Invariant 5: Total Token Tracking ============

    /// @notice Protector claims should stay covered by their active or expired backing ledger
    function invariant_totalTokenTracking() public view {
        // Sum all current protector claims
        uint256 sumActiveProtectorPositions = 0;
        uint256 sumExpiredProtectorPositions = 0;
        uint256 currentProtectorEpoch = pool.protectorShareEpoch();
        uint256 protectorNextTokenId = protectorNFT.nextTokenId();
        for (uint256 tokenId = 0; tokenId < protectorNextTokenId; tokenId++) {
            try protectorNFT.ownerOf(tokenId) returns (address owner) {
                if (owner != address(0)) {
                    uint256 positionAmount = pool.getProtectorPositionAmount(tokenId);
                    if (pool.protectorShareEpochs(tokenId) == currentProtectorEpoch) {
                        sumActiveProtectorPositions += positionAmount;
                    } else {
                        sumExpiredProtectorPositions += positionAmount;
                    }
                }
            } catch {
                // Token doesn't exist or was burned
            }
        }

        uint256 totalExpiredProtectorBackingReserve = 0;
        for (uint256 epoch = 0; epoch < currentProtectorEpoch; epoch++) {
            totalExpiredProtectorBackingReserve += pool.protectorEpochBackingRemainingReserve(epoch);
        }

        // Sum all shielded positions (only non-withdrawn)
        uint256 sumShieldedPositions = 0;
        uint256 sumShieldedValueAtDeposit = 0;
        uint256 sumShieldedCollateralAmount = 0;
        uint256 shieldedNextTokenId = shieldNFT.nextTokenId();
        for (uint256 tokenId = 0; tokenId < shieldedNextTokenId; tokenId++) {
            try shieldNFT.ownerOf(tokenId) returns (address owner) {
                if (owner != address(0)) {
                    IShieldReceiptNFT.ShieldPosition memory pos = shieldNFT.getPosition(tokenId);
                    sumShieldedPositions += pos.amount;
                    sumShieldedValueAtDeposit += pos.valueAtDeposit;
                    sumShieldedCollateralAmount += pos.collateralAmount;
                }
            } catch {
                // Token doesn't exist or was burned
            }
        }

        // Total tokens should match sum of positions
        assertLe(
            sumActiveProtectorPositions,
            pool.totalProtectorTokens(),
            "Summed active protector claims should never exceed active backing"
        );
        assertLe(
            pool.totalProtectorTokens() - sumActiveProtectorPositions,
            protectorNextTokenId,
            "Active protector rounding dust should stay bounded by position count"
        );
        assertLe(
            sumExpiredProtectorPositions,
            totalExpiredProtectorBackingReserve,
            "Summed expired protector claims should never exceed expired backing reserves"
        );
        assertLe(
            totalExpiredProtectorBackingReserve - sumExpiredProtectorPositions,
            protectorNextTokenId,
            "Expired protector rounding dust should stay bounded by position count"
        );
        assertEq(
            pool.totalShieldedTokens(), sumShieldedPositions, "Total shielded tokens should match sum of positions"
        );
        assertEq(
            pool.totalValueAtDeposit(),
            sumShieldedValueAtDeposit,
            "Total valueAtDeposit should match sum of position valueAtDeposit values"
        );
        assertEq(
            pool.totalShieldCollateralAmount(),
            sumShieldedCollateralAmount,
            "Total shield collateral should match sum of position collateral amounts"
        );
    }

    // ============ Invariant 6: Reserved Fees Protection ============

    /// @notice Withdrawable balance should never allow taking reserved fees
    function invariant_reservedFeesProtected() public view {
        uint256 reservedFees = pool.getReservedFees();
        uint256 withdrawableBalance = pool.getWithdrawableBalance();
        (uint256 shieldedBal,) = pool.getPoolBalances();

        // Withdrawable should be shieldedBal - reserved (or 0 if reserved > shieldedBal)
        if (shieldedBal > reservedFees) {
            assertEq(withdrawableBalance, shieldedBal - reservedFees, "Withdrawable should exclude reserved");
        } else {
            assertEq(withdrawableBalance, 0, "Withdrawable should be 0 when reserved >= balance");
        }
    }

    // ============ Invariant 7: Reward Per Share Monotonicity ============

    /// @notice Reward per share accumulator must not decrease across handler transitions
    function invariant_rewardPerShareMonotonic() public view {
        assertFalse(handler.rewardPerShareEverDecreased(), "reward per share decreased during a handler transition");
        assertGe(
            handler.highestRewardPerShareObserved(),
            pool.rewardPerShareAccumulated(),
            "handler must observe the current reward per share"
        );
    }

    // ============ Invariant 8: No Orphaned Commissions ============

    /// @notice When protector tokens exist, commissions should be claimable
    /// @dev If totalProtectorTokens == 0 and commissions exist, they're stranded
    function invariant_noOrphanedCommissions() public view {
        uint256 totalShares = pool.totalProtectorShares();
        uint256 accumulated = pool.accumulatedCommissions();

        // If no active shares exist in the initial epoch, commissions should be 0.
        // Later epochs may still have historical claims capped at the finalized epoch RPS.
        if (totalShares == 0 && pool.protectorShareEpoch() == 0) {
            assertEq(accumulated, 0, "No commissions should accumulate with 0 protectors");
        }
    }

    // ============ Invariant 9: Available + Locked Consistency ============

    /// @notice Available for withdrawal should be correctly computed based on locked amount
    /// @dev When locked >= amount, available should be 0
    function invariant_lockedAmountConsistent() public view {
        uint256 nextTokenId = protectorNFT.nextTokenId();

        for (uint256 tokenId = 0; tokenId < nextTokenId; tokenId++) {
            try protectorNFT.ownerOf(tokenId) returns (address owner) {
                if (owner != address(0)) {
                    uint256 positionAmount = pool.getProtectorPositionAmount(tokenId);
                    uint256 locked = pool.getLockedAmount(tokenId);
                    uint256 available = pool.getAvailableForWithdrawal(tokenId);

                    // If locked >= amount, available should be 0
                    if (locked >= positionAmount) {
                        assertEq(available, 0, "Available should be 0 when locked >= amount");
                    } else {
                        // Otherwise, available should equal amount - locked
                        assertEq(available, positionAmount - locked, "Available should equal amount - locked");
                    }
                }
            } catch {
                // Token doesn't exist or was burned
            }
        }
    }

    // ============ Invariant 10: TVL Limit Respected ============

    /// @notice No successful deposit may leave the pool above its TVL limit at execution time
    /// @dev Later oracle appreciation may legitimately move current TVL above the deposit cap.
    function invariant_depositsRespectTvlLimit() public view {
        assertFalse(handler.tvlLimitViolatedByDeposit(), "a successful deposit exceeded the contemporaneous TVL cap");
    }

    // ============ Invariant 11: Double Withdrawal Prevention ============

    /// @notice Existing shield positions should always carry a positive amount
    function invariant_noDoubleWithdrawal() public view {
        uint256 nextTokenId = shieldNFT.nextTokenId();

        for (uint256 tokenId = 0; tokenId < nextTokenId; tokenId++) {
            try shieldNFT.ownerOf(tokenId) returns (address owner) {
                if (owner != address(0)) {
                    IShieldReceiptNFT.ShieldPosition memory pos = shieldNFT.getPosition(tokenId);
                    assertGt(pos.amount, 0, "Existing shield position should carry a positive amount");
                }
            } catch {
                // Token doesn't exist or was burned
            }
        }
    }

    // ============ Invariant 12: Pool Value Conservation ============

    /// @notice Pool value should equal sum of all positions plus accumulated fees
    function invariant_poolValueConservation() public view {
        (uint256 shieldedBal, uint256 protectorBal) = pool.getPoolBalances();

        // For shielded side: balance = sum of positions + accumulated fees
        uint256 totalShielded = pool.totalShieldedTokens();

        // Shielded balance should be >= total shielded tokens + fees
        // (could be higher due to yield not yet claimed)
        assertGe(shieldedBal, totalShielded, "Shielded balance should be >= total shielded positions");

        // For protector side: balance should equal total protector tokens
        uint256 totalProtector = pool.totalProtectorTokens();
        assertGe(protectorBal, totalProtector, "Protector balance should be >= total positions");
    }

    // ============ Invariant 13: Shielded Balance Covers Positions + Fees ============

    /// @notice Shielded token balance must always cover total positions plus reserved fees
    /// @dev Critical for cross-asset withdrawal safety: ensures fees are never consumed by withdrawals
    function invariant_shieldedBalanceCoversPositionsAndFees() public view {
        uint256 shieldedBalance = shieldedToken.balanceOf(address(pool));
        uint256 totalShieldedTokens = pool.totalShieldedTokens();
        uint256 reservedFees = pool.getReservedFees();

        assertGe(
            shieldedBalance, totalShieldedTokens + reservedFees, "Shielded balance must cover positions + reserved fees"
        );
    }

    // ============ Invariant 14: Fee Payout Conservation ============

    /// @notice Random fee payouts must only move accrued fees from pool accounting to recipients.
    function invariant_feePayoutConservation() public view {
        assertFalse(handler.feePayoutRecipientMismatch(), "fee payout did not reach its configured recipient");
        assertEq(
            pool.accumulatedPoolFee() + handler.ghost_totalPoolFeesPaid(),
            handler.ghost_totalPoolFeesAccrued(),
            "pool fee accruals must equal outstanding plus paid fees"
        );
        assertEq(
            pool.accumulatedProtocolFee() + handler.ghost_totalProtocolFeesPaid(),
            handler.ghost_totalProtocolFeesAccrued(),
            "protocol fee accruals must equal outstanding plus paid fees"
        );
    }

    // ============ Invariant 15: Receipt Transfer Accounting ============

    /// @notice ERC721 ownership changes must not mutate receipt or aggregate pool accounting.
    function invariant_receiptTransfersPreserveAccounting() public view {
        assertFalse(handler.receiptTransferAccountingChanged(), "receipt transfer changed economic accounting");
    }

    // ============ Post-Run Coverage ============

    function afterInvariant() public view {
        if (requireRandomReachability) {
            _assertHandlerCoverage(SplitRiskPoolHandler.depositProtector.selector, 1, "protector deposits");
            _assertHandlerCoverage(SplitRiskPoolHandler.depositShielded.selector, 1, "shield deposits");
            _assertHandlerCoverage(SplitRiskPoolHandler.withdrawProtector.selector, 1, "protector exits");
            _assertHandlerCoverage(SplitRiskPoolHandler.withdrawShielded.selector, 1, "same-asset exits");
            _assertHandlerCoverage(SplitRiskPoolHandler.withdrawShieldedCrossAsset.selector, 1, "cross-asset exits");
            _assertHandlerCoverage(SplitRiskPoolHandler.claimRewards.selector, 1, "reward claims");
            _assertHandlerCoverage(SplitRiskPoolHandler.claimCommission.selector, 1, "commission claims");
            _assertHandlerCoverage(SplitRiskPoolHandler.generateYield.selector, 1, "positive price movement");
            _assertHandlerCoverage(SplitRiskPoolHandler.partialWithdrawShielded.selector, 1, "partial shield exits");
            _assertHandlerCoverage(SplitRiskPoolHandler.payPoolFee.selector, 1, "pool fee payouts");
            _assertHandlerCoverage(SplitRiskPoolHandler.payProtocolFee.selector, 1, "protocol fee payouts");
            _assertHandlerCoverage(SplitRiskPoolHandler.transferShieldNFT.selector, 1, "shield receipt transfers");
            _assertHandlerCoverage(SplitRiskPoolHandler.transferProtectorNFT.selector, 1, "protector receipt transfers");
        }

        _assertNoUnexpectedReverts(SplitRiskPoolHandler.depositProtector.selector, "protector deposits");
        _assertNoUnexpectedReverts(SplitRiskPoolHandler.depositShielded.selector, "shield deposits");
        _assertNoUnexpectedReverts(SplitRiskPoolHandler.withdrawProtector.selector, "protector exits");
        _assertNoUnexpectedReverts(SplitRiskPoolHandler.withdrawShielded.selector, "same-asset exits");
        _assertNoUnexpectedReverts(SplitRiskPoolHandler.withdrawShieldedCrossAsset.selector, "cross-asset exits");
        _assertNoUnexpectedReverts(SplitRiskPoolHandler.claimRewards.selector, "reward claims");
        _assertNoUnexpectedReverts(SplitRiskPoolHandler.claimCommission.selector, "commission claims");
        _assertNoUnexpectedReverts(SplitRiskPoolHandler.partialWithdrawShielded.selector, "partial shield exits");
        _assertNoUnexpectedReverts(SplitRiskPoolHandler.payPoolFee.selector, "pool fee payouts");
        _assertNoUnexpectedReverts(SplitRiskPoolHandler.payProtocolFee.selector, "protocol fee payouts");
        _assertNoUnexpectedReverts(SplitRiskPoolHandler.transferShieldNFT.selector, "shield receipt transfers");
        _assertNoUnexpectedReverts(SplitRiskPoolHandler.transferProtectorNFT.selector, "protector receipt transfers");
    }

    function _assertHandlerCoverage(bytes4 selector, uint256 minimumSuccesses, string memory label) internal view {
        (uint256 attempts,, uint256 successes,) = handler.callMetrics(selector);
        assertGt(attempts, 0, string.concat(label, " were never attempted"));
        assertGe(successes, minimumSuccesses, string.concat(label, " did not reach the success path"));
    }

    function _assertNoUnexpectedReverts(bytes4 selector, string memory label) internal view {
        (,,, uint256 unexpectedReverts) = handler.callMetrics(selector);
        assertEq(unexpectedReverts, 0, string.concat(label, " had modeled-valid reverts"));
    }

    function test_handlerSkipsShieldDepositWhenUsdValueRoundsToZero() public {
        for (uint256 i = 0; i < 32; i++) {
            handler.dropPrice(5_000);
        }
        assertEq(oracle.getPrice(address(shieldedToken)), 1, "precondition: fuzzed price reaches one");

        (, uint256 skipsBefore, uint256 successesBefore, uint256 revertsBefore) =
            handler.callMetrics(SplitRiskPoolHandler.depositShielded.selector);
        handler.depositShielded(0, 0);
        (, uint256 skipsAfter, uint256 successesAfter, uint256 revertsAfter) =
            handler.callMetrics(SplitRiskPoolHandler.depositShielded.selector);

        assertEq(skipsAfter, skipsBefore + 1, "zero-USD deposit should be a modeled skip");
        assertEq(successesAfter, successesBefore, "zero-USD deposit must not execute");
        assertEq(revertsAfter, revertsBefore, "zero-USD deposit must not count as an unexpected revert");
    }

    function test_handlerSkipsProtectorDepositWhenUsdValueRoundsToZero() public {
        for (uint256 i = 0; i < 32; i++) {
            handler.dropBackingPrice(5_000);
        }
        assertEq(oracle.getPrice(address(backingToken)), 1, "precondition: fuzzed backing price reaches one");

        (, uint256 skipsBefore, uint256 successesBefore, uint256 revertsBefore) =
            handler.callMetrics(SplitRiskPoolHandler.depositProtector.selector);
        handler.depositProtector(0, 0);
        (, uint256 skipsAfter, uint256 successesAfter, uint256 revertsAfter) =
            handler.callMetrics(SplitRiskPoolHandler.depositProtector.selector);

        assertEq(skipsAfter, skipsBefore + 1, "zero-USD protector deposit should be a modeled skip");
        assertEq(successesAfter, successesBefore, "zero-USD protector deposit must not execute");
        assertEq(revertsAfter, revertsBefore, "zero-USD protector deposit must not count as an unexpected revert");
    }

    // ============ Post-Run Summary ============

    /// @notice Helper to check handler call statistics after test run
    function invariant_callSummary() public view {
        console2.log("=== Handler Call Summary ===");
        console2.log("depositProtector:", handler.calls_depositProtector());
        console2.log("depositShielded:", handler.calls_depositShielded());
        console2.log("withdrawProtector:", handler.calls_withdrawProtector());
        console2.log("withdrawShielded:", handler.calls_withdrawShielded());
        console2.log("claimCommission:", handler.calls_claimCommission());
        console2.log("claimRewards:", handler.calls_claimRewards());
        console2.log("withdrawShieldedCrossAsset:", handler.calls_withdrawShieldedCrossAsset());
        console2.log("partialWithdrawShielded:", handler.calls_partialWithdrawShielded());
        console2.log("payPoolFee:", handler.calls_payPoolFee());
        console2.log("payProtocolFee:", handler.calls_payProtocolFee());
        console2.log("transferShieldNFT:", handler.calls_transferShieldNFT());
        console2.log("transferProtectorNFT:", handler.calls_transferProtectorNFT());
        console2.log("dropPrice:", handler.calls_dropPrice());
        console2.log("generateYield:", handler.calls_generateYield());
        console2.log("unexpected handler reverts are asserted in afterInvariant");
        console2.log("");
        console2.log("Ghost Variables:");
        console2.log("totalProtectorDeposits:", handler.ghost_totalProtectorDeposits());
        console2.log("totalShieldedDeposits:", handler.ghost_totalShieldedDeposits());
        console2.log("totalProtectorWithdrawals:", handler.ghost_totalProtectorWithdrawals());
        console2.log("totalShieldedWithdrawals:", handler.ghost_totalShieldedWithdrawals());
        console2.log("totalCommissionsClaimed:", handler.ghost_totalCommissionsClaimed());
        console2.log("totalCrossAssetWithdrawals:", handler.ghost_totalCrossAssetWithdrawals());
        console2.log("totalPartialShieldedWithdrawals:", handler.ghost_totalPartialShieldedWithdrawals());
        console2.log("totalPoolFeesPaid:", handler.ghost_totalPoolFeesPaid());
        console2.log("totalProtocolFeesPaid:", handler.ghost_totalProtocolFeesPaid());
    }
}
