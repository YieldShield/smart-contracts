// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ISequencerUptimeFeed
/// @notice Minimal Chainlink interface used to read an L2 sequencer uptime feed.
interface ISequencerUptimeFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title SequencerUptimeGuard
/// @author David Hawig
/// @notice Shared L2 sequencer-uptime + grace-period gate for oracle feeds.
/// @dev Mirrors the gate already built into ChainlinkOracleFeed so that the
///      Pyth/TWAP/ERC4626 feeds get the same protection without duplicating the
///      logic. Inheriting feeds call `_checkSequencerUptime()` before returning a
///      price. The deploying account becomes owner (via Ownable). These feeds are
///      deployed directly (non-upgradeable), so adding storage here is safe.
///
///      On a known L2 (Arbitrum/Optimism/Base/Robinhood + their testnets) the requirement
///      defaults on: a deployment must configure a sequencer uptime feed, or
///      explicitly opt out via `setSequencerUptimeFeedRequired(false)`, otherwise
///      every price read reverts. This is the same fail-closed posture as
///      ChainlinkOracleFeed.
abstract contract SequencerUptimeGuard is Ownable {
    /// @notice Grace period after the sequencer comes back up (1 hour).
    /// @dev Prices may be stale during this window as oracles catch up.
    uint256 public constant GRACE_PERIOD_TIME = 3600;

    /// @notice L2 sequencer uptime feed (address(0) on L1 or when not needed).
    ISequencerUptimeFeed public sequencerUptimeFeed;

    /// @notice Whether this deployment must have a sequencer uptime feed configured.
    bool public sequencerUptimeFeedRequired;

    /// @notice Emitted when the sequencer uptime feed is set or cleared.
    event SequencerUptimeFeedSet(address indexed oldFeed, address indexed newFeed);

    /// @notice Emitted when the sequencer uptime feed requirement changes.
    event SequencerUptimeFeedRequiredSet(bool oldRequired, bool newRequired);

    /// @notice Custom error for an invalid sequencer feed address at registration.
    error InvalidSequencerFeedAddress(address feed);

    /// @notice Custom error when the L2 sequencer is reported down.
    error SequencerDown();

    /// @notice Custom error when a known L2 deployment has no sequencer feed configured.
    error SequencerUptimeFeedRequired(uint256 chainId);

    /// @notice Custom error when the sequencer grace period has not elapsed.
    /// @param timeSinceUp Seconds since the sequencer came back up.
    /// @param gracePeriod Required grace period in seconds.
    error GracePeriodNotOver(uint256 timeSinceUp, uint256 gracePeriod);

    constructor() Ownable(msg.sender) {
        sequencerUptimeFeedRequired = _isKnownL2RequiringSequencer(block.chainid);
    }

    /// @notice Set the L2 sequencer uptime feed (Arbitrum/Optimism/Base).
    /// @dev Set to address(0) to disable the check (L1 or not needed), unless the
    ///      deployment requires a feed, in which case clearing it reverts.
    /// @param _sequencerUptimeFeed The Chainlink sequencer uptime feed address.
    function setSequencerUptimeFeed(address _sequencerUptimeFeed) external onlyOwner {
        address oldFeed = address(sequencerUptimeFeed);
        if (_sequencerUptimeFeed == address(0) && _requiresSequencerUptimeFeed()) {
            revert SequencerUptimeFeedRequired(block.chainid);
        }

        if (_sequencerUptimeFeed != address(0)) {
            // Reject EOAs / addresses with no code: a staticcall to a codeless
            // address succeeds with empty returndata, which would otherwise
            // surface as an opaque decode revert instead of a clear error.
            if (_sequencerUptimeFeed.code.length == 0) revert InvalidSequencerFeedAddress(_sequencerUptimeFeed);
            ISequencerUptimeFeed feed = ISequencerUptimeFeed(_sequencerUptimeFeed);
            // Only answer + startedAt are relevant for a sequencer uptime feed;
            // roundId/updatedAt/answeredInRound are intentionally unused.
            // slither-disable-next-line unused-return
            try feed.latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
                // Sequencer status: 0 = up, 1 = down. Reject anything else.
                if (answer != 0 && answer != 1) revert InvalidSequencerFeedAddress(_sequencerUptimeFeed);
                // Reject uninitialized or future-dated startedAt; both would brick reads.
                if (startedAt == 0 || startedAt > block.timestamp) {
                    revert InvalidSequencerFeedAddress(_sequencerUptimeFeed);
                }
            } catch {
                revert InvalidSequencerFeedAddress(_sequencerUptimeFeed);
            }
        }

        sequencerUptimeFeed = ISequencerUptimeFeed(_sequencerUptimeFeed);
        emit SequencerUptimeFeedSet(oldFeed, _sequencerUptimeFeed);
    }

    /// @notice Configure whether this deployment must use a sequencer uptime feed.
    /// @dev Defaults to true for known L2 chain IDs; can be toggled for newly
    ///      supported L2s (or testnets without a published feed) without redeploying.
    function setSequencerUptimeFeedRequired(bool required) external onlyOwner {
        bool oldRequired = sequencerUptimeFeedRequired;
        sequencerUptimeFeedRequired = required;
        emit SequencerUptimeFeedRequiredSet(oldRequired, required);
    }

    /// @notice Sequencer status for monitoring/frontends.
    /// @return isUp True if the sequencer is up (or no feed configured and none required).
    /// @return gracePeriodPassed True if the grace period has elapsed (or no feed).
    /// @return timeSinceUp Seconds since the sequencer came back up (0 if no feed).
    function getSequencerStatus() external view returns (bool isUp, bool gracePeriodPassed, uint256 timeSinceUp) {
        if (address(sequencerUptimeFeed) == address(0)) {
            if (_requiresSequencerUptimeFeed()) return (false, false, 0);
            return (true, true, 0);
        }

        // Only answer + startedAt are needed; the rest of the round tuple is
        // intentionally unused.
        // slither-disable-next-line unused-return
        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        isUp = answer == 0;
        if (startedAt == 0) return (false, false, 0);
        if (startedAt > block.timestamp) return (isUp, false, 0);
        timeSinceUp = block.timestamp - startedAt;
        gracePeriodPassed = timeSinceUp > GRACE_PERIOD_TIME;
    }

    /// @notice Revert unless the L2 sequencer is up and the grace period has elapsed.
    /// @dev No-op when no feed is configured and none is required (L1 / local).
    function _checkSequencerUptime() internal view {
        if (address(sequencerUptimeFeed) == address(0)) {
            if (_requiresSequencerUptimeFeed()) revert SequencerUptimeFeedRequired(block.chainid);
            return;
        }

        // Only answer + startedAt are needed; the rest of the round tuple is
        // intentionally unused.
        // slither-disable-next-line unused-return
        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();

        // Reject incomplete rounds: startedAt == 0 would let the grace check pass trivially.
        if (startedAt == 0) revert SequencerDown();
        // Answer: 0 = up, anything else = down/malformed.
        if (answer != 0) revert SequencerDown();
        // Future-dated startedAt (reporter clock skew) → treat as grace not elapsed.
        if (startedAt > block.timestamp) revert GracePeriodNotOver(0, GRACE_PERIOD_TIME);
        uint256 timeSinceUp = block.timestamp - startedAt;
        if (timeSinceUp <= GRACE_PERIOD_TIME) revert GracePeriodNotOver(timeSinceUp, GRACE_PERIOD_TIME);
    }

    function _isSequencerUnavailableForStaleness() internal view returns (bool) {
        if (address(sequencerUptimeFeed) == address(0)) {
            return _requiresSequencerUptimeFeed();
        }

        try sequencerUptimeFeed.latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
            if (startedAt == 0) return true;
            if (answer != 0) return true;
            if (startedAt > block.timestamp) return true;
            return block.timestamp - startedAt <= GRACE_PERIOD_TIME;
        } catch {
            return true;
        }
    }

    function _requiresSequencerUptimeFeed() internal view returns (bool) {
        return sequencerUptimeFeedRequired;
    }

    function _isKnownL2RequiringSequencer(uint256 chainId) internal pure returns (bool) {
        return chainId == 10 || chainId == 11155420 || chainId == 8453 || chainId == 84532 || chainId == 42161
            || chainId == 421614 || chainId == 4663 || chainId == 46630;
    }
}
