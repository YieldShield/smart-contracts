// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IShieldReceiptNFT } from "./interfaces/IShieldReceiptNFT.sol";
import { IProtectorReceiptNFT } from "./interfaces/IProtectorReceiptNFT.sol";
import { ISplitRiskPool } from "./interfaces/ISplitRiskPool.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";
import { EventsLib } from "./libraries/EventsLib.sol";
import { ConstantsLib } from "./libraries/ConstantsLib.sol";
import { PoolOracleValidationLib } from "./libraries/PoolOracleValidationLib.sol";

import { TokenWhitelistLib } from "./libraries/TokenWhitelistLib.sol";
import { IPriceOracle } from "./interfaces/IPriceOracle.sol";
import { ICompositeOracle } from "./interfaces/ICompositeOracle.sol";
import { ISplitRiskPoolFactory } from "./interfaces/ISplitRiskPoolFactory.sol";
import { SlippageLib } from "./libraries/SlippageLib.sol";
import { ProtocolAccessControlUpgradeable } from "./base/ProtocolAccessControlUpgradeable.sol";
import { IPoolAccessControl } from "./interfaces/IPoolAccessControl.sol";
import { TransferIntegrityProbe } from "./TransferIntegrityProbe.sol";

/// @title SplitRiskPool
/// @author David Hawig
/// @notice A decentralized balance protection protocol with tradeable risk tokens and time-based lifecycle phases
contract SplitRiskPool is Initializable, ISplitRiskPool, ProtocolAccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @dev Pool configuration parameters grouped for efficient storage access
    struct PoolConfig {
        uint256 shieldedMinDepositAmount; // Minimum shielded deposit in native shielded token units
        uint256 shieldedMaxDepositAmount; // Maximum shielded deposit in native shielded token units
        uint256 backingMinDepositAmount; // Minimum backing deposit in native backing token units
        uint256 backingMaxDepositAmount; // Maximum backing deposit in native backing token units
        uint256 maxTotalValueLockedUsd; // Maximum pool TVL in USD (8 decimals)
        uint256 minimumPoolTime; // Minimum time assets must stay in pool before withdrawal
        uint256 unlockDuration; // Duration of the lock period of the protector token
        address protocolFeeRecipient; // Protocol fee recipient (packed with protocolFee)
        uint96 protocolFee; // Protocol fee rate (in basis points, max 10000 fits in uint96)
        address priceOracle; // Price oracle for token valuation
    }

    /// @dev Pool state variables grouped for efficient storage access
    struct PoolState {
        uint256 shieldedTokenBalance; // Total shielded token held in pool
        uint256 totalBackingTokenBalance; // Sum of all protector token balances
    }

    // Storage variables using optimized structs
    PoolConfig public poolConfig;
    PoolState public poolState;

    address public accessControl; // Access control contract address (address(0) = no restrictions)

    /* Core Pool Parameters - Immutable (set once in constructor) */
    address public shieldReceiptNFT;
    address public protectorReceiptNFT;
    address public SHIELDED_TOKEN; // Yield Bearing Token A
    uint256 public COMMISSION_RATE; // Commission rate for the pool
    uint256 public POOL_FEE; // Pool creator fee rate (in basis points)
    address public POOL_CREATOR; // Address of the pool creator
    uint256 public COLLATERAL_RATIO; // Collateral ratio for the pool
    address public BACKING_TOKEN;

    /* Pool-Level Accounting - Used for USD-based capacity checks via price oracle */
    /// @notice Sum of all active shielded position amounts in native shielded token units
    /// @dev Invariant: totalShieldedTokens == sum of all extant shield receipt position amounts
    ///      Maintained by:
    ///      - depositShieldedAsset: += received
    ///      - shieldedWithdraw: -= pos.amount (full original amount)
    ///      - partialWithdrawShielded: -= (withdrawAmount + totalFees)
    ///      - claimRewards: -= totalFees
    uint256 public totalShieldedTokens;
    uint256 public totalProtectorTokens; // Sum of all active protector backing claims in native backing token units

    /// @notice Sum of all active shielded position original deposit values (8 decimals, USD-based)
    /// @dev Invariant: totalValueAtDeposit == sum of all extant shield receipt position values
    ///      Used for collateralization checks based on original deposit values (not current token amounts).
    ///      Maintained by:
    ///      - depositShieldedAsset: += valueAtDeposit
    ///      - shieldedWithdraw: -= pos.valueAtDeposit (full original value)
    ///      - partialWithdrawShielded: -= pos.valueAtDeposit, then += (pos.valueAtDeposit * remaining / pos.amount)
    ///      - claimRewards: Does NOT change (original deposit value remains the same)
    uint256 public totalValueAtDeposit;

    /// @notice Sum of all active shielded position collateral caps in native backing-token units
    /// @dev Invariant: totalShieldCollateralAmount == sum of all extant shield receipt collateralAmount values.
    ///      This caps how much backing liquidity shield holders can ever claim after price drawdowns.
    ///      Maintained by:
    ///      - depositShieldedAsset: += collateralAmount
    ///      - shieldedWithdraw: -= pos.collateralAmount
    ///      - partialWithdrawShielded: -= pos.collateralAmount, then += newCollateralAmount
    ///      - claimRewards: Does NOT change (cross-asset collateral cap remains unchanged)
    uint256 public totalShieldCollateralAmount;

    /* Pool Fee Accumulators */
    uint256 public accumulatedCommissions; // Pending commissions for protectors in native shielded token units
    uint256 public accumulatedPoolFee; // Total pool fee accumulated in native shielded token units
    uint256 public accumulatedProtocolFee; // Total protocol fee accumulated in native shielded token units

    /* Commission tracking - fees follow the NFT (tracked per tokenId, not per address) */
    mapping(uint256 => uint256) public commissionsClaimed; // tokenId => claimed amount
    uint256 public totalCommissionsEverAccumulated; // Running total for pro-rata calculation

    /* Rewards-per-share accumulator (MasterChef pattern) - fixes late-joiner exploit */
    uint256 public rewardPerShareAccumulated; // Accumulated rewards per share (scaled by REWARD_PRECISION)
    mapping(uint256 => uint256) public rewardDebt; // tokenId => reward debt (rewards accumulated before deposit)
    // L-14: cooldown is keyed by tokenId, not owner. When a shield NFT is
    // transferred, the new owner inherits the previous owner's cooldown
    // window. This is intentional for accounting consistency (fee baselines
    // travel with the NFT, so claim metadata should too) but means a
    // secondary-market buyer cannot crystallise fees immediately on receipt.
    // Resetting on transfer would require an NFT→pool callback into _update;
    // tracked as an accepted limitation. Documented in SECURITY.md.
    mapping(uint256 => uint256) public lastClaimRewardsTime; // tokenId => last claim timestamp

    /* Per-position fee baselines (USD, 8 decimals) to prevent re-taxing already charged yield */
    mapping(uint256 => uint256) public feeValueBaselineUsd; // tokenId => last value baseline used for fee accrual

    /* Errors */
    using ErrorsLib for *;

    /* Pool Events */
    using EventsLib for *;

    /// @notice B9 (H-5 follow-up): emitted at initialize when the factory
    ///         staticcall used to pin the strict-protected-backing-price
    ///         policy fails (call reverted or returned malformed data). The
    ///         pinned snapshot defaults to `false` in this case; monitoring
    ///         should treat that as a probe regression rather than a
    ///         deliberate downgrade.
    event StrictPricingProbeFailed(address indexed token, address indexed factory);
    event ShieldedTokenTransferIntegrityBroken(address indexed token, uint256 nominalAmount, uint256 receivedAmount);
    event ShieldedTokenTransferIntegrityRestored(address indexed token, uint256 probeAmount);

    /* Modifiers */
    modifier onlyShieldNFTOwner(uint256 tokenId) {
        if (IShieldReceiptNFT(shieldReceiptNFT).ownerOf(tokenId) != msg.sender) {
            revert ErrorsLib.InvalidTokenId();
        }
        _;
    }

    modifier onlyProtectorNFTOwner(uint256 tokenId) {
        if (IProtectorReceiptNFT(protectorReceiptNFT).ownerOf(tokenId) != msg.sender) {
            revert ErrorsLib.InvalidTokenId();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function _requireShieldNFTOwner(uint256 tokenId) internal view returns (address owner) {
        IShieldReceiptNFT shieldNFT = IShieldReceiptNFT(shieldReceiptNFT);
        owner = shieldNFT.ownerOf(tokenId);

        if (msg.sender != owner) {
            revert ErrorsLib.NotOwner();
        }
    }

    /**
     * @dev Initializer replacing the legacy constructor for UUPS deployments.
     * @param _shieldedTokenInfo Metadata for the shielded asset
     * @param _backingTokenInfo Metadata for the backing asset
     * @param _commissionRate Commission rate in basis points
     * @param _poolFee Pool creator fee rate in basis points
     * @param _poolCreator Address that sourced the pool (operator role)
     * @param _collateralRatio Collateral ratio in basis points
     * @param _governanceTimelock Governance timelock controller
     * @param _priceOracle Oracle used for valuation (set by factory from defaultPriceOracle)
     * @param _protocolFeeRecipient Protocol fee recipient address
     * @param _shieldReceiptNFT Address of the ShieldReceiptNFT contract (deployed by factory)
     * @param _protectorReceiptNFT Address of the ProtectorReceiptNFT contract (deployed by factory)
     * @param initialOwner Owner account for upgrade authority (typically the factory)
     */
    function initialize(
        TokenWhitelistLib.TokenInfo memory _shieldedTokenInfo,
        TokenWhitelistLib.TokenInfo memory _backingTokenInfo,
        uint256 _commissionRate,
        uint256 _poolFee,
        address _poolCreator,
        uint256 _collateralRatio,
        address _governanceTimelock,
        address _priceOracle,
        address _protocolFeeRecipient,
        address _shieldReceiptNFT,
        address _protectorReceiptNFT,
        address initialOwner
    ) external initializer {
        _initializePool(
            _shieldedTokenInfo,
            _backingTokenInfo,
            _commissionRate,
            _poolFee,
            _poolCreator,
            _collateralRatio,
            _governanceTimelock,
            _priceOracle,
            _protocolFeeRecipient,
            _shieldReceiptNFT,
            _protectorReceiptNFT,
            initialOwner,
            address(0)
        );
    }

    function initializeWithAccessControl(
        TokenWhitelistLib.TokenInfo memory _shieldedTokenInfo,
        TokenWhitelistLib.TokenInfo memory _backingTokenInfo,
        uint256 _commissionRate,
        uint256 _poolFee,
        address _poolCreator,
        uint256 _collateralRatio,
        address _governanceTimelock,
        address _priceOracle,
        address _protocolFeeRecipient,
        address _shieldReceiptNFT,
        address _protectorReceiptNFT,
        address initialOwner,
        address initialAccessControl
    ) external initializer {
        _initializePool(
            _shieldedTokenInfo,
            _backingTokenInfo,
            _commissionRate,
            _poolFee,
            _poolCreator,
            _collateralRatio,
            _governanceTimelock,
            _priceOracle,
            _protocolFeeRecipient,
            _shieldReceiptNFT,
            _protectorReceiptNFT,
            initialOwner,
            initialAccessControl
        );
    }

    function _initializePool(
        TokenWhitelistLib.TokenInfo memory _shieldedTokenInfo,
        TokenWhitelistLib.TokenInfo memory _backingTokenInfo,
        uint256 _commissionRate,
        uint256 _poolFee,
        address _poolCreator,
        uint256 _collateralRatio,
        address _governanceTimelock,
        address _priceOracle,
        address _protocolFeeRecipient,
        address _shieldReceiptNFT,
        address _protectorReceiptNFT,
        address initialOwner,
        address initialAccessControl
    ) internal {
        if (_shieldedTokenInfo.token == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_backingTokenInfo.token == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_poolCreator == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_protocolFeeRecipient == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_shieldReceiptNFT == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_protectorReceiptNFT == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (initialOwner == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_protocolFeeRecipient == address(this)) revert ErrorsLib.InvalidProtocolFeeRecipient();
        if (_backingTokenInfo.token == _shieldedTokenInfo.token) revert ErrorsLib.InvalidAssetAddress();
        if (_commissionRate > ConstantsLib.MAX_COMMISSION_RATE) revert ErrorsLib.InvalidCommissionRate();
        if (_poolFee > ConstantsLib.MAX_POOL_FEE) revert ErrorsLib.InvalidPoolFee();
        if (
            _collateralRatio < ConstantsLib.MIN_COLLATERAL_RATIO || _collateralRatio > ConstantsLib.MAX_COLLATERAL_RATIO
        ) {
            revert ErrorsLib.InvalidCollateralRatio();
        }

        __ProtocolAccessControl_init(initialOwner, _governanceTimelock);

        SHIELDED_TOKEN = _shieldedTokenInfo.token;
        COMMISSION_RATE = _commissionRate;
        POOL_FEE = _poolFee;
        POOL_CREATOR = _poolCreator;
        POOL_FACTORY = initialOwner;
        COLLATERAL_RATIO = _collateralRatio;
        BACKING_TOKEN = _backingTokenInfo.token;
        (shieldedTokenDecimals, shieldedTokenScale) = _getTokenMetadata(_shieldedTokenInfo.token);
        (backingTokenDecimals, backingTokenScale) = _getTokenMetadata(_backingTokenInfo.token);

        // M-14: default the fee recipient to the pool creator at init.
        poolFeeRecipient = _poolCreator;

        // H-5: snapshot the factory's strict-protected-backing-price policy at
        // initialize so a future factory regression cannot silently downgrade
        // strict-mode pricing for this pool. Direct test/legacy deployments that
        // do not look like a factory have no factory policy and pin the compatibility default.
        {
            (bool success, bytes memory data) = initialOwner.staticcall(
                abi.encodeCall(ISplitRiskPoolFactory.tokenRequiresStrictProtectedPrice, (_backingTokenInfo.token))
            );
            if (!success || data.length < 32) {
                if (_isPoolFactoryLikeController(initialOwner)) revert ErrorsLib.InvalidAssetAddress();
                _strictProtectedBackingPriceAtInit = false;
                emit StrictPricingProbeFailed(_backingTokenInfo.token, initialOwner);
            } else {
                _strictProtectedBackingPriceAtInit = abi.decode(data, (bool));
            }
            _strictProtectedBackingPricePinned = true;
        }

        poolConfig = PoolConfig({
            shieldedMinDepositAmount: _defaultMinDepositAmount(shieldedTokenScale),
            shieldedMaxDepositAmount: ConstantsLib.DEFAULT_MAX_DEPOSIT_TOKENS * shieldedTokenScale,
            backingMinDepositAmount: _defaultMinDepositAmount(backingTokenScale),
            backingMaxDepositAmount: ConstantsLib.DEFAULT_MAX_DEPOSIT_TOKENS * backingTokenScale,
            maxTotalValueLockedUsd: ConstantsLib.DEFAULT_MAX_TVL_USD,
            minimumPoolTime: ConstantsLib.DEFAULT_MINIMUM_POOL_TIME,
            unlockDuration: ConstantsLib.DEFAULT_UNLOCK_DURATION,
            protocolFeeRecipient: _protocolFeeRecipient,
            protocolFee: ConstantsLib.DEFAULT_PROTOCOL_FEE,
            priceOracle: _priceOracle
        });

        poolState = PoolState({ shieldedTokenBalance: 0, totalBackingTokenBalance: 0 });

        // Use NFT contracts deployed by factory
        // Factory should have already:
        // 1. Deployed the NFTs
        // 2. Set pool address on NFTs
        // 3. Transferred ownership to this contract
        shieldReceiptNFT = _shieldReceiptNFT;
        protectorReceiptNFT = _protectorReceiptNFT;

        if (initialAccessControl != address(0)) {
            _validateAccessControl(initialAccessControl);
            accessControl = initialAccessControl;
            emit EventsLib.AccessControlUpdated(address(0), initialAccessControl);
            emit EventsLib.AccessControlStatusUpdated(initialAccessControl, true, false, false);
        }
    }

    /**
     * @notice Get the current utilization ratio of the pool
     * @dev Returns the USD-based ratio so tokens with different decimals or prices
     *      are compared in the same unit. Equivalent to getUtilizationRatioUsd().
     * @return utilizationRatio Utilization ratio in basis points (0-10000 = 0%-100%)
     */
    function getUtilizationRatio() public view returns (uint256) {
        return getUtilizationRatioUsd();
    }

    /// @dev Returns the protector shares for a token.
    function _getProtectorPositionShares(uint256 tokenId) internal view returns (uint256) {
        return protectorShares[tokenId];
    }

    /// @dev Returns shares only when the position belongs to the current loss-socialization epoch.
    function _getActiveProtectorPositionShares(uint256 tokenId) internal view returns (uint256) {
        uint256 positionShares_ = _getProtectorPositionShares(tokenId);
        if (positionShares_ == 0) {
            return 0;
        }
        if (protectorShareEpochs[tokenId] != protectorShareEpoch) {
            return 0;
        }
        return positionShares_;
    }

    /// @dev Converts a protector share balance into the current backing-token claim.
    function _assetsFromProtectorShares(uint256 shares, uint256 totalAssets, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        if (shares == 0 || totalAssets == 0 || totalShares == 0) {
            return 0;
        }
        return Math.mulDiv(shares, totalAssets, totalShares);
    }

    /// @dev Returns the current backing-token claim for a protector share balance.
    function _getProtectorPositionAmountFromShares(uint256 shares) internal view returns (uint256) {
        return _assetsFromProtectorShares(shares, totalProtectorTokens, totalProtectorShares);
    }

    /// @dev Converts native backing-token units into 18-decimal protector share units.
    ///      Asset balances stay in native units; only shares are normalized so
    ///      high-decimal backing tokens cannot make material shielded rewards
    ///      round down to undistributable reward-per-share dust.
    function _backingAmountToProtectorShares(uint256 amount) internal view returns (uint256 shares) {
        if (amount == 0) return 0;

        if (backingTokenDecimals == ConstantsLib.TOKEN_DECIMALS_UINT8) {
            return amount;
        }

        if (backingTokenDecimals > ConstantsLib.TOKEN_DECIMALS_UINT8) {
            uint256 divisor = 10 ** (backingTokenDecimals - ConstantsLib.TOKEN_DECIMALS_UINT8);
            return amount / divisor;
        }

        uint256 multiplier = 10 ** (ConstantsLib.TOKEN_DECIMALS_UINT8 - backingTokenDecimals);
        return amount * multiplier;
    }

    function _requireProtectorShareRewardCapacity(uint256 shares) internal pure {
        if (shares > ConstantsLib.MAX_PROTECTOR_REWARD_SHARES) {
            revert ErrorsLib.ProtectorShareLimitExceeded(shares, ConstantsLib.MAX_PROTECTOR_REWARD_SHARES);
        }
    }

    /// @notice Returns the current backing-token claim for a protector position.
    function getProtectorPositionAmount(uint256 tokenId) public view returns (uint256) {
        uint256 shares = _getActiveProtectorPositionShares(tokenId);
        return _getProtectorPositionAmountFromShares(shares);
    }

    /**
     * @dev Internal helper to get USD collateral values for original deposit values.
     *      Single source of truth for USD-based collateral calculations.
     *      Uses original deposit values (valueAtDeposit) for collateralization checks.
     * @param shieldedValueAtDepositUsd Total original deposit values in USD (8 decimals, from totalValueAtDeposit)
     * @param protectorTokens Amount of protector tokens
     * @return shieldedValueUsd USD value of shielded positions (same as input, for consistency)
     * @return protectorValueUsd USD value of protector tokens
     * @return requiredCollateralUsd Required collateral in USD (shielded value * collateral ratio)
     */
    function _getUsdCollateralValues(uint256 shieldedValueAtDepositUsd, uint256 protectorTokens)
        internal
        view
        returns (uint256 shieldedValueUsd, uint256 protectorValueUsd, uint256 requiredCollateralUsd)
    {
        // shieldedValueAtDepositUsd is already in USD (8 decimals), no conversion needed
        shieldedValueUsd = shieldedValueAtDepositUsd;
        protectorValueUsd = _getProtectedBackingValue(protectorTokens);
        requiredCollateralUsd = _getRequiredCollateralUsd(shieldedValueUsd);
    }

    function _getRequiredCollateralUsd(uint256 shieldedValueUsd) internal view returns (uint256) {
        return Math.mulDiv(shieldedValueUsd, COLLATERAL_RATIO, ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);
    }

    function _getBackingAmountFromUsdFloor(uint256 valueUsd, uint256 backingPrice)
        internal
        view
        returns (uint256 amount)
    {
        if (valueUsd == 0) return 0;
        amount = Math.mulDiv(valueUsd, backingTokenScale, backingPrice);
        if (amount == 0) revert ErrorsLib.InvalidOraclePrice();
    }

    function _getShieldCollateralAmount(uint256 shieldedValueUsd) internal view returns (uint256) {
        uint256 requiredCollateralUsd = _getRequiredCollateralUsd(shieldedValueUsd);
        return _getBackingAmountFromUsdFloor(requiredCollateralUsd, _getProtectedBackingPrice());
    }

    /// @dev Returns backing-token price using the oracle's strongest available protection.
    function _getProtectedBackingPrice() internal view returns (uint256 price) {
        if (_requiresStrictProtectedBackingPrice()) {
            (bool strictSuccess, uint256 strictPrice) = _tryGetStrictProtectedBackingPrice();
            if (strictSuccess) {
                return strictPrice;
            }
            revert ErrorsLib.InvalidAssetAddress();
        }

        price = IPriceOracle(poolConfig.priceOracle).getPrice(BACKING_TOKEN);
        if (price == 0) revert ErrorsLib.InvalidOraclePrice();
    }

    /// @dev Returns the current shielded-token price using the strongest available protection.
    function _getShieldedPrice() internal view returns (uint256 price) {
        price = IPriceOracle(poolConfig.priceOracle).getPrice(SHIELDED_TOKEN);
        if (price == 0) revert ErrorsLib.InvalidOraclePrice();
    }

    /// @dev Returns true if `token` has a pending dual-feed challenge on the configured
    ///      `CompositeOracle`. Reads via try/catch so non-CompositeOracle price oracles
    ///      (which lack dual-feed semantics) are treated as challenge-free.
    function _hasOraclePendingChallenge(address token) internal view returns (bool) {
        try ICompositeOracle(poolConfig.priceOracle).getTokenDualFeedStatus(token) returns (
            bool, address, address, bool, bool isChallengePending, uint256
        ) {
            return isChallengePending;
        } catch { }

        return false;
    }

    /// @dev Returns true if the configured CompositeOracle can already detect that
    ///      protected pricing is unsafe, even before a public challenge is started.
    function _hasOracleChallengeablePrice(address token) internal view returns (bool) {
        try ICompositeOracle(poolConfig.priceOracle).isTokenChallengeable(token) returns (bool challengeable) {
            return challengeable;
        } catch { }

        return false;
    }

    /// @dev Reverts if `token` has a pending or currently challengeable dual-feed
    ///      dispute. Any operation that locks, releases, or sizes value from that
    ///      token's price must fail closed until the feeds converge or fail over.
    function _requireNoOraclePendingChallenge(address token) internal view {
        if (_hasOraclePendingChallenge(token) || _hasOracleChallengeablePrice(token)) {
            revert ErrorsLib.OraclePendingChallenge(token);
        }
    }

    /// @dev Returns true while any shield receipt liability remains in pool accounting.
    function _hasShieldedLiabilities() internal view returns (bool) {
        return totalShieldedTokens != 0 || totalValueAtDeposit != 0 || totalShieldCollateralAmount != 0;
    }

    /// @dev Returns the current shielded-token spot price for non-critical TVL estimation paths.
    ///      Intentionally uses the unprotected getter — view paths must opt into the raw
    ///      active-feed value because the safe `getPrice` would otherwise revert during a
    ///      dual-feed challenge window or fully halt view callers when the protected path
    ///      is temporarily unavailable.
    ///
    ///      B7: explicitly fail closed if the shielded leg has a pending or currently
    ///      challengeable dual-feed dispute. This removes the implicit invariant that
    ///      every caller already calls `_requireNoOraclePendingChallenge(SHIELDED_TOKEN)`
    ///      beforehand. Current callers (`_validateDeposit` via
    ///      `_getTotalPoolValueUsd(allowShieldedSpotFallback=true)`) already make that
    ///      check, so this guard is idempotent for them and prevents future call sites
    ///      from relying on a footgun precondition.
    function _getShieldedSpotPrice() internal view returns (uint256 price) {
        _requireNoOraclePendingChallenge(SHIELDED_TOKEN);
        price = IPriceOracle(poolConfig.priceOracle).getPriceUnsafe(SHIELDED_TOKEN);
        if (price == 0) revert ErrorsLib.InvalidOraclePrice();
    }

    /// @dev Best-effort wrapper for protected shielded-token pricing.
    function _tryGetShieldedProtectedPrice() internal view returns (bool success, uint256 price) {
        try IPriceOracle(poolConfig.priceOracle).getPrice(SHIELDED_TOKEN) returns (uint256 protectedPrice) {
            if (protectedPrice == 0) return (false, 0);
            return (true, protectedPrice);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Fee-accrual pricing can use live in-band ERC4626 NAV while keeping
    ///      protected underlying oracle checks. Oracles without the dedicated
    ///      selector fall back to the standard protected price.
    function _tryGetShieldedFeeAccrualPrice() internal view returns (bool success, uint256 price) {
        (bool callSuccess, bytes memory data) =
            poolConfig.priceOracle.staticcall(abi.encodeWithSignature("getPriceForFeeAccrual(address)", SHIELDED_TOKEN));

        if (callSuccess) {
            if (data.length < 32) return (false, 0);
            uint256 feePrice = abi.decode(data, (uint256));
            if (feePrice == 0) return (false, 0);
            return (true, feePrice);
        }

        if (data.length == 0) {
            return _tryGetShieldedProtectedPrice();
        }

        return (false, 0);
    }

    function _getShieldedFeeBaselineValue(uint256 amount) internal view returns (uint256 baselineValueUsd) {
        (bool priceAvailable, uint256 feePrice) = _tryGetShieldedFeeAccrualPrice();
        if (!priceAvailable) {
            revert ErrorsLib.ShieldedFeePriceUnavailable(SHIELDED_TOKEN);
        }
        return Math.mulDiv(amount, feePrice, shieldedTokenScale);
    }

    /// @dev Returns shielded-token USD value using native shielded token units.
    function _getShieldedValue(uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, _getShieldedPrice(), shieldedTokenScale);
    }

    /// @dev Returns shielded-token USD value using the spot path for non-critical TVL estimation.
    function _getShieldedSpotValue(uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, _getShieldedSpotPrice(), shieldedTokenScale);
    }

    /// @dev Best-effort wrapper for protected shielded-token valuation.
    function _tryGetShieldedValue(uint256 amount) internal view returns (bool success, uint256 value) {
        uint256 price;
        (success, price) = _tryGetShieldedProtectedPrice();
        if (!success) return (false, 0);
        return (true, Math.mulDiv(amount, price, shieldedTokenScale));
    }

    /// @dev Returns the default minimum deposit for a token scale, targeting roughly 0.01 token.
    function _defaultMinDepositAmount(uint256 tokenScale) internal pure returns (uint256) {
        uint256 hundredthToken = tokenScale / 100;
        return hundredthToken > 0 ? hundredthToken : 1;
    }

    /// @dev Best-effort wrapper for protected backing-token pricing.
    function _tryGetProtectedBackingPrice() internal view returns (bool success, uint256 price) {
        if (_requiresStrictProtectedBackingPrice()) {
            (success, price,) = _tryGetStrictProtectedBackingPriceSoft();
            return (success, price);
        }

        try IPriceOracle(poolConfig.priceOracle).getPrice(BACKING_TOKEN) returns (uint256 protectedPrice) {
            if (protectedPrice == 0) return (false, 0);
            return (true, protectedPrice);
        } catch {
            return (false, 0);
        }
    }

    /// @inheritdoc ISplitRiskPool
    /// @dev Pools use the last explicitly pinned factory snapshot. Factory policy
    ///      changes affect new pools immediately, but existing pools must be
    ///      refreshed by governance after their current oracle is validated.
    function requiresStrictProtectedBackingPrice() public view override returns (bool) {
        return _strictProtectedBackingPriceAtInit;
    }

    /// @notice Re-snapshot the strict-protected-backing-price flag from the factory.
    /// @dev Governance-only. Use when factory policy has intentionally changed and
    ///      the pool should adopt the new value. Without this call, the pinned
    ///      snapshot from initialize is used.
    function refreshStrictProtectedBackingPriceFlag() external onlyGovernance {
        address factory = _poolFactoryController();
        if (factory == address(0) || factory.code.length == 0) {
            revert ErrorsLib.InvalidAssetAddress();
        }

        (bool success, bytes memory data) = factory.staticcall(
            abi.encodeCall(ISplitRiskPoolFactory.tokenRequiresStrictProtectedPrice, (BACKING_TOKEN))
        );
        if (!success || data.length < 32) {
            revert ErrorsLib.InvalidAssetAddress();
        }
        bool newValue = abi.decode(data, (bool));
        if (newValue) {
            PoolOracleValidationLib.validateBackingTokenOracle(poolConfig.priceOracle, BACKING_TOKEN, true);
        }
        _strictProtectedBackingPriceAtInit = newValue;
        _strictProtectedBackingPricePinned = true;
        emit EventsLib.ParameterUpdated("strictProtectedBackingPrice", newValue ? 1 : 0);
    }

    /// @dev Resolves whether backing-token pricing must use the strict protected-price path.
    ///      Pools pin this policy to the deploying factory so later ownership changes
    ///      cannot silently downgrade strict pricing.
    function _requiresStrictProtectedBackingPrice() internal view returns (bool) {
        return requiresStrictProtectedBackingPrice();
    }

    function _isPoolFactoryLikeController(address controller) internal view returns (bool) {
        if (controller.code.length == 0) {
            return false;
        }
        (bool success, bytes memory data) =
            controller.staticcall(abi.encodeCall(ISplitRiskPoolFactory.splitRiskPoolImplementation, ()));
        return success && data.length >= 32;
    }

    /// @dev Uses the strict composite-oracle path when available and bubbles real strict-mode errors.
    function _tryGetStrictProtectedBackingPrice() internal view returns (bool success, uint256 price) {
        (bool callSuccess, bytes memory data) = poolConfig.priceOracle
            .staticcall(abi.encodeCall(ICompositeOracle.getPriceWithStrictCircuitBreaker, (BACKING_TOKEN)));

        if (!callSuccess) {
            if (data.length == 0) {
                return (false, 0);
            }

            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }

        price = abi.decode(data, (uint256));
        if (price == 0) revert ErrorsLib.InvalidOraclePrice();
        return (true, price);
    }

    /// @dev Soft strict-price probe used by best-effort valuation paths.
    function _tryGetStrictProtectedBackingPriceSoft()
        internal
        view
        returns (bool success, uint256 price, bool methodMissing)
    {
        (bool callSuccess, bytes memory data) = poolConfig.priceOracle
            .staticcall(abi.encodeCall(ICompositeOracle.getPriceWithStrictCircuitBreaker, (BACKING_TOKEN)));

        if (!callSuccess) {
            return (false, 0, data.length == 0);
        }

        if (data.length < 32) {
            return (false, 0, false);
        }

        price = abi.decode(data, (uint256));
        if (price == 0) return (false, 0, false);
        return (true, price, false);
    }

    /// @dev Returns backing-token USD value using the protected price path.
    function _getProtectedBackingValue(uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, _getProtectedBackingPrice(), backingTokenScale);
    }

    /// @dev Best-effort wrapper for protected backing-token valuation.
    function _tryGetProtectedBackingValue(uint256 amount) internal view returns (bool success, uint256 value) {
        uint256 price;
        (success, price) = _tryGetProtectedBackingPrice();
        if (!success) return (false, 0);
        return (true, Math.mulDiv(amount, price, backingTokenScale));
    }

    /**
     * @notice Get the current utilization ratio based on USD values
     * @dev Calculates utilization using USD-BASED accounting via price oracle.
     *      Uses original deposit values (valueAtDeposit) for collateralization checks.
     *      This accounts for price differences between shielded and protector tokens.
     *      Returns the ratio of required collateral (in USD) to protector value (in USD).
     * @return utilizationRatioUsd Utilization ratio in basis points (0-10000 = 0%-100%)
     */
    function getUtilizationRatioUsd() public view returns (uint256) {
        // slither-disable-next-line incorrect-equality — empty-state guard, no protectors means 0% utilization
        if (totalProtectorTokens == 0) return 0;
        // slither-disable-next-line incorrect-equality — empty-state guard, no deposits means 0% utilization
        if (totalValueAtDeposit == 0) return 0;

        (, uint256 protectorValueUsd, uint256 requiredCollateralUsd) =
            _getUsdCollateralValues(totalValueAtDeposit, totalProtectorTokens);

        // slither-disable-next-line incorrect-equality — division-by-zero guard for utilization ratio
        if (protectorValueUsd == 0) return type(uint256).max; // Max utilization if no protector value

        // Utilization = required collateral / protector value
        return (requiredCollateralUsd * ConstantsLib.BASIS_POINT_SCALE) / protectorValueUsd;
    }

    /**
     * @dev Internal helper to get USD-based utilization ratio without external call.
     *      Uses original deposit values (valueAtDeposit) for collateralization checks.
     *      Returns success flag and ratio to allow fallback on oracle failure.
     * @return success True if USD calculation succeeded
     * @return ratio Utilization ratio in basis points (0-10000+)
     */
    function _tryGetUtilizationRatioUsd() internal view returns (bool success, uint256 ratio) {
        // slither-disable-next-line incorrect-equality — empty-state guards, no protectors/deposits = 0% utilization
        if (totalProtectorTokens == 0 || totalValueAtDeposit == 0) {
            return (true, 0);
        }

        // totalValueAtDeposit is already in USD (8 decimals), no oracle conversion needed
        (bool valuationSuccess, uint256 uwUsd) = _tryGetProtectedBackingValue(totalProtectorTokens);
        if (!valuationSuccess) return (false, 0);

        // slither-disable-next-line incorrect-equality — division-by-zero guard for utilization ratio
        if (uwUsd == 0) return (true, type(uint256).max);
        // M-4 FIX: Multiply before divide to avoid precision loss
        // (totalValueAtDeposit * COLLATERAL_RATIO) gives utilization in basis points directly
        return (true, (totalValueAtDeposit * COLLATERAL_RATIO) / uwUsd);
    }

    /**
     * @notice Get the amount of tokens locked for a protector position
     * @dev Derived from getAvailableForWithdrawal for consistency with max withdrawable calculation.
     *      Locked = position amount - available for withdrawal.
     * @param tokenId The protector NFT token ID
     * @return lockedAmount Amount locked and unavailable for withdrawal
     */
    function getLockedAmount(uint256 tokenId) public view returns (uint256) {
        uint256 positionAmount = getProtectorPositionAmount(tokenId);
        uint256 available = getAvailableForWithdrawal(tokenId);
        return available >= positionAmount ? 0 : positionAmount - available;
    }

    /**
     * @notice Get the maximum amount withdrawable for a protector position in a single transaction
     * @dev Calculates the max withdrawable accounting for how utilization changes during withdrawal.
     *      Uses formula: min(positionAmount, totalProtectorTokens - totalShieldCollateralAmount).
     *      Shield receipts store backing-token collateral caps at deposit time; protector exits must keep
     *      those token-denominated caps funded while any shield liabilities remain.
     *      This allows users to withdraw all unlocked funds in one transaction instead of iterating.
     * @param tokenId The protector NFT token ID
     * @return availableAmount Maximum amount available for withdrawal
     */
    function getAvailableForWithdrawal(uint256 tokenId) public view returns (uint256) {
        uint256 positionShares_ = _getActiveProtectorPositionShares(tokenId);

        // slither-disable-next-line incorrect-equality — empty-position guard, 0 shares = nothing to withdraw
        if (positionShares_ == 0) return 0;

        uint256 positionAmount = _getProtectorPositionAmountFromShares(positionShares_);
        if (positionAmount == 0) {
            return 0;
        }

        // slither-disable-next-line incorrect-equality — empty-state guard, no deposits means nothing locked
        if (!_hasShieldedLiabilities()) return positionAmount; // No shielded deposits = nothing locked

        if (_hasOraclePendingChallenge(BACKING_TOKEN)) {
            return 0;
        }

        // Preserve the existing fail-closed oracle liveness check while reserving
        // the token-denominated shield caps instead of a current-price estimate.
        (bool priceSuccess,) = _tryGetProtectedBackingPrice();
        if (!priceSuccess) {
            // Fail closed when protected backing pricing is unavailable.
            return 0;
        }

        uint256 requiredProtectorTokens = totalShieldCollateralAmount;

        // Pool-level max withdrawable
        if (requiredProtectorTokens >= totalProtectorTokens) {
            return 0; // Pool is at or above 100% utilization (collateral-based check)
        }
        uint256 poolMaxWithdrawable = totalProtectorTokens - requiredProtectorTokens;

        // Position-level max (can't withdraw more than position)
        return positionAmount < poolMaxWithdrawable ? positionAmount : poolMaxWithdrawable;
    }

    // ============ Fee Reserve Protection ============

    /**
     * @notice Get total fees reserved for payment (cannot be withdrawn by users)
     * @return reservedAmount Total amount reserved for pool fee, protocol fee, and commissions
     */
    function getReservedFees() public view returns (uint256) {
        return accumulatedPoolFee + accumulatedProtocolFee + accumulatedCommissions;
    }

    /**
     * @notice Get balance available for user withdrawals (excludes reserved fees)
     * @return availableBalance Balance minus reserved fees
     */
    function getWithdrawableBalance() public view returns (uint256) {
        uint256 reserved = getReservedFees();
        return poolState.shieldedTokenBalance > reserved ? poolState.shieldedTokenBalance - reserved : 0;
    }

    function _requireAccountingBalanceCovered(address token, uint256 accountedBalance) internal view {
        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        if (actualBalance < accountedBalance) {
            revert ErrorsLib.AccountedBalanceExceedsTokenBalance(token, accountedBalance, actualBalance);
        }
    }

    function _requirePoolAccountingBalancesCovered() internal view {
        _requireAccountingBalanceCovered(SHIELDED_TOKEN, poolState.shieldedTokenBalance);
        _requireAccountingBalanceCovered(BACKING_TOKEN, poolState.totalBackingTokenBalance);
    }

    /**
     * @dev Gets total value locked in the pool (for TVL limit check)
     * @return totalValueUsd The combined USD value of all deposited assets
     */
    function _getTotalPoolValueUsd(bool allowShieldedSpotFallback) internal view returns (uint256 totalValueUsd) {
        uint256 shieldedValueUsd;
        if (allowShieldedSpotFallback) {
            (bool success, uint256 protectedShieldedValue) = _tryGetShieldedValue(poolState.shieldedTokenBalance);
            shieldedValueUsd = success ? protectedShieldedValue : _getShieldedSpotValue(poolState.shieldedTokenBalance);
        } else {
            shieldedValueUsd = _getShieldedValue(poolState.shieldedTokenBalance);
        }

        return shieldedValueUsd + _getProtectedBackingValue(poolState.totalBackingTokenBalance);
    }

    /**
     * @dev Check pool capacity using USD-BASED accounting via price oracle.
     *      Ensures the pool maintains proper collateralization in USD terms based on original deposit values.
     *      Uses totalValueAtDeposit (original deposit values) plus new deposit's valueAtDeposit for checks.
     *      Reverts with InvalidOraclePrice if all oracle paths fail (no 1:1 fallback).
     * @param newDepositValueAtDeposit USD value of the new shielded deposit
     * @param newCollateralAmount Native backing-token collateral cap for the new deposit
     * @custom:error InsufficientProtectorTokenBalance If collateral requirement exceeds protector value
     * @custom:error InvalidOraclePrice If all oracle paths fail
     */
    function _checkCapacity(uint256 newDepositValueAtDeposit, uint256 newCollateralAmount) internal view {
        uint256 newTotalValueAtDeposit = totalValueAtDeposit + newDepositValueAtDeposit;

        // Reject dust amounts where USD value truncates to 0
        if (newDepositValueAtDeposit == 0) {
            revert ErrorsLib.InvalidOraclePrice();
        }

        uint256 totalProtectorUsd = _getProtectedBackingValue(totalProtectorTokens);

        // Calculate required collateral based on original deposit values
        uint256 requiredCollateralUsd = _getRequiredCollateralUsd(newTotalValueAtDeposit);
        if (requiredCollateralUsd > totalProtectorUsd) {
            revert ErrorsLib.InsufficientProtectorTokenBalance();
        }

        if (totalShieldCollateralAmount + newCollateralAmount > totalProtectorTokens) {
            revert ErrorsLib.InsufficientProtectorTokenBalance();
        }
    }

    /**
     * @dev Validates deposit amount bounds and TVL limit.
     *      Single source of truth for deposit validation.
     * @param asset Asset being deposited
     * @param depositAmount Amount being deposited
     * @custom:error InsufficientDepositAmount If amount is below minimum
     * @custom:error DepositAmountTooLarge If amount exceeds maximum
     * @custom:error TVLLimitExceeded If deposit would exceed TVL limit
     */
    function _validateDeposit(address asset, uint256 depositAmount) internal view {
        uint256 minDepositAmount = 0;
        uint256 maxDepositAmount = 0;
        uint256 depositValueUsd = 0;
        bool allowShieldedSpotFallback = false;

        if (asset == SHIELDED_TOKEN) {
            minDepositAmount = poolConfig.shieldedMinDepositAmount;
            maxDepositAmount = poolConfig.shieldedMaxDepositAmount;
            depositValueUsd = _getShieldedValue(depositAmount);
        } else if (asset == BACKING_TOKEN) {
            minDepositAmount = poolConfig.backingMinDepositAmount;
            maxDepositAmount = poolConfig.backingMaxDepositAmount;
            depositValueUsd = _getProtectedBackingValue(depositAmount);
        } else {
            revert ErrorsLib.UnsupportedAsset();
        }

        if (depositAmount < minDepositAmount) revert ErrorsLib.InsufficientDepositAmount();
        if (depositAmount > maxDepositAmount) revert ErrorsLib.DepositAmountTooLarge();
        if (depositAmount > ConstantsLib.MAX_SAFE_ACCUMULATION) revert ErrorsLib.DepositAmountTooLarge();
        if (depositValueUsd == 0 && depositAmount > 0) revert ErrorsLib.InvalidOraclePrice();
        if (_getTotalPoolValueUsd(allowShieldedSpotFallback) + depositValueUsd > poolConfig.maxTotalValueLockedUsd) {
            revert ErrorsLib.TVLLimitExceeded();
        }
    }

    /**
     * @dev Transfers tokens from sender to contract and returns actual amount received
     * @param asset The token to transfer
     * @param depositAmount The amount to attempt to transfer
     * @return received The actual amount received (accounts for fee-on-transfer tokens)
     */
    function _transferAndGetReceived(address asset, uint256 depositAmount) internal returns (uint256 received) {
        uint256 beforeBal = IERC20(asset).balanceOf(address(this));
        SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), depositAmount);
        if (paused()) revert EnforcedPause();
        uint256 afterBal = IERC20(asset).balanceOf(address(this));
        received = afterBal - beforeBal;
        if (received == 0) revert ErrorsLib.TransferOperationFailed();
    }

    /**
     * @dev Transfers tokens to a recipient and returns the recipient's actual balance delta.
     *      This makes withdrawal-side slippage checks truthful for fee-on-transfer tokens.
     * @param asset The token to transfer
     * @param recipient The address receiving the tokens
     * @param transferAmount The nominal amount sent from the pool
     * @return received The actual amount credited to the recipient
     */
    function _transferOutAndGetReceived(address asset, address recipient, uint256 transferAmount)
        internal
        returns (uint256 received)
    {
        uint256 poolBalanceBefore = IERC20(asset).balanceOf(address(this));
        uint256 beforeBal = recipient == address(this) ? poolBalanceBefore : IERC20(asset).balanceOf(recipient);
        SafeERC20.safeTransfer(IERC20(asset), recipient, transferAmount);
        uint256 poolBalanceAfter = IERC20(asset).balanceOf(address(this));
        if (poolBalanceAfter > poolBalanceBefore) {
            revert ErrorsLib.UnexpectedOutboundTransferAmount(asset, transferAmount, 0);
        }
        uint256 debited = poolBalanceBefore - poolBalanceAfter;
        if (debited != transferAmount) {
            revert ErrorsLib.UnexpectedOutboundTransferAmount(asset, transferAmount, debited);
        }
        uint256 afterBal = recipient == address(this) ? poolBalanceAfter : IERC20(asset).balanceOf(recipient);
        received = afterBal - beforeBal;
    }

    function _markShieldedTransferIntegrityIfReduced(uint256 nominalAmount, uint256 receivedAmount) internal {
        if (receivedAmount < nominalAmount && !shieldedTokenTransferIntegrityBroken) {
            shieldedTokenTransferIntegrityBroken = true;
            emit ShieldedTokenTransferIntegrityBroken(SHIELDED_TOKEN, nominalAmount, receivedAmount);
        }
    }

    function _requireUntaxedShieldedRoundTrip(uint256 nominalAmount) internal {
        if (nominalAmount == 0) {
            return;
        }

        TransferIntegrityProbe probe = new TransferIntegrityProbe(address(this));
        uint256 beforeBal = IERC20(SHIELDED_TOKEN).balanceOf(address(this));
        uint256 probeBalanceBefore = IERC20(SHIELDED_TOKEN).balanceOf(address(probe));
        SafeERC20.safeTransfer(IERC20(SHIELDED_TOKEN), address(probe), nominalAmount);
        uint256 probeBalanceAfter = IERC20(SHIELDED_TOKEN).balanceOf(address(probe));
        uint256 probeReceived = probeBalanceAfter - probeBalanceBefore;
        if (probeReceived != nominalAmount) {
            revert ErrorsLib.IncompatibleShieldedTokenForCrossAssetWithdrawal(SHIELDED_TOKEN);
        }
        probe.returnToken(SHIELDED_TOKEN, probeReceived);
        uint256 afterBal = IERC20(SHIELDED_TOKEN).balanceOf(address(this));
        uint256 probeBalanceFinal = IERC20(SHIELDED_TOKEN).balanceOf(address(probe));
        if (afterBal != beforeBal || probeBalanceFinal != probeBalanceBefore) {
            revert ErrorsLib.IncompatibleShieldedTokenForCrossAssetWithdrawal(SHIELDED_TOKEN);
        }
    }

    function _scaleFeesToAvailableAmount(
        uint256 commissionAmount,
        uint256 poolFeeAmount,
        uint256 protocolFeeAmount,
        uint256 maxTotalFees
    ) internal pure returns (uint256 scaledCommission, uint256 scaledPoolFee, uint256 scaledProtocolFee) {
        uint256 totalFees = commissionAmount + poolFeeAmount + protocolFeeAmount;
        if (totalFees <= maxTotalFees) {
            return (commissionAmount, poolFeeAmount, protocolFeeAmount);
        }

        scaledCommission = Math.mulDiv(commissionAmount, maxTotalFees, totalFees);
        scaledPoolFee = Math.mulDiv(poolFeeAmount, maxTotalFees, totalFees);
        scaledProtocolFee = Math.mulDiv(protocolFeeAmount, maxTotalFees, totalFees);

        uint256 scaledTotal = scaledCommission + scaledPoolFee + scaledProtocolFee;
        uint256 remainder = maxTotalFees - scaledTotal;
        if (remainder != 0) {
            uint256 room = commissionAmount - scaledCommission;
            uint256 add = remainder < room ? remainder : room;
            scaledCommission += add;
            remainder -= add;
        }
        if (remainder != 0) {
            uint256 room = poolFeeAmount - scaledPoolFee;
            uint256 add = remainder < room ? remainder : room;
            scaledPoolFee += add;
            remainder -= add;
        }
        if (remainder != 0) {
            uint256 room = protocolFeeAmount - scaledProtocolFee;
            uint256 add = remainder < room ? remainder : room;
            scaledProtocolFee += add;
        }
    }

    function _tryDistributePendingProtectorRewardDust() internal {
        uint256 pendingDust = pendingProtectorRewardDust;
        if (pendingDust == 0 || totalProtectorShares == 0 || totalProtectorTokens == 0) {
            return;
        }

        uint256 rewardPerShareIncrement = Math.mulDiv(pendingDust, ConstantsLib.REWARD_PRECISION, totalProtectorShares);
        if (rewardPerShareIncrement == 0) {
            return;
        }

        uint256 representedReward =
            Math.mulDiv(rewardPerShareIncrement, totalProtectorShares, ConstantsLib.REWARD_PRECISION);
        if (representedReward == 0) {
            return;
        }
        rewardPerShareAccumulated += rewardPerShareIncrement;
        pendingProtectorRewardDust = pendingDust > representedReward ? pendingDust - representedReward : 0;
    }

    function _redirectPendingProtectorRewardDust(uint256 maxSafeAccumulation)
        internal
        returns (uint256 redirectedAmount)
    {
        uint256 pendingDust = pendingProtectorRewardDust;
        if (pendingDust == 0) {
            return 0;
        }

        pendingProtectorRewardDust = 0;

        redirectedAmount = pendingDust;
        if (redirectedAmount > accumulatedCommissions) {
            redirectedAmount = accumulatedCommissions;
        }
        if (redirectedAmount > currentEpochCommissionReserve) {
            redirectedAmount = currentEpochCommissionReserve;
        }
        if (redirectedAmount == 0) {
            return 0;
        }

        if (accumulatedProtocolFee + redirectedAmount > maxSafeAccumulation) {
            revert ErrorsLib.RewardAccumulationIncomplete(redirectedAmount, accumulatedProtocolFee, 0);
        }

        accumulatedCommissions -= redirectedAmount;
        currentEpochCommissionReserve -= redirectedAmount;
        accumulatedProtocolFee += redirectedAmount;
    }

    function _accumulateProtectorReward(uint256 rewardAmount, uint256 maxSafeAccumulation)
        internal
        returns (uint256 accumulatedReward, uint256 redirectedProtocolAmount)
    {
        if (rewardAmount == 0) {
            return (0, 0);
        }

        uint256 currentTotalShares = totalProtectorShares;
        if (currentTotalShares == 0 || totalProtectorTokens == 0) {
            uint256 availableProtocolCapacity =
                accumulatedProtocolFee < maxSafeAccumulation ? maxSafeAccumulation - accumulatedProtocolFee : 0;
            if (rewardAmount > availableProtocolCapacity) {
                revert ErrorsLib.RewardAccumulationIncomplete(rewardAmount, accumulatedProtocolFee, 0);
            }
            redirectedProtocolAmount = rewardAmount;
            accumulatedProtocolFee += redirectedProtocolAmount;
            return (0, redirectedProtocolAmount);
        }

        // B4: revert on commission-bucket overflow rather than silently emit
        // FeeDropped and return zero. Returning zero let the caller subtract 0
        // from totalFees while the position's feeValueBaselineUsd advanced past
        // the un-extracted yield, permanently forgiving that commission.
        // Matches the pool/protocol fee buckets in
        // `_calculateAndAccumulateFeesAtPrice` which also revert with
        // RewardAccumulationIncomplete on overflow.
        if (accumulatedCommissions + rewardAmount > maxSafeAccumulation) {
            revert ErrorsLib.RewardAccumulationIncomplete(rewardAmount, accumulatedCommissions, 0);
        }

        uint256 distributableReward = pendingProtectorRewardDust + rewardAmount;
        uint256 rewardPerShareIncrement =
            Math.mulDiv(distributableReward, ConstantsLib.REWARD_PRECISION, currentTotalShares);
        if (rewardPerShareIncrement == 0) {
            pendingProtectorRewardDust = distributableReward;
            accumulatedCommissions += rewardAmount;
            currentEpochCommissionReserve += rewardAmount;
            totalCommissionsEverAccumulated += rewardAmount;
            return (rewardAmount, 0);
        }

        uint256 representedReward =
            Math.mulDiv(rewardPerShareIncrement, currentTotalShares, ConstantsLib.REWARD_PRECISION);
        if (representedReward == 0) {
            pendingProtectorRewardDust = distributableReward;
            accumulatedCommissions += rewardAmount;
            currentEpochCommissionReserve += rewardAmount;
            totalCommissionsEverAccumulated += rewardAmount;
            return (rewardAmount, 0);
        }
        rewardPerShareAccumulated += rewardPerShareIncrement;
        pendingProtectorRewardDust =
            distributableReward > representedReward ? distributableReward - representedReward : 0;
        accumulatedCommissions += rewardAmount;
        currentEpochCommissionReserve += rewardAmount;
        totalCommissionsEverAccumulated += rewardAmount;
        return (rewardAmount, 0);
    }

    function _redirectCurrentEpochOrphanedCommissions() internal {
        if (totalProtectorShares != 0 || currentEpochCommissionReserve == 0) {
            return;
        }

        pendingProtectorRewardDust = 0;
        uint256 orphanedCommissions = currentEpochCommissionReserve;
        currentEpochCommissionReserve = 0;
        if (orphanedCommissions > accumulatedCommissions) {
            orphanedCommissions = accumulatedCommissions;
        }
        if (orphanedCommissions == 0) {
            return;
        }
        accumulatedCommissions -= orphanedCommissions;

        uint256 redirectAmount = orphanedCommissions;
        if (accumulatedProtocolFee + redirectAmount > ConstantsLib.MAX_SAFE_ACCUMULATION) {
            redirectAmount = accumulatedProtocolFee < ConstantsLib.MAX_SAFE_ACCUMULATION
                ? ConstantsLib.MAX_SAFE_ACCUMULATION - accumulatedProtocolFee
                : 0;
        }

        if (redirectAmount != 0) {
            accumulatedProtocolFee += redirectAmount;
        }

        if (redirectAmount != orphanedCommissions) {
            emit EventsLib.FeeDropped(
                "orphanedCommission", orphanedCommissions - redirectAmount, accumulatedProtocolFee
            );
        }
    }

    function _redirectHistoricalEpochDust(uint256 epoch) internal {
        uint256 orphanedCommissions = protectorEpochRemainingReserve[epoch];
        if (orphanedCommissions == 0) {
            return;
        }

        protectorEpochRemainingReserve[epoch] = 0;
        if (orphanedCommissions > historicalCommissionReserve) {
            orphanedCommissions = historicalCommissionReserve;
        }
        if (orphanedCommissions > accumulatedCommissions) {
            orphanedCommissions = accumulatedCommissions;
        }
        if (orphanedCommissions == 0) {
            return;
        }

        historicalCommissionReserve -= orphanedCommissions;
        accumulatedCommissions -= orphanedCommissions;

        uint256 redirectAmount = orphanedCommissions;
        if (accumulatedProtocolFee + redirectAmount > ConstantsLib.MAX_SAFE_ACCUMULATION) {
            redirectAmount = accumulatedProtocolFee < ConstantsLib.MAX_SAFE_ACCUMULATION
                ? ConstantsLib.MAX_SAFE_ACCUMULATION - accumulatedProtocolFee
                : 0;
        }

        if (redirectAmount != 0) {
            accumulatedProtocolFee += redirectAmount;
        }

        if (redirectAmount != orphanedCommissions) {
            emit EventsLib.FeeDropped(
                "historicalOrphanedCommission", orphanedCommissions - redirectAmount, accumulatedProtocolFee
            );
        }
    }

    function _settleExpiredEpochPosition(uint256 tokenId, uint256 positionEpoch, uint256 positionShares_) internal {
        if (positionEpoch >= protectorShareEpoch || protectorEpochPositionSettled[tokenId]) {
            return;
        }

        protectorEpochPositionSettled[tokenId] = true;
        uint256 remainingShares = protectorEpochRemainingShares[positionEpoch];
        if (remainingShares == 0) {
            return;
        }

        if (positionShares_ >= remainingShares) {
            protectorEpochRemainingShares[positionEpoch] = 0;
            _redirectHistoricalEpochDust(positionEpoch);
        } else {
            protectorEpochRemainingShares[positionEpoch] = remainingShares - positionShares_;
        }
    }

    /**
     * @dev Calculate and accumulate fees for a shielded position (USD-BASED for yield calculation)
     * @param tokenId The shield NFT token ID
     * @return commissionAmount The commission amount in native shielded token units
     * @return poolFeeAmount The pool fee amount in native shielded token units
     * @return protocolFeeAmount The protocol fee amount in native shielded token units
     */
    function _calculateAndAccumulateFees(uint256 tokenId)
        internal
        returns (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount)
    {
        if (shieldedTokenTransferIntegrityBroken) {
            _advanceFeeBaselineWithoutAccruingFees(tokenId);
            return (0, 0, 0);
        }

        _requireNoOraclePendingChallenge(SHIELDED_TOKEN);

        // Probe the shielded fee price up-front. Same-asset exits burn the receipt
        // and delete the fee baseline, so they cannot proceed while fees cannot be priced.
        (bool priceAvailable, uint256 currentPrice) = _tryGetShieldedFeeAccrualPrice();
        if (!priceAvailable) {
            revert ErrorsLib.ShieldedFeePriceUnavailable(SHIELDED_TOKEN);
        }

        return _calculateAndAccumulateFeesAtPrice(tokenId, currentPrice);
    }

    /// @dev Best-effort fee accrual for exit flows that can safely continue without
    ///      newly priced fees. If protected shielded pricing is unavailable or
    ///      disputed, returns zero new fees and leaves the position amount intact.
    function _tryCalculateAndAccumulateFees(uint256 tokenId)
        internal
        returns (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount)
    {
        if (shieldedTokenTransferIntegrityBroken) {
            _advanceFeeBaselineWithoutAccruingFees(tokenId);
            return (0, 0, 0);
        }

        if (_hasOraclePendingChallenge(SHIELDED_TOKEN) || _hasOracleChallengeablePrice(SHIELDED_TOKEN)) {
            return (0, 0, 0);
        }

        (bool priceAvailable, uint256 currentPrice) = _tryGetShieldedFeeAccrualPrice();
        if (!priceAvailable) return (0, 0, 0);

        return _calculateAndAccumulateFeesAtPrice(tokenId, currentPrice);
    }

    function _advanceFeeBaselineWithoutAccruingFees(uint256 tokenId) internal {
        (bool priceAvailable, uint256 currentPrice) = _tryGetShieldedFeeAccrualPrice();
        if (!priceAvailable) {
            return;
        }

        IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(shieldReceiptNFT).getPosition(tokenId);
        if (pos.amount == 0) {
            return;
        }

        uint256 currentValue = Math.mulDiv(pos.amount, currentPrice, shieldedTokenScale);
        uint256 baselineValueUsd = feeValueBaselineUsd[tokenId];
        if (baselineValueUsd == 0 && pos.valueAtDeposit != 0) {
            baselineValueUsd = pos.valueAtDeposit;
        }
        if (currentValue > baselineValueUsd) {
            feeValueBaselineUsd[tokenId] = currentValue;
        }
    }

    // Slither reentrancy-eth false positive: guarded by nonReentrant and/or governance-only access (or internal, reached only via such guarded entrypoints); external calls are to trusted protocol contracts.
    // slither-disable-next-line reentrancy-eth
    function _calculateAndAccumulateFeesAtPrice(uint256 tokenId, uint256 currentPrice)
        internal
        returns (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount)
    {
        IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(shieldReceiptNFT).getPosition(tokenId);
        if (pos.amount == 0) revert ErrorsLib.InsufficientTokenBalance();

        // Get current USD value (USD-BASED for yield calculation)
        uint256 currentValue = Math.mulDiv(pos.amount, currentPrice, shieldedTokenScale);

        // Use per-position high-water-mark baseline to avoid repeatedly taxing the same yield.
        uint256 baselineValueUsd = feeValueBaselineUsd[tokenId];
        if (baselineValueUsd == 0 && pos.valueAtDeposit != 0) {
            baselineValueUsd = pos.valueAtDeposit;
        }

        // Calculate NEW yield earned since last fee accrual (underflow-safe)
        uint256 yieldEarnedUsd = currentValue > baselineValueUsd ? currentValue - baselineValueUsd : 0;

        // Calculate fee amounts in USD (8 decimals)
        // NOTE: Uses Rounding.Ceil intentionally to ensure fee recipients receive at least the minimum
        // amount owed. This slightly favors fee recipients over shielded users for dust amounts.
        uint256 commissionAmountUsd =
            yieldEarnedUsd.mulDiv(COMMISSION_RATE, ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);
        uint256 poolFeeAmountUsd = yieldEarnedUsd.mulDiv(POOL_FEE, ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);
        uint256 protocolFeeAmountUsd =
            yieldEarnedUsd.mulDiv(poolConfig.protocolFee, ConstantsLib.BASIS_POINT_SCALE, Math.Rounding.Ceil);

        // Convert USD fees (8 decimals) to shielded token units using the same probed price.
        commissionAmount = commissionAmountUsd == 0
            ? 0
            : Math.mulDiv(commissionAmountUsd, shieldedTokenScale, currentPrice, Math.Rounding.Ceil);
        poolFeeAmount = poolFeeAmountUsd == 0
            ? 0
            : Math.mulDiv(poolFeeAmountUsd, shieldedTokenScale, currentPrice, Math.Rounding.Ceil);
        protocolFeeAmount = protocolFeeAmountUsd == 0
            ? 0
            : Math.mulDiv(protocolFeeAmountUsd, shieldedTokenScale, currentPrice, Math.Rounding.Ceil);

        // Cap total fees to available amount to prevent underflow
        uint256 totalFees = commissionAmount + poolFeeAmount + protocolFeeAmount;
        if (totalFees > pos.amount) {
            // Scale down fees proportionally without introducing a second rounding step.
            (commissionAmount, poolFeeAmount, protocolFeeAmount) =
                _scaleFeesToAvailableAmount(commissionAmount, poolFeeAmount, protocolFeeAmount, pos.amount);
        }

        // Prevent unbounded fee accumulation. If any fee bucket cannot fit the
        // increment, revert rather than silently zeroing the amount: zeroing
        // would let the position retain the yield AND advance the baseline
        // past it, permanently forgiving that fee. Reverting forces the
        // operator to drain the bucket via payPoolFee/payProtocolFee before
        // yield accrual continues — matching the cross-asset path's
        // RewardAccumulationIncomplete invariant. (H-6)
        uint256 maxSafeAccumulation = ConstantsLib.MAX_SAFE_ACCUMULATION;

        if (accumulatedPoolFee + poolFeeAmount > maxSafeAccumulation) {
            revert ErrorsLib.RewardAccumulationIncomplete(poolFeeAmount, accumulatedPoolFee, 0);
        }
        accumulatedPoolFee += poolFeeAmount;

        if (accumulatedProtocolFee + protocolFeeAmount > maxSafeAccumulation) {
            revert ErrorsLib.RewardAccumulationIncomplete(protocolFeeAmount, accumulatedProtocolFee, 0);
        }
        accumulatedProtocolFee += protocolFeeAmount;

        // Accumulate commissions in native shielded token units via rewards-per-share.
        // If no effective protector capital exists, redirect commissions to protocol fee.
        // _accumulateProtectorReward applies its own cap checks internally and now
        // reverts with RewardAccumulationIncomplete on commission-bucket overflow
        // (B4), matching the pool/protocol fee buckets above.
        uint256 redirectedCommission;
        (commissionAmount, redirectedCommission) = _accumulateProtectorReward(commissionAmount, maxSafeAccumulation);
        protocolFeeAmount += redirectedCommission;

        // Recalculate totalFees after potential commission redirect
        totalFees = commissionAmount + poolFeeAmount + protocolFeeAmount;

        // Update position amount for next calculation
        uint256 newAmount = pos.amount - totalFees;
        // H-2 FIX: valueAtDeposit represents the ORIGINAL deposit value and should NOT change.
        // Only amount and lastFeeClaimTime should be updated. Collateral amount also stays the same.
        // (Previously used oracle lookup which caused valueAtDeposit to drift from totalValueAtDeposit)
        IShieldReceiptNFT(shieldReceiptNFT)
            .updatePosition(tokenId, newAmount, pos.valueAtDeposit, pos.collateralAmount, uint64(block.timestamp));

        // Advance baseline to post-fee value, but never decrease it (high-water-mark behavior).
        // This prevents a drawdown claim from lowering the threshold and taxing pure recovery gains.
        uint256 postFeeValueUsd = Math.mulDiv(newAmount, currentPrice, shieldedTokenScale);
        feeValueBaselineUsd[tokenId] = postFeeValueUsd > baselineValueUsd ? postFeeValueUsd : baselineValueUsd;

        return (commissionAmount, poolFeeAmount, protocolFeeAmount);
    }

    /**
     * @dev Internal helper to pay out an accumulated fee amount to a recipient.
     *      Validates balance, updates pool state, and transfers tokens.
     * @param feeAmount The fee amount to pay out
     * @param recipient The address to receive the fee
     * @return paidAmount The amount actually paid (0 if feeAmount was 0)
     * @custom:error InsufficientTokenBalance If pool has insufficient balance
     */
    function _payAccumulatedFee(uint256 feeAmount, address recipient) internal returns (uint256 paidAmount) {
        // slither-disable-next-line incorrect-equality — early-return guard, nothing to pay
        if (feeAmount == 0) return 0;
        _validateFeeRecipient(recipient);
        _requirePoolAccountingBalancesCovered();

        // Check actual balance (source of truth)
        uint256 actualBalance = IERC20(SHIELDED_TOKEN).balanceOf(address(this));
        if (actualBalance < feeAmount) {
            revert ErrorsLib.InsufficientTokenBalance();
        }

        // Reduce pool's shielded token balance by the fees paid out
        poolState.shieldedTokenBalance -= feeAmount;

        return _transferOutAndGetReceived(SHIELDED_TOKEN, recipient, feeAmount);
    }

    /**
     * @notice Pay out accumulated pool fee to the pool creator
     * @dev Only pool creator or governance can trigger fee payment.
     *      Transfers accumulated pool fee from the pool to the pool creator.
     *      Resets the accumulated fee counter to prevent double payment.
     * @custom:error AccessControlDenied If caller is not pool creator or governance
     * @custom:error InsufficientTokenBalance If pool has insufficient balance
     */
    function payPoolFee() external nonReentrant whenNotPaused {
        if (msg.sender != POOL_CREATOR && msg.sender != _governanceTimelock) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "payPoolFee");
        }

        uint256 amount = accumulatedPoolFee;
        accumulatedPoolFee = 0;

        // M-14: legacy upgraded pools have poolFeeRecipient == address(0) until
        // POOL_CREATOR sets one; fall back to POOL_CREATOR in that case so
        // behavior is unchanged for old proxies.
        address recipient = poolFeeRecipient == address(0) ? POOL_CREATOR : poolFeeRecipient;
        uint256 paidAmount = _payAccumulatedFee(amount, recipient);
        if (paidAmount > 0) {
            emit EventsLib.PoolFeePaid(recipient, paidAmount);
        }
    }

    /// @notice Rotate the recipient of accumulated pool fees (M-14)
    /// @dev POOL_CREATOR can rotate. Useful if the original recipient is
    ///      blacklisted by the SHIELDED_TOKEN issuer, preventing fees from
    ///      becoming permanently unreachable.
    /// @dev B8: governance timelock is also accepted as a backstop. If the
    ///      POOL_CREATOR key is lost or the creator itself is blacklisted /
    ///      otherwise compromised, accumulated pool fees would be permanently
    ///      stuck without a second authorised rotator. Mirrors the
    ///      POOL_CREATOR-or-governance pattern used by `payPoolFee`.
    function setPoolFeeRecipient(address newRecipient) external {
        if (msg.sender != POOL_CREATOR && msg.sender != _governanceTimelock) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "setPoolFeeRecipient");
        }
        _validateFeeRecipient(newRecipient);
        address previous = poolFeeRecipient == address(0) ? POOL_CREATOR : poolFeeRecipient;
        poolFeeRecipient = newRecipient;
        emit EventsLib.ParameterUpdated("poolFeeRecipient", uint256(uint160(newRecipient)));
        // Emit also the previous→current pair through the existing
        // ProtocolFeeRecipientUpdated topic so monitoring tools that watch
        // recipient changes pick this up.
        emit EventsLib.ProtocolFeeRecipientUpdated(previous, newRecipient);
    }

    /**
     * @notice Pay out accumulated protocol fee to the protocol fee recipient
     * @dev Only protocol fee recipient or governance can trigger fee payment.
     *      Transfers accumulated protocol fee from the pool to the protocol fee recipient.
     *      Resets the accumulated fee counter to prevent double payment.
     * @custom:error AccessControlDenied If caller is not protocol fee recipient or governance
     * @custom:error InsufficientTokenBalance If pool has insufficient balance
     */
    function payProtocolFee() external nonReentrant whenNotPaused {
        if (msg.sender != poolConfig.protocolFeeRecipient && msg.sender != _governanceTimelock) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "payProtocolFee");
        }

        uint256 amount = accumulatedProtocolFee;
        accumulatedProtocolFee = 0;

        uint256 paidAmount = _payAccumulatedFee(amount, poolConfig.protocolFeeRecipient);
        if (paidAmount > 0) {
            emit EventsLib.ProtocolFeePaid(poolConfig.protocolFeeRecipient, paidAmount);
        }
    }

    /**
     * @dev Internal helper to calculate claimable commission using rewards-per-share pattern.
     *      Single source of truth for MasterChef-style commission calculation.
     * @param tokenId The protector NFT token ID
     * @param positionShares_ The protector share balance to calculate claimable for
     * @return claimable The amount that can be claimed
     */
    function _calculateClaimableCommission(uint256 tokenId, uint256 positionShares_)
        internal
        view
        returns (uint256 claimable)
    {
        uint256 effectiveRewardPerShare = rewardPerShareAccumulated;
        uint256 positionEpoch = protectorShareEpochs[tokenId];
        if (positionEpoch < protectorShareEpoch) {
            effectiveRewardPerShare = protectorEpochFinalRewardPerShare[positionEpoch];
        }

        uint256 totalEarned = Math.mulDiv(effectiveRewardPerShare, positionShares_, ConstantsLib.REWARD_PRECISION);
        uint256 debt = rewardDebt[tokenId];
        uint256 alreadyClaimed = commissionsClaimed[tokenId];
        return totalEarned > (debt + alreadyClaimed) ? totalEarned - debt - alreadyClaimed : 0;
    }

    /// @dev Ends the current share epoch when shield activation wipes all backing assets.
    ///      If only below-minimum unprotected dust remains, the dust is swept so stale
    ///      live shares cannot permanently block fresh protector deposits.
    function _expireProtectorShareEpochIfDrained(bool includeUnprotectedDust) internal {
        uint256 currentProtectorTokens = totalProtectorTokens;
        bool sweepUnprotectedDust = includeUnprotectedDust && totalValueAtDeposit == 0 && currentProtectorTokens != 0
            && currentProtectorTokens < poolConfig.backingMinDepositAmount;

        if (totalProtectorShares != 0 && (currentProtectorTokens == 0 || sweepUnprotectedDust)) {
            uint256 expiredEpoch = protectorShareEpoch;
            protectorEpochFinalRewardPerShare[expiredEpoch] = rewardPerShareAccumulated;
            protectorEpochRemainingShares[expiredEpoch] = totalProtectorShares;
            if (currentEpochCommissionReserve != 0) {
                protectorEpochRemainingReserve[expiredEpoch] += currentEpochCommissionReserve;
                historicalCommissionReserve += currentEpochCommissionReserve;
                currentEpochCommissionReserve = 0;
            }
            pendingProtectorRewardDust = 0;
            totalProtectorShares = 0;
            protectorShareEpoch += 1;
        }

        if (sweepUnprotectedDust) {
            totalProtectorTokens = 0;
            poolState.totalBackingTokenBalance -= currentProtectorTokens;
            uint256 received =
                _transferOutAndGetReceived(BACKING_TOKEN, poolConfig.protocolFeeRecipient, currentProtectorTokens);
            emit EventsLib.ProtectorResidualBackingSwept(poolConfig.protocolFeeRecipient, BACKING_TOKEN, received);
        }
    }

    /// @dev Claims pending commissions for a protector position using share-based accounting.
    function _claimCommissionTo(address recipient, uint256 tokenId, uint256 positionShares_)
        internal
        returns (uint256 claimable)
    {
        _tryDistributePendingProtectorRewardDust();

        uint256 positionEpoch = protectorShareEpochs[tokenId];
        bool isExpiredEpoch = positionEpoch < protectorShareEpoch;
        claimable = _calculateClaimableCommission(tokenId, positionShares_);
        if (claimable > accumulatedCommissions) claimable = accumulatedCommissions;
        if (isExpiredEpoch && claimable > protectorEpochRemainingReserve[positionEpoch]) {
            claimable = protectorEpochRemainingReserve[positionEpoch];
        }
        if (claimable == 0) {
            if (isExpiredEpoch) {
                _settleExpiredEpochPosition(tokenId, positionEpoch, positionShares_);
            }
            return 0;
        }
        _requireAccountingBalanceCovered(SHIELDED_TOKEN, poolState.shieldedTokenBalance);

        commissionsClaimed[tokenId] += claimable;
        accumulatedCommissions -= claimable;
        if (isExpiredEpoch) {
            protectorEpochRemainingReserve[positionEpoch] = claimable >= protectorEpochRemainingReserve[positionEpoch]
                ? 0
                : protectorEpochRemainingReserve[positionEpoch] - claimable;
            historicalCommissionReserve =
                claimable >= historicalCommissionReserve ? 0 : historicalCommissionReserve - claimable;
        } else {
            currentEpochCommissionReserve =
                claimable >= currentEpochCommissionReserve ? 0 : currentEpochCommissionReserve - claimable;
        }

        uint256 actualBalance = IERC20(SHIELDED_TOKEN).balanceOf(address(this));
        if (actualBalance < claimable) {
            revert ErrorsLib.InsufficientTokenBalance();
        }

        poolState.shieldedTokenBalance -= claimable;
        uint256 received = _transferOutAndGetReceived(SHIELDED_TOKEN, recipient, claimable);
        if (received != claimable) {
            revert ErrorsLib.IncompatibleShieldedTokenForCrossAssetWithdrawal(SHIELDED_TOKEN);
        }
        if (isExpiredEpoch) {
            _settleExpiredEpochPosition(tokenId, positionEpoch, positionShares_);
        }

        emit EventsLib.CommissionClaimed(recipient, tokenId, received);
    }

    /// @dev Clears claimable commission without transferring shielded tokens. The forfeited
    ///      amount becomes unaccounted surplus and can only be swept once the pool has no
    ///      tracked liabilities, letting principal exits continue when commission payout is
    ///      impossible for a shielded token or recipient.
    function _forfeitCommission(uint256 tokenId, uint256 positionShares_) internal returns (uint256 claimable) {
        _tryDistributePendingProtectorRewardDust();

        uint256 positionEpoch = protectorShareEpochs[tokenId];
        bool isExpiredEpoch = positionEpoch < protectorShareEpoch;
        claimable = _calculateClaimableCommission(tokenId, positionShares_);
        if (claimable > accumulatedCommissions) claimable = accumulatedCommissions;
        if (isExpiredEpoch && claimable > protectorEpochRemainingReserve[positionEpoch]) {
            claimable = protectorEpochRemainingReserve[positionEpoch];
        }
        if (claimable == 0) {
            if (isExpiredEpoch) {
                _settleExpiredEpochPosition(tokenId, positionEpoch, positionShares_);
            }
            return 0;
        }

        _requireAccountingBalanceCovered(SHIELDED_TOKEN, poolState.shieldedTokenBalance);

        commissionsClaimed[tokenId] += claimable;
        accumulatedCommissions -= claimable;
        if (isExpiredEpoch) {
            protectorEpochRemainingReserve[positionEpoch] = claimable >= protectorEpochRemainingReserve[positionEpoch]
                ? 0
                : protectorEpochRemainingReserve[positionEpoch] - claimable;
            historicalCommissionReserve =
                claimable >= historicalCommissionReserve ? 0 : historicalCommissionReserve - claimable;
        } else {
            currentEpochCommissionReserve =
                claimable >= currentEpochCommissionReserve ? 0 : currentEpochCommissionReserve - claimable;
        }

        poolState.shieldedTokenBalance -= claimable;
        if (isExpiredEpoch) {
            _settleExpiredEpochPosition(tokenId, positionEpoch, positionShares_);
        }
    }

    /**
     * @notice Claims accumulated commission for a protector NFT position
     * @dev Uses MasterChef pattern to prevent late-joiner exploit. Only the current
     *      NFT owner can claim. Commission is paid in shielded tokens.
     *      Emits NoCommissionToClaim event if no commission is available.
     * @dev Intentionally NOT gated by `whenNotPaused`. B4 (PR #21) made
     *      commission-bucket overflow revert with `RewardAccumulationIncomplete`,
     *      and `_tryCalculateAndAccumulateFees` does not catch that revert. Once
     *      `accumulatedCommissions` saturates `MAX_SAFE_ACCUMULATION`, every
     *      withdrawal path that accrues fees reverts until the bucket is
     *      drained. `claimCommission` is the only drain path; keeping it
     *      callable during pause prevents a saturated+paused state from
     *      trapping all user exits. The companion `payPoolFee` / `payProtocolFee`
     *      / `claimRewards` paths remain pause-gated since they are value-
     *      extraction surfaces unrelated to the drain mechanic.
     * @param tokenId The protector NFT token ID
     * @custom:error NotOwner If caller is not the NFT owner
     * @custom:error InsufficientTokenBalance If pool has insufficient balance or no protectors
     */
    function claimCommission(uint256 tokenId) external nonReentrant {
        if (IProtectorReceiptNFT(protectorReceiptNFT).ownerOf(tokenId) != msg.sender) {
            revert ErrorsLib.NotOwner();
        }
        _requirePoolAccountingBalancesCovered();
        _requireProtectorWithdrawalAllowed(msg.sender, "claimCommission");

        uint256 positionShares_ = _getProtectorPositionShares(tokenId);

        if (_claimCommissionTo(msg.sender, tokenId, positionShares_) == 0) {
            emit EventsLib.NoCommissionToClaim(msg.sender, tokenId);
        }
    }

    /**
     * @notice Forfeit claimable commission for a protector NFT position
     * @dev The NFT owner may voluntarily forfeit commission if shielded-token payouts
     *      are impossible. Governance may also clear it to unblock pool retirement.
     *      Principal accounting is left intact.
     * @param tokenId The protector NFT token ID
     */
    function forfeitCommission(uint256 tokenId) external nonReentrant {
        address positionOwner = IProtectorReceiptNFT(protectorReceiptNFT).ownerOf(tokenId);
        if (msg.sender != positionOwner && msg.sender != governanceTimelock()) {
            revert ErrorsLib.NotOwner();
        }
        _requirePoolAccountingBalancesCovered();

        uint256 positionShares_ = _getProtectorPositionShares(tokenId);
        uint256 forfeited = _forfeitCommission(tokenId, positionShares_);
        if (forfeited == 0) {
            emit EventsLib.NoCommissionToClaim(positionOwner, tokenId);
            return;
        }

        emit EventsLib.CommissionForfeited(msg.sender, positionOwner, tokenId, forfeited);
    }

    /**
     * @notice Settles commission for an expired protector-share epoch without requiring the NFT owner to call
     * @dev Pays any claimable commission to the current NFT owner. This lets keepers clear
     *      drained-pool reserves after a full shield activation while preserving ownership of funds.
     * @param tokenId The protector NFT token ID
     */
    function settleExpiredProtectorPosition(uint256 tokenId) external nonReentrant {
        if (protectorShareEpochs[tokenId] >= protectorShareEpoch) {
            revert ErrorsLib.InvalidTokenId();
        }
        _requirePoolAccountingBalancesCovered();

        address positionOwner = IProtectorReceiptNFT(protectorReceiptNFT).ownerOf(tokenId);
        _requireProtectorWithdrawalAllowed(positionOwner, "settleExpiredProtectorPosition");
        uint256 positionShares_ = _getProtectorPositionShares(tokenId);

        if (_claimCommissionTo(positionOwner, tokenId, positionShares_) == 0) {
            emit EventsLib.NoCommissionToClaim(positionOwner, tokenId);
        }
    }

    /**
     * @notice Get the claimable commission amount for a protector NFT position
     * @dev Calculates claimable commission using rewards-per-share pattern (MasterChef).
     *      Returns 0 if no commission is available or if there are no protector tokens.
     * @param tokenId The protector NFT token ID
     * @return claimableAmount Amount that can be claimed (in shielded tokens)
     */
    function getClaimableCommission(uint256 tokenId) public view returns (uint256) {
        uint256 positionShares_ = _getProtectorPositionShares(tokenId);
        if (positionShares_ == 0) return 0;

        uint256 claimable = _calculateClaimableCommission(tokenId, positionShares_);
        uint256 positionEpoch = protectorShareEpochs[tokenId];
        if (positionEpoch < protectorShareEpoch && claimable > protectorEpochRemainingReserve[positionEpoch]) {
            return protectorEpochRemainingReserve[positionEpoch];
        }
        return claimable;
    }

    // Core Pool Functions
    /**
     * @notice Deposits backing tokens to receive a protector receipt NFT
     * @dev Mints an NFT representing the protector position. Uses balance-delta pattern
     *      to support fee-on-transfer tokens. Records reward debt at current accumulator
     *      to prevent late-joiner exploit (MasterChef pattern).
     * @param asset The backing asset to deposit (must be BACKING_TOKEN)
     * @param depositAmount Amount of asset to deposit
     * @param minReceivedAmount Minimum tokens to receive after transfer (slippage protection for fee-on-transfer tokens)
     * @return tokenId The minted NFT token ID
     * @custom:error UnsupportedAsset If asset is not the backing token
     * @custom:error InsufficientDepositAmount If amount is below minimum
     * @custom:error DepositAmountTooLarge If amount exceeds maximum
     * @custom:error TVLLimitExceeded If deposit would exceed TVL limit
     * @custom:error InsufficientProtectorTokenBalance If insufficient collateral capacity
     */
    function depositBackingAsset(address asset, uint256 depositAmount, uint256 minReceivedAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId)
    {
        if (asset != BACKING_TOKEN) revert ErrorsLib.UnsupportedAsset();
        _requireActiveFactoryPoolForDeposit();
        _requirePoolAccountingBalancesCovered();
        if (accessControl != address(0) && !IPoolAccessControl(accessControl).canDepositProtector(msg.sender)) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "depositProtector");
        }

        // Backing deposits lock protector shares from protected backing value and TVL
        // accounting, so both priced legs must be free of pending oracle challenges.
        _requireNoOraclePendingChallenge(BACKING_TOKEN);
        _requireNoOraclePendingChallenge(SHIELDED_TOKEN);

        // Balance-delta deposit to support fee-on-transfer tokens
        uint256 received = _transferAndGetReceived(asset, depositAmount);

        // If minReceivedAmount > 0, verify received amount meets minimum expectation
        if (minReceivedAmount > 0) {
            SlippageLib.enforceMinReceived(received, minReceivedAmount);
        }

        _validateDeposit(asset, received);
        _markPoolLaunched();

        _expireProtectorShareEpochIfDrained(true);
        _redirectPendingProtectorRewardDust(ConstantsLib.MAX_SAFE_ACCUMULATION);

        uint256 currentTotalShares = totalProtectorShares;
        uint256 sharesMinted = currentTotalShares == 0 || totalProtectorTokens == 0
            ? _backingAmountToProtectorShares(received)
            : Math.mulDiv(received, currentTotalShares, totalProtectorTokens);
        if (sharesMinted == 0) revert ErrorsLib.InsufficientDepositAmount();
        uint256 newTotalShares = currentTotalShares + sharesMinted;
        _requireProtectorShareRewardCapacity(newTotalShares);

        // Update pool balances (TOKEN-BASED)
        poolState.totalBackingTokenBalance += received;
        totalProtectorTokens += received;
        totalProtectorShares = newTotalShares;

        // M-12: pre-compute the tokenId and initialise per-id mappings BEFORE
        // the external mint call. _safeMint invokes onERC721Received on
        // contract recipients; any view-only inspection from that callback
        // (or a future state mutation moved post-mint) must see a consistent
        // position, not a half-initialised one.
        tokenId = IProtectorReceiptNFT(protectorReceiptNFT).nextTokenId();
        protectorShares[tokenId] = sharesMinted;
        protectorShareEpochs[tokenId] = protectorShareEpoch;
        rewardDebt[tokenId] = Math.mulDiv(rewardPerShareAccumulated, sharesMinted, ConstantsLib.REWARD_PRECISION);

        uint256 mintedTokenId = IProtectorReceiptNFT(protectorReceiptNFT).mint(msg.sender, received);
        require(mintedTokenId == tokenId, "protector tokenId mismatch");

        emit EventsLib.ProtectorAssetDeposited(msg.sender, asset, received, tokenId);
    }

    /**
     * @notice Deposits yield-bearing assets to receive a shielded receipt NFT
     * @dev Mints an NFT representing the shielded position. Requires sufficient
     *      protector tokens in the pool to meet collateral requirements.
     *      Uses USD-BASED accounting for capacity checks via price oracle.
     *      Stores valueAtDeposit and collateralAmount for cross-asset withdrawal.
     * @param asset The yield-bearing token to deposit (must be SHIELDED_TOKEN)
     * @param depositAmount Amount of asset to deposit
     * @param minReceivedAmount Minimum tokens to receive after transfer (slippage protection for fee-on-transfer tokens)
     * @return tokenId The minted NFT token ID
     * @custom:error UnsupportedAsset If asset is not the shielded token
     * @custom:error InsufficientDepositAmount If amount is below minimum
     * @custom:error DepositAmountTooLarge If amount exceeds maximum
     * @custom:error TVLLimitExceeded If deposit would exceed TVL limit
     * @custom:error InsufficientProtectorTokenBalance If insufficient collateral capacity
     * @custom:error AccessControlDenied If access control is set and caller is not authorized
     */
    function depositShieldedAsset(address asset, uint256 depositAmount, uint256 minReceivedAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId)
    {
        if (asset != SHIELDED_TOKEN) revert ErrorsLib.UnsupportedAsset();
        if (shieldedTokenTransferIntegrityBroken) {
            revert ErrorsLib.IncompatibleShieldedTokenForCrossAssetWithdrawal(SHIELDED_TOKEN);
        }
        _requireActiveFactoryPoolForDeposit();
        _requirePoolAccountingBalancesCovered();
        if (accessControl != address(0) && !IPoolAccessControl(accessControl).canDepositShielded(msg.sender)) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "depositShielded");
        }

        // Block deposits while either priced leg has a pending dual-feed challenge.
        // The active feed is suspect for up to `challengeDurationSec`; locking
        // `valueAtDeposit` or the backing collateral cap from that feed would let a
        // depositor realise the deviation via cross-asset withdraw.
        _requireNoOraclePendingChallenge(SHIELDED_TOKEN);
        _requireNoOraclePendingChallenge(BACKING_TOKEN);

        // Transfer asset from depositor (balance-delta for fee-on-transfer tokens)
        uint256 received = _transferAndGetReceived(asset, depositAmount);
        if (received != depositAmount) {
            revert ErrorsLib.IncompatibleShieldedTokenForCrossAssetWithdrawal(SHIELDED_TOKEN);
        }

        // If minReceivedAmount > 0, verify received amount meets minimum expectation
        if (minReceivedAmount > 0) {
            SlippageLib.enforceMinReceived(received, minReceivedAmount);
        }

        _validateDeposit(asset, received);

        // Calculate USD value for cross-asset withdrawal and fee calculation
        uint256 valueAtDeposit = _getShieldedValue(received);
        uint256 collateralAmount = _getShieldCollateralAmount(valueAtDeposit);

        // Check capacity using both USD accounting and native-token collateral caps.
        _checkCapacity(valueAtDeposit, collateralAmount);
        _markPoolLaunched();

        // Update pool balances (TOKEN-BASED)
        poolState.shieldedTokenBalance += received;
        totalShieldedTokens += received;

        // Update total original deposit value (USD-BASED)
        totalValueAtDeposit += valueAtDeposit;
        totalShieldCollateralAmount += collateralAmount;

        // M-12: pre-compute the tokenId and initialise per-id mappings BEFORE
        // the external mint call. _safeMint invokes onERC721Received on
        // contract recipients; any view-only inspection from that callback
        // must see a consistent position.
        tokenId = IShieldReceiptNFT(shieldReceiptNFT).nextTokenId();
        feeValueBaselineUsd[tokenId] = _getShieldedFeeBaselineValue(received);

        uint256 mintedTokenId =
            IShieldReceiptNFT(shieldReceiptNFT).mint(msg.sender, received, valueAtDeposit, collateralAmount);
        require(mintedTokenId == tokenId, "shield tokenId mismatch");

        emit EventsLib.ShieldedAssetDeposited(msg.sender, asset, received, tokenId);
    }

    /**
     * @notice Withdraws a shielded position, allowing choice of asset type
     * @dev Burns the shield NFT and transfers tokens to the owner. Can withdraw
     *      as shielded tokens (normal) or backing tokens (cross-asset / shield activation).
     *      Fees are calculated and accumulated before withdrawal.
     *      Ensures withdrawal doesn't take reserved fee funds.
     *      If withdrawing backing tokens, minimumPoolTime must be met.
     * @param tokenId The shield NFT token ID
     * @param preferredAsset Asset to withdraw (SHIELDED_TOKEN or BACKING_TOKEN)
     * @param minAmountOut Minimum amount the recipient must actually receive
     * @custom:error InvalidTokenId If caller is not the NFT owner or position is already withdrawn
     * @custom:error UnsupportedAsset If preferredAsset is not SHIELDED_TOKEN or BACKING_TOKEN
     * @custom:error InsufficientPoolTime If withdrawing backing tokens before minimumPoolTime
     * @custom:error InsufficientTokenBalance If pool has insufficient balance or withdrawal exceeds withdrawable balance
     * @custom:error AccessControlDenied If access control is set and caller is not authorized
     */
    // Slither reentrancy-eth false positive: guarded by nonReentrant and/or governance-only access (or internal, reached only via such guarded entrypoints); external calls are to trusted protocol contracts.
    // slither-disable-next-line reentrancy-eth
    function shieldedWithdraw(uint256 tokenId, address preferredAsset, uint256 minAmountOut)
        external
        nonReentrant
        whenNotPaused
        onlyShieldNFTOwner(tokenId)
    {
        if (!(preferredAsset == BACKING_TOKEN || preferredAsset == SHIELDED_TOKEN)) {
            revert ErrorsLib.UnsupportedAsset();
        }
        _requirePoolAccountingBalancesCovered();
        if (_withdrawalAccessControlActive() && !IPoolAccessControl(accessControl).canWithdrawShielded(msg.sender)) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "withdrawShielded");
        }

        IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(shieldReceiptNFT).getPosition(tokenId);

        // Check minimum pool time only if withdrawing backing assets (shield activation)
        if (preferredAsset == BACKING_TOKEN) {
            if (shieldedTokenTransferIntegrityBroken) {
                revert ErrorsLib.IncompatibleShieldedTokenForCrossAssetWithdrawal(SHIELDED_TOKEN);
            }
            _requireNoOraclePendingChallenge(BACKING_TOKEN);
            _requireNoOraclePendingChallenge(SHIELDED_TOKEN);

            uint256 timeElapsed = block.timestamp - uint256(pos.depositTime);
            if (timeElapsed < poolConfig.minimumPoolTime) {
                revert ErrorsLib.InsufficientPoolTimeWithDetails(poolConfig.minimumPoolTime, timeElapsed);
            }
        }

        uint256 totalFees;
        if (preferredAsset == SHIELDED_TOKEN) {
            // M-13: refuse same-asset withdrawals while the shielded leg has a
            // pending dual-feed challenge. Previously fees silently rounded to
            // zero in that window, so a user could intentionally trigger a
            // challenge to exit without paying yield fees. Generic oracle
            // outages also fail closed here so yield fees cannot be bypassed by
            // waiting for a protected-price outage.
            //
            // B6: Same-asset exits also release the full
            // `pos.collateralAmount` from `totalShieldCollateralAmount` below,
            // loosening the protector clamp computed from backing-token pricing.
            // Backing-token oracle state therefore matters here too — gate both
            // legs, mirroring the cross-asset / deposit paths.
            _requireNoOraclePendingChallenge(BACKING_TOKEN);
            _requireNoOraclePendingChallenge(SHIELDED_TOKEN);

            (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount) =
                _calculateAndAccumulateFees(tokenId);
            totalFees = commissionAmount + poolFeeAmount + protocolFeeAmount;
        } else {
            // Shield activation also consumes the shielded position, so it must
            // collect yield fees before routing the remaining forfeiture.
            (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount) =
                _calculateAndAccumulateFees(tokenId);
            totalFees = commissionAmount + poolFeeAmount + protocolFeeAmount;
        }

        // Burn NFT (position data is deleted by burn, no need to update first)
        IShieldReceiptNFT(shieldReceiptNFT).burn(tokenId);
        delete lastClaimRewardsTime[tokenId]; // Clean up stale state
        delete feeValueBaselineUsd[tokenId];

        // Update total original deposit value (subtract original value at deposit)
        totalValueAtDeposit -= pos.valueAtDeposit;

        uint256 payoutAmount;

        if (preferredAsset == SHIELDED_TOKEN) {
            // Same-asset exit: no backing tokens leave the pool, so the full
            // backing-collateral reservation for this position can be released.
            totalShieldCollateralAmount -= pos.collateralAmount;

            // Normal withdrawal: user gets shielded tokens back (minus fees)
            payoutAmount = pos.amount - totalFees;

            if (payoutAmount > getWithdrawableBalance()) {
                revert ErrorsLib.InsufficientTokenBalance();
            }

            poolState.shieldedTokenBalance -= payoutAmount;
        } else {
            // Cross-asset withdrawal (USD-BASED): user gets backing tokens (shield activation)
            // Use stored valueAtDeposit (locked at deposit time - manipulation resistant)
            uint256 forfeitedShieldedAmount = pos.amount - totalFees;
            _requireUntaxedShieldedRoundTrip(forfeitedShieldedAmount);
            (uint256 accumulatedReward, uint256 redirectedReward) =
                _accumulateProtectorReward(forfeitedShieldedAmount, ConstantsLib.MAX_SAFE_ACCUMULATION);
            if (accumulatedReward + redirectedReward != forfeitedShieldedAmount) {
                revert ErrorsLib.RewardAccumulationIncomplete(
                    forfeitedShieldedAmount, accumulatedReward, redirectedReward
                );
            }

            uint256 uwPrice = _getProtectedBackingPrice();
            payoutAmount = _getBackingAmountFromUsdFloor(pos.valueAtDeposit, uwPrice);

            // Cap to original collateral amount (in token terms, not recalculated)
            // This ensures users can't claim more tokens than were originally allocated
            // even if backing token depegs dramatically
            uint256 maxBackingTokens = pos.collateralAmount;
            if (payoutAmount > maxBackingTokens) {
                payoutAmount = maxBackingTokens;
            }

            // The whole shield NFT is burned, so release its whole stored
            // collateral cap. The cap is per-position accounting, not a record
            // of how many backing tokens actually left during this withdrawal.
            totalShieldCollateralAmount -= pos.collateralAmount;

            // Deduct from protector pool (TOKEN-BASED accounting)
            // Check balance before deduction to prevent underflow
            if (poolState.totalBackingTokenBalance < payoutAmount) {
                revert ErrorsLib.InsufficientTokenBalance();
            }
            totalProtectorTokens -= payoutAmount;
            poolState.totalBackingTokenBalance -= payoutAmount;
            _expireProtectorShareEpochIfDrained(false);
            emit EventsLib.ShieldActivated(msg.sender, payoutAmount, forfeitedShieldedAmount, payoutAmount);
        }

        // Update shielded totals (TOKEN-BASED)
        totalShieldedTokens -= pos.amount;

        uint256 actualReceived = _transferOutAndGetReceived(preferredAsset, msg.sender, payoutAmount);
        if (preferredAsset == SHIELDED_TOKEN) {
            _markShieldedTransferIntegrityIfReduced(payoutAmount, actualReceived);
        }
        SlippageLib.enforceMinReceived(actualReceived, minAmountOut);

        emit EventsLib.ShieldedWithdrawal(msg.sender, payoutAmount, preferredAsset);
    }

    /**
     * @notice Performs a partial withdrawal from a shielded position, creating a new NFT for the remainder
     * @dev Atomically burns the old NFT and mints a new one with the remaining amount.
     *      Preserves original deposit time to prevent minimumPoolTime bypass.
     *      Ensures partial withdrawal doesn't take reserved fee funds.
     *      Only allows withdrawal of shielded tokens (not cross-asset for partial withdrawals).
     * @param tokenId The shield NFT token ID
     * @param withdrawAmount Amount to withdraw (must be less than position amount)
     * @param preferredAsset Asset to withdraw (must be SHIELDED_TOKEN for partial withdrawals)
     * @param minAmountOut Minimum amount the recipient must actually receive
     * @return newTokenId The new NFT token ID for remaining position
     * @custom:error InvalidTokenId If caller is not the NFT owner, position is withdrawn, or withdrawAmount >= position amount
     * @custom:error UnsupportedAsset If preferredAsset is not SHIELDED_TOKEN
     * @custom:error InsufficientTokenBalance If pool has insufficient balance or withdrawal exceeds withdrawable balance
     */
    // Slither reentrancy-eth false positive: guarded by nonReentrant and/or governance-only access (or internal, reached only via such guarded entrypoints); external calls are to trusted protocol contracts.
    // slither-disable-next-line reentrancy-eth
    function partialWithdrawShielded(
        uint256 tokenId,
        uint256 withdrawAmount,
        address preferredAsset,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused onlyShieldNFTOwner(tokenId) returns (uint256 newTokenId) {
        if (preferredAsset != SHIELDED_TOKEN) revert ErrorsLib.UnsupportedAsset(); // Partial withdrawal only for same asset
        if (withdrawAmount == 0) revert ErrorsLib.NoTokensToWithdraw();
        _requirePoolAccountingBalancesCovered();
        _requireNoOraclePendingChallenge(BACKING_TOKEN);
        _requireNoOraclePendingChallenge(SHIELDED_TOKEN);

        if (_withdrawalAccessControlActive() && !IPoolAccessControl(accessControl).canWithdrawShielded(msg.sender)) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "withdrawShielded");
        }

        IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(shieldReceiptNFT).getPosition(tokenId);
        if (withdrawAmount >= pos.amount) revert ErrorsLib.InvalidTokenId(); // Use full withdraw instead

        // Calculate and accumulate fees on FULL position
        (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount) =
            _calculateAndAccumulateFees(tokenId);
        uint256 totalFees = commissionAmount + poolFeeAmount + protocolFeeAmount;

        // M-1 FIX: Bounds check to prevent arithmetic underflow
        // Position must have enough to cover both withdrawal amount and accumulated fees
        if (pos.amount < withdrawAmount + totalFees) {
            revert ErrorsLib.InsufficientTokenBalance();
        }

        // Calculate remaining after withdrawal and fees (safe after bounds check)
        uint256 remaining = pos.amount - withdrawAmount - totalFees;
        if (remaining < poolConfig.shieldedMinDepositAmount) {
            revert ErrorsLib.PartialWithdrawalBelowMinimum();
        }

        // _calculateAndAccumulateFees() updates baseline for amount-after-fees.
        // Scale that baseline down proportionally for the new token after user withdrawal.
        uint256 amountAfterFees = pos.amount - totalFees;
        uint256 baselineAfterFeesUsd = feeValueBaselineUsd[tokenId];
        uint256 newFeeBaselineUsd =
            amountAfterFees > 0 ? Math.mulDiv(baselineAfterFeesUsd, remaining, amountAfterFees) : 0;

        // === ATOMIC SECTION START ===

        // 1. Mark old position withdrawn
        IShieldReceiptNFT(shieldReceiptNFT).updatePosition(tokenId, 0, 0, 0, uint64(block.timestamp));

        // 2. Burn old NFT
        IShieldReceiptNFT(shieldReceiptNFT).burn(tokenId);

        // 3. Prepare the new position with remaining amount
        // L-13: round the recalculated value/collateral UP (Ceil) so repeated
        // partial withdrawals don't slowly under-collateralise the remaining
        // position relative to its USD value. The asymmetry slightly inflates
        // totalValueAtDeposit / totalShieldCollateralAmount per call — bounded
        // by 1 wei per recompute — but is the correct rounding direction for
        // the user's protection.
        uint256 newCollateralAmount = Math.mulDiv(pos.collateralAmount, remaining, amountAfterFees, Math.Rounding.Ceil);
        uint256 newValueAtDeposit = Math.mulDiv(pos.valueAtDeposit, remaining, amountAfterFees, Math.Rounding.Ceil);

        // 4. Update pool totals (TOKEN-BASED)
        // Deduct both withdrawn amount AND fees from totalShieldedTokens
        // Fees were deducted from position in _calculateAndAccumulateFees
        if (withdrawAmount > getWithdrawableBalance()) {
            revert ErrorsLib.InsufficientTokenBalance();
        }
        totalShieldedTokens -= (withdrawAmount + totalFees);
        poolState.shieldedTokenBalance -= withdrawAmount;

        // Update total original deposit value (USD-BASED)
        // Subtract full original valueAtDeposit, then add back proportionally reduced value
        totalValueAtDeposit -= pos.valueAtDeposit;
        totalValueAtDeposit += newValueAtDeposit;
        totalShieldCollateralAmount -= pos.collateralAmount;
        totalShieldCollateralAmount += newCollateralAmount;

        // 5. Initialise per-id pool mappings BEFORE the safe mint callback can
        // inspect the new receipt. This mirrors depositShieldedAsset's ordering.
        newTokenId = IShieldReceiptNFT(shieldReceiptNFT).nextTokenId();
        uint256 oldLastClaimRewardsTime = lastClaimRewardsTime[tokenId];
        feeValueBaselineUsd[newTokenId] = newFeeBaselineUsd;
        lastClaimRewardsTime[newTokenId] = oldLastClaimRewardsTime;
        delete feeValueBaselineUsd[tokenId];
        delete lastClaimRewardsTime[tokenId];

        uint256 mintedTokenId = IShieldReceiptNFT(shieldReceiptNFT)
            .mintWithDepositTime(msg.sender, remaining, newValueAtDeposit, newCollateralAmount, pos.depositTime);
        require(mintedTokenId == newTokenId, "shield tokenId mismatch");

        // === ATOMIC SECTION END ===

        // Transfer (external call, safe after state updates)
        uint256 actualReceived = _transferOutAndGetReceived(preferredAsset, msg.sender, withdrawAmount);
        _markShieldedTransferIntegrityIfReduced(withdrawAmount, actualReceived);
        SlippageLib.enforceMinReceived(actualReceived, minAmountOut);

        emit EventsLib.PartialWithdrawal(msg.sender, tokenId, newTokenId, withdrawAmount, remaining);
    }

    function startUnlockProcess(uint256 tokenId) external nonReentrant onlyProtectorNFTOwner(tokenId) {
        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(protectorReceiptNFT).getPosition(tokenId);
        uint256 positionShares_ = _getActiveProtectorPositionShares(tokenId);
        uint256 positionAmount = _getProtectorPositionAmountFromShares(positionShares_);
        if (positionAmount == 0 && !_isProtectorDustExitAvailable(positionShares_, positionAmount)) {
            revert ErrorsLib.InsufficientTokenBalance();
        }
        if (pos.unlockRequestTime != 0 && !_isProtectorUnlockExpired(pos.unlockRequestTime)) {
            revert ErrorsLib.UnlockProcessAlreadyStarted();
        }

        IProtectorReceiptNFT(protectorReceiptNFT)
            .setUnlockRequestTime(tokenId, uint64(block.timestamp + poolConfig.unlockDuration));
        emit EventsLib.UnlockProcessStarted(msg.sender, tokenId, positionAmount);
    }

    function _isProtectorDustExitAvailable(uint256 positionShares_, uint256 positionAmount)
        internal
        view
        returns (bool)
    {
        return positionAmount == 0 && positionShares_ != 0 && totalProtectorTokens != 0 && totalValueAtDeposit == 0;
    }

    function _isProtectorUnlockExpired(uint256 unlockRequestTime) internal view returns (bool) {
        return unlockRequestTime != 0 && block.timestamp > unlockRequestTime + ConstantsLib.PROTECTOR_UNLOCK_WINDOW;
    }

    function _isProtectorUnlockActive(uint256 unlockRequestTime) internal view returns (bool) {
        return unlockRequestTime != 0 && unlockRequestTime <= block.timestamp
            && block.timestamp <= unlockRequestTime + ConstantsLib.PROTECTOR_UNLOCK_WINDOW;
    }

    /**
     * @notice Cancels an active unlock process for a protector position
     * @dev Resets the unlock request time, allowing the position to remain locked.
     * @param tokenId The protector NFT token ID
     * @custom:error InvalidTokenId If caller is not the NFT owner
     * @custom:error NoUnlockToCancel If no unlock process is active
     */
    function cancelUnlockProcess(uint256 tokenId) external nonReentrant onlyProtectorNFTOwner(tokenId) {
        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(protectorReceiptNFT).getPosition(tokenId);
        if (pos.unlockRequestTime == 0) {
            revert ErrorsLib.NoUnlockToCancel();
        }

        IProtectorReceiptNFT(protectorReceiptNFT).setUnlockRequestTime(tokenId, 0);
        emit EventsLib.UnlockProcessCancelled(msg.sender, tokenId);
    }

    /**
     * @notice Claims rewards for a shielded NFT position, triggering fee accumulation
     * @dev Rate limiting prevents griefing attacks. Minimum 24 hours
     *      between calls per tokenId. Calculates and accumulates fees (commission,
     *      pool fee, protocol fee) based on yield since last claim. Only the
     *      shield NFT owner can call it.
     * @param tokenId The shield NFT token ID
     * @custom:error NotOwner If caller is not the NFT owner
     * @custom:error ClaimRewardsCooldownNotMet If called too soon after previous claim
     * @custom:error InvalidTokenId If position is already withdrawn
     */
    function claimRewards(uint256 tokenId) external nonReentrant whenNotPaused {
        address owner = _requireShieldNFTOwner(tokenId);
        _requirePoolAccountingBalancesCovered();

        // Rate limiting: minimum 24 hours between calls per tokenId
        uint256 lastClaim = lastClaimRewardsTime[tokenId];
        if (lastClaim != 0 && block.timestamp < lastClaim + ConstantsLib.CLAIM_REWARDS_COOLDOWN) {
            revert ErrorsLib.ClaimRewardsCooldownNotMet(lastClaim + ConstantsLib.CLAIM_REWARDS_COOLDOWN);
        }
        lastClaimRewardsTime[tokenId] = block.timestamp;
        uint256 positionAmountBeforeFees = IShieldReceiptNFT(shieldReceiptNFT).getPosition(tokenId).amount;

        // Calculate and accumulate fees (this updates the position internally)
        (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount) =
            _calculateAndAccumulateFees(tokenId);
        uint256 totalFees = commissionAmount + poolFeeAmount + protocolFeeAmount;

        // Update totalShieldedTokens to reflect fees deducted from position
        if (totalFees > 0) {
            if (totalFees >= positionAmountBeforeFees) {
                revert ErrorsLib.FeeAccrualWouldConsumePosition(tokenId, positionAmountBeforeFees, totalFees);
            }
            totalShieldedTokens -= totalFees;
        }

        emit EventsLib.RewardsClaimed(owner, totalFees, SHIELDED_TOKEN);
    }

    /**
     * @notice Withdraws tokens from a protector position
     * @dev Allows partial or full withdrawal. For partial withdrawals, proportionally
     *      adjusts reward debt and claimed commissions (MasterChef pattern).
     *      Requires unlock process to be completed (unlockRequestTime <= block.timestamp).
     *      Unlock completion removes the time gate only; collateral and utilization limits still apply.
     *      Only available amount (after utilization lock) can be withdrawn.
     * @param tokenId The protector NFT token ID
     * @param amount Amount of tokens to withdraw
     * @param preferredAsset The asset to withdraw (must be BACKING_TOKEN)
     * @param minAmountOut Minimum amount the recipient must actually receive
     * @custom:error InvalidTokenId If caller is not the NFT owner
     * @custom:error UnsupportedAsset If preferredAsset is not BACKING_TOKEN
     * @custom:error NoTokensToWithdraw If amount is zero
     * @custom:error InsufficientUnlockedTokens If unlock period has not passed, amount exceeds available,
     *               or withdrawal would cause USD-based undercollateralization
     * @custom:error InsufficientTokenBalance If pool has insufficient balance
     * @custom:error AccessControlDenied If access control is set and caller is not authorized
     */
    // Slither reentrancy-eth false positive: guarded by nonReentrant and/or governance-only access (or internal, reached only via such guarded entrypoints); external calls are to trusted protocol contracts.
    // slither-disable-next-line reentrancy-eth
    function protectorWithdraw(uint256 tokenId, uint256 amount, address preferredAsset, uint256 minAmountOut)
        external
        nonReentrant
        whenNotPaused
        onlyProtectorNFTOwner(tokenId)
    {
        if (preferredAsset != BACKING_TOKEN) revert ErrorsLib.UnsupportedAsset();
        _requirePoolAccountingBalancesCovered();
        if (_hasShieldedLiabilities()) {
            _requireNoOraclePendingChallenge(BACKING_TOKEN);
        }

        _requireProtectorWithdrawalAllowed(msg.sender, "withdrawProtector");

        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(protectorReceiptNFT).getPosition(tokenId);
        uint256 currentTotalShares = totalProtectorShares;
        uint256 positionShares_ = _getActiveProtectorPositionShares(tokenId);
        uint256 positionAmount = _assetsFromProtectorShares(positionShares_, totalProtectorTokens, currentTotalShares);

        bool dustExit;
        if (amount == 0) {
            if (!_isProtectorDustExitAvailable(positionShares_, positionAmount)) {
                revert ErrorsLib.NoTokensToWithdraw();
            }
            dustExit = true;
            // I-14: the previous "sole-holder ⇒ amount = totalProtectorTokens"
            // branch is unreachable: dust-exit availability requires
            // positionAmount == 0 AND totalProtectorTokens != 0, but with
            // positionShares_ == currentTotalShares the positionAmount
            // would equal totalProtectorTokens (≠ 0) by definition, so the
            // outer check would have failed. Removed; if dust-exit semantics
            // ever extend to sole holders that branch must be reinstated
            // with a proper guard.
        }

        if (!_isProtectorUnlockActive(pos.unlockRequestTime)) {
            revert ErrorsLib.InsufficientUnlockedTokens();
        }

        // Unlock completion removes the time gate but never bypasses collateral requirements.
        uint256 available = dustExit ? amount : getAvailableForWithdrawal(tokenId);

        if (!dustExit && amount > positionAmount) {
            revert ErrorsLib.InsufficientTokenBalance();
        } else if (amount > available) {
            revert ErrorsLib.InsufficientUnlockedTokens();
        }

        uint256 sharesToBurn = amount == positionAmount
            ? positionShares_
            : Math.mulDiv(amount, currentTotalShares, totalProtectorTokens, Math.Rounding.Ceil);
        if (sharesToBurn > positionShares_) {
            sharesToBurn = positionShares_;
        }

        uint256 newShares = positionShares_ - sharesToBurn;
        uint256 newTotalShares = currentTotalShares - sharesToBurn;
        uint256 newAmount = 0;
        if (newShares != 0) {
            newAmount = _assetsFromProtectorShares(newShares, totalProtectorTokens - amount, newTotalShares);
        }
        if (newAmount != 0 && newAmount < poolConfig.backingMinDepositAmount) {
            revert ErrorsLib.PartialWithdrawalBelowMinimum();
        }

        // Settle pending commissions before changing share ownership so exits cannot orphan rewards.
        _claimCommissionTo(msg.sender, tokenId, positionShares_);
        if (IProtectorReceiptNFT(protectorReceiptNFT).ownerOf(tokenId) != msg.sender) {
            revert ErrorsLib.InvalidTokenId();
        }
        if (!dustExit) {
            if (_hasShieldedLiabilities()) {
                _requireNoOraclePendingChallenge(BACKING_TOKEN);
            }
            uint256 refreshedAvailable = getAvailableForWithdrawal(tokenId);
            if (amount > refreshedAvailable) {
                revert ErrorsLib.InsufficientUnlockedTokens();
            }
        }
        _redirectPendingProtectorRewardDust(ConstantsLib.MAX_SAFE_ACCUMULATION);

        if (newShares == 0) {
            // Full withdrawal - burn NFT and clean up mappings
            IProtectorReceiptNFT(protectorReceiptNFT).burn(tokenId);
            delete rewardDebt[tokenId];
            delete protectorShares[tokenId];
            delete protectorShareEpochs[tokenId];
            delete commissionsClaimed[tokenId];
        } else {
            // Partial withdrawal - reset to clean slate to avoid rounding exploits
            // Set rewardDebt to current accumulator for new amount (fresh start)
            rewardDebt[tokenId] = Math.mulDiv(rewardPerShareAccumulated, newShares, ConstantsLib.REWARD_PRECISION);
            // Clear commissions claimed - position gets fresh accounting
            delete commissionsClaimed[tokenId];
            protectorShares[tokenId] = newShares;
            protectorShareEpochs[tokenId] = protectorShareEpoch;
            IProtectorReceiptNFT(protectorReceiptNFT).updateAmount(tokenId, newAmount);
            // Re-arm the unlock window for the remaining position. Without this,
            // the already-elapsed unlockRequestTime persists, leaving the
            // remainder permanently in the "unlocked" state so the protector
            // could withdraw again with no fresh cooldown — defeating the
            // unlock-duration exit-notice protection shielders rely on. The
            // protector must call startUnlockProcess again before the remaining
            // position can exit. (Mirrors cancelUnlockProcess.)
            IProtectorReceiptNFT(protectorReceiptNFT).setUnlockRequestTime(tokenId, 0);
        }

        // Update pool balances (TOKEN-BASED)
        totalProtectorTokens -= amount;
        totalProtectorShares = newTotalShares;
        poolState.totalBackingTokenBalance -= amount;
        _redirectCurrentEpochOrphanedCommissions();

        // Verify pool has sufficient balance
        uint256 poolBalance = IERC20(preferredAsset).balanceOf(address(this));
        if (poolBalance < amount) {
            revert ErrorsLib.InsufficientTokenBalance();
        }

        uint256 actualReceived;
        if (amount != 0) {
            actualReceived = _transferOutAndGetReceived(preferredAsset, msg.sender, amount);
        }
        SlippageLib.enforceMinReceived(actualReceived, minAmountOut);

        emit EventsLib.ProtectorAssetWithdrawn(msg.sender, preferredAsset, actualReceived, sharesToBurn);
    }

    // View Functions
    /**
     * @notice Checks if an asset is supported by this pool
     * @dev Returns true if the asset is either the shielded token or backing token
     * @param asset The asset address to check
     * @return supported True if the asset is supported (SHIELDED_TOKEN or BACKING_TOKEN)
     */
    function isAssetSupported(address asset) external view returns (bool supported) {
        return asset == SHIELDED_TOKEN || asset == BACKING_TOKEN;
    }

    /// @notice Get the count of NFT positions owned by a user
    /// @dev Returns NFT counts, not token amounts. Query individual NFT positions for amounts.
    /// @param user The user address to query
    /// @return shieldNFTCount Number of shield position NFTs owned
    /// @return protectorNFTCount Number of protector position NFTs owned
    function getUserNFTCounts(address user) external view returns (uint256 shieldNFTCount, uint256 protectorNFTCount) {
        shieldNFTCount = IShieldReceiptNFT(shieldReceiptNFT).balanceOf(user);
        protectorNFTCount = IProtectorReceiptNFT(protectorReceiptNFT).balanceOf(user);
    }

    /// @notice Get the current pool token balances
    /// @dev Returns the tracked balances, not actual token balances (should be equal in normal operation)
    /// @return shieldedTokenPoolBalance Total shielded tokens held in pool
    /// @return totalBackingTokenPoolBalance Total backing tokens held in pool
    function getPoolBalances()
        external
        view
        returns (uint256 shieldedTokenPoolBalance, uint256 totalBackingTokenPoolBalance)
    {
        return (poolState.shieldedTokenBalance, poolState.totalBackingTokenBalance);
    }

    /**
     * @notice Gets comprehensive information about a protector position
     * @dev Aggregates position data, lock status, and claimable commission.
     *      Calculates locked and available amounts based on current utilization ratio.
     * @param tokenId The protector NFT token ID
     * @return amount Total deposited amount
     * @return depositTime Timestamp of deposit
     * @return unlockRequestTime Timestamp when unlock was requested (0 if not started)
     * @return lockedAmount Amount currently locked (calculated from utilization)
     * @return availableAmount Amount available for withdrawal
     * @return claimableCommission Commission amount that can be claimed
     */
    function getProtectorDepositInfo(uint256 tokenId)
        external
        view
        returns (
            uint256 amount,
            uint64 depositTime,
            uint64 unlockRequestTime,
            uint256 lockedAmount,
            uint256 availableAmount,
            uint256 claimableCommission
        )
    {
        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(protectorReceiptNFT).getPosition(tokenId);
        amount = getProtectorPositionAmount(tokenId);
        depositTime = pos.depositTime;
        unlockRequestTime = pos.unlockRequestTime;
        lockedAmount = getLockedAmount(tokenId);
        availableAmount = getAvailableForWithdrawal(tokenId);
        claimableCommission = getClaimableCommission(tokenId);
    }

    /**
     * @notice Gets comprehensive information about a shielded position
     * @dev Returns position data including deposit time, stored USD value, and withdrawal status.
     *      valueAtDeposit is locked at deposit time for cross-asset withdrawal calculations.
     * @param tokenId The shield NFT token ID
     * @return amount Current token amount
     * @return depositTime Timestamp of deposit
     * @return valueAtDeposit USD value at deposit time (locked for cross-asset withdrawals)
     * @return lastFeeClaimTime Last time fees were calculated (timestamp)
     */
    function getShieldDepositInfo(uint256 tokenId)
        external
        view
        returns (uint256 amount, uint64 depositTime, uint256 valueAtDeposit, uint64 lastFeeClaimTime)
    {
        IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(shieldReceiptNFT).getPosition(tokenId);
        amount = pos.amount;
        depositTime = pos.depositTime;
        valueAtDeposit = pos.valueAtDeposit;
        lastFeeClaimTime = pos.lastFeeClaimTime;
    }

    /**
     * @notice Gets oracle configuration and status information for this pool
     * @dev Detects if the oracle is a CompositeOracle with dual-feed support and returns
     *      additional information about primary/backup feeds and active status.
     *      Uses try-catch to gracefully handle non-CompositeOracle oracles.
     * @return oracle The address of the price oracle
     * @return isDualOracle True if the oracle supports dual-feed for this pool's shielded token
     * @return primaryFeed Address of primary feed (if dual-oracle, otherwise address(0))
     * @return backupFeed Address of backup feed (if dual-oracle, otherwise address(0))
     * @return isBackupActive True if backup oracle is currently active (if dual-oracle, otherwise false)
     */
    function getOracleInfo()
        external
        view
        returns (address oracle, bool isDualOracle, address primaryFeed, address backupFeed, bool isBackupActive)
    {
        oracle = poolConfig.priceOracle;

        // Check if oracle is a CompositeOracle with dual-feed support for this token
        try ICompositeOracle(oracle).getTokenDualFeedStatus(SHIELDED_TOKEN) returns (
            bool _isDualFeed,
            address _primaryFeed,
            address _backupFeed,
            bool _isBackupActive,
            bool, // isChallengePending - not needed here
            uint256 // challengeStartTime - not needed here
        ) {
            isDualOracle = _isDualFeed;
            primaryFeed = _primaryFeed;
            backupFeed = _backupFeed;
            isBackupActive = _isBackupActive;
        } catch {
            // Not a CompositeOracle or doesn't support dual-feed query
            isDualOracle = false;
            primaryFeed = address(0);
            backupFeed = address(0);
            isBackupActive = false;
        }
    }

    /* Governance Functions */
    /**
     * @notice Updates all pool configuration parameters
     * @dev Only callable by governance timelock. Validates all parameters to ensure
     *      they are within acceptable bounds.
     * @param newShieldedMinDepositAmount New minimum shielded deposit amount
     * @param newShieldedMaxDepositAmount New maximum shielded deposit amount
     * @param newBackingMinDepositAmount New minimum backing deposit amount
     * @param newBackingMaxDepositAmount New maximum backing deposit amount
     * @param newMaxTotalValueLockedUsd New maximum total value locked in USD (8 decimals)
     * @param newMinimumPoolTime New minimum pool time in seconds
     * @param newUnlockDuration New unlock duration in seconds
     * @param newProtocolFee New protocol fee rate in basis points
     * @param newProtocolFeeRecipient New protocol fee recipient address
     * @param newPriceOracle New price oracle address
     * @custom:error InvalidDepositAmountBounds If either asset's min deposit is >= its max deposit
     * @custom:error InvalidProtocolFee If protocol fee exceeds maximum
     * @custom:error InvalidProtocolFeeRecipient If recipient is zero address
     * @custom:error InvalidUnlockDuration If duration is outside allowed bounds
     * @custom:error InvalidMinimumPoolTime If minimum pool time exceeds maximum allowed
     */
    function updatePoolConfig(
        uint256 newShieldedMinDepositAmount,
        uint256 newShieldedMaxDepositAmount,
        uint256 newBackingMinDepositAmount,
        uint256 newBackingMaxDepositAmount,
        uint256 newMaxTotalValueLockedUsd,
        uint256 newMinimumPoolTime,
        uint256 newUnlockDuration,
        uint256 newProtocolFee,
        address newProtocolFeeRecipient,
        address newPriceOracle
    ) external onlyGovernance {
        if (
            newShieldedMinDepositAmount >= newShieldedMaxDepositAmount
                || newBackingMinDepositAmount >= newBackingMaxDepositAmount
        ) {
            revert ErrorsLib.InvalidDepositAmountBounds();
        }

        if (
            newShieldedMaxDepositAmount > ConstantsLib.MAX_SAFE_ACCUMULATION
                || newBackingMaxDepositAmount > ConstantsLib.MAX_SAFE_ACCUMULATION
        ) {
            revert ErrorsLib.DepositAmountTooLarge();
        }

        if (newProtocolFee > ConstantsLib.MAX_PROTOCOL_FEE) {
            revert ErrorsLib.InvalidProtocolFee();
        }

        _validateFeeRecipient(newProtocolFeeRecipient);

        if (
            newUnlockDuration < ConstantsLib.MIN_UNLOCK_DURATION || newUnlockDuration > ConstantsLib.MAX_UNLOCK_DURATION
        ) {
            revert ErrorsLib.InvalidUnlockDuration();
        }

        if (newMinimumPoolTime > ConstantsLib.MAX_MINIMUM_POOL_TIME) {
            revert ErrorsLib.InvalidMinimumPoolTime();
        }

        if (newPriceOracle == address(0)) {
            revert ErrorsLib.InvalidAssetAddress();
        }

        PoolOracleValidationLib.validatePoolOracle(
            newPriceOracle, SHIELDED_TOKEN, BACKING_TOKEN, _requiresStrictProtectedBackingPrice()
        );

        poolConfig.shieldedMinDepositAmount = newShieldedMinDepositAmount;
        poolConfig.shieldedMaxDepositAmount = newShieldedMaxDepositAmount;
        poolConfig.backingMinDepositAmount = newBackingMinDepositAmount;
        poolConfig.backingMaxDepositAmount = newBackingMaxDepositAmount;
        poolConfig.maxTotalValueLockedUsd = newMaxTotalValueLockedUsd;
        poolConfig.minimumPoolTime = newMinimumPoolTime;
        poolConfig.unlockDuration = newUnlockDuration;
        poolConfig.protocolFeeRecipient = newProtocolFeeRecipient;
        poolConfig.protocolFee = uint96(newProtocolFee); // Safe: validated <= MAX_PROTOCOL_FEE (1000)
        poolConfig.priceOracle = newPriceOracle;

        emit EventsLib.PoolConfigUpdated(
            newShieldedMinDepositAmount,
            newShieldedMaxDepositAmount,
            newBackingMinDepositAmount,
            newBackingMaxDepositAmount,
            newMaxTotalValueLockedUsd,
            newMinimumPoolTime,
            newUnlockDuration,
            newProtocolFee,
            newProtocolFeeRecipient,
            newPriceOracle
        );
    }

    /// @notice Updates the shield NFT transfer lock period
    /// @dev Only callable by governance timelock.
    /// @param newPeriod New transfer lock period in seconds
    function setShieldTransferLockPeriod(uint256 newPeriod) external onlyGovernance {
        IShieldReceiptNFT(shieldReceiptNFT).setTransferLockPeriod(newPeriod);
        emit EventsLib.ParameterUpdated("shieldTransferLockPeriod", newPeriod);
    }

    /// @notice Updates the protector NFT transfer lock period
    /// @dev Only callable by governance timelock.
    /// @param newPeriod New transfer lock period in seconds
    function setProtectorTransferLockPeriod(uint256 newPeriod) external onlyGovernance {
        IProtectorReceiptNFT(protectorReceiptNFT).setTransferLockPeriod(newPeriod);
        emit EventsLib.ParameterUpdated("protectorTransferLockPeriod", newPeriod);
    }

    /// @notice Returns the governance timelock address
    /// @return The address of the governance timelock contract
    function governanceTimelock()
        public
        view
        override(ISplitRiskPool, ProtocolAccessControlUpgradeable)
        returns (address)
    {
        return ProtocolAccessControlUpgradeable.governanceTimelock();
    }

    /**
     * @notice Sets the governance timelock address
     * @dev Only callable by governance. Updates the timelock address used
     *      for governance-controlled operations.
     * @param newGovernanceTimelock The new governance timelock address
     * @custom:error InvalidGovernanceTimelock If new address is zero
     */
    function setGovernanceTimelock(address newGovernanceTimelock)
        public
        override(ProtocolAccessControlUpgradeable)
        onlyGovernance
    {
        _requireFactoryGovernanceTransferAlignment(newGovernanceTimelock);
        ProtocolAccessControlUpgradeable.setGovernanceTimelock(newGovernanceTimelock);
    }

    function _requireFactoryGovernanceTransferAlignment(address newGovernanceTimelock) internal view {
        address factory = _poolFactoryController();
        if (factory == address(0) || !_isPoolFactoryLikeController(factory)) {
            return;
        }

        (bool success, bytes memory data) =
            factory.staticcall(abi.encodeCall(ISplitRiskPoolFactory.pendingGovernanceTimelock, ()));
        if (!success || data.length < 32) {
            return;
        }

        address factoryPendingGovernance = abi.decode(data, (address));
        if (factoryPendingGovernance != address(0) && newGovernanceTimelock != factoryPendingGovernance) {
            revert InvalidGovernanceTimelock(newGovernanceTimelock);
        }
    }

    function setGovernanceTimelockFromFactory(address newGovernanceTimelock) external override {
        address factory = _poolFactoryController();
        if (msg.sender != factory) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "setGovernanceTimelockFromFactory");
        }
        if (ISplitRiskPoolFactory(factory).pendingGovernanceTimelock() != newGovernanceTimelock) {
            revert InvalidGovernanceTimelock(newGovernanceTimelock);
        }

        _validateGovernanceTimelock(newGovernanceTimelock, _governanceTimelockImplementationHash());
        _validateGovernanceTimelockOperationalRolesMatch(newGovernanceTimelock, _governanceTimelock);
        _validateKnownDefaultAdminCleared(newGovernanceTimelock, owner());
        _validateKnownDefaultAdminCleared(newGovernanceTimelock, _governanceTimelock);
        _pendingGovernanceTimelock = newGovernanceTimelock;
        emit GovernanceTimelockTransferStarted(_governanceTimelock, newGovernanceTimelock);
    }

    /// @notice Completes the two-step governance transfer
    /// @dev Only callable by the pending governance address
    function acceptGovernanceTimelock() public override(ProtocolAccessControlUpgradeable) {
        address previousGovernance = governanceTimelock();
        ProtocolAccessControlUpgradeable.acceptGovernanceTimelock();

        if (poolConfig.protocolFeeRecipient == previousGovernance) {
            poolConfig.protocolFeeRecipient = governanceTimelock();
            emit EventsLib.ProtocolFeeRecipientUpdated(previousGovernance, poolConfig.protocolFeeRecipient);
        }
    }

    function acceptGovernanceTimelockFromFactory(address expectedGovernanceTimelock) external override {
        address factory = _poolFactoryController();
        if (msg.sender != factory) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "acceptGovernanceTimelockFromFactory");
        }
        if (
            _pendingGovernanceTimelock == address(0) || _pendingGovernanceTimelock != expectedGovernanceTimelock
                || ISplitRiskPoolFactory(factory).governanceTimelock() != expectedGovernanceTimelock
        ) {
            revert InvalidGovernanceTimelock(expectedGovernanceTimelock);
        }

        _validateGovernanceTimelock(_pendingGovernanceTimelock, _governanceTimelockImplementationHash());
        _validateGovernanceTimelockOperationalRolesMatch(_pendingGovernanceTimelock, _governanceTimelock);
        _validateKnownDefaultAdminCleared(_pendingGovernanceTimelock, owner());
        _validateKnownDefaultAdminCleared(_pendingGovernanceTimelock, _governanceTimelock);
        address previousGovernance = _governanceTimelock;
        emit GovernanceTimelockUpdated(previousGovernance, _pendingGovernanceTimelock);
        _governanceTimelock = _pendingGovernanceTimelock;
        _governanceTimelockCodehash = _pendingGovernanceTimelock.codehash;
        _pendingGovernanceTimelock = address(0);

        if (owner() == previousGovernance) {
            _transferOwnership(_governanceTimelock);
        }
        if (poolConfig.protocolFeeRecipient == previousGovernance) {
            poolConfig.protocolFeeRecipient = _governanceTimelock;
            emit EventsLib.ProtocolFeeRecipientUpdated(previousGovernance, poolConfig.protocolFeeRecipient);
        }
    }

    /// @notice Returns the pending governance timelock address
    function pendingGovernanceTimelock()
        public
        view
        override(ISplitRiskPool, ProtocolAccessControlUpgradeable)
        returns (address)
    {
        return ProtocolAccessControlUpgradeable.pendingGovernanceTimelock();
    }

    /// @notice Pauses the pool, blocking deposits and withdrawals
    /// @dev Only callable by governance for emergency situations
    function pause() public override(ISplitRiskPool, ProtocolAccessControlUpgradeable) onlyGovernance {
        ProtocolAccessControlUpgradeable.pause();
    }

    /// @notice Pauses the pool for factory-led close and deactivation flows
    /// @dev Only callable by the pinned deploying factory. This keeps the public
    ///      emergency pause under timelock control while still letting the factory
    ///      freeze an empty pool immediately before shutdown bookkeeping.
    function pauseFromFactory() external {
        if (msg.sender != _poolFactoryController()) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "pauseFromFactory");
        }
        _pause();
    }

    /// @notice Lets the factory clear a dust-only protector side before governance deactivates the pool.
    /// @dev This is intentionally narrower than normal withdrawals: it only applies when there
    ///      are no shielded liabilities, no reserved fees, and backing is at or below the pool
    ///      minimum deposit amount. The residual is swept to the protocol fee recipient and
    ///      the creation bond can then be forfeited by the factory.
    function sweepInactiveProtectorBackingDustFromFactory()
        external
        nonReentrant
        whenPaused
        returns (uint256 sweptAmount)
    {
        if (msg.sender != _poolFactoryController()) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "sweepInactiveProtectorBackingDustFromFactory");
        }
        if (
            totalShieldedTokens != 0 || totalValueAtDeposit != 0 || totalShieldCollateralAmount != 0
                || getReservedFees() != 0 || poolState.shieldedTokenBalance != 0
                || poolState.totalBackingTokenBalance != totalProtectorTokens
        ) {
            revert ErrorsLib.PoolNotEmptyForDeactivation();
        }
        _requireAccountingBalanceCovered(BACKING_TOKEN, poolState.totalBackingTokenBalance);

        sweptAmount = totalProtectorTokens;
        if (sweptAmount == 0) {
            return 0;
        }
        if (sweptAmount > poolConfig.backingMinDepositAmount) {
            revert ErrorsLib.PoolNotEmptyForDeactivation();
        }
        if (totalProtectorShares != 0) {
            revert ErrorsLib.PoolNotEmptyForDeactivation();
        }

        totalProtectorTokens = 0;
        poolState.totalBackingTokenBalance = 0;
        uint256 received = _transferOutAndGetReceived(BACKING_TOKEN, poolConfig.protocolFeeRecipient, sweptAmount);
        emit EventsLib.ProtectorResidualBackingSwept(poolConfig.protocolFeeRecipient, BACKING_TOKEN, received);
    }

    /// @notice Sweeps ERC20 balances that arrived outside pool accounting.
    /// @dev Factory-only cleanup for close/deactivation flows. User principal and
    ///      reserved fees must remain accounted; deficits still fail closed.
    function sweepUnaccountedSurplusFromFactory()
        external
        nonReentrant
        returns (uint256 shieldedSweptAmount, uint256 backingSweptAmount)
    {
        if (msg.sender != _poolFactoryController()) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "sweepUnaccountedSurplusFromFactory");
        }
        if (
            totalShieldedTokens != 0 || totalValueAtDeposit != 0 || totalShieldCollateralAmount != 0
                || getReservedFees() != 0 || poolState.shieldedTokenBalance != 0
                || poolState.totalBackingTokenBalance != totalProtectorTokens
        ) {
            revert ErrorsLib.PoolNotEmptyForDeactivation();
        }

        address recipient = poolConfig.protocolFeeRecipient;
        shieldedSweptAmount = _sweepUnaccountedTokenSurplus(SHIELDED_TOKEN, poolState.shieldedTokenBalance, recipient);
        backingSweptAmount = _sweepUnaccountedTokenSurplus(BACKING_TOKEN, poolState.totalBackingTokenBalance, recipient);
    }

    function _sweepUnaccountedTokenSurplus(address token, uint256 accountedBalance, address recipient)
        internal
        returns (uint256 sweptAmount)
    {
        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        if (actualBalance < accountedBalance) {
            revert ErrorsLib.AccountedBalanceExceedsTokenBalance(token, accountedBalance, actualBalance);
        }

        sweptAmount = actualBalance - accountedBalance;
        if (sweptAmount == 0) {
            return 0;
        }

        uint256 received = _transferOutAndGetReceived(token, recipient, sweptAmount);
        emit EventsLib.PoolUnaccountedSurplusSwept(recipient, token, sweptAmount, received);
    }

    /// @notice Unpauses the pool, resuming normal operations
    /// @dev Only callable by governance
    function unpause() public override(ProtocolAccessControlUpgradeable) onlyGovernance {
        ProtocolAccessControlUpgradeable.unpause();
    }

    /// @notice Clears a shielded-token transfer-integrity suspension after governance validates a clean round trip.
    /// @dev Governance is the timelock. If the pool still accounts for shielded-token liabilities,
    ///      `probeAmount` must be nonzero and must round-trip exactly through a third-party probe.
    function resetShieldedTokenTransferIntegrity(uint256 probeAmount) external onlyGovernance {
        if (!shieldedTokenTransferIntegrityBroken) {
            return;
        }

        uint256 accountedShieldedBalance = poolState.shieldedTokenBalance;
        if (accountedShieldedBalance != 0) {
            if (probeAmount == 0) {
                revert ErrorsLib.TransferIntegrityProbeRequired(SHIELDED_TOKEN);
            }
            _requireAccountingBalanceCovered(SHIELDED_TOKEN, accountedShieldedBalance);
            if (probeAmount > IERC20(SHIELDED_TOKEN).balanceOf(address(this))) {
                revert ErrorsLib.InsufficientTokenBalance();
            }
            _requireUntaxedShieldedRoundTrip(probeAmount);
        }

        shieldedTokenTransferIntegrityBroken = false;
        emit ShieldedTokenTransferIntegrityRestored(SHIELDED_TOKEN, probeAmount);
    }

    /// @notice Returns whether the pool is currently paused
    function paused() public view override(ISplitRiskPool, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    function _authorizeUpgrade(address) internal pure override {
        revert ErrorsLib.UpgradeDisabled();
    }

    function _poolFactoryController() internal view returns (address factory) {
        factory = POOL_FACTORY;
        if (factory == address(0)) {
            factory = owner();
        }
    }

    function _requireActiveFactoryPoolForDeposit() internal view {
        address factory = _poolFactoryController();
        if (factory == address(0) || !_isPoolFactoryLikeController(factory)) {
            return;
        }

        (bool success, bytes memory data) =
            factory.staticcall(abi.encodeCall(ISplitRiskPoolFactory.isPoolActive, (address(this))));
        if (!success || data.length < 32 || !abi.decode(data, (bool))) {
            revert ErrorsLib.PoolNotActive();
        }
    }

    /**
     * @notice Sets the access control contract address for pool operations
     * @dev Governance can change ACL at any time. The pool creator may only configure ACL
     *      before the first successful deposit. Sets address(0) to disable access control.
     *      Validates the interface to prevent bricking the pool with an invalid contract.
     * @param newAccessControl The new access control contract address (address(0) to disable)
     * @custom:error InvalidPoolCreator If caller is not the pool creator
     * @custom:error InvalidAccessControlAddress If contract doesn't implement IPoolAccessControl
     */
    function setAccessControl(address newAccessControl) external {
        bool callerIsGovernance = msg.sender == _governanceTimelock;
        bool callerIsCreatorBeforeLaunch = msg.sender == POOL_CREATOR && !governanceAccessControlInstalled
            && !hasEverLaunched && totalShieldedTokens == 0 && totalProtectorTokens == 0;
        if (!callerIsGovernance && !callerIsCreatorBeforeLaunch) {
            revert ErrorsLib.InvalidPoolCreator();
        }

        // Validate interface if not disabling access control
        if (newAccessControl != address(0)) {
            _validateAccessControl(newAccessControl);
        }

        bool depositsGated = newAccessControl != address(0);
        bool withdrawalsGated =
            callerIsGovernance && depositsGated && _accessControlAuthorityIsGovernance(newAccessControl);

        emit EventsLib.AccessControlUpdated(accessControl, newAccessControl);
        accessControl = newAccessControl;
        accessControlCanGateWithdrawals = withdrawalsGated;
        if (callerIsGovernance && newAccessControl != address(0)) {
            governanceAccessControlInstalled = true;
        }
        emit EventsLib.AccessControlStatusUpdated(
            newAccessControl, depositsGated, withdrawalsGated, governanceAccessControlInstalled
        );
    }

    function getAccessControlStatus()
        external
        view
        returns (address activeAccessControl, bool depositsGated, bool withdrawalsGated, bool governanceInstalled)
    {
        activeAccessControl = accessControl;
        depositsGated = activeAccessControl != address(0);
        withdrawalsGated = _withdrawalAccessControlActive();
        governanceInstalled = governanceAccessControlInstalled;
    }

    function _validateAccessControl(address newAccessControl) internal view {
        // L-15: probe each hook with two distinct addresses (zero + a known
        // non-zero) so a malicious ACL that returns true for address(0) but
        // reverts for every real caller can't pass validation.
        address probe = address(this);
        _validateAccessControlHook(
            newAccessControl, abi.encodeCall(IPoolAccessControl.canDepositShielded, (address(0)))
        );
        _validateAccessControlHook(newAccessControl, abi.encodeCall(IPoolAccessControl.canDepositShielded, (probe)));
        _validateAccessControlHook(
            newAccessControl, abi.encodeCall(IPoolAccessControl.canWithdrawShielded, (address(0)))
        );
        _validateAccessControlHook(newAccessControl, abi.encodeCall(IPoolAccessControl.canWithdrawShielded, (probe)));
        _validateAccessControlHook(
            newAccessControl, abi.encodeCall(IPoolAccessControl.canDepositProtector, (address(0)))
        );
        _validateAccessControlHook(newAccessControl, abi.encodeCall(IPoolAccessControl.canDepositProtector, (probe)));
        _validateAccessControlHook(
            newAccessControl, abi.encodeCall(IPoolAccessControl.canWithdrawProtector, (address(0)))
        );
        _validateAccessControlHook(newAccessControl, abi.encodeCall(IPoolAccessControl.canWithdrawProtector, (probe)));
    }

    function _validateAccessControlHook(address newAccessControl, bytes memory callData) internal view {
        (bool success, bytes memory returndata) = newAccessControl.staticcall(callData);
        if (!success || returndata.length != 32) revert ErrorsLib.InvalidAccessControlAddress();

        // Decode the response to ensure the hook returns a bool.
        abi.decode(returndata, (bool));
    }

    function _withdrawalAccessControlActive() internal view returns (bool) {
        address activeAccessControl = accessControl;
        return accessControlCanGateWithdrawals && activeAccessControl != address(0)
            && _accessControlAuthorityIsGovernance(activeAccessControl);
    }

    function _accessControlAuthorityIsGovernance(address candidateAccessControl) internal view returns (bool) {
        if (candidateAccessControl == address(0)) {
            return false;
        }

        (bool ownerCallSucceeded, bytes memory ownerData) =
            candidateAccessControl.staticcall(abi.encodeWithSignature("owner()"));
        if (ownerCallSucceeded && ownerData.length >= 32 && abi.decode(ownerData, (address)) == _governanceTimelock) {
            return true;
        }

        bytes32 defaultAdminRole = bytes32(0);
        (bool countCallSucceeded, bytes memory countData) = candidateAccessControl.staticcall(
            abi.encodeWithSignature("getRoleMemberCount(bytes32)", defaultAdminRole)
        );
        if (!countCallSucceeded || countData.length < 32 || abi.decode(countData, (uint256)) != 1) {
            return false;
        }

        (bool memberCallSucceeded, bytes memory memberData) = candidateAccessControl.staticcall(
            abi.encodeWithSignature("getRoleMember(bytes32,uint256)", defaultAdminRole, 0)
        );
        return
            memberCallSucceeded && memberData.length >= 32 && abi.decode(memberData, (address)) == _governanceTimelock;
    }

    function _validateFeeRecipient(address recipient) internal view {
        if (recipient == address(0) || recipient == address(this)) {
            revert ErrorsLib.InvalidProtocolFeeRecipient();
        }
    }

    function _requireProtectorWithdrawalAllowed(address account, string memory operation) internal view {
        if (_withdrawalAccessControlActive() && !IPoolAccessControl(accessControl).canWithdrawProtector(account)) {
            revert ErrorsLib.AccessControlDenied(account, operation);
        }
    }

    function _markPoolLaunched() internal {
        if (!hasEverLaunched) {
            hasEverLaunched = true;
            emit EventsLib.ParameterUpdated("hasEverLaunched", 1);
        }
    }

    function _getTokenMetadata(address token) internal view returns (uint8 tokenDecimals, uint256 tokenScale) {
        try IERC20Metadata(token).decimals() returns (uint8 reportedDecimals) {
            tokenDecimals = reportedDecimals;
        } catch {
            revert ErrorsLib.InvalidTokenAddress();
        }

        if (
            tokenDecimals < ConstantsLib.MIN_POOL_TOKEN_DECIMALS || tokenDecimals > ConstantsLib.MAX_POOL_TOKEN_DECIMALS
        ) {
            revert ErrorsLib.InvalidTokenDecimals(token, tokenDecimals);
        }

        tokenScale = 10 ** tokenDecimals;
    }

    /* ETH Transfer Protection */

    /// @notice Reject direct ETH transfers
    receive() external payable {
        revert ErrorsLib.EtherTransferNotAllowed();
    }

    /// @notice Reject unknown function calls
    fallback() external {
        revert ErrorsLib.EtherTransferNotAllowed();
    }

    /**
     * @dev Storage gap for future upgrades.
     * This ensures that future versions of this contract can add new storage variables
     * without colliding with storage variables in derived contracts.
     * The remaining slots shrink as upgrade state is appended below.
     */
    /// @notice Cached shielded token decimals for native-unit accounting
    uint8 public shieldedTokenDecimals;
    /// @notice Cached backing token decimals for native-unit accounting
    uint8 public backingTokenDecimals;
    /// @notice Cached 10**shieldedTokenDecimals
    uint256 public shieldedTokenScale;
    /// @notice Cached 10**backingTokenDecimals
    uint256 public backingTokenScale;
    /// @notice Sum of all protector ownership shares for loss socialization
    uint256 public totalProtectorShares;
    /// @notice tokenId => loss-socialized ownership shares
    mapping(uint256 => uint256) public protectorShares;
    /// @notice Sticky launch flag used to lock creator-only ACL changes after first deposit
    /// @dev Layout-stable: this field has occupied this slot since the original
    ///      deployment. Do NOT insert new state above it — append after, claiming
    ///      slots from `__gap`, so existing proxy storage remains valid on upgrade.
    bool public hasEverLaunched;
    /// @notice Current protector share generation; increments when a shield activation wipes all backing assets
    /// @dev Appended after `hasEverLaunched` in upgrade-safe order: existing proxies
    ///      had this slot zero-initialised inside the prior `__gap`, so the value
    ///      reads as 0 on first upgrade — matching the intended initial epoch.
    uint256 public protectorShareEpoch;
    /// @notice tokenId => share generation used to exclude wiped shares from future backing deposits
    mapping(uint256 => uint256) public protectorShareEpochs;
    /// @notice share generation => reward-per-share cap for historical commission claims
    mapping(uint256 => uint256) public protectorEpochFinalRewardPerShare;
    /// @notice True when governance installed the active ACL as withdrawal-gating eligible.
    /// @dev Live governance authority over the ACL is rechecked before each withdrawal gate.
    bool public accessControlCanGateWithdrawals;
    /// @notice True after governance has installed a withdrawal-gating ACL at least once.
    bool public governanceAccessControlInstalled;
    /// @notice Commissions owed to the current active protector share epoch
    uint256 public currentEpochCommissionReserve;
    /// @notice Commissions still owed to expired protector share epochs
    uint256 public historicalCommissionReserve;
    /// @notice share generation => shares that have not yet settled expired-epoch commissions
    mapping(uint256 => uint256) public protectorEpochRemainingShares;
    /// @notice share generation => expired-epoch commission reserve that can still be claimed or swept as dust
    mapping(uint256 => uint256) public protectorEpochRemainingReserve;
    /// @notice tokenId => whether its expired-epoch shares have been settled
    mapping(uint256 => bool) public protectorEpochPositionSettled;
    /// @notice Factory pinned at initialization for shared policy lookups and shutdown hooks
    /// @dev Legacy pools upgraded from older versions read this as zero and fall back to owner().
    address public POOL_FACTORY;
    /// @notice H-5: strict-protected-backing-price requirement, pinned at initialize.
    /// @dev Snapshotted from the factory's tokenRequiresStrictProtectedPrice(BACKING_TOKEN)
    ///      at deploy time. A future factory upgrade or storage-layout regression cannot
    ///      silently downgrade strict pricing for live pools. Governance can refresh via
    ///      `refreshStrictProtectedBackingPriceFlag()`.
    bool internal _strictProtectedBackingPriceAtInit;
    /// @notice One-bit tracker for whether the strict snapshot has been initialized or refreshed.
    /// @dev Retained as part of the storage layout even though pricing now reads the pinned value directly.
    bool internal _strictProtectedBackingPricePinned;
    /// @notice M-14: explicit recipient for accumulated pool fees, rotatable by
    ///         POOL_CREATOR. Defaults to POOL_CREATOR at initialize; legacy
    ///         upgraded pools read this as zero and the payPoolFee path falls
    ///         back to POOL_CREATOR.
    address public poolFeeRecipient;
    /// @notice Protector commission dust reserved until it becomes share-distributable.
    uint256 public pendingProtectorRewardDust;
    /// @notice True once the shielded token has charged transfer tax against this pool.
    bool public shieldedTokenTransferIntegrityBroken;
    uint256[27] private __gap;
}
