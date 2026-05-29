// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/// @title MockSequencerUptimeFeed
/// @notice Mock Chainlink L2 sequencer uptime feed for testing
/// @dev Simulates the sequencer uptime feed behavior on L2s (Arbitrum, Optimism, Base)
contract MockSequencerUptimeFeed {
    int256 private _answer; // 0 = up, 1 = down
    uint256 private _startedAt; // When the current status began
    uint80 private _roundId;

    constructor() {
        _roundId = 1;
        _answer = 0; // Sequencer up by default
        _startedAt = block.timestamp;
    }

    /// @notice Set sequencer status
    /// @param isUp True if sequencer should be up, false if down
    function setSequencerUp(bool isUp) external {
        int256 newAnswer = isUp ? int256(0) : int256(1);
        if (_answer != newAnswer) {
            _answer = newAnswer;
            _startedAt = block.timestamp; // Status changed
            _roundId++;
        }
    }

    /// @notice Set the startedAt timestamp directly (for testing grace period)
    /// @param startedAt The timestamp when current status began
    function setStartedAt(uint256 startedAt) external {
        _startedAt = startedAt;
    }

    /// @notice Chainlink AggregatorV3Interface compatible function
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, block.timestamp, _roundId);
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }

    function description() external pure returns (string memory) {
        return "Mock L2 Sequencer Uptime Status Feed";
    }

    function version() external pure returns (uint256) {
        return 1;
    }
}
