// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockERC20 Token
/// @author David Hawig
/// @notice Simple ERC20 token with ownership control for testing purposes.
/// @dev Based on OpenZeppelin's ERC20 and Ownable implementations.
contract MockERC20 is ERC20, Ownable {
    /// @notice Transfer fee in basis points (e.g., 100 = 1%)
    uint256 public transferFee = 0;

    /// @notice Deploys the MockERC20 token with initial parameters.
    /// @param name Name of the token (e.g., "Mock Token").
    /// @param symbol Token symbol (e.g., "MTK").
    constructor(string memory name, string memory symbol) ERC20(name, symbol) Ownable(msg.sender) {
        _mint(msg.sender, 1000000 * 10 ** 18);
    }

    /// @notice Mints new tokens to a specified address (only owner)
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burns tokens from a specified address (only owner)
    /// @param from The address to burn tokens from
    /// @param amount The amount of tokens to burn
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    /// @notice Sets the transfer fee (only owner)
    /// @param _transferFee Transfer fee in basis points (e.g., 100 = 1%)
    function setTransferFee(uint256 _transferFee) external onlyOwner {
        require(_transferFee <= 1000, "Transfer fee cannot exceed 10%");
        transferFee = _transferFee;
    }

    /// @notice Override transfer to implement fee-on-transfer
    /// @param to The address to transfer to
    /// @param amount The amount to transfer
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        if (transferFee > 0) {
            uint256 fee = (amount * transferFee) / 10000;
            uint256 transferAmount = amount - fee;

            _transfer(msg.sender, to, transferAmount);
            if (fee > 0) {
                _transfer(msg.sender, owner(), fee);
            }
            return true;
        } else {
            return super.transfer(to, amount);
        }
    }

    /// @notice Override transferFrom to implement fee-on-transfer
    /// @param from The address to transfer from
    /// @param to The address to transfer to
    /// @param amount The amount to transfer
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        if (transferFee > 0) {
            uint256 fee = (amount * transferFee) / 10000;
            uint256 transferAmount = amount - fee;

            _spendAllowance(from, msg.sender, amount);
            _transfer(from, to, transferAmount);
            if (fee > 0) {
                _transfer(from, owner(), fee);
            }
            return true;
        } else {
            return super.transferFrom(from, to, amount);
        }
    }
}
