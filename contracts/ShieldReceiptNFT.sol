// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IShieldReceiptNFT } from "./interfaces/IShieldReceiptNFT.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";
import { EventsLib } from "./libraries/EventsLib.sol";

/// @title ShieldReceiptNFT
/// @notice ERC-721 NFT representing a shielded position in a YieldShield pool
/// @dev Extends OpenZeppelin ERC721 for security and standard compliance
contract ShieldReceiptNFT is ERC721, Ownable, IShieldReceiptNFT {
    using ErrorsLib for *;

    /// @dev Mapping from token ID to position data
    mapping(uint256 => ShieldPosition) public positions;

    /// @dev Next token ID to mint
    uint256 public nextTokenId;

    /// @dev Transfer lock period (default 1 day, configurable by governance)
    uint256 public transferLockPeriod;

    /// @dev Maximum transfer lock period (safety limit)
    uint256 public constant MAX_TRANSFER_LOCK = 30 days;

    /// @dev Address of the SplitRiskPool that can mint/burn
    address public pool;

    constructor(string memory name, string memory symbol) ERC721(name, symbol) Ownable(msg.sender) {
        transferLockPeriod = 1 days;
    }

    /// @notice Set the pool address (can only be set once)
    function setPool(address _pool) external onlyOwner {
        if (pool != address(0)) revert ErrorsLib.PoolAlreadySet();
        if (_pool == address(0)) revert ErrorsLib.InvalidPoolAddress();
        pool = _pool;
        emit EventsLib.ShieldNFTPoolSet(_pool);
    }

    /// @notice Mint a new shielded position NFT
    /// @dev Only callable by the pool contract
    function mint(address to, uint256 amount, uint256 valueAtDeposit, uint256 collateralAmount)
        external
        onlyPool
        returns (uint256 tokenId)
    {
        tokenId = nextTokenId++;
        positions[tokenId] = ShieldPosition({
            amount: amount,
            depositTime: uint64(block.timestamp),
            valueAtDeposit: valueAtDeposit,
            collateralAmount: collateralAmount,
            lastFeeClaimTime: uint64(block.timestamp),
            isWithdrawn: false // Reserved: always false (burn is used for withdrawal). Kept for storage layout compatibility.
        });
        _mint(to, tokenId);
        emit EventsLib.ShieldNFTMinted(to, tokenId, amount, valueAtDeposit);
    }

    /// @notice Mint a new shielded position NFT with preserved deposit time
    /// @dev Used for partial withdrawals to preserve original deposit time
    /// @param to Recipient address
    /// @param amount Token amount
    /// @param valueAtDeposit USD value at deposit
    /// @param collateralAmount Collateral amount
    /// @param originalDepositTime Original deposit timestamp to preserve
    function mintWithDepositTime(
        address to,
        uint256 amount,
        uint256 valueAtDeposit,
        uint256 collateralAmount,
        uint64 originalDepositTime
    ) external onlyPool returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        positions[tokenId] = ShieldPosition({
            amount: amount,
            depositTime: originalDepositTime, // Preserve original deposit time
            valueAtDeposit: valueAtDeposit,
            collateralAmount: collateralAmount,
            lastFeeClaimTime: uint64(block.timestamp),
            isWithdrawn: false // Reserved: always false (burn is used for withdrawal). Kept for storage layout compatibility.
        });
        _mint(to, tokenId);
        emit EventsLib.ShieldNFTMinted(to, tokenId, amount, valueAtDeposit);
    }

    /// @notice Burn a shielded position NFT
    /// @dev Only callable by the pool contract. Clears position data for gas refund.
    function burn(uint256 tokenId) external onlyPool {
        _burn(tokenId);
        delete positions[tokenId];
        emit EventsLib.ShieldNFTBurned(tokenId);
    }

    /// @notice Get position data for a token ID
    function getPosition(uint256 tokenId) external view returns (ShieldPosition memory) {
        return positions[tokenId];
    }

    /// @notice Update position data (only pool can call)
    function updatePosition(
        uint256 tokenId,
        uint256 newAmount,
        uint256 newValue,
        uint256 newCollateralAmount,
        uint64 newLastFeeClaimTime
    ) external onlyPool {
        if (_ownerOf(tokenId) == address(0)) revert ErrorsLib.TokenDoesNotExist();
        ShieldPosition storage pos = positions[tokenId];
        pos.amount = newAmount;
        pos.valueAtDeposit = newValue;
        pos.collateralAmount = newCollateralAmount;
        pos.lastFeeClaimTime = newLastFeeClaimTime;
    }

    /// @notice Set transfer lock period (only governance)
    function setTransferLockPeriod(uint256 newPeriod) external onlyOwner {
        if (newPeriod > MAX_TRANSFER_LOCK) revert ErrorsLib.InvalidUnlockDuration();
        transferLockPeriod = newPeriod;
        emit EventsLib.ParameterUpdated("transferLockPeriod", newPeriod);
    }

    /// @notice Override _update to enforce transfer lock
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Allow minting (from == 0) and burning (to == 0)
        if (from != address(0) && to != address(0)) {
            ShieldPosition storage pos = positions[tokenId];
            uint256 unlockTime = pos.depositTime + transferLockPeriod;
            if (block.timestamp < unlockTime) {
                revert ErrorsLib.TransferLocked(unlockTime);
            }
        }

        return super._update(to, tokenId, auth);
    }

    /// @dev Modifier to ensure only pool can call
    modifier onlyPool() {
        if (msg.sender != pool) revert ErrorsLib.NotOwner();
        _;
    }
}
