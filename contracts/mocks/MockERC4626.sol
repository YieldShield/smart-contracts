// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockERC4626 Vault
/// @author David Hawig
/// @notice Simple ERC4626 vault with ownership control for testing purposes.
/// @dev Based on OpenZeppelin's ERC4626 and Ownable implementations.
contract MockERC4626 is ERC4626, Ownable {
    /// @notice Deploys the MockERC4626 vault with initial parameters.
    /// @param asset The underlying asset token (ERC20)
    /// @param name Name of the vault (e.g., "Mock Vault").
    /// @param symbol Vault symbol (e.g., "mVLT").
    constructor(IERC20 asset, string memory name, string memory symbol)
        ERC4626(asset)
        ERC20(name, symbol)
        Ownable(msg.sender)
    {
        // No initial mint - vault starts empty for proper ERC4626 accounting
    }

    /// @notice Mints new shares to a specified address (only owner)
    /// @param to The address to mint shares to
    /// @param amount The amount of shares to mint
    function mintShares(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burns shares from a specified address (only owner)
    /// @param from The address to burn shares from
    /// @param amount The amount of shares to burn
    function burnShares(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
