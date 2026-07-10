// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title USMarketSessionGate
/// @author David Hawig
/// @notice Fail-closed UTC calendar for operations that may open new US-equity risk
/// @dev Governance must explicitly configure every open UTC day. This represents weekends,
///      exchange holidays, early closes, and daylight-saving changes without relying on a
///      weekday approximation. Missing days and malformed status both remain closed. A
///      pause-only guardian can react to unscheduled trading halts but cannot open a session.
contract USMarketSessionGate is Ownable {
    uint32 public constant SECONDS_PER_DAY = 1 days;
    uint256 public constant MAX_SESSION_BATCH = 370;

    struct DailySession {
        uint32 opensAtSecond;
        uint32 closesAtSecond;
    }

    mapping(uint64 => DailySession) private _dailySessions;

    address public emergencyGuardian;
    bool public emergencyPaused;

    error InvalidEmergencyGuardian(address guardian);
    error InvalidSession(uint64 epochDay, uint32 opensAtSecond, uint32 closesAtSecond);
    error InvalidSessionBatch(uint256 epochDays, uint256 opens, uint256 closes);
    error UnauthorizedEmergencyPause(address caller);

    event DailySessionSet(uint64 indexed epochDay, uint32 opensAtSecond, uint32 closesAtSecond);
    event DailySessionCleared(uint64 indexed epochDay);
    event EmergencyGuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event EmergencyPauseUpdated(bool paused, address indexed caller);

    constructor(address initialOwner, address initialEmergencyGuardian) Ownable(initialOwner) {
        if (initialEmergencyGuardian == address(0)) {
            revert InvalidEmergencyGuardian(initialEmergencyGuardian);
        }
        emergencyGuardian = initialEmergencyGuardian;
        emit EmergencyGuardianUpdated(address(0), initialEmergencyGuardian);
    }

    /// @notice Configure one UTC day's open interval
    /// @param epochDay Unix timestamp divided by 1 day
    /// @param opensAtSecond Inclusive UTC second within the day
    /// @param closesAtSecond Exclusive UTC second within the day; 86,400 represents day end
    function setDailySession(uint64 epochDay, uint32 opensAtSecond, uint32 closesAtSecond) external onlyOwner {
        _setDailySession(epochDay, opensAtSecond, closesAtSecond);
    }

    /// @notice Configure multiple explicit UTC sessions atomically
    function setDailySessions(
        uint64[] calldata epochDays,
        uint32[] calldata opensAtSeconds,
        uint32[] calldata closesAtSeconds
    ) external onlyOwner {
        uint256 length = epochDays.length;
        if (
            length == 0 || length > MAX_SESSION_BATCH || opensAtSeconds.length != length
                || closesAtSeconds.length != length
        ) {
            revert InvalidSessionBatch(length, opensAtSeconds.length, closesAtSeconds.length);
        }

        for (uint256 i = 0; i < length;) {
            _setDailySession(epochDays[i], opensAtSeconds[i], closesAtSeconds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Remove a configured day, making it fail closed
    function clearDailySession(uint64 epochDay) external onlyOwner {
        delete _dailySessions[epochDay];
        emit DailySessionCleared(epochDay);
    }

    /// @notice Update the pause-only emergency guardian
    function setEmergencyGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert InvalidEmergencyGuardian(newGuardian);
        address previousGuardian = emergencyGuardian;
        emergencyGuardian = newGuardian;
        emit EmergencyGuardianUpdated(previousGuardian, newGuardian);
    }

    /// @notice Close all sessions immediately
    /// @dev The guardian may only pause. Reopening remains an owner/timelock action.
    function emergencyPause() external {
        if (msg.sender != owner() && msg.sender != emergencyGuardian) {
            revert UnauthorizedEmergencyPause(msg.sender);
        }
        emergencyPaused = true;
        emit EmergencyPauseUpdated(true, msg.sender);
    }

    /// @notice Re-enable the configured calendar after an emergency pause
    function clearEmergencyPause() external onlyOwner {
        emergencyPaused = false;
        emit EmergencyPauseUpdated(false, msg.sender);
    }

    /// @notice Return the configured UTC session for an epoch day
    function getDailySession(uint64 epochDay) external view returns (uint32 opensAtSecond, uint32 closesAtSecond) {
        DailySession memory session = _dailySessions[epochDay];
        return (session.opensAtSecond, session.closesAtSecond);
    }

    /// @notice Whether the configured US-equity session is open at the current timestamp
    function isMarketOpen() external view returns (bool) {
        if (emergencyPaused) return false;

        uint64 epochDay = uint64(block.timestamp / SECONDS_PER_DAY);
        // This modulo derives a deterministic UTC clock offset for calendar
        // lookup; it is never used as randomness or as an unpredictable value.
        // slither-disable-next-line weak-prng
        uint32 secondOfDay = uint32(block.timestamp % SECONDS_PER_DAY);
        DailySession memory session = _dailySessions[epochDay];
        return
            session.closesAtSecond != 0 && secondOfDay >= session.opensAtSecond && secondOfDay < session.closesAtSecond;
    }

    function _setDailySession(uint64 epochDay, uint32 opensAtSecond, uint32 closesAtSecond) internal {
        if (opensAtSecond >= closesAtSecond || closesAtSecond > SECONDS_PER_DAY) {
            revert InvalidSession(epochDay, opensAtSecond, closesAtSecond);
        }
        _dailySessions[epochDay] = DailySession(opensAtSecond, closesAtSecond);
        emit DailySessionSet(epochDay, opensAtSecond, closesAtSecond);
    }
}
