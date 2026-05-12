// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ProtocolAccessControlUpgradeable
/// @notice Upgradeable variant of the shared access-control scaffold for all YieldShield contracts
abstract contract ProtocolAccessControlUpgradeable is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard
{
    error GovernanceZeroAddress();
    error UnauthorizedGovernance(address caller);
    error NoPendingGovernance();
    error UnauthorizedPendingGovernance(address caller);
    error InvalidGovernanceTimelock(address candidate);
    error GovernanceTimelockDelayTooShort(address candidate, uint256 minDelay);

    event GovernanceTimelockUpdated(address indexed previousGovernance, address indexed newGovernance);
    event GovernanceTimelockTransferStarted(address indexed currentGovernance, address indexed pendingGovernance);

    address internal _governanceTimelock;
    address internal _pendingGovernanceTimelock;

    bytes4 private constant GET_MIN_DELAY_SELECTOR = bytes4(keccak256("getMinDelay()"));
    bytes4 private constant HAS_ROLE_SELECTOR = bytes4(keccak256("hasRole(bytes32,address)"));
    bytes32 private constant DEFAULT_ADMIN_ROLE_VALUE = 0x00;

    function __ProtocolAccessControl_init(address initialOwner, address governanceTimelock_) internal onlyInitializing {
        __Ownable_init(initialOwner);
        __Pausable_init();
        __ProtocolAccessControl_init_unchained(governanceTimelock_);
    }

    function __ProtocolAccessControl_init_unchained(address governanceTimelock_) internal onlyInitializing {
        _validateGovernanceTimelock(governanceTimelock_);
        _governanceTimelock = governanceTimelock_;
    }

    function governanceTimelock() public view virtual returns (address) {
        return _governanceTimelock;
    }

    modifier onlyGovernance() {
        if (msg.sender != _governanceTimelock) {
            revert UnauthorizedGovernance(msg.sender);
        }
        _;
    }

    modifier onlyGovernanceOrOwner() {
        if (msg.sender != _governanceTimelock && msg.sender != owner()) {
            revert UnauthorizedGovernance(msg.sender);
        }
        _;
    }

    /// @notice Starts a two-step governance transfer by setting the pending governance address
    /// @param newGovernance The address of the proposed new governance timelock
    function setGovernanceTimelock(address newGovernance) public virtual onlyGovernanceOrOwner {
        _validateGovernanceTimelock(newGovernance);
        _pendingGovernanceTimelock = newGovernance;
        emit GovernanceTimelockTransferStarted(_governanceTimelock, newGovernance);
    }

    /// @notice Completes the two-step governance transfer
    /// @dev Only callable by the pending governance address
    function acceptGovernanceTimelock() public virtual {
        if (_pendingGovernanceTimelock == address(0)) revert NoPendingGovernance();
        if (msg.sender != _pendingGovernanceTimelock) revert UnauthorizedPendingGovernance(msg.sender);
        emit GovernanceTimelockUpdated(_governanceTimelock, _pendingGovernanceTimelock);
        _governanceTimelock = _pendingGovernanceTimelock;
        _pendingGovernanceTimelock = address(0);
    }

    /// @notice Returns the pending governance timelock address
    function pendingGovernanceTimelock() public view virtual returns (address) {
        return _pendingGovernanceTimelock;
    }

    function _validateGovernanceTimelock(address candidate) internal view {
        if (candidate == address(0)) revert GovernanceZeroAddress();
        if (candidate.code.length == 0) revert InvalidGovernanceTimelock(candidate);

        (bool success, bytes memory data) = candidate.staticcall(abi.encodeWithSelector(GET_MIN_DELAY_SELECTOR));
        if (!success || data.length < 32) revert InvalidGovernanceTimelock(candidate);

        uint256 minDelay = abi.decode(data, (uint256));
        if (minDelay == 0) revert GovernanceTimelockDelayTooShort(candidate, minDelay);

        (success, data) =
            candidate.staticcall(abi.encodeWithSelector(HAS_ROLE_SELECTOR, DEFAULT_ADMIN_ROLE_VALUE, candidate));
        if (!success || data.length < 32 || !abi.decode(data, (bool))) revert InvalidGovernanceTimelock(candidate);
    }

    function pause() public virtual onlyGovernanceOrOwner {
        _pause();
    }

    function unpause() public virtual onlyGovernanceOrOwner {
        _unpause();
    }

    /**
     * @dev Storage gap for future upgrades.
     * This ensures that future versions of this contract can add new storage variables
     * without colliding with storage variables in derived contracts.
     * Reserved 50 slots to follow OpenZeppelin's upgrade-safe pattern.
     */
    uint256[48] private __gap; // 48 slots because _governanceTimelock and _pendingGovernanceTimelock use 2 slots
}
