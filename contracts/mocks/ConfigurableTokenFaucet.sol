// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ConfigurableTokenFaucet
/// @notice Drips configured ERC20 test assets with per-token amounts and cooldowns.
contract ConfigurableTokenFaucet is Ownable {
    uint256 public constant COOLDOWN_PERIOD = 1 days;

    mapping(address => mapping(address => uint256)) public lastDripTime;
    mapping(address => bool) public enabledTokens;
    mapping(address => uint256) public dripAmount;

    address[] public tokens;

    event TokenConfigured(address indexed token, uint256 dripAmount);
    event TokenRemoved(address indexed token);
    event TokensDripped(address indexed token, address indexed recipient, uint256 amount);

    constructor(address owner_) Ownable(owner_) { }

    function setTokens(address[] memory newTokens, uint256[] memory newDripAmounts) external onlyOwner {
        require(newTokens.length == newDripAmounts.length, "ConfigurableTokenFaucet: length mismatch");

        for (uint256 i = 0; i < tokens.length; i++) {
            enabledTokens[tokens[i]] = false;
            dripAmount[tokens[i]] = 0;
        }
        delete tokens;

        for (uint256 i = 0; i < newTokens.length; i++) {
            tokens.push(newTokens[i]);
            _configureToken(newTokens[i], newDripAmounts[i]);
        }
    }

    function configureToken(address token, uint256 amount) external onlyOwner {
        if (!enabledTokens[token]) {
            tokens.push(token);
        }
        _configureToken(token, amount);
    }

    function removeToken(address token) external onlyOwner {
        require(enabledTokens[token], "ConfigurableTokenFaucet: token not enabled");

        enabledTokens[token] = false;
        dripAmount[token] = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == token) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }

        emit TokenRemoved(token);
    }

    function drip(address token, address recipient) external {
        (bool canDripNow,) = canDrip(token, recipient);
        require(canDripNow, "ConfigurableTokenFaucet: drip unavailable");

        uint256 amount = dripAmount[token];
        lastDripTime[token][recipient] = block.timestamp;
        require(IERC20(token).transfer(recipient, amount), "ConfigurableTokenFaucet: transfer failed");

        emit TokensDripped(token, recipient, amount);
    }

    function dripAll(address recipient) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            (bool canDripNow,) = canDrip(token, recipient);
            if (!canDripNow) {
                continue;
            }

            uint256 amount = dripAmount[token];
            lastDripTime[token][recipient] = block.timestamp;
            if (IERC20(token).transfer(recipient, amount)) {
                emit TokensDripped(token, recipient, amount);
            }
        }
    }

    function getTokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function getAllTokens() external view returns (address[] memory) {
        return tokens;
    }

    function canDrip(address token, address recipient) public view returns (bool canDripNow, uint256 nextDripTime) {
        if (!enabledTokens[token]) {
            return (false, 0);
        }

        uint256 lastDrip = lastDripTime[token][recipient];
        if (lastDrip != 0) {
            uint256 nextDrip = lastDrip + COOLDOWN_PERIOD;
            if (block.timestamp < nextDrip) {
                return (false, nextDrip);
            }
        }

        uint256 amount = dripAmount[token];
        return (amount > 0 && IERC20(token).balanceOf(address(this)) >= amount, 0);
    }

    function _configureToken(address token, uint256 amount) internal {
        require(token != address(0), "ConfigurableTokenFaucet: invalid token");
        require(amount > 0, "ConfigurableTokenFaucet: invalid amount");

        enabledTokens[token] = true;
        dripAmount[token] = amount;

        emit TokenConfigured(token, amount);
    }
}
