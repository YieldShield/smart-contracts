// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

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
    /// @dev Invariant: totalShieldedTokens == sum of all pos.amount where !pos.isWithdrawn
    ///      Maintained by:
    ///      - depositShieldedAsset: += received
    ///      - shieldedWithdraw: -= pos.amount (full original amount)
    ///      - partialWithdrawShielded: -= (withdrawAmount + totalFees)
    ///      - claimRewards: -= totalFees
    uint256 public totalShieldedTokens;
    uint256 public totalProtectorTokens; // Sum of all active protector backing claims in native backing token units

    /// @notice Sum of all active shielded position original deposit values (8 decimals, USD-based)
    /// @dev Invariant: totalValueAtDeposit == sum of all pos.valueAtDeposit where !pos.isWithdrawn
    ///      Used for collateralization checks based on original deposit values (not current token amounts).
    ///      Maintained by:
    ///      - depositShieldedAsset: += valueAtDeposit
    ///      - shieldedWithdraw: -= pos.valueAtDeposit (full original value)
    ///      - partialWithdrawShielded: -= pos.valueAtDeposit, then += (pos.valueAtDeposit * remaining / pos.amount)
    ///      - claimRewards: Does NOT change (original deposit value remains the same)
    uint256 public totalValueAtDeposit;

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
    mapping(uint256 => uint256) public lastClaimRewardsTime; // tokenId => last claim timestamp

    /* Per-position fee baselines (USD, 8 decimals) to prevent re-taxing already charged yield */
    mapping(uint256 => uint256) public feeValueBaselineUsd; // tokenId => last value baseline used for fee accrual

    /* Migration tracking for legacy positions */
    mapping(uint256 => bool) public positionMigrated; // tokenId => whether position has been migrated

    /* Errors */
    using ErrorsLib for *;

    /* Pool Events */
    using EventsLib for *;

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
        if (_shieldedTokenInfo.token == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_backingTokenInfo.token == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_poolCreator == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_protocolFeeRecipient == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_shieldReceiptNFT == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_protectorReceiptNFT == address(0)) revert ErrorsLib.InvalidAssetAddress();
        if (_backingTokenInfo.token == _shieldedTokenInfo.token) revert ErrorsLib.InvalidAssetAddress();
        if (_commissionRate > ConstantsLib.MAX_COMMISSION_RATE) revert ErrorsLib.InvalidCommissionRate();
        if (_poolFee > ConstantsLib.MAX_POOL_FEE) revert ErrorsLib.InvalidPoolFee();
        if (
            _collateralRatio < ConstantsLib.MIN_COLLATERAL_RATIO || _collateralRatio > ConstantsLib.MAX_COLLATERAL_RATIO
        ) {
            revert ErrorsLib.InvalidCollateralRatio();
        }

        __ProtocolAccessControl_init(initialOwner, _governanceTimelock);
        __UUPSUpgradeable_init();

        SHIELDED_TOKEN = _shieldedTokenInfo.token;
        COMMISSION_RATE = _commissionRate;
        POOL_FEE = _poolFee;
        POOL_CREATOR = _poolCreator;
        COLLATERAL_RATIO = _collateralRatio;
        BACKING_TOKEN = _backingTokenInfo.token;
        (shieldedTokenDecimals, shieldedTokenScale) = _getTokenMetadata(_shieldedTokenInfo.token);
        (backingTokenDecimals, backingTokenScale) = _getTokenMetadata(_backingTokenInfo.token);

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
    }

    /**
     * @notice Get the current utilization ratio of the pool (token-based estimation)
     * @dev Calculates utilization using TOKEN-BASED accounting (no oracle needed).
     *      This is an estimation that may differ from the USD-based version.
     *      Returns the ratio of required collateral to total protector tokens.
     * @return utilizationRatio Utilization ratio in basis points (0-10000 = 0%-100%)
     */
    function getUtilizationRatio() public view returns (uint256) {
        // slither-disable-next-line incorrect-equality — division-by-zero guard, not exploitable
        if (totalProtectorTokens == 0) return 0;
        // M-4 FIX: Multiply before divide to avoid precision loss
        // (totalShieldedTokens * COLLATERAL_RATIO) gives utilization in basis points directly
        return (totalShieldedTokens * COLLATERAL_RATIO) / totalProtectorTokens;
    }

    /// @dev Returns the active protector-share supply, defaulting legacy pools to 1:1 accounting.
    function _currentTotalProtectorShares() internal view returns (uint256) {
        uint256 recordedShares = totalProtectorShares;
        return recordedShares == 0 ? totalProtectorTokens : recordedShares;
    }

    /// @dev Initializes share supply for legacy pools before the first loss-socializing mutation.
    function _ensureProtectorSharesInitialized() internal {
        if (totalProtectorShares == 0 && totalProtectorTokens != 0) {
            totalProtectorShares = totalProtectorTokens;
        }
    }

    /// @dev Returns the protector shares for a token, treating legacy positions as 1:1 shares.
    function _getProtectorPositionShares(uint256 tokenId, IProtectorReceiptNFT.ProtectorPosition memory pos)
        internal
        view
        returns (uint256)
    {
        uint256 recordedShares = protectorShares[tokenId];
        if (recordedShares == 0 && pos.amount != 0) {
            return pos.amount;
        }
        return recordedShares;
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
        return _assetsFromProtectorShares(shares, totalProtectorTokens, _currentTotalProtectorShares());
    }

    /// @notice Returns the current backing-token claim for a protector position.
    function getProtectorPositionAmount(uint256 tokenId) public view returns (uint256) {
        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(protectorReceiptNFT).getPosition(tokenId);
        uint256 shares = _getProtectorPositionShares(tokenId, pos);
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
        requiredCollateralUsd = (shieldedValueUsd * COLLATERAL_RATIO) / ConstantsLib.BASIS_POINT_SCALE;
    }

    /// @dev Returns backing-token price using the oracle's strongest available protection.
    function _getProtectedBackingPrice() internal view returns (uint256 price) {
        if (_requiresStrictProtectedBackingPrice()) {
            (bool strictSuccess, uint256 strictPrice) = _tryGetStrictProtectedBackingPrice();
            if (strictSuccess) {
                return strictPrice;
            }
        }

        price = IPriceOracle(poolConfig.priceOracle).getPriceWithCircuitBreaker(BACKING_TOKEN);
        if (price == 0) revert ErrorsLib.InvalidOraclePrice();
    }

    /// @dev Returns the current shielded-token price using the strongest available protection.
    function _getShieldedPrice() internal view returns (uint256 price) {
        price = IPriceOracle(poolConfig.priceOracle).getPriceWithCircuitBreaker(SHIELDED_TOKEN);
        if (price == 0) revert ErrorsLib.InvalidOraclePrice();
    }

    /// @dev Returns the current shielded-token spot price for non-critical TVL estimation paths.
    function _getShieldedSpotPrice() internal view returns (uint256 price) {
        price = IPriceOracle(poolConfig.priceOracle).getPrice(SHIELDED_TOKEN);
        if (price == 0) revert ErrorsLib.InvalidOraclePrice();
    }

    /// @dev Best-effort wrapper for protected shielded-token pricing.
    function _tryGetShieldedProtectedPrice() internal view returns (bool success, uint256 price) {
        try IPriceOracle(poolConfig.priceOracle).getPriceWithCircuitBreaker(SHIELDED_TOKEN) returns (
            uint256 protectedPrice
        ) {
            if (protectedPrice == 0) return (false, 0);
            return (true, protectedPrice);
        } catch {
            return (false, 0);
        }
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
            bool methodMissing;
            (success, price, methodMissing) = _tryGetStrictProtectedBackingPriceSoft();
            if (success || !methodMissing) {
                return (success, price);
            }
        }

        try IPriceOracle(poolConfig.priceOracle).getPriceWithCircuitBreaker(BACKING_TOKEN) returns (
            uint256 protectedPrice
        ) {
            if (protectedPrice == 0) return (false, 0);
            return (true, protectedPrice);
        } catch {
            return (false, 0);
        }
    }

    /// @inheritdoc ISplitRiskPool
    function requiresStrictProtectedBackingPrice() public view override returns (bool) {
        address poolOwner = owner();
        if (poolOwner == address(0) || poolOwner.code.length == 0) {
            return false;
        }

        (bool success, bytes memory data) = poolOwner.staticcall(
            abi.encodeCall(ISplitRiskPoolFactory.tokenRequiresStrictProtectedPrice, (BACKING_TOKEN))
        );

        if (!success || data.length < 32) {
            return false;
        }

        return abi.decode(data, (bool));
    }

    /// @dev Resolves whether backing-token pricing must use the strict protected-price path.
    ///      Pools owned directly by EOAs or tests default to compatibility mode.
    function _requiresStrictProtectedBackingPrice() internal view returns (bool) {
        return requiresStrictProtectedBackingPrice();
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
     *      Uses formula: min(positionAmount, totalProtectorTokens - requiredCollateralInProtectorTokens)
     *      Collateralization is based on original deposit values (valueAtDeposit), not current token amounts.
     *      This allows users to withdraw all unlocked funds in one transaction instead of iterating.
     * @param tokenId The protector NFT token ID
     * @return availableAmount Maximum amount available for withdrawal
     */
    function getAvailableForWithdrawal(uint256 tokenId) public view returns (uint256) {
        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(protectorReceiptNFT).getPosition(tokenId);
        uint256 positionShares_ = _getProtectorPositionShares(tokenId, pos);

        // slither-disable-next-line incorrect-equality — empty-position guard, 0 shares = nothing to withdraw
        if (positionShares_ == 0) return 0;

        uint256 positionAmount = _getProtectorPositionAmountFromShares(positionShares_);
        if (positionAmount == 0) {
            return 0;
        }

        // slither-disable-next-line incorrect-equality — empty-state guard, no deposits means nothing locked
        if (totalValueAtDeposit == 0) return positionAmount; // No shielded deposits = nothing locked

        // Calculate required protector tokens based on USD collateral requirement using protected backing pricing.
        (bool priceSuccess, uint256 uwPrice) = _tryGetProtectedBackingPrice();
        if (!priceSuccess) {
            // Fail closed when protected backing pricing is unavailable.
            return 0;
        }

        // M-4 FIX: Multiply before divide to avoid precision loss
        uint256 requiredProtectorTokens =
            (totalValueAtDeposit * COLLATERAL_RATIO * backingTokenScale) / (ConstantsLib.BASIS_POINT_SCALE * uwPrice);

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
     * @param shieldedAmount Amount of shielded tokens to deposit
     * @custom:error InsufficientProtectorTokenBalance If collateral requirement exceeds protector value
     * @custom:error InvalidOraclePrice If all oracle paths fail
     */
    function _checkCapacity(uint256 shieldedAmount) internal view {
        // Calculate new deposit's valueAtDeposit (USD)
        uint256 newDepositValueAtDeposit = _getShieldedValue(shieldedAmount);
        uint256 newTotalValueAtDeposit = totalValueAtDeposit + newDepositValueAtDeposit;

        // Reject dust amounts where USD value truncates to 0
        if (newDepositValueAtDeposit == 0 && shieldedAmount > 0) {
            revert ErrorsLib.InvalidOraclePrice();
        }

        uint256 totalProtectorUsd = _getProtectedBackingValue(totalProtectorTokens);

        // Calculate required collateral based on original deposit values
        uint256 requiredCollateralUsd = (newTotalValueAtDeposit * COLLATERAL_RATIO) / ConstantsLib.BASIS_POINT_SCALE;
        if (requiredCollateralUsd > totalProtectorUsd) {
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
            allowShieldedSpotFallback = true;
        } else {
            revert ErrorsLib.UnsupportedAsset();
        }

        if (depositAmount < minDepositAmount) revert ErrorsLib.InsufficientDepositAmount();
        if (depositAmount > maxDepositAmount) revert ErrorsLib.DepositAmountTooLarge();
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
        uint256 beforeBal = IERC20(asset).balanceOf(recipient);
        SafeERC20.safeTransfer(IERC20(asset), recipient, transferAmount);
        uint256 afterBal = IERC20(asset).balanceOf(recipient);
        received = afterBal - beforeBal;
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
        IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(shieldReceiptNFT).getPosition(tokenId);

        if (pos.amount == 0) revert ErrorsLib.InsufficientTokenBalance();
        if (pos.isWithdrawn) revert ErrorsLib.PositionAlreadyWithdrawn();

        // Get current USD value (USD-BASED for yield calculation)
        uint256 currentValue = _getShieldedValue(pos.amount);

        // Use per-position high-water-mark baseline to avoid repeatedly taxing the same yield.
        // Backward compatibility: legacy positions without an initialized baseline use valueAtDeposit.
        uint256 baselineValueUsd = feeValueBaselineUsd[tokenId];
        // slither-disable-next-line incorrect-equality — legacy position migration check, baseline not yet initialized
        if (baselineValueUsd == 0) {
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

        // Convert USD fees (8 decimals) to shielded token units using cached scale.
        uint256 currentPrice = _getShieldedPrice();
        commissionAmount = Math.mulDiv(commissionAmountUsd, shieldedTokenScale, currentPrice);
        poolFeeAmount = Math.mulDiv(poolFeeAmountUsd, shieldedTokenScale, currentPrice);
        protocolFeeAmount = Math.mulDiv(protocolFeeAmountUsd, shieldedTokenScale, currentPrice);

        // Cap total fees to available amount to prevent underflow
        uint256 totalFees = commissionAmount + poolFeeAmount + protocolFeeAmount;
        if (totalFees > pos.amount) {
            // Scale down fees proportionally without introducing a second rounding step.
            (commissionAmount, poolFeeAmount, protocolFeeAmount) =
                _scaleFeesToAvailableAmount(commissionAmount, poolFeeAmount, protocolFeeAmount, pos.amount);
        }

        // Prevent unbounded fee accumulation
        uint256 maxSafeAccumulation = ConstantsLib.MAX_SAFE_ACCUMULATION;

        // Accumulate pool fee in native shielded token units.
        if (accumulatedPoolFee + poolFeeAmount > maxSafeAccumulation) {
            emit EventsLib.FeeDropped("poolFee", poolFeeAmount, accumulatedPoolFee);
            poolFeeAmount = 0;
        }
        accumulatedPoolFee += poolFeeAmount;

        // Accumulate protocol fee in native shielded token units.
        if (accumulatedProtocolFee + protocolFeeAmount > maxSafeAccumulation) {
            emit EventsLib.FeeDropped("protocolFee", protocolFeeAmount, accumulatedProtocolFee);
            protocolFeeAmount = 0;
        }
        accumulatedProtocolFee += protocolFeeAmount;

        // Accumulate commissions in native shielded token units via rewards-per-share.
        // If no effective protector capital exists, redirect commissions to protocol fee.
        uint256 currentTotalShares = _currentTotalProtectorShares();
        // slither-disable-next-line incorrect-equality — empty-state guard, no effective protector capital = redirect
        if (currentTotalShares == 0 || totalProtectorTokens == 0) {
            // Redirect commission to protocol fee when no protectors exist
            // This prevents commissions from becoming permanently stranded
            uint256 redirectedAmount = commissionAmount;

            // Add to protocol fee (with overflow protection)
            // Note: accumulatedProtocolFee already includes protocolFeeAmount at this point
            if (accumulatedProtocolFee + redirectedAmount > maxSafeAccumulation) {
                // If overflow would occur, cap the redirected amount
                if (accumulatedProtocolFee < maxSafeAccumulation) {
                    redirectedAmount = maxSafeAccumulation - accumulatedProtocolFee;
                } else {
                    redirectedAmount = 0;
                }
            }
            accumulatedProtocolFee += redirectedAmount;
            protocolFeeAmount += redirectedAmount;

            // Don't accumulate as commission since there are no protectors to claim it
            commissionAmount = 0;
        } else {
            // Normal commission accumulation when protectors exist
            if (accumulatedCommissions + commissionAmount > maxSafeAccumulation) {
                emit EventsLib.FeeDropped("commission", commissionAmount, accumulatedCommissions);
                commissionAmount = 0;
            }
            // Update rewards-per-share accumulator (MasterChef pattern)
            rewardPerShareAccumulated += (commissionAmount * ConstantsLib.REWARD_PRECISION) / currentTotalShares;
            accumulatedCommissions += commissionAmount;
            totalCommissionsEverAccumulated += commissionAmount;
        }

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

        // Check actual balance (source of truth)
        uint256 actualBalance = IERC20(SHIELDED_TOKEN).balanceOf(address(this));
        if (actualBalance < feeAmount) {
            revert ErrorsLib.InsufficientTokenBalance();
        }

        // Reduce pool's shielded token balance by the fees paid out
        poolState.shieldedTokenBalance -= feeAmount;

        // Transfer the fee
        SafeERC20.safeTransfer(IERC20(SHIELDED_TOKEN), recipient, feeAmount);
        return feeAmount;
    }

    /**
     * @notice Pay out accumulated pool fee to the pool creator
     * @dev Only pool creator or governance can trigger fee payment.
     *      Transfers accumulated pool fee from the pool to the pool creator.
     *      Resets the accumulated fee counter to prevent double payment.
     * @custom:error AccessControlDenied If caller is not pool creator or governance
     * @custom:error InsufficientTokenBalance If pool has insufficient balance
     */
    function payPoolFee() external nonReentrant {
        if (msg.sender != POOL_CREATOR && msg.sender != _governanceTimelock) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "payPoolFee");
        }

        uint256 amount = accumulatedPoolFee;
        accumulatedPoolFee = 0;

        if (_payAccumulatedFee(amount, POOL_CREATOR) > 0) {
            emit EventsLib.PoolFeePaid(POOL_CREATOR, amount);
        }
    }

    /**
     * @notice Pay out accumulated protocol fee to the protocol fee recipient
     * @dev Only protocol fee recipient or governance can trigger fee payment.
     *      Transfers accumulated protocol fee from the pool to the protocol fee recipient.
     *      Resets the accumulated fee counter to prevent double payment.
     * @custom:error AccessControlDenied If caller is not protocol fee recipient or governance
     * @custom:error InsufficientTokenBalance If pool has insufficient balance
     */
    function payProtocolFee() external nonReentrant {
        if (msg.sender != poolConfig.protocolFeeRecipient && msg.sender != _governanceTimelock) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "payProtocolFee");
        }

        uint256 amount = accumulatedProtocolFee;
        accumulatedProtocolFee = 0;

        if (_payAccumulatedFee(amount, poolConfig.protocolFeeRecipient) > 0) {
            emit EventsLib.ProtocolFeePaid(poolConfig.protocolFeeRecipient, amount);
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
        uint256 totalEarned = (rewardPerShareAccumulated * positionShares_) / ConstantsLib.REWARD_PRECISION;
        uint256 debt = rewardDebt[tokenId];
        uint256 alreadyClaimed = commissionsClaimed[tokenId];
        return totalEarned > (debt + alreadyClaimed) ? totalEarned - debt - alreadyClaimed : 0;
    }

    /// @dev Claims pending commissions for a protector position using share-based accounting.
    function _claimCommissionTo(address recipient, uint256 tokenId, uint256 positionShares_)
        internal
        returns (uint256 claimable)
    {
        claimable = _calculateClaimableCommission(tokenId, positionShares_);
        if (claimable > accumulatedCommissions) claimable = accumulatedCommissions;
        if (claimable == 0) return 0;

        commissionsClaimed[tokenId] += claimable;
        accumulatedCommissions -= claimable;

        uint256 actualBalance = IERC20(SHIELDED_TOKEN).balanceOf(address(this));
        if (actualBalance < claimable) {
            revert ErrorsLib.InsufficientTokenBalance();
        }

        poolState.shieldedTokenBalance -= claimable;
        SafeERC20.safeTransfer(IERC20(SHIELDED_TOKEN), recipient, claimable);

        emit EventsLib.CommissionClaimed(recipient, tokenId, claimable);
    }

    /**
     * @notice Claims accumulated commission for a protector NFT position
     * @dev Uses MasterChef pattern to prevent late-joiner exploit. Only the current
     *      NFT owner can claim. Commission is paid in shielded tokens.
     *      Emits NoCommissionToClaim event if no commission is available.
     * @param tokenId The protector NFT token ID
     * @custom:error NotOwner If caller is not the NFT owner
     * @custom:error InsufficientTokenBalance If pool has insufficient balance or no protectors
     */
    function claimCommission(uint256 tokenId) external nonReentrant {
        if (IProtectorReceiptNFT(protectorReceiptNFT).ownerOf(tokenId) != msg.sender) {
            revert ErrorsLib.NotOwner();
        }

        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(protectorReceiptNFT).getPosition(tokenId);
        uint256 positionShares_ = _getProtectorPositionShares(tokenId, pos);

        if (_claimCommissionTo(msg.sender, tokenId, positionShares_) == 0) {
            emit EventsLib.NoCommissionToClaim(msg.sender, tokenId);
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
        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(protectorReceiptNFT).getPosition(tokenId);
        uint256 positionShares_ = _getProtectorPositionShares(tokenId, pos);
        if (positionShares_ == 0) return 0;

        return _calculateClaimableCommission(tokenId, positionShares_);
    }

    /**
     * @notice Migrates an existing protector position to the rewards-per-share system
     * @dev Grants existing positions credit for historical rewards (grandfather clause).
     *      Sets debt to 0 so they can claim all accumulated rewards from the old system.
     *      Only callable by governance.
     * @param tokenId The protector NFT token ID to migrate
     * @custom:error InsufficientTokenBalance If position amount is zero
     * @custom:error InvalidTokenId If position has already been migrated
     */
    function migrateExistingPosition(uint256 tokenId) external onlyGovernance {
        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(protectorReceiptNFT).getPosition(tokenId);
        if (pos.amount == 0) revert ErrorsLib.InsufficientTokenBalance();
        if (positionMigrated[tokenId]) revert ErrorsLib.InvalidTokenId(); // Already migrated
        // L-2 FIX: Only allow migration for pre-commission positions (grandfather clause)
        // Positions created after commissions started already have rewardDebt set
        if (rewardDebt[tokenId] != 0) revert ErrorsLib.InvalidTokenId();

        // Mark as migrated and set debt to 0 for historical rewards (grandfather clause)
        positionMigrated[tokenId] = true;
        rewardDebt[tokenId] = 0;

        emit EventsLib.PositionMigrated(tokenId);
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
        if (accessControl != address(0) && !IPoolAccessControl(accessControl).canDepositProtector(msg.sender)) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "depositProtector");
        }

        // Balance-delta deposit to support fee-on-transfer tokens
        uint256 received = _transferAndGetReceived(asset, depositAmount);

        // If minReceivedAmount > 0, verify received amount meets minimum expectation
        if (minReceivedAmount > 0) {
            SlippageLib.enforceMinReceived(received, minReceivedAmount);
        }

        _validateDeposit(asset, received);
        _markPoolLaunched();

        _ensureProtectorSharesInitialized();
        uint256 currentTotalShares = _currentTotalProtectorShares();
        uint256 sharesMinted = currentTotalShares == 0 || totalProtectorTokens == 0
            ? received
            : Math.mulDiv(received, currentTotalShares, totalProtectorTokens);
        if (sharesMinted == 0) revert ErrorsLib.InsufficientDepositAmount();

        // Update pool balances (TOKEN-BASED)
        poolState.totalBackingTokenBalance += received;
        totalProtectorTokens += received;
        totalProtectorShares = currentTotalShares + sharesMinted;

        // Mint NFT
        tokenId = IProtectorReceiptNFT(protectorReceiptNFT).mint(msg.sender, received);
        protectorShares[tokenId] = sharesMinted;

        // Record reward debt at current accumulator value (MasterChef pattern)
        // This "debits" the position for rewards it didn't earn, preventing late-joiner exploit
        rewardDebt[tokenId] = (rewardPerShareAccumulated * sharesMinted) / ConstantsLib.REWARD_PRECISION;

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
        if (accessControl != address(0) && !IPoolAccessControl(accessControl).canDepositShielded(msg.sender)) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "depositShielded");
        }
        if (asset != SHIELDED_TOKEN) revert ErrorsLib.UnsupportedAsset();

        // Transfer asset from depositor (balance-delta for fee-on-transfer tokens)
        uint256 received = _transferAndGetReceived(asset, depositAmount);

        // If minReceivedAmount > 0, verify received amount meets minimum expectation
        if (minReceivedAmount > 0) {
            SlippageLib.enforceMinReceived(received, minReceivedAmount);
        }

        _validateDeposit(asset, received);

        // Check capacity using USD-BASED accounting via price oracle
        _checkCapacity(received);
        _markPoolLaunched();

        // Calculate USD value for cross-asset withdrawal and fee calculation
        uint256 valueAtDeposit = _getShieldedValue(received);
        uint256 requiredCollateralUsd = (valueAtDeposit * COLLATERAL_RATIO) / ConstantsLib.BASIS_POINT_SCALE;
        uint256 collateralAmount = Math.mulDiv(requiredCollateralUsd, backingTokenScale, _getProtectedBackingPrice());

        // Update pool balances (TOKEN-BASED)
        poolState.shieldedTokenBalance += received;
        totalShieldedTokens += received;

        // Update total original deposit value (USD-BASED)
        totalValueAtDeposit += valueAtDeposit;

        // Mint NFT with collateral amount stored
        tokenId = IShieldReceiptNFT(shieldReceiptNFT).mint(msg.sender, received, valueAtDeposit, collateralAmount);
        feeValueBaselineUsd[tokenId] = valueAtDeposit;

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
    function shieldedWithdraw(uint256 tokenId, address preferredAsset, uint256 minAmountOut)
        external
        nonReentrant
        whenNotPaused
        onlyShieldNFTOwner(tokenId)
    {
        if (!(preferredAsset == BACKING_TOKEN || preferredAsset == SHIELDED_TOKEN)) {
            revert ErrorsLib.UnsupportedAsset();
        }
        if (accessControl != address(0) && !IPoolAccessControl(accessControl).canWithdrawShielded(msg.sender)) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "withdrawShielded");
        }

        IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(shieldReceiptNFT).getPosition(tokenId);
        if (pos.isWithdrawn) revert ErrorsLib.PositionAlreadyWithdrawn();

        // Check minimum pool time only if withdrawing backing assets (shield activation)
        if (preferredAsset == BACKING_TOKEN) {
            uint256 timeElapsed = block.timestamp - uint256(pos.depositTime);
            if (timeElapsed < poolConfig.minimumPoolTime) {
                revert ErrorsLib.InsufficientPoolTimeWithDetails(poolConfig.minimumPoolTime, timeElapsed);
            }
        }

        // Calculate and accumulate fees (USD-BASED)
        (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount) =
            _calculateAndAccumulateFees(tokenId);
        uint256 totalFees = commissionAmount + poolFeeAmount + protocolFeeAmount;

        // Burn NFT (position data is deleted by burn, no need to update first)
        IShieldReceiptNFT(shieldReceiptNFT).burn(tokenId);
        delete lastClaimRewardsTime[tokenId]; // Clean up stale state
        delete feeValueBaselineUsd[tokenId];

        // Update total original deposit value (subtract original value at deposit)
        totalValueAtDeposit -= pos.valueAtDeposit;

        uint256 payoutAmount;

        if (preferredAsset == SHIELDED_TOKEN) {
            // Normal withdrawal: user gets shielded tokens back (minus fees)
            payoutAmount = pos.amount - totalFees;

            if (payoutAmount > getWithdrawableBalance()) {
                revert ErrorsLib.InsufficientTokenBalance();
            }

            poolState.shieldedTokenBalance -= payoutAmount;
        } else {
            // Cross-asset withdrawal (USD-BASED): user gets backing tokens (shield activation)
            // Use stored valueAtDeposit (locked at deposit time - manipulation resistant)
            _ensureProtectorSharesInitialized();
            uint256 uwPrice = _getProtectedBackingPrice();
            payoutAmount = Math.mulDiv(pos.valueAtDeposit, backingTokenScale, uwPrice);

            // Cap to original collateral amount (in token terms, not recalculated)
            // This ensures users can't claim more tokens than were originally allocated
            // even if backing token depegs dramatically
            uint256 maxBackingTokens = pos.collateralAmount;
            if (payoutAmount > maxBackingTokens) {
                payoutAmount = maxBackingTokens;
            }

            // Deduct from protector pool (TOKEN-BASED accounting)
            // Check balance before deduction to prevent underflow
            if (poolState.totalBackingTokenBalance < payoutAmount) {
                revert ErrorsLib.InsufficientTokenBalance();
            }
            totalProtectorTokens -= payoutAmount;
            poolState.totalBackingTokenBalance -= payoutAmount;
        }

        // Update shielded totals (TOKEN-BASED)
        totalShieldedTokens -= pos.amount;

        uint256 actualReceived = _transferOutAndGetReceived(preferredAsset, msg.sender, payoutAmount);
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
    function partialWithdrawShielded(
        uint256 tokenId,
        uint256 withdrawAmount,
        address preferredAsset,
        uint256 minAmountOut
    ) external nonReentrant whenNotPaused onlyShieldNFTOwner(tokenId) returns (uint256 newTokenId) {
        if (preferredAsset != SHIELDED_TOKEN) revert ErrorsLib.UnsupportedAsset(); // Partial withdrawal only for same asset
        if (withdrawAmount == 0) revert ErrorsLib.NoTokensToWithdraw();
        if (accessControl != address(0) && !IPoolAccessControl(accessControl).canWithdrawShielded(msg.sender)) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "withdrawShielded");
        }

        IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(shieldReceiptNFT).getPosition(tokenId);
        if (pos.isWithdrawn) revert ErrorsLib.PositionAlreadyWithdrawn();
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

        // 3. Create new position with remaining amount
        // Calculate new collateral amount proportionally to remaining amount
        uint256 newCollateralAmount = (pos.collateralAmount * remaining) / pos.amount;
        // Calculate new valueAtDeposit proportionally from original (not from current price)
        // This ensures collateralization is based on original deposit values
        uint256 newValueAtDeposit = (pos.valueAtDeposit * remaining) / pos.amount;
        newTokenId = IShieldReceiptNFT(shieldReceiptNFT)
            .mintWithDepositTime(msg.sender, remaining, newValueAtDeposit, newCollateralAmount, pos.depositTime);
        feeValueBaselineUsd[newTokenId] = newFeeBaselineUsd;
        delete feeValueBaselineUsd[tokenId];

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

        // === ATOMIC SECTION END ===

        // Transfer (external call, safe after state updates)
        uint256 actualReceived = _transferOutAndGetReceived(preferredAsset, msg.sender, withdrawAmount);
        SlippageLib.enforceMinReceived(actualReceived, minAmountOut);

        emit EventsLib.PartialWithdrawal(msg.sender, tokenId, newTokenId, withdrawAmount, remaining);
    }

    function startUnlockProcess(uint256 tokenId) external nonReentrant onlyProtectorNFTOwner(tokenId) {
        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(protectorReceiptNFT).getPosition(tokenId);
        uint256 positionShares_ = _getProtectorPositionShares(tokenId, pos);
        uint256 positionAmount = _getProtectorPositionAmountFromShares(positionShares_);
        if (positionAmount == 0) revert ErrorsLib.InsufficientTokenBalance();
        if (pos.unlockRequestTime != 0) revert ErrorsLib.UnlockProcessAlreadyStarted();

        IProtectorReceiptNFT(protectorReceiptNFT)
            .setUnlockRequestTime(tokenId, uint64(block.timestamp + poolConfig.unlockDuration));
        emit EventsLib.UnlockProcessStarted(msg.sender, tokenId, positionAmount);
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
    function claimRewards(uint256 tokenId) external nonReentrant {
        address owner = _requireShieldNFTOwner(tokenId);

        // Rate limiting: minimum 24 hours between calls per tokenId
        uint256 lastClaim = lastClaimRewardsTime[tokenId];
        if (lastClaim != 0 && block.timestamp < lastClaim + ConstantsLib.CLAIM_REWARDS_COOLDOWN) {
            revert ErrorsLib.ClaimRewardsCooldownNotMet(lastClaim + ConstantsLib.CLAIM_REWARDS_COOLDOWN);
        }
        lastClaimRewardsTime[tokenId] = block.timestamp;

        // Calculate and accumulate fees (this updates the position internally)
        (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount) =
            _calculateAndAccumulateFees(tokenId);
        uint256 totalFees = commissionAmount + poolFeeAmount + protocolFeeAmount;

        // Update totalShieldedTokens to reflect fees deducted from position
        if (totalFees > 0) {
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
    function protectorWithdraw(uint256 tokenId, uint256 amount, address preferredAsset, uint256 minAmountOut)
        external
        nonReentrant
        whenNotPaused
        onlyProtectorNFTOwner(tokenId)
    {
        if (amount == 0) revert ErrorsLib.NoTokensToWithdraw();
        if (preferredAsset != BACKING_TOKEN) revert ErrorsLib.UnsupportedAsset();

        if (accessControl != address(0) && !IPoolAccessControl(accessControl).canWithdrawProtector(msg.sender)) {
            revert ErrorsLib.AccessControlDenied(msg.sender, "withdrawProtector");
        }

        IProtectorReceiptNFT.ProtectorPosition memory pos =
            IProtectorReceiptNFT(protectorReceiptNFT).getPosition(tokenId);
        _ensureProtectorSharesInitialized();
        uint256 currentTotalShares = _currentTotalProtectorShares();
        uint256 positionShares_ = _getProtectorPositionShares(tokenId, pos);
        uint256 positionAmount = _assetsFromProtectorShares(positionShares_, totalProtectorTokens, currentTotalShares);

        if (pos.unlockRequestTime == 0 || pos.unlockRequestTime > block.timestamp) {
            revert ErrorsLib.InsufficientUnlockedTokens();
        }

        // Unlock completion removes the time gate but never bypasses collateral requirements.
        uint256 available = getAvailableForWithdrawal(tokenId);

        if (amount > positionAmount) {
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

        if (newShares == 0) {
            // Full withdrawal - burn NFT and clean up mappings
            IProtectorReceiptNFT(protectorReceiptNFT).burn(tokenId);
            delete rewardDebt[tokenId];
            delete protectorShares[tokenId];
            delete commissionsClaimed[tokenId];
        } else {
            // Partial withdrawal - reset to clean slate to avoid rounding exploits
            // Set rewardDebt to current accumulator for new amount (fresh start)
            rewardDebt[tokenId] = (rewardPerShareAccumulated * newShares) / ConstantsLib.REWARD_PRECISION;
            // Clear commissions claimed - position gets fresh accounting
            delete commissionsClaimed[tokenId];
            protectorShares[tokenId] = newShares;
            IProtectorReceiptNFT(protectorReceiptNFT).updateAmount(tokenId, newAmount);
        }

        // Update pool balances (TOKEN-BASED)
        totalProtectorTokens -= amount;
        totalProtectorShares = newTotalShares;
        poolState.totalBackingTokenBalance -= amount;

        // Verify pool has sufficient balance
        uint256 poolBalance = IERC20(preferredAsset).balanceOf(address(this));
        if (poolBalance < amount) {
            revert ErrorsLib.InsufficientTokenBalance();
        }

        uint256 actualReceived = _transferOutAndGetReceived(preferredAsset, msg.sender, amount);
        SlippageLib.enforceMinReceived(actualReceived, minAmountOut);

        emit EventsLib.ShieldActivated(msg.sender, amount, 0, amount);
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
     * @return isWithdrawn Whether position has been withdrawn
     */
    function getShieldDepositInfo(uint256 tokenId)
        external
        view
        returns (uint256 amount, uint64 depositTime, uint256 valueAtDeposit, uint64 lastFeeClaimTime, bool isWithdrawn)
    {
        IShieldReceiptNFT.ShieldPosition memory pos = IShieldReceiptNFT(shieldReceiptNFT).getPosition(tokenId);
        amount = pos.amount;
        depositTime = pos.depositTime;
        valueAtDeposit = pos.valueAtDeposit;
        lastFeeClaimTime = pos.lastFeeClaimTime;
        isWithdrawn = pos.isWithdrawn;
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

        if (newProtocolFee > ConstantsLib.MAX_PROTOCOL_FEE) {
            revert ErrorsLib.InvalidProtocolFee();
        }

        if (newProtocolFeeRecipient == address(0)) {
            revert ErrorsLib.InvalidProtocolFeeRecipient();
        }

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
    function governanceTimelock() public view override(ProtocolAccessControlUpgradeable) returns (address) {
        return ProtocolAccessControlUpgradeable.governanceTimelock();
    }

    /**
     * @notice Sets the governance timelock address
     * @dev Only callable by governance or owner. Updates the timelock address used
     *      for governance-controlled operations.
     * @param newGovernanceTimelock The new governance timelock address
     * @custom:error InvalidGovernanceTimelock If new address is zero
     */
    function setGovernanceTimelock(address newGovernanceTimelock)
        public
        override(ProtocolAccessControlUpgradeable)
        onlyGovernanceOrOwner
    {
        ProtocolAccessControlUpgradeable.setGovernanceTimelock(newGovernanceTimelock);
    }

    /// @notice Completes the two-step governance transfer
    /// @dev Only callable by the pending governance address
    function acceptGovernanceTimelock() public override(ProtocolAccessControlUpgradeable) {
        ProtocolAccessControlUpgradeable.acceptGovernanceTimelock();
    }

    /// @notice Returns the pending governance timelock address
    function pendingGovernanceTimelock() public view override(ProtocolAccessControlUpgradeable) returns (address) {
        return ProtocolAccessControlUpgradeable.pendingGovernanceTimelock();
    }

    /// @notice Pauses the pool, blocking deposits and withdrawals
    /// @dev Only callable by governance or owner for emergency situations
    function pause() public override(ISplitRiskPool, ProtocolAccessControlUpgradeable) onlyGovernanceOrOwner {
        ProtocolAccessControlUpgradeable.pause();
    }

    /// @notice Unpauses the pool, resuming normal operations
    /// @dev Only callable by governance or owner
    function unpause() public override(ProtocolAccessControlUpgradeable) onlyGovernanceOrOwner {
        ProtocolAccessControlUpgradeable.unpause();
    }

    /// @notice Returns whether the pool is currently paused
    function paused() public view override(ISplitRiskPool, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyGovernance { }

    /// @notice Governance migration hook for upgraded legacy pools that have already launched
    function markPoolAsLaunched() external onlyGovernance {
        _markPoolLaunched();
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
        bool callerIsCreatorBeforeLaunch =
            msg.sender == POOL_CREATOR && !hasEverLaunched && totalShieldedTokens == 0 && totalProtectorTokens == 0;
        if (!callerIsGovernance && !callerIsCreatorBeforeLaunch) {
            revert ErrorsLib.InvalidPoolCreator();
        }

        // Validate interface if not disabling access control
        if (newAccessControl != address(0)) {
            _validateAccessControl(newAccessControl);
        }

        emit EventsLib.AccessControlUpdated(accessControl, newAccessControl);
        accessControl = newAccessControl;
    }

    function _validateAccessControl(address newAccessControl) internal view {
        _validateAccessControlHook(
            newAccessControl, abi.encodeCall(IPoolAccessControl.canDepositShielded, (address(0)))
        );
        _validateAccessControlHook(
            newAccessControl, abi.encodeCall(IPoolAccessControl.canWithdrawShielded, (address(0)))
        );
        _validateAccessControlHook(
            newAccessControl, abi.encodeCall(IPoolAccessControl.canDepositProtector, (address(0)))
        );
        _validateAccessControlHook(
            newAccessControl, abi.encodeCall(IPoolAccessControl.canWithdrawProtector, (address(0)))
        );
    }

    function _validateAccessControlHook(address newAccessControl, bytes memory callData) internal view {
        (bool success, bytes memory returndata) = newAccessControl.staticcall(callData);
        if (!success || returndata.length != 32) revert ErrorsLib.InvalidAccessControlAddress();

        // Decode the response to ensure the hook returns a bool.
        abi.decode(returndata, (bool));
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

        if (tokenDecimals > 77) {
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
     * Reserved 43 slots after adding launch-state tracking to follow OpenZeppelin's upgrade-safe pattern.
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
    bool public hasEverLaunched;
    uint256[43] private __gap;
}
