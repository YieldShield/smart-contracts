// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockUSD0
/// @notice Mock implementation of the USD0 stablecoin (Usual Protocol)
/// @dev Simple ERC20 with mint capability for testing
contract MockUSD0 is ERC20, Ownable {
    constructor() ERC20("USD0 Stablecoin", "USD0") Ownable(msg.sender) { }

    /// @notice Returns 18 decimals (standard for USD0)
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Mint tokens to an address (owner only)
    /// @param to Address to mint tokens to
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
