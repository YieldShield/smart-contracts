// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

/// @title IPoolAccessControl
/// @notice Interface for access control contracts that restrict pool operations
/// @dev Similar to Morpho V2's Gates, allows pool creators to control who can deposit and withdraw
interface IPoolAccessControl {
    /// @notice Checks if an account can deposit shielded assets
    /// @param account The account to check
    /// @return true if the account can deposit shielded assets, false otherwise
    function canDepositShielded(address account) external view returns (bool);

    /// @notice Checks if an account can withdraw shielded assets
    /// @param account The account to check
    /// @return true if the account can withdraw shielded assets, false otherwise
    function canWithdrawShielded(address account) external view returns (bool);

    /// @notice Checks if an account can deposit protector assets
    /// @param account The account to check
    /// @return true if the account can deposit protector assets, false otherwise
    function canDepositProtector(address account) external view returns (bool);

    /// @notice Checks if an account can withdraw protector assets
    /// @param account The account to check
    /// @return true if the account can withdraw protector assets, false otherwise
    function canWithdrawProtector(address account) external view returns (bool);
}
