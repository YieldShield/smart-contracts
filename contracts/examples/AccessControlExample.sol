// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IPoolAccessControl } from "../interfaces/IPoolAccessControl.sol";

/// @title AccessControlExample
/// @notice Example access control contract for SplitRiskPool with whitelist functionality
/// @dev Similar to Morpho V2's GateExample, allows pool creators to control who can deposit and withdraw
/// @dev Uses a simple whitelist approach: whitelisted accounts can perform all operations
contract AccessControlExample is IPoolAccessControl {
    address public owner;

    mapping(address => bool) public whitelisted;

    /* ERRORS */
    error Unauthorized();

    /* EVENTS */
    event OwnerUpdated(address indexed previousOwner, address indexed newOwner);
    event WhitelistUpdated(address indexed account, bool isWhitelisted);

    constructor(address _owner) {
        if (_owner == address(0)) revert Unauthorized();
        owner = _owner;
    }

    /* ROLE FUNCTIONS */

    /// @notice Set the owner of the access control contract
    /// @param newOwner The new owner address
    function setOwner(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newOwner == address(0)) revert Unauthorized();
        address previousOwner = owner;
        owner = newOwner;
        emit OwnerUpdated(previousOwner, newOwner);
    }

    /// @notice Set whether an account is whitelisted
    /// @param account The account to whitelist/unwhitelist
    /// @param isWhitelisted Whether the account should be whitelisted
    function setWhitelisted(address account, bool isWhitelisted) external {
        if (msg.sender != owner) revert Unauthorized();
        whitelisted[account] = isWhitelisted;
        emit WhitelistUpdated(account, isWhitelisted);
    }

    /// @notice Batch set multiple accounts as whitelisted
    /// @param accounts Array of accounts to whitelist
    /// @param isWhitelisted Whether the accounts should be whitelisted
    function batchSetWhitelisted(address[] calldata accounts, bool isWhitelisted) external {
        if (msg.sender != owner) revert Unauthorized();
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelisted[accounts[i]] = isWhitelisted;
            emit WhitelistUpdated(accounts[i], isWhitelisted);
        }
    }

    /* VIEW FUNCTIONS */

    /// @notice Check if an account can deposit shielded assets
    /// @param account The account to check
    /// @return true if the account is whitelisted
    function canDepositShielded(address account) external view returns (bool) {
        return whitelisted[account];
    }

    /// @notice Check if an account can withdraw shielded assets
    /// @param account The account to check
    /// @return true if the account is whitelisted
    function canWithdrawShielded(address account) external view returns (bool) {
        return whitelisted[account];
    }

    /// @notice Check if an account can deposit protector assets
    /// @param account The account to check
    /// @return true if the account is whitelisted
    function canDepositProtector(address account) external view returns (bool) {
        return whitelisted[account];
    }

    /// @notice Check if an account can withdraw protector assets
    /// @param account The account to check
    /// @return true if the account is whitelisted
    function canWithdrawProtector(address account) external view returns (bool) {
        return whitelisted[account];
    }
}
