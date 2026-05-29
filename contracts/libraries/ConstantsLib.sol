// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

/// @title ConstantsLib
/// @author David Hawig
/// @notice Library containing all protocol constants
library ConstantsLib {
    // ============ Basis Points ============
    /// @notice Scale for percentage calculations (100% = 10000 = 100%)
    uint256 public constant BASIS_POINT_SCALE = 1e4;

    // ============ Fee Rate Bounds ============
    /// @notice Minimum commission rate (1%)
    uint256 public constant MIN_COMMISSION_RATE = 100;
    /// @notice Maximum commission rate (50%)
    uint256 public constant MAX_COMMISSION_RATE = 5000;
    /// @notice Minimum pool fee (0%)
    uint256 public constant MIN_POOL_FEE = 0;
    /// @notice Maximum pool fee (20%)
    uint256 public constant MAX_POOL_FEE = 2000;
    /// @notice Maximum protocol fee (10%)
    uint256 public constant MAX_PROTOCOL_FEE = 1000;

    // ============ Collateral Ratio Bounds ============
    /// @notice Minimum collateral ratio (100%)
    uint256 public constant MIN_COLLATERAL_RATIO = 10000;
    /// @notice Maximum collateral ratio (500%)
    uint256 public constant MAX_COLLATERAL_RATIO = 50000;

    // ============ Time Duration Bounds ============
    /// @notice Minimum unlock duration for protector withdrawals
    uint256 public constant MIN_UNLOCK_DURATION = 1 days;
    /// @notice Maximum unlock duration for protector withdrawals
    uint256 public constant MAX_UNLOCK_DURATION = 365 days;
    /// @notice Maximum minimum pool time before shielded can withdraw to backing token (NEW-4 FIX)
    uint256 public constant MAX_MINIMUM_POOL_TIME = 90 days;
    /// @notice Cooldown period between reward claims
    uint256 public constant CLAIM_REWARDS_COOLDOWN = 1 days;

    // ============ Precision Constants ============
    /// @notice Precision for reward per share calculations (MasterChef pattern)
    /// @dev Kept above protector share decimals so sub-native-unit rewards do
    ///      not become material when backing assets have very large supplies.
    uint256 public constant REWARD_PRECISION = 1e36;
    /// @notice Maximum normalized protector share supply.
    /// @dev Bounds the largest reward that can round to zero to less than 100
    ///      native shielded-token units at REWARD_PRECISION.
    uint256 public constant MAX_PROTECTOR_REWARD_SHARES = 1e38;
    /// @notice Standard token decimals (18) as a scale factor (1e18)
    uint256 public constant TOKEN_DECIMALS = 1e18;
    /// @notice Standard token decimals as uint8 (for ERC20.decimals() compatibility)
    uint8 public constant TOKEN_DECIMALS_UINT8 = 18;
    /// @notice Standard decimals for USD prices in oracles (8)
    /// @dev Used by CompositeOracle, ERC4626OracleFeed, ChainlinkOracleFeed, PythOracle
    uint8 public constant USD_DECIMALS = 8;
    /// @notice Minimum ERC20 decimals supported for pool assets.
    /// @dev Very low-decimal backing assets can make share-socialized dust material and unclaimable.
    uint8 public constant MIN_POOL_TOKEN_DECIMALS = 6;
    /// @notice Maximum ERC20 decimals supported for pool assets.
    /// @dev Keeps the default max deposit below MAX_SAFE_ACCUMULATION in native units.
    uint8 public constant MAX_POOL_TOKEN_DECIMALS = 32;
    /// @notice Maximum safe accumulation value to prevent overflow
    uint256 public constant MAX_SAFE_ACCUMULATION = type(uint128).max;

    // ============ String Length Limits ============
    /// @notice Maximum length for token symbols
    uint256 public constant MAX_TOKEN_SYMBOL_LENGTH = 32;

    // ============ Default Pool Configuration (INFO-2 FIX) ============
    /// @notice Default max deposit expressed in whole tokens before native scaling
    uint256 public constant DEFAULT_MAX_DEPOSIT_TOKENS = 1_000_000;
    /// @notice Default maximum total value locked in USD (8 decimals)
    uint256 public constant DEFAULT_MAX_TVL_USD = 10_000_000 * 1e8;
    /// @notice Default minimum pool time before shielded can withdraw to backing token
    uint256 public constant DEFAULT_MINIMUM_POOL_TIME = 1 days;
    /// @notice Default unlock duration for protector withdrawals
    uint256 public constant DEFAULT_UNLOCK_DURATION = 28 days;
    /// @notice Default protocol fee in basis points (1%)
    uint96 public constant DEFAULT_PROTOCOL_FEE = 100;
}
