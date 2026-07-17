// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract MockChainlinkAggregator is Ownable {
    uint8 private immutable _decimals;
    string private _description;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    int192 public minAnswer;
    int192 public maxAnswer;

    event AnswerRefreshed(uint80 indexed roundId, int256 answer, uint256 updatedAt, address indexed caller);

    constructor(string memory description_, uint8 decimals_, int256 answer_) Ownable(msg.sender) {
        _description = description_;
        _decimals = decimals_;
        _roundId = 1;
        _answer = answer_;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
        minAnswer = 1;
        maxAnswer = type(int192).max;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function setAnswer(int256 answer_) external onlyOwner {
        _roundId++;
        _answer = answer_;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
    }

    /// @notice Signals that this test feed supports depositor-triggered freshness updates.
    /// @dev Production Chainlink aggregators do not expose this capability. Consumers must
    ///      probe it explicitly instead of assuming every Chainlink-shaped feed is writable.
    function supportsUserUpdates() external pure returns (bool) {
        return true;
    }

    /// @notice Advances the mock round and timestamp without allowing the caller to choose a price.
    /// @dev This is intentionally permissionless for testnet rehearsal flows. Price changes remain
    ///      owner-only through `setAnswer`, preventing depositors from manipulating pool valuation.
    function refresh() external {
        _roundId++;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
        emit AnswerRefreshed(_roundId, _answer, _updatedAt, msg.sender);
    }

    function setRoundData(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external onlyOwner {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function setBounds(int192 minAnswer_, int192 maxAnswer_) external onlyOwner {
        require(minAnswer_ < maxAnswer_, "invalid bounds");
        minAnswer = minAnswer_;
        maxAnswer = maxAnswer_;
    }
}
