// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockGauntletUSDCPrime
/// @author David Hawig
/// @notice Mock implementation of the Gauntlet USDC Prime Morpho vault
/// @dev Simulates ERC4626 vault behavior with time-based yield accrual
///      Real vault: https://app.morpho.org/ethereum/vault/0xdd0f28e19C1780eb6396170735D45153D261490d
///      CoinGecko: https://www.coingecko.com/en/coins/gauntlet-usdc-prime-morpho-vault
contract MockGauntletUSDCPrime is ERC4626, Ownable {
    using Math for uint256;

    /// @notice Timestamp of last yield accrual
    uint256 public lastYieldAccrualTime;

    /// @notice Annual yield in basis points (e.g., 500 = 5% APY)
    uint256 public annualYieldBps;

    /// @notice Accumulated yield multiplier (scaled by 1e18)
    /// @dev Starts at 1e18 (1:1 ratio), increases as yield accrues
    uint256 public accumulatedYieldMultiplier;

    /// @notice Precision for yield calculations
    uint256 private constant PRECISION = 1e18;

    /// @notice Basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Seconds per year for yield calculation
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    /// @notice Emitted when yield is accrued
    event YieldAccrued(uint256 newMultiplier, uint256 yieldAmount, uint256 timeElapsed);

    /// @notice Emitted when annual yield rate is updated
    event AnnualYieldUpdated(uint256 oldYieldBps, uint256 newYieldBps);

    /// @notice Constructor
    /// @param _usdc The underlying USDC token (6 decimals)
    /// @param _annualYieldBps Annual yield in basis points (e.g., 500 = 5%)
    constructor(IERC20 _usdc, uint256 _annualYieldBps)
        ERC4626(_usdc)
        ERC20("Gauntlet USDC Prime", "gtUSDC")
        Ownable(msg.sender)
    {
        annualYieldBps = _annualYieldBps;
        accumulatedYieldMultiplier = PRECISION; // Start at 1:1
        lastYieldAccrualTime = block.timestamp;
    }

    /// @notice Update the annual yield rate
    /// @param _newYieldBps New yield rate in basis points
    function setAnnualYield(uint256 _newYieldBps) external onlyOwner {
        // Accrue pending yield before changing rate
        _accrueYield();

        uint256 oldYield = annualYieldBps;
        annualYieldBps = _newYieldBps;
        emit AnnualYieldUpdated(oldYield, _newYieldBps);
    }

    /// @notice Manually trigger yield accrual
    /// @dev Can be called by anyone to update the yield multiplier
    function accrueYield() external {
        _accrueYield();
    }

    /// @notice Get the current yield multiplier including pending yield
    /// @return The current multiplier (scaled by 1e18)
    function getCurrentMultiplier() public view returns (uint256) {
        return _calculateCurrentMultiplier();
    }

    /// @notice Mint shares to a specified address (for testing)
    /// @param to Address to mint shares to
    /// @param amount Amount of shares to mint
    function mintShares(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burn shares from a specified address (for testing)
    /// @param from Address to burn shares from
    /// @param amount Amount of shares to burn
    function burnShares(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    // ============ ERC4626 Overrides ============

    /// @inheritdoc ERC4626
    /// @dev Returns the amount of assets that would be received for a given amount of shares
    ///      This reflects the current NAV including accrued yield
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 currentMultiplier = _calculateCurrentMultiplier();
        // shares * multiplier / PRECISION, adjusting for decimal difference
        // gtUSDC has 18 decimals, USDC has 6 decimals
        // multiplier is in 18 decimals
        return shares.mulDiv(currentMultiplier, PRECISION * 1e12, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626
    /// @dev Returns the amount of shares that would be minted for a given amount of assets
    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 currentMultiplier = _calculateCurrentMultiplier();
        // assets * PRECISION * 1e12 / multiplier
        // USDC has 6 decimals, gtUSDC has 18 decimals
        return assets.mulDiv(PRECISION * 1e12, currentMultiplier, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return convertToShares(assets);
    }

    /// @inheritdoc ERC4626
    function previewMint(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    /// @inheritdoc ERC4626
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 currentMultiplier = _calculateCurrentMultiplier();
        return assets.mulDiv(PRECISION * 1e12, currentMultiplier, Math.Rounding.Ceil);
    }

    /// @inheritdoc ERC4626
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    /// @inheritdoc ERC4626
    function totalAssets() public view override returns (uint256) {
        // Total assets = total shares * current exchange rate
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return convertToAssets(supply);
    }

    // ============ Internal Functions ============

    /// @notice Calculate current multiplier including pending yield
    /// @return multiplier The current yield multiplier (scaled by 1e18)
    function _calculateCurrentMultiplier() internal view returns (uint256) {
        if (annualYieldBps == 0) {
            return accumulatedYieldMultiplier;
        }

        uint256 timeElapsed = block.timestamp - lastYieldAccrualTime;
        if (timeElapsed == 0) {
            return accumulatedYieldMultiplier;
        }

        // Calculate yield for elapsed time
        // yield = principal * rate * time / (365 days * 10000)
        // newMultiplier = oldMultiplier * (1 + yield)
        uint256 yieldForPeriod =
            (accumulatedYieldMultiplier * annualYieldBps * timeElapsed) / (SECONDS_PER_YEAR * BPS_DENOMINATOR);

        return accumulatedYieldMultiplier + yieldForPeriod;
    }

    /// @notice Internal function to accrue yield
    function _accrueYield() internal {
        uint256 newMultiplier = _calculateCurrentMultiplier();
        uint256 yieldAmount = newMultiplier - accumulatedYieldMultiplier;
        uint256 timeElapsed = block.timestamp - lastYieldAccrualTime;

        if (yieldAmount > 0) {
            accumulatedYieldMultiplier = newMultiplier;
            lastYieldAccrualTime = block.timestamp;
            emit YieldAccrued(newMultiplier, yieldAmount, timeElapsed);
        } else if (timeElapsed > 0) {
            lastYieldAccrualTime = block.timestamp;
        }
    }

    /// @notice Override decimals to return 18 (standard for ERC4626 shares)
    /// @dev ERC4626 already overrides ERC20.decimals()
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
