// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IProtectorReceiptNFT
/// @notice Interface for ProtectorReceiptNFT contract
interface IProtectorReceiptNFT is IERC721 {
    struct ProtectorPosition {
        uint256 amount; // Backing token balance in native token units
        uint64 depositTime; // Timestamp of deposit (for transfer lock)
        uint64 unlockRequestTime; // When unlock process was started (0 = not started)
    }

    function mint(address to, uint256 amount) external returns (uint256 tokenId);

    function burn(uint256 tokenId) external;

    function getPosition(uint256 tokenId) external view returns (ProtectorPosition memory);

    function getPositionWithFreshness(uint256 tokenId)
        external
        view
        returns (ProtectorPosition memory position, bool isAmountFresh);

    function updateAmount(uint256 tokenId, uint256 newAmount) external;

    function setUnlockRequestTime(uint256 tokenId, uint64 time) external;

    function setTransferLockPeriod(uint256 newPeriod) external;

    function transferLockPeriod() external view returns (uint256);

    function nextTokenId() external view returns (uint256);
}
