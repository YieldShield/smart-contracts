// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockERC20Decimals
/// @author David Hawig
/// @notice Configurable-decimals ERC20 used for mixed-decimal test coverage
contract MockERC20Decimals is ERC20, Ownable {
    uint8 private immutable tokenDecimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) Ownable(msg.sender) {
        tokenDecimals = decimals_;
        _mint(msg.sender, 1_000_000 * 10 ** decimals_);
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
