// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockTokenFaucet
/// @notice Faucet contract that dispenses mock ERC4626 tokens with rate limiting
/// @dev Implements 24-hour rate limiting per address per token
contract MockTokenFaucet is Ownable {
    /// @notice The amount of tokens to drip per request (100 tokens)
    uint256 public constant DRIP_AMOUNT = 100e18;

    /// @notice The cooldown period between drips (24 hours)
    uint256 public constant COOLDOWN_PERIOD = 1 days;

    /// @notice Mapping of token address => recipient address => last drip timestamp
    mapping(address => mapping(address => uint256)) public lastDripTime;

    /// @notice Array of token addresses managed by this faucet
    address[] public tokens;

    /// @notice Mapping to check if a token is enabled
    mapping(address => bool) public enabledTokens;

    /// @notice Event emitted when tokens are dripped
    event TokensDripped(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Event emitted when a token is added
    event TokenAdded(address indexed token);

    /// @notice Event emitted when a token is removed
    event TokenRemoved(address indexed token);

    /// @notice Constructor sets the deployer as owner
    constructor() Ownable(msg.sender) { }

    /// @notice Drip a specific token to a recipient
    /// @param token The token address to drip
    /// @param recipient The address to receive tokens
    function drip(address token, address recipient) external {
        require(enabledTokens[token], "MockTokenFaucet: token not enabled");
        require(
            block.timestamp >= lastDripTime[token][recipient] + COOLDOWN_PERIOD,
            "MockTokenFaucet: cooldown period not elapsed"
        );

        IERC20 tokenContract = IERC20(token);
        uint256 faucetBalance = tokenContract.balanceOf(address(this));
        require(faucetBalance >= DRIP_AMOUNT, "MockTokenFaucet: insufficient balance");

        // Update last drip time
        lastDripTime[token][recipient] = block.timestamp;

        // Transfer tokens to recipient
        require(tokenContract.transfer(recipient, DRIP_AMOUNT), "MockTokenFaucet: transfer failed");

        emit TokensDripped(token, recipient, DRIP_AMOUNT);
    }

    /// @notice Drip all enabled tokens to a recipient
    /// @param recipient The address to receive tokens
    function dripAll(address recipient) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (enabledTokens[token]) {
                // Check if cooldown has elapsed for this token
                if (block.timestamp >= lastDripTime[token][recipient] + COOLDOWN_PERIOD) {
                    IERC20 tokenContract = IERC20(token);
                    uint256 faucetBalance = tokenContract.balanceOf(address(this));
                    if (faucetBalance >= DRIP_AMOUNT) {
                        lastDripTime[token][recipient] = block.timestamp;
                        if (tokenContract.transfer(recipient, DRIP_AMOUNT)) {
                            emit TokensDripped(token, recipient, DRIP_AMOUNT);
                        }
                    }
                }
            }
        }
    }

    /// @notice Add a token to the faucet (owner only)
    /// @param token The token address to add
    function addToken(address token) external onlyOwner {
        require(token != address(0), "MockTokenFaucet: invalid token address");
        require(!enabledTokens[token], "MockTokenFaucet: token already enabled");

        enabledTokens[token] = true;
        tokens.push(token);

        emit TokenAdded(token);
    }

    /// @notice Remove a token from the faucet (owner only)
    /// @param token The token address to remove
    function removeToken(address token) external onlyOwner {
        require(enabledTokens[token], "MockTokenFaucet: token not enabled");

        enabledTokens[token] = false;

        // Remove from tokens array
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == token) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }

        emit TokenRemoved(token);
    }

    /// @notice Set multiple tokens at once (owner only)
    /// @param _tokens Array of token addresses to set
    function setTokens(address[] memory _tokens) external onlyOwner {
        // Clear existing tokens
        for (uint256 i = 0; i < tokens.length; i++) {
            enabledTokens[tokens[i]] = false;
        }
        delete tokens;

        // Add new tokens
        for (uint256 i = 0; i < _tokens.length; i++) {
            require(_tokens[i] != address(0), "MockTokenFaucet: invalid token address");
            enabledTokens[_tokens[i]] = true;
            tokens.push(_tokens[i]);
            emit TokenAdded(_tokens[i]);
        }
    }

    /// @notice Get the number of enabled tokens
    /// @return The number of tokens
    function getTokenCount() external view returns (uint256) {
        return tokens.length;
    }

    /// @notice Get all enabled token addresses
    /// @return Array of token addresses
    function getAllTokens() external view returns (address[] memory) {
        return tokens;
    }

    /// @notice Check if a recipient can request tokens for a specific token
    /// @param token The token address
    /// @param recipient The recipient address
    /// @return canDripNow True if recipient can request tokens
    /// @return nextDripTime Timestamp when next drip is available (0 if can drip now)
    function canDrip(address token, address recipient) external view returns (bool canDripNow, uint256 nextDripTime) {
        if (!enabledTokens[token]) {
            return (false, 0);
        }

        uint256 lastDrip = lastDripTime[token][recipient];
        uint256 nextDrip = lastDrip + COOLDOWN_PERIOD;

        if (block.timestamp >= nextDrip) {
            IERC20 tokenContract = IERC20(token);
            uint256 faucetBalance = tokenContract.balanceOf(address(this));
            return (faucetBalance >= DRIP_AMOUNT, 0);
        } else {
            return (false, nextDrip);
        }
    }
}
