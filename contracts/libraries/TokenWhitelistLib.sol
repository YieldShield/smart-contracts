// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

/// @title TokenWhitelistLib
/// @author David Hawig
/// @notice Library for token whitelist management
library TokenWhitelistLib {
    error TokenNotWhitelisted();
    error TokenAlreadyWhitelisted();
    error InvalidTokenAddress();

    struct TokenInfo {
        string name; // the name of the token
        string symbol; // the symbol of the token
        address token; // the token address
        address primaryOracleFeed; // primary oracle feed for this token's price
        address backupOracleFeed; // backup oracle feed (address(0) if no backup)
        uint256 minCollateralRatioBp; // minimum collateral ratio (basis points) when used as backing asset
    }

    /**
     * @dev Adds a token to whitelist
     * @param tokens Array to add token to
     * @param whitelist Mapping to update
     * @param token Address of the token to whitelist
     */
    function addToken(address[] storage tokens, mapping(address => bool) storage whitelist, address token) external {
        if (token == address(0)) revert InvalidTokenAddress();
        if (whitelist[token]) revert TokenAlreadyWhitelisted();

        tokens.push(token);
        whitelist[token] = true;
    }

    /**
     * @dev Removes a token from whitelist
     * @param tokens Array to remove token from
     * @param whitelist Mapping to update
     * @param token Address of the token to remove
     */
    function removeToken(address[] storage tokens, mapping(address => bool) storage whitelist, address token) external {
        if (!whitelist[token]) revert TokenNotWhitelisted();

        whitelist[token] = false;

        // Remove from array
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len;) {
            if (tokens[i] == token) {
                tokens[i] = tokens[len - 1];
                tokens.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
    }
}
