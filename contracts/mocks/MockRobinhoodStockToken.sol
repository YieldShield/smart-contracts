// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { MockERC20 } from "./MockERC20.sol";

contract MockRobinhoodStockToken is MockERC20 {
    uint256 public uiMultiplier = 1e18;
    uint256 public pendingUIMultiplier = 1e18;
    uint256 public multiplierEffectiveAt;
    bool public oraclePaused;

    event UIMultiplierScheduled(uint256 indexed multiplier, uint256 indexed effectiveAt);
    event UIMultiplierApplied(uint256 indexed multiplier);
    event OraclePausedUpdated(bool indexed paused);

    constructor(string memory name_, string memory symbol_) MockERC20(name_, symbol_) { }

    function scheduleUIMultiplier(uint256 multiplier, uint256 effectiveAt) external onlyOwner {
        require(multiplier > 0, "invalid multiplier");
        pendingUIMultiplier = multiplier;
        multiplierEffectiveAt = effectiveAt;
        emit UIMultiplierScheduled(multiplier, effectiveAt);
    }

    function applyPendingUIMultiplier() external {
        require(multiplierEffectiveAt != 0 && block.timestamp >= multiplierEffectiveAt, "not effective");
        uiMultiplier = pendingUIMultiplier;
        multiplierEffectiveAt = 0;
        emit UIMultiplierApplied(uiMultiplier);
    }

    function setUIMultiplier(uint256 multiplier) external onlyOwner {
        require(multiplier > 0, "invalid multiplier");
        uiMultiplier = multiplier;
        pendingUIMultiplier = multiplier;
        multiplierEffectiveAt = 0;
        emit UIMultiplierApplied(multiplier);
    }

    function setOraclePaused(bool paused) external onlyOwner {
        oraclePaused = paused;
        emit OraclePausedUpdated(paused);
    }

    function balanceOfUI(address account) external view returns (uint256) {
        return balanceOf(account) * uiMultiplier / 1e18;
    }

    function totalSupplyUI() external view returns (uint256) {
        return totalSupply() * uiMultiplier / 1e18;
    }
}
