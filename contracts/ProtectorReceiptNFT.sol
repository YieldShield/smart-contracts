// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IProtectorReceiptNFT } from "./interfaces/IProtectorReceiptNFT.sol";
import { ErrorsLib } from "./libraries/ErrorsLib.sol";
import { EventsLib } from "./libraries/EventsLib.sol";

interface IProtectorPositionAmountView {
    function getProtectorPositionAmount(uint256 tokenId) external view returns (uint256);
}

/// @title ProtectorReceiptNFT
/// @notice ERC-721 NFT representing a protector position in a YieldShield pool
/// @dev Extends OpenZeppelin ERC721 for security and standard compliance
contract ProtectorReceiptNFT is ERC721, Ownable, IProtectorReceiptNFT {
    using ErrorsLib for *;

    /// @dev Mapping from token ID to position data
    mapping(uint256 => ProtectorPosition) public positions;

    /// @dev Operator approvals are valid for a locked token only if granted after that token unlocked.
    mapping(address => mapping(address => uint64)) private _operatorApprovalTimestamp;

    /// @dev Last mint/transfer timestamp for each token. Operator approvals granted
    ///      before the current owner received the token cannot move it.
    mapping(uint256 => uint64) private _tokenMovementTimestamp;

    /// @dev Next token ID to mint
    uint256 public nextTokenId;

    /// @dev Transfer lock period (default 28 days, configurable by governance)
    uint256 public transferLockPeriod;

    /// @dev Maximum transfer lock period (safety limit)
    uint256 public constant MAX_TRANSFER_LOCK = 90 days;

    /// @dev Minimum transfer lock period - protects against governance accidentally
    ///      or maliciously disabling the lock that prevents wash-trading protector positions.
    uint256 public constant MIN_TRANSFER_LOCK = 1 hours;

    /// @dev Address of the SplitRiskPool that can mint/burn
    address public pool;

    constructor(string memory name, string memory symbol) ERC721(name, symbol) Ownable(msg.sender) {
        transferLockPeriod = 28 days;
    }

    /// @notice Set the pool address (can only be set once)
    function setPool(address _pool) external onlyOwner {
        if (pool != address(0)) revert ErrorsLib.PoolAlreadySet();
        if (_pool == address(0)) revert ErrorsLib.InvalidPoolAddress();
        pool = _pool;
        emit EventsLib.ProtectorNFTPoolSet(_pool);
    }

    /// @notice Mint a new protector position NFT
    /// @dev Only callable by the pool contract
    function mint(address to, uint256 amount) external onlyPool returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        positions[tokenId] =
            ProtectorPosition({ amount: amount, depositTime: uint64(block.timestamp), unlockRequestTime: 0 });
        _safeMint(to, tokenId);
        emit EventsLib.ProtectorNFTMinted(to, tokenId, amount);
    }

    /// @notice Burn a protector position NFT
    /// @dev Only callable by the pool contract. Clears position data for gas refund.
    function burn(uint256 tokenId) external onlyPool {
        _burn(tokenId);
        delete positions[tokenId];
        emit EventsLib.ProtectorNFTBurned(tokenId);
    }

    /// @notice Get position data for a token ID
    /// @dev Returns the stored snapshot. If the pool reverts (paused, upgraded,
    ///      cleared), the returned `amount` is the stale stored value. Use
    ///      {getPositionWithFreshness} to detect that case explicitly.
    function getPosition(uint256 tokenId) external view returns (ProtectorPosition memory) {
        (ProtectorPosition memory position,) = _getPositionWithFreshness(tokenId);
        return position;
    }

    /// @notice Get position data with an explicit freshness flag (M-16)
    /// @return position The position struct, with `amount` set to the
    ///         pool's current view if available, or the stored snapshot otherwise.
    /// @return isAmountFresh True iff the pool successfully returned a current
    ///         amount; false when the stored snapshot was used as fallback.
    function getPositionWithFreshness(uint256 tokenId)
        external
        view
        returns (ProtectorPosition memory position, bool isAmountFresh)
    {
        return _getPositionWithFreshness(tokenId);
    }

    function _getPositionWithFreshness(uint256 tokenId)
        internal
        view
        returns (ProtectorPosition memory position, bool isAmountFresh)
    {
        position = positions[tokenId];
        if (msg.sender == pool || pool == address(0) || position.amount == 0) {
            return (position, true);
        }

        try IProtectorPositionAmountView(pool).getProtectorPositionAmount(tokenId) returns (uint256 currentAmount) {
            position.amount = currentAmount;
            isAmountFresh = true;
        } catch {
            isAmountFresh = false;
        }
    }

    /// @notice Update amount for a position (only pool can call)
    function updateAmount(uint256 tokenId, uint256 newAmount) external onlyPool {
        if (_ownerOf(tokenId) == address(0)) revert ErrorsLib.TokenDoesNotExist();
        positions[tokenId].amount = newAmount;
    }

    /// @notice Set unlock request time (only pool can call)
    function setUnlockRequestTime(uint256 tokenId, uint64 time) external onlyPool {
        if (_ownerOf(tokenId) == address(0)) revert ErrorsLib.TokenDoesNotExist();
        positions[tokenId].unlockRequestTime = time;
    }

    /// @notice Set transfer lock period (only governance)
    function setTransferLockPeriod(uint256 newPeriod) external onlyOwner {
        if (newPeriod < MIN_TRANSFER_LOCK || newPeriod > MAX_TRANSFER_LOCK) {
            revert ErrorsLib.InvalidUnlockDuration();
        }
        transferLockPeriod = newPeriod;
        emit EventsLib.ParameterUpdated("transferLockPeriod", newPeriod);
    }

    /// @notice Override _update to enforce transfer lock
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Allow minting (from == 0) and burning (to == 0)
        if (from != address(0) && to != address(0)) {
            ProtectorPosition storage pos = positions[tokenId];
            uint256 unlockTime = pos.depositTime + transferLockPeriod;
            if (block.timestamp < unlockTime) {
                revert ErrorsLib.TransferLocked(unlockTime);
            }
            // No commission claim check needed - fees follow the NFT
            // New owner will be able to claim accumulated commissions
        }

        address previousOwner = super._update(to, tokenId, auth);
        if (to == address(0)) {
            delete _tokenMovementTimestamp[tokenId];
        } else if (from != to) {
            _tokenMovementTimestamp[tokenId] = uint64(block.timestamp);
        }
        return previousOwner;
    }

    function setApprovalForAll(address operator, bool approved) public virtual override(ERC721, IERC721) {
        super.setApprovalForAll(operator, approved);

        if (approved) {
            _operatorApprovalTimestamp[msg.sender][operator] = uint64(block.timestamp);
        } else {
            delete _operatorApprovalTimestamp[msg.sender][operator];
        }
    }

    function _isAuthorized(address owner, address spender, uint256 tokenId)
        internal
        view
        virtual
        override
        returns (bool)
    {
        if (spender == address(0)) {
            return false;
        }
        if (owner == spender || _getApproved(tokenId) == spender) {
            return true;
        }
        if (!isApprovedForAll(owner, spender)) {
            return false;
        }

        uint64 approvalTimestamp = _operatorApprovalTimestamp[owner][spender];
        if (approvalTimestamp == 0) {
            return false;
        }
        return approvalTimestamp >= _unlockTime(tokenId) && approvalTimestamp >= _tokenMovementTimestamp[tokenId];
    }

    /// @dev Block per-token approvals during the lock window. Without this gate,
    ///      an owner could approve a wrapper contract immediately after deposit
    ///      and the wrapper could `transferFrom` the position the instant the
    ///      lock expires — defeating the economic intent of the lock. (H-7)
    function _approve(address to, uint256 tokenId, address auth, bool emitEvent) internal virtual override {
        if (to != address(0)) {
            uint256 unlockTime = _unlockTime(tokenId);
            if (block.timestamp < unlockTime) {
                revert ErrorsLib.TransferLocked(unlockTime);
            }
        }
        super._approve(to, tokenId, auth, emitEvent);
    }

    function _unlockTime(uint256 tokenId) internal view returns (uint256) {
        return uint256(positions[tokenId].depositTime) + transferLockPeriod;
    }

    /// @dev Modifier to ensure only pool can call
    modifier onlyPool() {
        if (msg.sender != pool) revert ErrorsLib.NotOwner();
        _;
    }
}
