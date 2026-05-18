// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IShieldReceiptNFT
/// @notice Interface for ShieldReceiptNFT contract
interface IShieldReceiptNFT is IERC721 {
    struct ShieldPosition {
        uint256 amount; // Shielded token amount in native token units
        uint64 depositTime; // Timestamp of deposit (for transfer lock)
        uint256 valueAtDeposit; // USD value at deposit time (8 decimals) - USD-BASED cross-asset & fees
        uint256 collateralAmount; // Original collateral cap in backing-token native units
        uint64 lastFeeClaimTime; // Last time fees were calculated
    }

    function mint(address to, uint256 amount, uint256 valueAtDeposit, uint256 collateralAmount)
        external
        returns (uint256 tokenId);

    /// @notice Mint with preserved deposit time (for partial withdrawals)
    function mintWithDepositTime(
        address to,
        uint256 amount,
        uint256 valueAtDeposit,
        uint256 collateralAmount,
        uint64 originalDepositTime
    ) external returns (uint256 tokenId);

    function burn(uint256 tokenId) external;

    function getPosition(uint256 tokenId) external view returns (ShieldPosition memory);

    function updatePosition(
        uint256 tokenId,
        uint256 newAmount,
        uint256 newValue,
        uint256 newCollateralAmount,
        uint64 newLastFeeClaimTime
    ) external;

    function setTransferLockPeriod(uint256 newPeriod) external;

    function transferLockPeriod() external view returns (uint256);

    function nextTokenId() external view returns (uint256);
}
