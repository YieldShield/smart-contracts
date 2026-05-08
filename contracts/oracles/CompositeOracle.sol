// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ICompositeOracle } from "../interfaces/ICompositeOracle.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { IOracleFeed } from "../interfaces/IOracleFeed.sol";
import { DecimalNormalizationLib } from "../libraries/DecimalNormalizationLib.sol";
import { OracleValidationLib } from "../libraries/OracleValidationLib.sol";
import { ConstantsLib } from "../libraries/ConstantsLib.sol";

/// @title CompositeOracle
/// @author David Hawig
/// @notice Routes token pricing to per-token oracle feeds with optional dual-feed support
/// @dev Implements IPriceOracle interface by delegating to registered IOracleFeed implementations.
///      Supports both single-feed and dual-feed (primary + backup) configurations per token.
///      Dual-feed tokens include a challenge mechanism for switching between feeds.
///      All price outputs are normalized to 8 decimals (USD format).
/// - getPrice() returns: price with 8 decimals (e.g., $1.00 = 1e8)
/// - getValue() returns: USD value with 8 decimals
/// - getEquivalentAmount() returns: token amount in tokenB's native decimals
contract CompositeOracle is ICompositeOracle, Ownable {
    using DecimalNormalizationLib for uint256;

    // ============ Dual-Feed Configuration ============

    /// @notice Configuration for a token's oracle feed(s)
    struct TokenOracleConfig {
        address primaryFeed; // Required: primary oracle feed
        address backupFeed; // Optional: backup oracle feed (address(0) = single-feed mode)
        bool isBackupActive; // Which feed is currently active (only relevant if backupFeed != 0)
        uint256 challengeStartTime; // Timestamp when challenge started (0 if no challenge pending)
        uint256 lastChallengeTime; // For cooldown enforcement
    }

    /// @notice Per-token oracle configuration
    mapping(address => TokenOracleConfig) private _tokenOracleConfig;

    /// @notice Mapping from token address to oracle type identifier
    mapping(address => string) private _tokenOracleType;

    /// @notice Mapping to track supported tokens
    mapping(address => bool) private _isTokenSupported;

    /// @notice Tokens that require every configured feed to support circuit-breaker pricing
    mapping(address => bool) public override strictCircuitBreakerRequired;

    /// @notice Authorized callers that can set token oracle feeds (e.g., factory)
    mapping(address => bool) public authorizedCallers;

    // ============ Challenge Mechanism Configuration ============

    /// @notice Deviation threshold in basis points (e.g., 75 = 0.75%)
    uint256 public deviationThresholdBps = 75;

    /// @notice Challenge duration (timelock period) in seconds
    uint256 public challengeDurationSec = 16 hours;

    /// @notice Minimum cooldown period between challenges in seconds
    uint256 public constant COOLDOWN_PERIOD = 1 hours;

    /// @notice Maximum allowed challenge duration (7 days)
    uint256 public constant MAX_CHALLENGE_DURATION = 7 days;

    // ============ Events ============

    /// @notice Emitted when an authorized caller is added or removed
    event AuthorizedCallerSet(address indexed caller, bool authorized);

    /// @notice Emitted when deviation threshold is updated
    event DeviationThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    /// @notice Emitted when challenge duration is updated
    event ChallengeDurationUpdated(uint256 oldDuration, uint256 newDuration);

    /// @notice Emitted when strict circuit-breaker support is toggled for a token
    event StrictCircuitBreakerRequirementUpdated(address indexed token, bool oldRequired, bool newRequired);

    /// @notice Emitted when a backup feed is set for a token
    event BackupFeedSet(address indexed token, address indexed backupFeed);

    /// @notice Emitted when a challenge is initiated for a token
    event ChallengeInitiated(
        address indexed token, address indexed challenger, uint256 primaryPrice, uint256 backupPrice, uint256 deviation
    );

    /// @notice Emitted when a challenge is finalized and oracle switches
    event ChallengeFinalized(address indexed token, address indexed finalizer);

    /// @notice Emitted when a challenge is cancelled
    event ChallengeCancelled(address indexed token, string reason);

    /// @notice Emitted when the active oracle is switched for a token
    event OracleSwitched(address indexed token, bool isBackupActive);

    /// @notice Emitted when reverted to primary after market stabilizes
    event RevertedToPrimary(address indexed token, address indexed caller, uint256 deviation);

    /// @notice Emitted when cooldown is applied
    event CooldownApplied(address indexed token, address indexed trigger, uint256 cooldownUntil, string reason);

    // ============ Custom Errors ============

    /// @notice Custom error for unauthorized caller
    error UnauthorizedCaller(address caller);

    /// @notice Custom error for invalid/zero price
    error InvalidPrice(address token, uint256 price);

    /// @notice Custom error for invalid token decimals
    error InvalidTokenDecimals(address token, uint8 decimals);

    /// @notice Custom error for invalid deviation threshold
    error InvalidDeviationThreshold(uint256 threshold);

    /// @notice Custom error for invalid challenge duration
    error InvalidChallengeDuration(uint256 duration);

    /// @notice Custom error when challenge cannot be initiated
    error ChallengeNotPossible(address token, string reason);

    /// @notice Custom error when challenge cannot be finalized
    error FinalizeNotPossible(address token, string reason);

    /// @notice Custom error when challenge cannot be cancelled
    error CancelNotPossible(address token, string reason);

    /// @notice Custom error when revert to primary is not possible
    error RevertNotPossible(address token, string reason);

    /// @notice Custom error when token is not configured for dual-feed
    error NotDualFeedToken(address token);

    /// @notice Custom error when primary and backup feeds are the same
    error SameFeedNotAllowed(address feed);

    /// @notice Custom error when a strict circuit-breaker price is requested from an unsupported feed
    error CircuitBreakerNotSupported(address token, address feed);

    /// @notice Constructor
    constructor() Ownable(msg.sender) { }

    // ============ Admin Functions ============

    /// @notice Set an authorized caller (e.g., factory contract)
    /// @param caller The address to authorize/deauthorize
    /// @param authorized Whether the caller is authorized
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit AuthorizedCallerSet(caller, authorized);
    }

    /// @notice Update the deviation threshold for challenge mechanism
    /// @param newThresholdBps New threshold in basis points (1-10000)
    function setDeviationThreshold(uint256 newThresholdBps) external onlyOwner {
        if (newThresholdBps == 0 || newThresholdBps > 10000) {
            revert InvalidDeviationThreshold(newThresholdBps);
        }
        uint256 oldThreshold = deviationThresholdBps;
        deviationThresholdBps = newThresholdBps;
        emit DeviationThresholdUpdated(oldThreshold, newThresholdBps);
    }

    /// @notice Update the challenge duration
    /// @param newDurationSec New duration in seconds (must be > 0 and <= MAX_CHALLENGE_DURATION)
    function setChallengeDuration(uint256 newDurationSec) external onlyOwner {
        if (newDurationSec == 0 || newDurationSec > MAX_CHALLENGE_DURATION) {
            revert InvalidChallengeDuration(newDurationSec);
        }
        uint256 oldDuration = challengeDurationSec;
        challengeDurationSec = newDurationSec;
        emit ChallengeDurationUpdated(oldDuration, newDurationSec);
    }

    /// @notice Modifier to check if caller is owner or authorized
    modifier onlyAuthorized() {
        if (msg.sender != owner() && !authorizedCallers[msg.sender]) {
            revert UnauthorizedCaller(msg.sender);
        }
        _;
    }

    // ============ ICompositeOracle Implementation ============

    /// @inheritdoc ICompositeOracle
    function setTokenOracleFeed(address token, address oracleFeed) external onlyAuthorized {
        if (token == address(0)) revert InvalidTokenAddress(token);
        if (oracleFeed == address(0)) revert InvalidOracleFeed(oracleFeed);
        _validateStrictCircuitBreakerConfig(token, oracleFeed, address(0));

        TokenOracleConfig storage config = _tokenOracleConfig[token];

        // BUG-2 FIX: Emit events if challenge was pending or backup was active
        if (config.challengeStartTime != 0) {
            emit ChallengeCancelled(token, "Reconfigured to single-feed");
        }
        if (config.isBackupActive) {
            emit OracleSwitched(token, false);
        }

        config.primaryFeed = oracleFeed;
        // Clear backup feed and challenge state if setting single feed
        config.backupFeed = address(0);
        config.isBackupActive = false;
        config.challengeStartTime = 0;
        config.lastChallengeTime = 0; // Reset cooldown state for fresh configuration
        _isTokenSupported[token] = true;

        // Try to detect oracle type from feed description
        try IOracleFeed(oracleFeed).description() returns (string memory desc) {
            _tokenOracleType[token] = _detectOracleType(desc);
        } catch {
            _tokenOracleType[token] = "unknown";
        }

        emit TokenOracleFeedSet(token, oracleFeed);
    }

    /// @notice Set token oracle feed with explicit type
    /// @param token The token address
    /// @param oracleFeed The oracle feed address
    /// @param oracleType The oracle type identifier (e.g., "pyth", "erc4626")
    function setTokenOracleFeedWithType(address token, address oracleFeed, string memory oracleType)
        external
        onlyAuthorized
    {
        if (token == address(0)) revert InvalidTokenAddress(token);
        if (oracleFeed == address(0)) revert InvalidOracleFeed(oracleFeed);
        _validateStrictCircuitBreakerConfig(token, oracleFeed, address(0));

        TokenOracleConfig storage config = _tokenOracleConfig[token];

        // BUG-2 FIX: Emit events if challenge was pending or backup was active
        if (config.challengeStartTime != 0) {
            emit ChallengeCancelled(token, "Reconfigured to single-feed");
        }
        if (config.isBackupActive) {
            emit OracleSwitched(token, false);
        }

        config.primaryFeed = oracleFeed;
        // Clear backup feed and challenge state if setting single feed
        config.backupFeed = address(0);
        config.isBackupActive = false;
        config.challengeStartTime = 0;
        config.lastChallengeTime = 0; // Reset cooldown state for fresh configuration
        _isTokenSupported[token] = true;
        _tokenOracleType[token] = oracleType;

        emit TokenOracleFeedSet(token, oracleFeed);
    }

    /// @inheritdoc ICompositeOracle
    function setTokenOracleFeedDual(address token, address primaryFeed, address backupFeed) external onlyAuthorized {
        if (token == address(0)) revert InvalidTokenAddress(token);
        if (primaryFeed == address(0)) revert InvalidOracleFeed(primaryFeed);
        if (backupFeed == address(0)) revert InvalidOracleFeed(backupFeed);
        // BUG-1 FIX: Validate that primary and backup feeds are different
        if (primaryFeed == backupFeed) revert SameFeedNotAllowed(primaryFeed);
        _validateStrictCircuitBreakerConfig(token, primaryFeed, backupFeed);

        TokenOracleConfig storage config = _tokenOracleConfig[token];

        // BUG-2 FIX: Emit events if challenge was pending or backup was active
        if (config.challengeStartTime != 0) {
            emit ChallengeCancelled(token, "Reconfigured to dual-feed");
        }
        if (config.isBackupActive) {
            emit OracleSwitched(token, false);
        }

        config.primaryFeed = primaryFeed;
        config.backupFeed = backupFeed;
        config.isBackupActive = false;
        config.challengeStartTime = 0;
        config.lastChallengeTime = 0;
        _isTokenSupported[token] = true;

        // Try to detect oracle type from primary feed description
        try IOracleFeed(primaryFeed).description() returns (string memory desc) {
            _tokenOracleType[token] = _detectOracleType(desc);
        } catch {
            _tokenOracleType[token] = "dual";
        }

        emit TokenOracleFeedSet(token, primaryFeed);
        emit BackupFeedSet(token, backupFeed);
    }

    /// @inheritdoc ICompositeOracle
    function setStrictCircuitBreakerRequired(address token, bool required) external onlyAuthorized {
        if (token == address(0)) revert InvalidTokenAddress(token);

        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (required) {
            if (config.primaryFeed == address(0)) revert TokenNotSupported(token);
            _validateStrictCircuitBreakerConfig(token, config.primaryFeed, config.backupFeed, true);
        }

        bool previousRequirement = strictCircuitBreakerRequired[token];
        strictCircuitBreakerRequired[token] = required;
        emit StrictCircuitBreakerRequirementUpdated(token, previousRequirement, required);
    }

    /// @inheritdoc ICompositeOracle
    function removeTokenOracleFeed(address token) external onlyAuthorized {
        if (!_isTokenSupported[token]) revert TokenNotSupported(token);

        TokenOracleConfig storage config = _tokenOracleConfig[token];

        // BUG-4 FIX: Emit events for state being cleared
        if (config.challengeStartTime != 0) {
            emit ChallengeCancelled(token, "Token oracle feed removed");
        }
        if (config.isBackupActive) {
            emit OracleSwitched(token, false);
        }

        delete _tokenOracleConfig[token];
        delete _tokenOracleType[token];
        _isTokenSupported[token] = false;

        emit TokenOracleFeedRemoved(token);
    }

    /// @inheritdoc ICompositeOracle
    function getTokenOracleFeed(address token) external view returns (address) {
        return _tokenOracleConfig[token].primaryFeed;
    }

    /// @inheritdoc ICompositeOracle
    function isTokenSupported(address token) external view returns (bool) {
        return _isTokenSupported[token];
    }

    /// @inheritdoc ICompositeOracle
    function getOracleType(address token) external view returns (string memory) {
        return _tokenOracleType[token];
    }

    // ============ Dual-Feed View Functions ============

    /// @inheritdoc ICompositeOracle
    function getTokenDualFeedStatus(address token)
        external
        view
        returns (
            bool isDualFeed,
            address primaryFeed,
            address backupFeed,
            bool isBackupActive,
            bool isChallengePending,
            uint256 challengeStartTime
        )
    {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        primaryFeed = config.primaryFeed;
        backupFeed = config.backupFeed;
        isDualFeed = backupFeed != address(0);
        isBackupActive = config.isBackupActive;
        challengeStartTime = config.challengeStartTime;
        isChallengePending = challengeStartTime != 0 && !isBackupActive;
    }

    /// @inheritdoc ICompositeOracle
    function isBackupActiveForToken(address token) external view returns (bool) {
        return _tokenOracleConfig[token].isBackupActive;
    }

    /// @notice Get current deviation for a token between primary and backup feeds
    /// @param token The token to check
    /// @return deviation The current deviation in basis points
    function getCurrentDeviation(address token) external view returns (uint256) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.backupFeed == address(0)) revert NotDualFeedToken(token);

        uint256 primaryPrice = IOracleFeed(config.primaryFeed).getPrice(token);
        uint256 backupPrice = IOracleFeed(config.backupFeed).getPrice(token);
        return OracleValidationLib.calculateDeviation(primaryPrice, backupPrice);
    }

    // ============ Challenge Mechanism ============

    /// @inheritdoc ICompositeOracle
    function challengeForToken(address token) external {
        TokenOracleConfig storage config = _tokenOracleConfig[token];

        if (config.backupFeed == address(0)) {
            revert ChallengeNotPossible(token, "Not a dual-feed token");
        }
        if (config.isBackupActive) {
            revert ChallengeNotPossible(token, "Backup oracle already active");
        }
        if (config.challengeStartTime != 0) {
            revert ChallengeNotPossible(token, "Challenge already pending");
        }
        if (block.timestamp < config.lastChallengeTime + COOLDOWN_PERIOD) {
            revert ChallengeNotPossible(token, "Cooldown period not elapsed");
        }

        uint256 primaryPrice = IOracleFeed(config.primaryFeed).getPrice(token);
        uint256 backupPrice = IOracleFeed(config.backupFeed).getPrice(token);

        uint256 deviation = OracleValidationLib.calculateDeviation(primaryPrice, backupPrice);
        if (deviation <= deviationThresholdBps) {
            revert ChallengeNotPossible(token, "Deviation below threshold");
        }

        config.challengeStartTime = block.timestamp;
        config.lastChallengeTime = block.timestamp;

        emit ChallengeInitiated(token, msg.sender, primaryPrice, backupPrice, deviation);
    }

    /// @inheritdoc ICompositeOracle
    function finalizeChallenge(address token) external {
        TokenOracleConfig storage config = _tokenOracleConfig[token];

        if (config.challengeStartTime == 0 || config.isBackupActive) {
            revert FinalizeNotPossible(token, "No challenge pending");
        }
        if (block.timestamp < config.challengeStartTime + challengeDurationSec) {
            revert FinalizeNotPossible(token, "Timelock not elapsed");
        }

        // Verify deviation still persists
        uint256 primaryPrice = IOracleFeed(config.primaryFeed).getPrice(token);
        uint256 backupPrice = IOracleFeed(config.backupFeed).getPrice(token);
        uint256 currentDeviation = OracleValidationLib.calculateDeviation(primaryPrice, backupPrice);

        if (currentDeviation <= deviationThresholdBps) {
            // Deviation resolved during timelock - cancel challenge instead
            config.challengeStartTime = 0;
            config.lastChallengeTime = block.timestamp;

            emit CooldownApplied(token, msg.sender, block.timestamp + COOLDOWN_PERIOD, "finalize_auto_cancelled");
            emit ChallengeCancelled(token, "Deviation resolved during timelock");
            return;
        }

        if (strictCircuitBreakerRequired[token]) {
            _validateStrictCircuitBreakerConfig(token, config.primaryFeed, config.backupFeed, true);
        }

        config.isBackupActive = true;
        config.challengeStartTime = 0;
        config.lastChallengeTime = block.timestamp;

        emit CooldownApplied(token, msg.sender, block.timestamp + COOLDOWN_PERIOD, "challenge_finalized");
        emit ChallengeFinalized(token, msg.sender);
        emit OracleSwitched(token, true);
    }

    /// @inheritdoc ICompositeOracle
    function cancelChallenge(address token) external {
        TokenOracleConfig storage config = _tokenOracleConfig[token];

        if (config.challengeStartTime == 0 || config.isBackupActive) {
            revert CancelNotPossible(token, "No challenge pending");
        }

        // Check if deviation has resolved
        uint256 primaryPrice = IOracleFeed(config.primaryFeed).getPrice(token);
        uint256 backupPrice = IOracleFeed(config.backupFeed).getPrice(token);
        uint256 currentDeviation = OracleValidationLib.calculateDeviation(primaryPrice, backupPrice);

        if (currentDeviation > deviationThresholdBps) {
            revert CancelNotPossible(token, "Deviation still exceeds threshold");
        }

        config.challengeStartTime = 0;
        config.lastChallengeTime = block.timestamp;

        emit CooldownApplied(token, msg.sender, block.timestamp + COOLDOWN_PERIOD, "challenge_cancelled");
        emit ChallengeCancelled(token, "Deviation resolved");
    }

    /// @inheritdoc ICompositeOracle
    function revertToPrimary(address token) external {
        TokenOracleConfig storage config = _tokenOracleConfig[token];

        if (!config.isBackupActive) {
            revert RevertNotPossible(token, "Primary oracle already active");
        }

        // Check if deviation has returned to normal
        uint256 primaryPrice = IOracleFeed(config.primaryFeed).getPrice(token);
        uint256 backupPrice = IOracleFeed(config.backupFeed).getPrice(token);
        uint256 currentDeviation = OracleValidationLib.calculateDeviation(primaryPrice, backupPrice);

        if (currentDeviation > deviationThresholdBps) {
            revert RevertNotPossible(token, "Deviation still exceeds threshold");
        }

        config.isBackupActive = false;
        config.lastChallengeTime = block.timestamp;

        emit CooldownApplied(token, msg.sender, block.timestamp + COOLDOWN_PERIOD, "reverted_to_primary");
        emit RevertedToPrimary(token, msg.sender, currentDeviation);
        emit OracleSwitched(token, false);
    }

    /// @notice Admin function to force reset a token to primary oracle (emergency use)
    /// @dev Only owner can call this. Use with caution. Preserves lastChallengeTime for cooldown.
    /// @param token The token to reset
    function forceResetToPrimary(address token) external onlyOwner {
        TokenOracleConfig storage config = _tokenOracleConfig[token];

        // BUG-5 FIX: Emit ChallengeCancelled if a challenge was pending
        if (config.challengeStartTime != 0) {
            emit ChallengeCancelled(token, "Force reset by owner");
        }

        config.isBackupActive = false;
        config.challengeStartTime = 0;
        // Note: lastChallengeTime intentionally NOT reset to preserve cooldown

        emit OracleSwitched(token, false);
    }

    /// @notice Emergency cancel a pending challenge without price checks (for oracle outage)
    /// @dev BUG-3 FIX: Only owner can call this. Use when oracle feeds are reverting.
    /// @param token The token to cancel challenge for
    function emergencyCancelChallenge(address token) external onlyOwner {
        TokenOracleConfig storage config = _tokenOracleConfig[token];

        if (config.challengeStartTime == 0) {
            revert CancelNotPossible(token, "No challenge pending");
        }

        config.challengeStartTime = 0;
        // Note: lastChallengeTime intentionally NOT reset to preserve cooldown

        emit ChallengeCancelled(token, "Emergency cancelled by owner");
    }

    // ============ Staleness Support for ERC4626OracleFeed ============

    /// @notice Check if a price is stale for a given token
    /// @dev Delegates to the active feed's isPriceStale if available.
    ///      Staleness-aware feeds should expose a staticcall-safe/view helper here.
    ///      Returns (false, block.timestamp) if the active feed lacks staleness support,
    ///      since CompositeOracle already validates prices via its feeds.
    /// @param token The token address
    /// @return isStale True if the price is stale
    /// @return publishTime The timestamp of the price
    function isPriceStale(address token) external view returns (bool isStale, uint64 publishTime) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) return (true, 0);

        address activeFeed =
            (config.backupFeed != address(0) && config.isBackupActive) ? config.backupFeed : config.primaryFeed;

        // Try to delegate to active feed's isPriceStale
        (bool success, bytes memory data) =
            activeFeed.staticcall(abi.encodeWithSignature("isPriceStale(address)", token));

        if (success && data.length >= 64) {
            return abi.decode(data, (bool, uint64));
        }

        // Active feed doesn't support staleness — treat as fresh since CompositeOracle
        // already validates prices through the feed's getPrice()
        return (false, uint64(block.timestamp));
    }

    // ============ IPriceOracle Implementation ============

    /// @notice Internal helper to get price for a token (respects dual-feed active state)
    /// @param token The token address
    /// @return price The price in USD with 8 decimals
    function _getPrice(address token) internal view returns (uint256) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) revert TokenNotSupported(token);

        // Determine which feed to use
        address activeFeed;
        if (config.backupFeed != address(0) && config.isBackupActive) {
            activeFeed = config.backupFeed;
        } else {
            activeFeed = config.primaryFeed;
        }

        // Get price from the active feed
        uint256 price = IOracleFeed(activeFeed).getPrice(token);
        uint8 feedDecimals = IOracleFeed(activeFeed).decimals();

        // Normalize to USD_DECIMALS (8)
        return price.normalize(feedDecimals, ConstantsLib.USD_DECIMALS);
    }

    /// @dev Tries to fetch a circuit-breaker-protected price from the active feed.
    ///      Returns (false, 0) only when the feed does not implement the function.
    ///      If the feed implements it and reverts, the revert is bubbled to preserve safety.
    function _tryGetCircuitBreakerPrice(address feed, address token)
        internal
        view
        returns (bool supported, uint256 price)
    {
        (bool success, bytes memory data) =
            feed.staticcall(abi.encodeCall(IPriceOracle.getPriceWithCircuitBreaker, (token)));

        if (success) {
            uint8 feedDecimals = IOracleFeed(feed).decimals();
            return (true, abi.decode(data, (uint256)).normalize(feedDecimals, ConstantsLib.USD_DECIMALS));
        }

        // Missing function / no fallback.
        if (data.length == 0) {
            return (false, 0);
        }

        // Bubble real circuit-breaker or oracle errors instead of silently downgrading to spot.
        assembly ("memory-safe") {
            revert(add(data, 0x20), mload(data))
        }
    }

    /// @notice Get the price for a token by routing to its registered oracle feed
    /// @param token The token address
    /// @return price The price in USD with 8 decimals
    function getPrice(address token) external view override returns (uint256) {
        return _getPrice(token);
    }

    /// @notice Calculate the value of an amount of tokens in USD
    /// @param token The token address
    /// @param amount The amount of tokens in the token's native ERC20 units
    /// @return value The value in USD with 8 decimals
    function getValue(address token, uint256 amount) external view override returns (uint256) {
        return _getValueForPrice(token, amount, _getPrice(token));
    }

    /// @inheritdoc ICompositeOracle
    function getValueWithFallback(address token, uint256 amount)
        external
        view
        override
        returns (uint256 value, bool isReliable)
    {
        uint256 tokenScale = _getTokenScale(token);
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) revert TokenNotSupported(token);

        // Determine which feed is currently active
        address activeFeed = config.isBackupActive ? config.backupFeed : config.primaryFeed;
        address inactiveFeed = config.isBackupActive ? config.primaryFeed : config.backupFeed;

        // Try active feed first
        try IOracleFeed(activeFeed).getPrice(token) returns (uint256 price) {
            if (price > 0) {
                uint8 feedDecimals = IOracleFeed(activeFeed).decimals();
                uint256 normalizedPrice = price.normalize(feedDecimals, ConstantsLib.USD_DECIMALS);
                return (Math.mulDiv(amount, normalizedPrice, tokenScale), true);
            }
        } catch {
            // Active feed failed, continue to try backup
        }

        // Try inactive feed if available (backup when primary is active, or primary when backup is active)
        if (inactiveFeed != address(0)) {
            try IOracleFeed(inactiveFeed).getPrice(token) returns (uint256 price) {
                if (price > 0) {
                    uint8 feedDecimals = IOracleFeed(inactiveFeed).decimals();
                    uint256 normalizedPrice = price.normalize(feedDecimals, ConstantsLib.USD_DECIMALS);
                    return (Math.mulDiv(amount, normalizedPrice, tokenScale), false);
                }
            } catch {
                // Inactive feed also failed
            }
        }

        // All sources failed
        return (0, false);
    }

    /// @notice Calculate how many tokenB are needed to match the value of tokenA amount
    /// @param tokenA The first token address
    /// @param amountA The amount of tokenA in tokenA's native ERC20 units
    /// @param tokenB The second token address
    /// @return amountB The amount of tokenB in tokenB's native ERC20 units
    function getEquivalentAmount(address tokenA, uint256 amountA, address tokenB)
        external
        view
        override
        returns (uint256)
    {
        uint256 priceA = _getPrice(tokenA);
        uint256 priceB = _getPrice(tokenB);

        // Prevent division by zero using shared library
        OracleValidationLib.validateNonZeroPrice(priceB, tokenB);

        return _getEquivalentAmountForPrices(tokenA, amountA, tokenB, priceA, priceB);
    }

    /// @notice Get price with circuit breaker protection
    /// @dev Delegates to the active feed's getPriceWithCircuitBreaker() and fails closed
    ///      when the feed does not expose a protected pricing path.
    /// @param token The token address
    /// @return price The price in USD with 8 decimals
    function getPriceWithCircuitBreaker(address token) external view override returns (uint256) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) revert TokenNotSupported(token);

        address activeFeed =
            (config.backupFeed != address(0) && config.isBackupActive) ? config.backupFeed : config.primaryFeed;

        (bool supported, uint256 price) = _tryGetCircuitBreakerPrice(activeFeed, token);
        if (supported) {
            return price;
        }

        revert CircuitBreakerNotSupported(token, activeFeed);
    }

    /// @inheritdoc ICompositeOracle
    function getPriceWithStrictCircuitBreaker(address token) external view override returns (uint256) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) revert TokenNotSupported(token);
        _validateStrictCircuitBreakerConfig(token, config.primaryFeed, config.backupFeed, true);

        address activeFeed =
            (config.backupFeed != address(0) && config.isBackupActive) ? config.backupFeed : config.primaryFeed;

        (bool supported, uint256 price) = _tryGetCircuitBreakerPrice(activeFeed, token);
        if (!supported) {
            revert CircuitBreakerNotSupported(token, activeFeed);
        }

        return price;
    }

    /// @notice Calculate equivalent amount with circuit breaker protection
    /// @dev Uses getPriceWithCircuitBreaker() for both tokens to ensure circuit breaker is applied
    /// @param tokenA The first token address
    /// @param amountA The amount of tokenA
    /// @param tokenB The second token address
    /// @return amountB The amount of tokenB with equivalent value
    function getEquivalentAmountWithCircuitBreaker(address tokenA, uint256 amountA, address tokenB)
        external
        view
        override
        returns (uint256)
    {
        uint256 priceA = this.getPriceWithCircuitBreaker(tokenA);
        uint256 priceB = this.getPriceWithCircuitBreaker(tokenB);

        // Prevent division by zero using shared library
        OracleValidationLib.validateNonZeroPrice(priceB, tokenB);

        return _getEquivalentAmountForPrices(tokenA, amountA, tokenB, priceA, priceB);
    }

    // ============ Internal Helper Functions ============

    function _getValueForPrice(address token, uint256 amount, uint256 price) internal view returns (uint256) {
        return Math.mulDiv(amount, price, _getTokenScale(token));
    }

    function _getEquivalentAmountForPrices(
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 priceA,
        uint256 priceB
    ) internal view returns (uint256) {
        uint256 amountAValueUsd = Math.mulDiv(amountA, priceA, _getTokenScale(tokenA));
        return Math.mulDiv(amountAValueUsd, _getTokenScale(tokenB), priceB);
    }

    function _getTokenScale(address token) internal view returns (uint256 tokenScale) {
        uint8 tokenDecimals = 0;
        try IERC20Metadata(token).decimals() returns (uint8 reportedDecimals) {
            tokenDecimals = reportedDecimals;
        } catch {
            revert InvalidTokenAddress(token);
        }

        if (tokenDecimals > 77) revert InvalidTokenDecimals(token, tokenDecimals);
        tokenScale = 10 ** tokenDecimals;
    }

    function _validateStrictCircuitBreakerConfig(address token, address primaryFeed, address backupFeed) internal view {
        _validateStrictCircuitBreakerConfig(token, primaryFeed, backupFeed, strictCircuitBreakerRequired[token]);
    }

    function _validateStrictCircuitBreakerConfig(
        address token,
        address primaryFeed,
        address backupFeed,
        bool requireStrictSupport
    ) internal view {
        if (!requireStrictSupport) {
            return;
        }

        _requireCircuitBreakerSupport(token, primaryFeed);
        if (backupFeed != address(0)) {
            _requireCircuitBreakerSupport(token, backupFeed);
        }
    }

    function _requireCircuitBreakerSupport(address token, address feed) internal view {
        if (!_supportsCircuitBreaker(feed, token)) {
            revert CircuitBreakerNotSupported(token, feed);
        }
    }

    function _supportsCircuitBreaker(address feed, address token) internal view returns (bool) {
        if (feed == address(0)) {
            return false;
        }

        (bool success, bytes memory data) =
            feed.staticcall(abi.encodeCall(IPriceOracle.getPriceWithCircuitBreaker, (token)));

        if (success) {
            return true;
        }

        return data.length != 0;
    }

    /// @notice Detect oracle type from feed description
    /// @param desc The feed description string
    /// @return oracleType The detected oracle type
    function _detectOracleType(string memory desc) internal pure returns (string memory) {
        bytes memory descBytes = bytes(desc);

        // Check for common patterns in description
        if (_containsSubstring(descBytes, "Pyth")) {
            return "pyth";
        }
        if (_containsSubstring(descBytes, "ERC4626") || _containsSubstring(descBytes, "NAV")) {
            return "erc4626";
        }
        if (_containsSubstring(descBytes, "Chainlink")) {
            return "chainlink";
        }
        if (_containsSubstring(descBytes, "TWAP") || _containsSubstring(descBytes, "Uniswap")) {
            return "twap";
        }
        if (_containsSubstring(descBytes, "Mock")) {
            return "mock";
        }

        return "unknown";
    }

    /// @notice Check if a string contains a substring
    /// @param haystack The string to search in
    /// @param needle The substring to search for
    /// @return found True if substring is found
    function _containsSubstring(bytes memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length > haystack.length) return false;

        for (uint256 i = 0; i <= haystack.length - needleBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < needleBytes.length; j++) {
                // Case-insensitive comparison
                bytes1 h = haystack[i + j];
                bytes1 n = needleBytes[j];
                // Convert to lowercase for comparison
                if (h >= 0x41 && h <= 0x5A) h = bytes1(uint8(h) + 32);
                if (n >= 0x41 && n <= 0x5A) n = bytes1(uint8(n) + 32);
                if (h != n) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
