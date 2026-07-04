// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ICompositeOracle } from "../interfaces/ICompositeOracle.sol";
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
        uint256 challengeEndTime; // Timestamp when the pending challenge can be finalized
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

    /// @notice Enumerable active authorized callers
    address[] private _authorizedCallerList;
    mapping(address => uint256) private _authorizedCallerIndexPlusOne;

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

    /// @notice Custom error for invalid authorized caller
    error InvalidAuthorizedCaller(address caller);

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

    /// @notice Custom error when protected pricing is requested while a challenge is pending
    error OracleChallengePending(address token);
    error OraclePriceDisputed(address token);

    /// @notice Constructor
    constructor() Ownable(msg.sender) { }

    // ============ Admin Functions ============

    /// @notice Set an authorized caller (e.g., factory contract)
    /// @param caller The address to authorize/deauthorize
    /// @param authorized Whether the caller is authorized
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        if (caller == address(0)) revert InvalidAuthorizedCaller(caller);
        bool wasAuthorized = authorizedCallers[caller];
        if (wasAuthorized == authorized) {
            emit AuthorizedCallerSet(caller, authorized);
            return;
        }

        authorizedCallers[caller] = authorized;
        if (authorized) {
            _authorizedCallerIndexPlusOne[caller] = _authorizedCallerList.length + 1;
            _authorizedCallerList.push(caller);
        } else {
            _removeAuthorizedCaller(caller);
        }
        emit AuthorizedCallerSet(caller, authorized);
    }

    /// @notice Returns the number of active authorized callers.
    function authorizedCallerCount() external view returns (uint256) {
        return _authorizedCallerList.length;
    }

    /// @notice Returns the active authorized caller at `index`.
    function authorizedCallerAt(uint256 index) external view returns (address) {
        return _authorizedCallerList[index];
    }

    /// @notice Clears every enumerable authorized caller.
    function clearAuthorizedCallers() external onlyOwner {
        while (_authorizedCallerList.length != 0) {
            address caller = _authorizedCallerList[_authorizedCallerList.length - 1];
            authorizedCallers[caller] = false;
            _authorizedCallerList.pop();
            delete _authorizedCallerIndexPlusOne[caller];
            emit AuthorizedCallerSet(caller, false);
        }
    }

    function _removeAuthorizedCaller(address caller) internal {
        uint256 indexPlusOne = _authorizedCallerIndexPlusOne[caller];
        if (indexPlusOne == 0) {
            return;
        }

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _authorizedCallerList.length - 1;
        if (index != lastIndex) {
            address lastCaller = _authorizedCallerList[lastIndex];
            _authorizedCallerList[index] = lastCaller;
            _authorizedCallerIndexPlusOne[lastCaller] = index + 1;
        }

        _authorizedCallerList.pop();
        delete _authorizedCallerIndexPlusOne[caller];
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

        // Codex P2 follow-up: any reconfiguration of the token oracle
        // invalidates a prior pending removal schedule — the migration window
        // applied to the *previous* config, not this new one.
        _clearScheduledRemoval(token);

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
        config.challengeEndTime = 0;
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
        _clearScheduledRemoval(token);

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
        config.challengeEndTime = 0;
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
        _clearScheduledRemoval(token);

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
        config.challengeEndTime = 0;
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

    /// @notice L-4: removal of a token oracle feed is timelocked. Schedule
    ///         the removal via scheduleRemoveTokenOracleFeed, wait
    ///         FEED_REMOVAL_DELAY, then call removeTokenOracleFeed. Users
    ///         and dependent pools have the window to migrate or unwind.
    /// @dev Codex P2 follow-up: schedules expire after FEED_REMOVAL_EXPIRY
    ///      (default 7 days after the delay) so a stale schedule cannot wait
    ///      indefinitely and surprise integrators long after the original
    ///      migration window has passed. Schedules are also cleared whenever
    ///      the token's oracle config changes (setTokenOracleFeed*) so the
    ///      migration window applies to the actually-being-removed config.
    uint256 public constant FEED_REMOVAL_DELAY = 1 days;
    uint256 public constant FEED_REMOVAL_EXPIRY = 7 days;

    mapping(address => uint256) public scheduledRemovalTime;

    event TokenOracleFeedRemovalScheduled(address indexed token, uint256 executableAt);
    event TokenOracleFeedRemovalCancelled(address indexed token);

    error TokenOracleFeedRemovalNotScheduled(address token);
    error TokenOracleFeedRemovalTooEarly(address token, uint256 executableAt);
    error TokenOracleFeedRemovalExpired(address token, uint256 expiredAt);

    function scheduleRemoveTokenOracleFeed(address token) external onlyAuthorized {
        if (!_isTokenSupported[token]) revert TokenNotSupported(token);
        uint256 executableAt = block.timestamp + FEED_REMOVAL_DELAY;
        scheduledRemovalTime[token] = executableAt;
        emit TokenOracleFeedRemovalScheduled(token, executableAt);
    }

    function cancelScheduledRemoveTokenOracleFeed(address token) external onlyAuthorized {
        // slither-disable-next-line incorrect-equality
        if (scheduledRemovalTime[token] == 0) revert TokenOracleFeedRemovalNotScheduled(token);
        delete scheduledRemovalTime[token];
        emit TokenOracleFeedRemovalCancelled(token);
    }

    /// @dev Internal helper called from every setTokenOracleFeed* path so a
    ///      mid-window oracle reconfiguration invalidates the prior removal
    ///      schedule. The new config gets a fresh migration window if removal
    ///      is later intended.
    function _clearScheduledRemoval(address token) internal {
        if (scheduledRemovalTime[token] != 0) {
            delete scheduledRemovalTime[token];
            emit TokenOracleFeedRemovalCancelled(token);
        }
    }

    /// @inheritdoc ICompositeOracle
    /// @dev L-4: timelocked. Requires a prior scheduleRemoveTokenOracleFeed
    ///      call at least FEED_REMOVAL_DELAY ago and at most
    ///      (FEED_REMOVAL_DELAY + FEED_REMOVAL_EXPIRY) ago.
    function removeTokenOracleFeed(address token) external onlyAuthorized {
        if (!_isTokenSupported[token]) revert TokenNotSupported(token);
        uint256 executableAt = scheduledRemovalTime[token];
        // slither-disable-next-line incorrect-equality
        if (executableAt == 0) revert TokenOracleFeedRemovalNotScheduled(token);
        if (block.timestamp < executableAt) revert TokenOracleFeedRemovalTooEarly(token, executableAt);
        uint256 expiresAt = executableAt + FEED_REMOVAL_EXPIRY;
        if (block.timestamp >= expiresAt) {
            delete scheduledRemovalTime[token];
            revert TokenOracleFeedRemovalExpired(token, expiresAt);
        }
        delete scheduledRemovalTime[token];

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

        // Clear the strict circuit-breaker requirement when removing the feed; otherwise
        // re-adding the token with a single feed lacking circuit-breaker support would
        // revert in `setTokenOracleFeed` against a stale flag.
        if (strictCircuitBreakerRequired[token]) {
            strictCircuitBreakerRequired[token] = false;
            emit StrictCircuitBreakerRequirementUpdated(token, true, false);
        }

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

    /// @inheritdoc ICompositeOracle
    function isTokenChallengeable(address token) external view returns (bool) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) return false;
        if (config.challengeStartTime != 0 && !config.isBackupActive) return true;

        return _hasUnresolvedDualFeedDeviation(config, token);
    }

    /// @notice Get current deviation for a token between primary and backup feeds
    /// @dev L-5: returns type(uint256).max if either feed fails to produce a
    ///      price, so off-chain monitoring can distinguish "no signal" from
    ///      "real deviation" instead of seeing the call revert. The strict
    ///      internal _calculateFeedDeviation is unchanged and still reverts.
    /// @param token The token to check
    /// @return deviation Deviation in basis points, or type(uint256).max on
    ///         partial feed failure
    function getCurrentDeviation(address token) external view returns (uint256) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.backupFeed == address(0)) revert NotDualFeedToken(token);

        (bool primarySuccess, uint256 primaryPrice) = _tryGetNormalizedFeedPrice(config.primaryFeed, token);
        (bool backupSuccess, uint256 backupPrice) = _tryGetNormalizedDisputeFeedPrice(config.backupFeed, token);
        if (!primarySuccess || !backupSuccess) return type(uint256).max;
        return OracleValidationLib.calculateDeviation(primaryPrice, backupPrice);
    }

    /// @dev Returns the absolute deviation in bps between two feeds for a token, after
    ///      normalising both prices to `USD_DECIMALS`. The challenge mechanism compares
    ///      raw integers, so feeds with different `decimals()` would otherwise produce
    ///      astronomical false deviations and let any caller force-trip the dual-feed
    ///      switch without any real price divergence.
    function _calculateFeedDeviation(address primaryFeed, address backupFeed, address token)
        internal
        view
        returns (uint256)
    {
        (bool primarySuccess, uint256 primaryPrice) = _tryGetNormalizedFeedPrice(primaryFeed, token);
        (bool backupSuccess, uint256 backupPrice) = _tryGetNormalizedFeedPrice(backupFeed, token);
        if (!primarySuccess || !backupSuccess) {
            revert InvalidPrice(token, 0);
        }
        return OracleValidationLib.calculateDeviation(primaryPrice, backupPrice);
    }

    function _tryGetNormalizedFeedPrice(address feed, address token)
        internal
        view
        returns (bool success, uint256 normalizedPrice)
    {
        try IOracleFeed(feed).getPrice(token) returns (uint256 price) {
            if (price == 0) {
                return (false, 0);
            }
            try IOracleFeed(feed).decimals() returns (uint8 feedDecimals) {
                return _tryNormalizeFeedPrice(price, feedDecimals);
            } catch {
                return (false, 0);
            }
        } catch {
            return (false, 0);
        }
    }

    /// @dev Named wrapper for dispute-gate reads. It intentionally uses the same
    ///      protected `getPrice` path as normal feed reads, rather than `getPriceUnsafe`,
    ///      so feed-level circuit breakers still apply during challenge checks.
    function _tryGetNormalizedDisputeFeedPrice(address feed, address token)
        internal
        view
        returns (bool success, uint256 normalizedPrice)
    {
        return _tryGetNormalizedFeedPrice(feed, token);
    }

    /// @dev Returns true when the primary active feed is already unsafe for protected
    ///      pricing even if no public challenge has been started yet.
    ///
    ///      A transient failure of the backup feed must NOT, on its own, mark the
    ///      primary as disputed — the protected primary often has its own circuit
    ///      breaker, and `challengeForToken` independently requires a working backup
    ///      before any real dispute can land. Earlier revisions returned `true`
    ///      whenever the backup reverted (including transient Pyth confidence
    ///      widening on a healthy Chainlink primary), DoSing every protected
    ///      `getPrice/getValue/getEquivalentAmount` call on the token.
    ///
    ///      However, `setTokenOracleFeedDual` only requires the backup to support
    ///      the circuit-breaker selector — non-strict tokens may pair a CB-backup
    ///      with a primary that has NO safe/unsafe split of its own. In that
    ///      configuration the dual-feed deviation check is the primary's only
    ///      safety net, and quietly serving the primary while the backup is down
    ///      would re-introduce the very gap dual-feed mode is meant to plug
    ///      (raised by Codex on PR #21). We therefore only suppress the dispute on
    ///      backup failure when the primary itself currently supports the circuit
    ///      breaker; otherwise we fail closed and keep the token disputed.
    function _hasUnresolvedDualFeedDeviation(TokenOracleConfig storage config, address token)
        internal
        view
        returns (bool)
    {
        if (config.backupFeed == address(0)) {
            return false;
        }

        bool primarySupportsCircuitBreaker = _supportsCircuitBreaker(config.primaryFeed, token);
        bool backupSupportsCircuitBreaker = _supportsCircuitBreaker(config.backupFeed, token);

        if (config.isBackupActive) {
            (bool activePrimarySuccess, uint256 activePrimaryPrice) =
                _tryGetNormalizedFeedPrice(config.primaryFeed, token);
            bool activePrimaryProtectedAvailable = activePrimarySuccess && primarySupportsCircuitBreaker;
            if (!activePrimaryProtectedAvailable) {
                return false;
            }

            if (!backupSupportsCircuitBreaker) {
                return true;
            }

            (bool activeBackupSuccess, uint256 activeBackupPrice) =
                _tryGetNormalizedDisputeFeedPrice(config.backupFeed, token);
            if (!activeBackupSuccess) {
                return true;
            }

            return OracleValidationLib.calculateDeviation(activePrimaryPrice, activeBackupPrice) > deviationThresholdBps;
        }

        if (!backupSupportsCircuitBreaker) {
            // A backup that no longer advertises the protected/unsafe split cannot
            // be used as a dispute signal. If the primary has its own circuit
            // breaker, keep serving it; otherwise fail closed until governance
            // repairs the dual-feed configuration.
            return !primarySupportsCircuitBreaker;
        }

        (bool backupSuccess, uint256 backupPrice) = _tryGetNormalizedDisputeFeedPrice(config.backupFeed, token);
        if (!backupSuccess) {
            // Backup is the only safety net for primaries that lack a circuit
            // breaker. If the primary has its own CB, defer to it; otherwise
            // fail closed until the backup recovers.
            return !primarySupportsCircuitBreaker;
        }

        (bool primarySuccess, uint256 primaryPrice) = _tryGetNormalizedFeedPrice(config.primaryFeed, token);
        bool primaryProtectedAvailable = primarySuccess && primarySupportsCircuitBreaker;
        uint256 deviation = primaryProtectedAvailable
            ? OracleValidationLib.calculateDeviation(primaryPrice, backupPrice)
            : type(uint256).max;

        return deviation > deviationThresholdBps;
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

        (bool primarySuccess, uint256 primaryPrice) = _tryGetNormalizedFeedPrice(config.primaryFeed, token);
        (bool backupSuccess, uint256 backupPrice) = _tryGetNormalizedDisputeFeedPrice(config.backupFeed, token);
        if (!backupSuccess) {
            revert ChallengeNotPossible(token, "Backup oracle unavailable");
        }
        _requireCircuitBreakerSupport(token, config.backupFeed);

        bool primaryProtectedAvailable = primarySuccess && _supportsCircuitBreaker(config.primaryFeed, token);
        uint256 deviation = primaryProtectedAvailable
            ? OracleValidationLib.calculateDeviation(primaryPrice, backupPrice)
            : type(uint256).max;
        if (deviation <= deviationThresholdBps) {
            revert ChallengeNotPossible(token, "Deviation below threshold");
        }

        config.challengeStartTime = block.timestamp;
        config.challengeEndTime = block.timestamp + challengeDurationSec;
        config.lastChallengeTime = block.timestamp;

        emit ChallengeInitiated(token, msg.sender, primarySuccess ? primaryPrice : 0, backupPrice, deviation);
    }

    /// @inheritdoc ICompositeOracle
    function finalizeChallenge(address token) external {
        TokenOracleConfig storage config = _tokenOracleConfig[token];

        if (config.challengeStartTime == 0 || config.isBackupActive) {
            revert FinalizeNotPossible(token, "No challenge pending");
        }
        uint256 challengeEndTime =
            config.challengeEndTime == 0 ? config.challengeStartTime + challengeDurationSec : config.challengeEndTime;
        if (block.timestamp < challengeEndTime) {
            revert FinalizeNotPossible(token, "Timelock not elapsed");
        }

        (bool primarySuccess, uint256 primaryPrice) = _tryGetNormalizedFeedPrice(config.primaryFeed, token);
        (bool backupSuccess, uint256 backupPrice) = _tryGetNormalizedDisputeFeedPrice(config.backupFeed, token);
        if (!backupSuccess) {
            revert FinalizeNotPossible(token, "Backup oracle unavailable");
        }

        // Verify deviation still persists unless the primary is unavailable. A broken primary
        // is itself sufficient reason to complete the timelocked failover to a healthy backup.
        bool primaryProtectedAvailable = primarySuccess && _supportsCircuitBreaker(config.primaryFeed, token);
        uint256 currentDeviation = primaryProtectedAvailable
            ? OracleValidationLib.calculateDeviation(primaryPrice, backupPrice)
            : type(uint256).max;

        if (currentDeviation <= deviationThresholdBps) {
            // Deviation resolved during timelock - cancel challenge instead.
            // Preserve `lastChallengeTime` set at challenge initiation; the cooldown
            // already runs from then, so resetting it here would only let any caller
            // extend the lockout against future legitimate challenges.
            config.challengeStartTime = 0;
            config.challengeEndTime = 0;

            emit CooldownApplied(
                token, msg.sender, config.lastChallengeTime + COOLDOWN_PERIOD, "finalize_auto_cancelled"
            );
            emit ChallengeCancelled(token, "Deviation resolved during timelock");
            return;
        }

        // Once activated, the backup becomes the feed used by protected pool valuation paths.
        // Do not re-check the primary protected path here: the challenge may be
        // completing precisely because that path is now unusable.
        _requireCircuitBreakerSupport(token, config.backupFeed);

        config.isBackupActive = true;
        config.challengeStartTime = 0;
        config.challengeEndTime = 0;
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

        (bool primarySuccess, uint256 primaryPrice) = _tryGetNormalizedFeedPrice(config.primaryFeed, token);
        (bool backupSuccess, uint256 backupPrice) = _tryGetNormalizedDisputeFeedPrice(config.backupFeed, token);
        if (!primarySuccess || !backupSuccess) {
            revert CancelNotPossible(token, "Oracle unavailable");
        }

        bool primaryProtectedAvailable = _supportsCircuitBreaker(config.primaryFeed, token);
        uint256 currentDeviation = primaryProtectedAvailable
            ? OracleValidationLib.calculateDeviation(primaryPrice, backupPrice)
            : type(uint256).max;

        if (currentDeviation > deviationThresholdBps) {
            revert CancelNotPossible(token, "Deviation still exceeds threshold");
        }

        // Preserve `lastChallengeTime` set at challenge initiation. Resetting it on
        // cancel would let anyone extend the cooldown lockout each time a brief
        // deviation appears and resolves, suppressing legitimate future challenges.
        config.challengeStartTime = 0;
        config.challengeEndTime = 0;

        emit CooldownApplied(token, msg.sender, config.lastChallengeTime + COOLDOWN_PERIOD, "challenge_cancelled");
        emit ChallengeCancelled(token, "Deviation resolved");
    }

    /// @inheritdoc ICompositeOracle
    function revertToPrimary(address token) external {
        TokenOracleConfig storage config = _tokenOracleConfig[token];

        if (!config.isBackupActive) {
            revert RevertNotPossible(token, "Primary oracle already active");
        }

        (bool primarySuccess, uint256 primaryPrice) = _tryGetNormalizedFeedPrice(config.primaryFeed, token);
        bool backupSupportsCircuitBreaker = _supportsCircuitBreaker(config.backupFeed, token);
        (bool backupSuccess, uint256 backupPrice) = _tryGetNormalizedDisputeFeedPrice(config.backupFeed, token);
        bool primaryProtectedAvailable = primarySuccess && _supportsCircuitBreaker(config.primaryFeed, token);
        if (!primaryProtectedAvailable) {
            revert RevertNotPossible(token, "Primary oracle unavailable");
        }

        uint256 currentDeviation = type(uint256).max;
        if (backupSupportsCircuitBreaker && backupSuccess) {
            currentDeviation = OracleValidationLib.calculateDeviation(primaryPrice, backupPrice);
            if (currentDeviation > deviationThresholdBps) {
                revert RevertNotPossible(token, "Deviation still exceeds threshold");
            }
        }

        config.isBackupActive = false;
        config.lastChallengeTime = block.timestamp;

        emit CooldownApplied(token, msg.sender, block.timestamp + COOLDOWN_PERIOD, "reverted_to_primary");
        emit RevertedToPrimary(token, msg.sender, currentDeviation);
        emit OracleSwitched(token, false);
    }

    /// @notice M-8: timelock on emergency overrides. Owner schedules the
    ///         action, waits EMERGENCY_OVERRIDE_DELAY, then executes. Users
    ///         can withdraw / front-run in the window if the override is
    ///         hostile. Cancellation is unilateral.
    /// @dev Codex P1 follow-up: schedules are bound to a state nonce
    ///      (`challengeStartTime` for ACTION_EMERGENCY_CANCEL, `isBackupActive`
    ///      for ACTION_FORCE_RESET) so a schedule made before any challenge
    ///      exists cannot be silently reused against a *later* challenge —
    ///      the timelock window resets on every state change. Schedules also
    ///      expire after EMERGENCY_OVERRIDE_EXPIRY to avoid indefinite stale
    ///      entries.
    uint256 public constant EMERGENCY_OVERRIDE_DELAY = 2 hours;
    uint256 public constant EMERGENCY_OVERRIDE_EXPIRY = 1 days;

    struct EmergencyOverrideSchedule {
        uint64 executableAt;
        uint64 expiresAt;
        bytes32 stateNonce; // hash of the live oracle state at schedule time
    }

    /// @dev Scheduled override per (token, action). executableAt == 0 = not scheduled.
    mapping(bytes32 => EmergencyOverrideSchedule) public emergencyOverrides;

    event EmergencyOverrideScheduled(
        address indexed token, bytes32 indexed action, uint256 executableAt, bytes32 stateNonce
    );
    event EmergencyOverrideCancelled(address indexed token, bytes32 indexed action);

    error EmergencyOverrideNotScheduled(address token, bytes32 action);
    error EmergencyOverrideTooEarly(address token, bytes32 action, uint256 executableAt);
    error EmergencyOverrideExpired(address token, bytes32 action, uint256 expiredAt);
    error EmergencyOverrideStateChanged(address token, bytes32 action);
    error EmergencyOverridePreconditionNotMet(address token, bytes32 action, string reason);

    bytes32 private constant ACTION_FORCE_RESET = keccak256("forceResetToPrimary");
    bytes32 private constant ACTION_EMERGENCY_CANCEL = keccak256("emergencyCancelChallenge");

    function _overrideKey(address token, bytes32 action) internal pure returns (bytes32) {
        return keccak256(abi.encode(token, action));
    }

    function _stateNonce(address token, bytes32 action) internal view returns (bytes32) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (action == ACTION_EMERGENCY_CANCEL) {
            // Bind to the active challenge so a cancel scheduled for one
            // challenge cannot be reused against a later challenge.
            return keccak256(abi.encode("CANCEL", config.challengeStartTime, config.challengeEndTime));
        }
        // ACTION_FORCE_RESET binds to whether backup is currently active —
        // resetting a system that is already on primary is meaningless, and
        // a schedule taken before backup activation must not survive into a
        // future activation.
        return keccak256(abi.encode("RESET", config.isBackupActive, config.challengeStartTime, config.challengeEndTime));
    }

    function _requireOverridePrecondition(address token, bytes32 action) internal view {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (action == ACTION_EMERGENCY_CANCEL) {
            if (config.challengeStartTime == 0) {
                revert EmergencyOverridePreconditionNotMet(token, action, "No challenge pending");
            }
        } else if (action == ACTION_FORCE_RESET) {
            if (!config.isBackupActive && config.challengeStartTime == 0) {
                revert EmergencyOverridePreconditionNotMet(token, action, "Already on primary");
            }
        }
    }

    function _scheduleOverride(address token, bytes32 action) internal {
        // Require the action to be meaningful right now: there must be a
        // pending challenge to cancel, or an active backup / challenge to reset.
        _requireOverridePrecondition(token, action);

        bytes32 key = _overrideKey(token, action);
        emergencyOverrides[key] = EmergencyOverrideSchedule({
            executableAt: uint64(block.timestamp + EMERGENCY_OVERRIDE_DELAY),
            expiresAt: uint64(block.timestamp + EMERGENCY_OVERRIDE_DELAY + EMERGENCY_OVERRIDE_EXPIRY),
            stateNonce: _stateNonce(token, action)
        });
        emit EmergencyOverrideScheduled(
            token, action, block.timestamp + EMERGENCY_OVERRIDE_DELAY, emergencyOverrides[key].stateNonce
        );
    }

    function _consumeOverride(address token, bytes32 action) internal {
        bytes32 key = _overrideKey(token, action);
        EmergencyOverrideSchedule memory schedule = emergencyOverrides[key];
        // slither-disable-next-line incorrect-equality
        if (schedule.executableAt == 0) revert EmergencyOverrideNotScheduled(token, action);
        if (block.timestamp < schedule.executableAt) {
            revert EmergencyOverrideTooEarly(token, action, schedule.executableAt);
        }
        if (block.timestamp >= schedule.expiresAt) {
            delete emergencyOverrides[key];
            revert EmergencyOverrideExpired(token, action, schedule.expiresAt);
        }
        // Re-check the state nonce so an override scheduled against one
        // challenge cannot be executed against a different one finalised
        // during the timelock window.
        if (schedule.stateNonce != _stateNonce(token, action)) {
            delete emergencyOverrides[key];
            revert EmergencyOverrideStateChanged(token, action);
        }
        // Also re-check the precondition — the live state may have advanced
        // back to a state where the action would be a no-op.
        _requireOverridePrecondition(token, action);
        delete emergencyOverrides[key];
    }

    function scheduleForceResetToPrimary(address token) external onlyOwner {
        _scheduleOverride(token, ACTION_FORCE_RESET);
    }

    function scheduleEmergencyCancelChallenge(address token) external onlyOwner {
        _scheduleOverride(token, ACTION_EMERGENCY_CANCEL);
    }

    function cancelScheduledOverride(address token, bytes32 action) external onlyOwner {
        bytes32 key = _overrideKey(token, action);
        // slither-disable-next-line incorrect-equality
        if (emergencyOverrides[key].executableAt == 0) revert EmergencyOverrideNotScheduled(token, action);
        delete emergencyOverrides[key];
        emit EmergencyOverrideCancelled(token, action);
    }

    /// @notice Admin function to force reset a token to primary oracle (emergency use)
    /// @dev Now timelocked — first call scheduleForceResetToPrimary, then wait
    ///      EMERGENCY_OVERRIDE_DELAY before this executes.
    /// @param token The token to reset
    function forceResetToPrimary(address token) external onlyOwner {
        _consumeOverride(token, ACTION_FORCE_RESET);
        TokenOracleConfig storage config = _tokenOracleConfig[token];

        // BUG-5 FIX: Emit ChallengeCancelled if a challenge was pending
        if (config.challengeStartTime != 0) {
            emit ChallengeCancelled(token, "Force reset by owner");
        }

        config.isBackupActive = false;
        config.challengeStartTime = 0;
        config.challengeEndTime = 0;
        // Note: lastChallengeTime intentionally NOT reset to preserve cooldown

        emit OracleSwitched(token, false);
    }

    /// @notice Emergency cancel a pending challenge without price checks (for oracle outage)
    /// @dev Now timelocked — first call scheduleEmergencyCancelChallenge, then
    ///      wait EMERGENCY_OVERRIDE_DELAY before this executes.
    /// @param token The token to cancel challenge for
    function emergencyCancelChallenge(address token) external onlyOwner {
        _consumeOverride(token, ACTION_EMERGENCY_CANCEL);
        TokenOracleConfig storage config = _tokenOracleConfig[token];

        if (config.challengeStartTime == 0) {
            revert CancelNotPossible(token, "No challenge pending");
        }

        config.challengeStartTime = 0;
        config.challengeEndTime = 0;
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
        if (config.challengeStartTime != 0 && !config.isBackupActive) return (true, 0);
        if (_hasUnresolvedDualFeedDeviation(config, token)) return (true, 0);

        address activeFeed =
            (config.backupFeed != address(0) && config.isBackupActive) ? config.backupFeed : config.primaryFeed;

        // Try to delegate to active feed's isPriceStale
        (bool success, bytes memory data) =
            activeFeed.staticcall(abi.encodeWithSignature("isPriceStale(address)", token));

        if (success && data.length >= 64) {
            return abi.decode(data, (bool, uint64));
        }

        // M-9: active feed doesn't expose isPriceStale. Fail closed (true, 0)
        // instead of pretending the price is fresh — a downstream consumer
        // (e.g., ERC4626OracleFeed._checkUnderlyingStaleness) would otherwise
        // silently lose its staleness gate when the underlying composite
        // resolves to a feed without the helper.
        return (true, 0);
    }

    // ============ IPriceOracle Implementation ============

    /// @notice Internal helper for the SAFE price path
    /// @dev Fails closed when a challenge is pending, when an unresolved dual-feed deviation
    ///      exists, or when the active feed lacks a circuit-breaker discipline. The
    ///      challenge-gate checks live in this helper so every safe entry point
    ///      (`getPrice`, `getValue`, `getEquivalentAmount`) inherits them automatically.
    /// @param token The token address
    /// @return price The price in USD with 8 decimals
    function _getPrice(address token) internal view returns (uint256) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) revert TokenNotSupported(token);
        if (config.challengeStartTime != 0 && !config.isBackupActive) revert OracleChallengePending(token);
        if (_hasUnresolvedDualFeedDeviation(config, token)) revert OraclePriceDisputed(token);

        address activeFeed =
            (config.backupFeed != address(0) && config.isBackupActive) ? config.backupFeed : config.primaryFeed;

        if (!_supportsCircuitBreaker(activeFeed, token)) {
            revert CircuitBreakerNotSupported(token, activeFeed);
        }

        // After the safe-default rename, every CB-capable feed exposes its protected
        // computation under `getPrice` (the unprotected path lives behind `getPriceUnsafe`).
        // Calling `getPrice` here therefore inherits the feed-level circuit breaker.
        uint256 price = IOracleFeed(activeFeed).getPrice(token);
        uint8 feedDecimals = IOracleFeed(activeFeed).decimals();

        return _normalizeFeedPriceOrRevert(token, price, feedDecimals);
    }

    function _getPriceForFeeAccrual(address token) internal view returns (uint256) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) revert TokenNotSupported(token);
        if (config.challengeStartTime != 0 && !config.isBackupActive) revert OracleChallengePending(token);
        if (_hasUnresolvedDualFeedDeviation(config, token)) revert OraclePriceDisputed(token);

        address activeFeed =
            (config.backupFeed != address(0) && config.isBackupActive) ? config.backupFeed : config.primaryFeed;

        if (!_supportsCircuitBreaker(activeFeed, token)) {
            revert CircuitBreakerNotSupported(token, activeFeed);
        }

        (bool feePriceSupported, uint256 feePrice) = _tryGetFeeAccrualPrice(activeFeed, token);
        uint8 feedDecimals = IOracleFeed(activeFeed).decimals();
        if (feePriceSupported) {
            return _normalizeFeedPriceOrRevert(token, feePrice, feedDecimals);
        }

        uint256 price = IOracleFeed(activeFeed).getPrice(token);
        return _normalizeFeedPriceOrRevert(token, price, feedDecimals);
    }

    /// @notice Internal helper for the UNSAFE price path
    /// @dev Bypasses challenge-gate checks and returns the active feed's price even when
    ///      the dual-feed challenge mechanism flags it as disputed. Used only by the
    ///      explicit `*Unsafe` external entry points.
    function _getPriceUnsafe(address token) internal view returns (uint256) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) revert TokenNotSupported(token);

        address activeFeed =
            (config.backupFeed != address(0) && config.isBackupActive) ? config.backupFeed : config.primaryFeed;

        // Probe the feed's `getPriceUnsafe(address)` selector first so callers that
        // explicitly opted into the unsafe path receive raw spot pricing where available.
        // Feeds without the unsafe split (PythEMA, UniswapV3 TWAP) fall back to `getPrice`,
        // which is their canonical (and only) price computation.
        (bool unsafeSupported, uint256 unsafePrice) = _tryGetUnsafePrice(activeFeed, token);
        if (unsafeSupported) {
            uint8 unsafeDecimals = IOracleFeed(activeFeed).decimals();
            return _normalizeFeedPriceOrRevert(token, unsafePrice, unsafeDecimals);
        }

        uint256 price = IOracleFeed(activeFeed).getPrice(token);
        uint8 feedDecimals = IOracleFeed(activeFeed).decimals();
        return _normalizeFeedPriceOrRevert(token, price, feedDecimals);
    }

    /// @dev Best-effort wrapper around the feed's `getPriceUnsafe(address)` selector.
    ///      Returns (false, 0) when the feed does not implement it. Reverts that the
    ///      feed surfaces from a present selector are bubbled so callers do not silently
    ///      receive a stale or zero value.
    function _tryGetUnsafePrice(address feed, address token) internal view returns (bool supported, uint256 price) {
        if (feed.code.length == 0) {
            return (false, 0);
        }

        (bool success, bytes memory data) = feed.staticcall(abi.encodeWithSignature("getPriceUnsafe(address)", token));

        if (success) {
            if (data.length < 32) {
                return (false, 0);
            }
            return (true, abi.decode(data, (uint256)));
        }

        // Selector not implemented — fall back to the canonical `getPrice` path.
        if (data.length == 0) {
            return (false, 0);
        }

        // Bubble real revert reasons from a present `getPriceUnsafe` implementation.
        assembly ("memory-safe") {
            revert(add(data, 0x20), mload(data))
        }
    }

    function _tryGetFeeAccrualPrice(address feed, address token) internal view returns (bool supported, uint256 price) {
        if (feed.code.length == 0) {
            return (false, 0);
        }

        (bool success, bytes memory data) =
            feed.staticcall(abi.encodeWithSignature("getPriceForFeeAccrual(address)", token));

        if (success) {
            if (data.length < 32) {
                return (false, 0);
            }
            return (true, abi.decode(data, (uint256)));
        }

        if (data.length == 0) {
            return (false, 0);
        }

        assembly ("memory-safe") {
            revert(add(data, 0x20), mload(data))
        }
    }

    /// @notice Get the safest-available price for a token via its registered oracle feed
    /// @dev Honours the dual-feed challenge gate and feed-level circuit breakers.
    ///      Production write paths must use this entry point.
    /// @param token The token address
    /// @return price The price in USD with 8 decimals
    function getPrice(address token) external view override returns (uint256) {
        return _getPrice(token);
    }

    /// @notice Fee-accrual price that preserves challenge gates but lets feeds expose live bounded NAV
    /// @dev Falls back to protected `getPrice` for feeds without a dedicated fee-accrual selector.
    function getPriceForFeeAccrual(address token) external view returns (uint256) {
        return _getPriceForFeeAccrual(token);
    }

    /// @notice Unprotected price getter — bypasses dual-feed challenge gates
    /// @dev Reserved for read-only callers (off-chain analytics, NFT metadata, monitoring).
    function getPriceUnsafe(address token) external view override returns (uint256) {
        return _getPriceUnsafe(token);
    }

    /// @notice Calculate the protected USD value of an amount of tokens
    /// @dev Uses the same circuit-breaker-validated price as `getPrice`.
    function getValue(address token, uint256 amount) external view override returns (uint256) {
        return _getValueForPrice(token, amount, _getPrice(token));
    }

    /// @notice Unprotected USD value getter — bypasses dual-feed challenge gates
    function getValueUnsafe(address token, uint256 amount) external view override returns (uint256) {
        return _getValueForPrice(token, amount, _getPriceUnsafe(token));
    }

    /// @inheritdoc ICompositeOracle
    /// @dev Fails closed when the active feed is disputed:
    ///      - If a challenge is pending, the active primary is explicitly under dispute.
    ///      - If the backup/comparison feed is unavailable, the active primary cannot be verified.
    ///      - If `isBackupActive == true`, the primary feed is the known-bad inactive feed;
    ///        do NOT silently fall back to it (H-3).
    ///      - If `_hasUnresolvedDualFeedDeviation == true`, the dual-feed challenge mechanism
    ///        has already flagged the active feed as unsafe; skip the inactive feed too.
    ///      Otherwise the inactive feed is the legitimate backup of an undisputed primary
    ///      and may safely serve as a fallback when the active feed has a transient failure.
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
        // Cache the dual-feed deviation result — the helper is `view` and reads the
        // same storage twice in this function, costing ~4 extra staticcalls per
        // fallback price read when the primary supports the safe/unsafe split.
        bool unresolvedDualFeedDeviation = _hasUnresolvedDualFeedDeviation(config, token);
        bool activeFeedDisputed =
            (config.challengeStartTime != 0 && !config.isBackupActive) || unresolvedDualFeedDeviation;

        if (activeFeedDisputed) {
            return (0, false);
        }
        if (!_supportsCircuitBreaker(activeFeed, token)) {
            return (0, false);
        }

        // Try active feed first
        try IOracleFeed(activeFeed).getPrice(token) returns (uint256 price) {
            if (price > 0) {
                uint8 feedDecimals = IOracleFeed(activeFeed).decimals();
                (bool normalized, uint256 normalizedPrice) = _tryNormalizeFeedPrice(price, feedDecimals);
                if (normalized) {
                    return (Math.mulDiv(amount, normalizedPrice, tokenScale), true);
                }
            }
        } catch {
            // Active feed failed, continue to evaluate the fallback policy below.
        }

        // H-3 FIX: never silently re-promote a feed governance has already moved off of.
        // When the backup is active, the inactive feed is the disabled primary. When
        // an unresolved deviation exists, both feeds are mutually suspect — fail closed.
        bool inactiveFeedDisputed = config.isBackupActive || unresolvedDualFeedDeviation;

        if (inactiveFeed != address(0) && !inactiveFeedDisputed && _supportsCircuitBreaker(inactiveFeed, token)) {
            try IOracleFeed(inactiveFeed).getPrice(token) returns (uint256 price) {
                if (price > 0) {
                    uint8 feedDecimals = IOracleFeed(inactiveFeed).decimals();
                    (bool normalized, uint256 normalizedPrice) = _tryNormalizeFeedPrice(price, feedDecimals);
                    if (normalized) {
                        return (Math.mulDiv(amount, normalizedPrice, tokenScale), false);
                    }
                }
            } catch {
                // Inactive feed also failed
            }
        }

        // All sources failed (or the inactive feed is disputed and intentionally skipped).
        return (0, false);
    }

    /// @notice Calculate how many tokenB are needed to match the value of tokenA amount
    /// @dev Uses the safe `_getPrice` path for both tokens.
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

    /// @notice Unprotected equivalent-amount calculator — bypasses dual-feed challenge gates
    function getEquivalentAmountUnsafe(address tokenA, uint256 amountA, address tokenB)
        external
        view
        override
        returns (uint256)
    {
        uint256 priceA = _getPriceUnsafe(tokenA);
        uint256 priceB = _getPriceUnsafe(tokenB);

        OracleValidationLib.validateNonZeroPrice(priceB, tokenB);

        return _getEquivalentAmountForPrices(tokenA, amountA, tokenB, priceA, priceB);
    }

    /// @inheritdoc ICompositeOracle
    /// @dev Strict variant additionally requires the active feed to advertise the safe/unsafe
    ///      split (i.e. expose a `getPriceUnsafe(address)` selector). Feeds that do not
    ///      (PythEMA, UniswapV3 TWAP) are rejected with `CircuitBreakerNotSupported`.
    function getPriceWithStrictCircuitBreaker(address token) external view override returns (uint256) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) revert TokenNotSupported(token);
        if (config.challengeStartTime != 0 && !config.isBackupActive) revert OracleChallengePending(token);
        if (_hasUnresolvedDualFeedDeviation(config, token)) revert OraclePriceDisputed(token);

        address activeFeed =
            (config.backupFeed != address(0) && config.isBackupActive) ? config.backupFeed : config.primaryFeed;

        if (!_supportsCircuitBreaker(activeFeed, token)) {
            revert CircuitBreakerNotSupported(token, activeFeed);
        }
        if (!_supportsStrictProtectedPrice(activeFeed, token)) {
            revert CircuitBreakerNotSupported(token, activeFeed);
        }

        uint256 price = IOracleFeed(activeFeed).getPrice(token);
        if (price == 0) {
            revert CircuitBreakerNotSupported(token, activeFeed);
        }
        uint8 feedDecimals = IOracleFeed(activeFeed).decimals();
        return _normalizeFeedPriceOrRevert(token, price, feedDecimals);
    }

    /// @inheritdoc ICompositeOracle
    function supportsStrictProtectedPrice(address token) external view override returns (bool) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) {
            return false;
        }

        address activeFeed =
            (config.backupFeed != address(0) && config.isBackupActive) ? config.backupFeed : config.primaryFeed;
        return _supportsStrictProtectedPrice(activeFeed, token);
    }

    /// @notice Whether this wrapper exposes the protected/unsafe price split for `token`.
    /// @dev Exposed as an explicit capability marker so callers do not infer support from
    ///      arbitrary fallback revert data.
    function supportsCircuitBreaker(address token) external view returns (bool) {
        TokenOracleConfig storage config = _tokenOracleConfig[token];
        if (config.primaryFeed == address(0)) {
            return false;
        }

        address activeFeed =
            (config.backupFeed != address(0) && config.isBackupActive) ? config.backupFeed : config.primaryFeed;
        return _supportsCircuitBreaker(activeFeed, token);
    }

    // ============ Internal Helper Functions ============

    function _getValueForPrice(address token, uint256 amount, uint256 price) internal view returns (uint256) {
        return Math.mulDiv(amount, price, _getTokenScale(token));
    }

    function _tryNormalizeFeedPrice(uint256 price, uint8 feedDecimals)
        internal
        pure
        returns (bool success, uint256 normalizedPrice)
    {
        if (feedDecimals > 77) {
            return (false, 0);
        }
        normalizedPrice = price.normalize(feedDecimals, ConstantsLib.USD_DECIMALS);
        return (normalizedPrice != 0, normalizedPrice);
    }

    function _normalizeFeedPriceOrRevert(address token, uint256 price, uint8 feedDecimals)
        internal
        pure
        returns (uint256 normalizedPrice)
    {
        (bool success, uint256 normalized) = _tryNormalizeFeedPrice(price, feedDecimals);
        if (!success) {
            revert InvalidPrice(token, 0);
        }
        return normalized;
    }

    function _getEquivalentAmountForPrices(
        address tokenA,
        uint256 amountA,
        address tokenB,
        uint256 priceA,
        uint256 priceB
    ) internal view returns (uint256) {
        uint256 tokenScaleA = _getTokenScale(tokenA);
        uint256 tokenScaleB = _getTokenScale(tokenB);

        if (priceA <= type(uint256).max / tokenScaleB && priceB <= type(uint256).max / tokenScaleA) {
            return Math.mulDiv(amountA, priceA * tokenScaleB, priceB * tokenScaleA);
        }

        uint256 amountAValueUsd = Math.mulDiv(amountA, priceA, tokenScaleA);
        return Math.mulDiv(amountAValueUsd, tokenScaleB, priceB);
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
        bool strictRequired
    ) internal view {
        _requireCircuitBreakerSupport(token, primaryFeed);
        if (strictRequired) {
            _requireStrictProtectedPriceSupport(token, primaryFeed);
        }

        if (backupFeed != address(0)) {
            _requireCircuitBreakerSupport(token, backupFeed);
            if (strictRequired) {
                _requireStrictProtectedPriceSupport(token, backupFeed);
            }
        }
    }

    function _requireCircuitBreakerSupport(address token, address feed) internal view {
        if (!_supportsCircuitBreaker(feed, token)) {
            revert CircuitBreakerNotSupported(token, feed);
        }
    }

    function _requireStrictProtectedPriceSupport(address token, address feed) internal view {
        if (!_supportsStrictProtectedPrice(feed, token)) {
            revert CircuitBreakerNotSupported(token, feed);
        }
    }

    /// @dev A feed "supports the circuit breaker" if it explicitly advertises the
    ///      protected/unsafe split via `supportsCircuitBreaker(address)`. Legacy feeds
    ///      without the marker are accepted only when `getPriceUnsafe(address)` currently
    ///      succeeds with a 32-byte return. Revert data is intentionally not treated as
    ///      proof of support because generic fallbacks can also revert with custom errors.
    function _supportsCircuitBreaker(address feed, address token) internal view returns (bool) {
        if (feed == address(0)) {
            return false;
        }
        // staticcall to a no-code address succeeds with empty returndata, which would
        // falsely register an EOA as supporting the circuit breaker. Require code.
        if (feed.code.length == 0) {
            return false;
        }

        (bool markerSuccess, bytes memory markerData) =
            feed.staticcall(abi.encodeWithSignature("supportsCircuitBreaker(address)", token));
        if (markerSuccess && markerData.length >= 32) {
            return abi.decode(markerData, (bool));
        }

        (bool unsafeSuccess, bytes memory unsafeData) =
            feed.staticcall(abi.encodeWithSignature("getPriceUnsafe(address)", token));

        if (unsafeSuccess) {
            return unsafeData.length >= 32;
        }
        return false;
    }

    function _supportsStrictProtectedPrice(address feed, address token) internal view returns (bool) {
        if (feed.code.length == 0) {
            return false;
        }

        (bool success, bytes memory data) =
            feed.staticcall(abi.encodeWithSignature("supportsStrictProtectedPrice(address)", token));

        if (!success || data.length < 32) return false;
        return abi.decode(data, (bool));
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
