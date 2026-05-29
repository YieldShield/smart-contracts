// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockUSDC Token
/// @author David Hawig
/// @notice Mock USDC token with 6 decimals for testing
contract MockUSDC is ERC20, Ownable {
    /// @notice Number of decimals (6 like real USDC)
    uint8 private constant USDC_DECIMALS = 6;

    constructor() ERC20("USD Coin", "USDC") Ownable(msg.sender) {
        // Mint 1 million USDC to deployer
        _mint(msg.sender, 1000000 * 10 ** USDC_DECIMALS);
    }

    /// @notice Returns 6 decimals like real USDC
    function decimals() public pure override returns (uint8) {
        return USDC_DECIMALS;
    }

    /// @notice Mints new tokens to a specified address (only owner)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burns tokens from a specified address (only owner)
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
