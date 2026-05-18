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
    error GovernanceTimelockImplementationMismatch(address candidate, bytes32 expectedCodehash, bytes32 actualCodehash);
    error GovernanceTimelockAdminRetained(address candidate, address retainedAdmin);
    /// @notice Thrown when the timelock candidate has admin role members beyond the candidate itself.
    error GovernanceTimelockHasExtraAdmins(address candidate, uint256 adminCount);
    error GovernanceTimelockInvalidRoleMemberCount(address candidate, bytes32 role, uint256 memberCount);
    error GovernanceTimelockRoleMemberMismatch(
        address candidate, bytes32 role, address expectedMember, address actualMember
    );

    event GovernanceTimelockUpdated(address indexed previousGovernance, address indexed newGovernance);
    event GovernanceTimelockTransferStarted(address indexed currentGovernance, address indexed pendingGovernance);

    address internal _governanceTimelock;
    address internal _pendingGovernanceTimelock;
    bytes32 internal _governanceTimelockCodehash;

    bytes4 private constant GET_MIN_DELAY_SELECTOR = bytes4(keccak256("getMinDelay()"));
    bytes4 private constant HAS_ROLE_SELECTOR = bytes4(keccak256("hasRole(bytes32,address)"));
    bytes4 private constant GET_ROLE_MEMBER_COUNT_SELECTOR = bytes4(keccak256("getRoleMemberCount(bytes32)"));
    bytes4 private constant GET_ROLE_MEMBER_SELECTOR = bytes4(keccak256("getRoleMember(bytes32,uint256)"));
    bytes32 private constant DEFAULT_ADMIN_ROLE_VALUE = 0x00;
    bytes32 private constant PROPOSER_ROLE_VALUE = keccak256("PROPOSER_ROLE");
    bytes32 private constant EXECUTOR_ROLE_VALUE = keccak256("EXECUTOR_ROLE");
    bytes32 private constant CANCELLER_ROLE_VALUE = keccak256("CANCELLER_ROLE");
    uint256 private constant MIN_PUBLIC_GOVERNANCE_DELAY = 2 days;

    function __ProtocolAccessControl_init(address initialOwner, address governanceTimelock_) internal onlyInitializing {
        __Ownable_init(initialOwner);
        __Pausable_init();
        __ProtocolAccessControl_init_unchained(governanceTimelock_);
    }

    function __ProtocolAccessControl_init_unchained(address governanceTimelock_) internal onlyInitializing {
        _governanceTimelockCodehash = _validateGovernanceTimelock(governanceTimelock_, bytes32(0));
        _validateKnownDefaultAdminCleared(governanceTimelock_, owner());
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

    /// @notice Starts a two-step governance transfer by setting the pending governance address
    /// @param newGovernance The address of the proposed new governance timelock
    function setGovernanceTimelock(address newGovernance) public virtual onlyGovernance {
        _validateGovernanceTimelock(newGovernance, _governanceTimelockImplementationHash());
        _validateGovernanceTimelockOperationalRolesMatch(newGovernance, _governanceTimelock);
        _validateKnownDefaultAdminCleared(newGovernance, owner());
        _validateKnownDefaultAdminCleared(newGovernance, _governanceTimelock);
        _pendingGovernanceTimelock = newGovernance;
        emit GovernanceTimelockTransferStarted(_governanceTimelock, newGovernance);
    }

    /// @notice Completes the two-step governance transfer
    /// @dev Only callable by the pending governance address
    function acceptGovernanceTimelock() public virtual {
        if (_pendingGovernanceTimelock == address(0)) revert NoPendingGovernance();
        if (msg.sender != _pendingGovernanceTimelock) revert UnauthorizedPendingGovernance(msg.sender);
        _validateGovernanceTimelock(_pendingGovernanceTimelock, _governanceTimelockImplementationHash());
        _validateGovernanceTimelockOperationalRolesMatch(_pendingGovernanceTimelock, _governanceTimelock);
        _validateKnownDefaultAdminCleared(_pendingGovernanceTimelock, owner());
        _validateKnownDefaultAdminCleared(_pendingGovernanceTimelock, _governanceTimelock);
        address previousGovernance = _governanceTimelock;
        emit GovernanceTimelockUpdated(previousGovernance, _pendingGovernanceTimelock);
        _governanceTimelock = _pendingGovernanceTimelock;
        _governanceTimelockCodehash = _pendingGovernanceTimelock.codehash;
        _pendingGovernanceTimelock = address(0);

        if (owner() == previousGovernance) {
            _transferOwnership(_governanceTimelock);
        }
    }

    /// @notice Returns the pending governance timelock address
    function pendingGovernanceTimelock() public view virtual returns (address) {
        return _pendingGovernanceTimelock;
    }

    function _validateGovernanceTimelock(address candidate, bytes32 expectedCodehash)
        internal
        view
        returns (bytes32 candidateCodehash)
    {
        if (candidate == address(0)) revert GovernanceZeroAddress();
        if (candidate.code.length == 0) revert InvalidGovernanceTimelock(candidate);
        candidateCodehash = candidate.codehash;
        if (expectedCodehash != bytes32(0) && candidateCodehash != expectedCodehash) {
            revert GovernanceTimelockImplementationMismatch(candidate, expectedCodehash, candidateCodehash);
        }

        (bool success, bytes memory data) = candidate.staticcall(abi.encodeWithSelector(GET_MIN_DELAY_SELECTOR));
        if (!success || data.length < 32) revert InvalidGovernanceTimelock(candidate);

        uint256 minDelay = abi.decode(data, (uint256));
        if (minDelay == 0) revert GovernanceTimelockDelayTooShort(candidate, minDelay);
        if (!_isLocalDevelopmentChain() && minDelay < MIN_PUBLIC_GOVERNANCE_DELAY) {
            revert GovernanceTimelockDelayTooShort(candidate, minDelay);
        }

        (success, data) =
            candidate.staticcall(abi.encodeWithSelector(HAS_ROLE_SELECTOR, DEFAULT_ADMIN_ROLE_VALUE, candidate));
        if (!success || data.length < 32 || !abi.decode(data, (bool))) revert InvalidGovernanceTimelock(candidate);

        // H-8: enumerate DEFAULT_ADMIN_ROLE members on the candidate timelock.
        // The previous validator only confirmed the candidate admins itself and
        // the known owner/current-timelock are not admins — but any *other*
        // pre-granted admin (attacker EOA, secondary multisig, …) would pass.
        // Require the candidate to use AccessControlEnumerable and to hold the
        // role exclusively for itself.
        (success, data) =
            candidate.staticcall(abi.encodeWithSelector(GET_ROLE_MEMBER_COUNT_SELECTOR, DEFAULT_ADMIN_ROLE_VALUE));
        if (!success || data.length < 32) revert InvalidGovernanceTimelock(candidate);
        uint256 adminCount = abi.decode(data, (uint256));
        if (adminCount != 1) {
            revert GovernanceTimelockHasExtraAdmins(candidate, adminCount);
        }
        (success, data) = candidate.staticcall(
            abi.encodeWithSelector(GET_ROLE_MEMBER_SELECTOR, DEFAULT_ADMIN_ROLE_VALUE, uint256(0))
        );
        if (!success || data.length < 32) revert InvalidGovernanceTimelock(candidate);
        address soleAdmin = abi.decode(data, (address));
        if (soleAdmin != candidate) {
            revert GovernanceTimelockAdminRetained(candidate, soleAdmin);
        }

        _validateGovernanceTimelockOperationalRoleShape(candidate);
    }

    function _validateGovernanceTimelockOperationalRoleShape(address candidate)
        internal
        view
        returns (address controller)
    {
        controller = _getSoleRoleMember(candidate, PROPOSER_ROLE_VALUE);
        if (controller == address(0) || controller == candidate) {
            revert GovernanceTimelockRoleMemberMismatch(candidate, PROPOSER_ROLE_VALUE, address(1), controller);
        }

        address executor = _getSoleRoleMember(candidate, EXECUTOR_ROLE_VALUE);
        if (executor != controller) {
            revert GovernanceTimelockRoleMemberMismatch(candidate, EXECUTOR_ROLE_VALUE, controller, executor);
        }

        address canceller = _getSoleRoleMember(candidate, CANCELLER_ROLE_VALUE);
        if (canceller != controller) {
            revert GovernanceTimelockRoleMemberMismatch(candidate, CANCELLER_ROLE_VALUE, controller, canceller);
        }
    }

    function _validateGovernanceTimelockOperationalRolesMatch(address candidate, address expectedTimelock)
        internal
        view
    {
        if (expectedTimelock == address(0) || expectedTimelock.code.length == 0) {
            return;
        }

        address expectedController = _getSoleRoleMember(expectedTimelock, PROPOSER_ROLE_VALUE);
        address candidateController = _getSoleRoleMember(candidate, PROPOSER_ROLE_VALUE);
        if (candidateController != expectedController) {
            revert GovernanceTimelockRoleMemberMismatch(
                candidate, PROPOSER_ROLE_VALUE, expectedController, candidateController
            );
        }
    }

    function _getSoleRoleMember(address candidate, bytes32 role) internal view returns (address member) {
        (bool success, bytes memory data) =
            candidate.staticcall(abi.encodeWithSelector(GET_ROLE_MEMBER_COUNT_SELECTOR, role));
        if (!success || data.length < 32) revert InvalidGovernanceTimelock(candidate);
        uint256 memberCount = abi.decode(data, (uint256));
        if (memberCount != 1) {
            revert GovernanceTimelockInvalidRoleMemberCount(candidate, role, memberCount);
        }

        (success, data) = candidate.staticcall(abi.encodeWithSelector(GET_ROLE_MEMBER_SELECTOR, role, uint256(0)));
        if (!success || data.length < 32) revert InvalidGovernanceTimelock(candidate);
        member = abi.decode(data, (address));
    }

    function _governanceTimelockImplementationHash() internal view returns (bytes32 codehash) {
        codehash = _governanceTimelockCodehash;
        if (codehash == bytes32(0) && _governanceTimelock != address(0) && _governanceTimelock.code.length != 0) {
            codehash = _governanceTimelock.codehash;
        }
    }

    function _validateKnownDefaultAdminCleared(address candidate, address retainedAdmin) internal view {
        if (_isLocalDevelopmentChain() || retainedAdmin == address(0) || retainedAdmin == candidate) {
            return;
        }

        (bool success, bytes memory data) =
            candidate.staticcall(abi.encodeWithSelector(HAS_ROLE_SELECTOR, DEFAULT_ADMIN_ROLE_VALUE, retainedAdmin));
        if (!success || data.length < 32) revert InvalidGovernanceTimelock(candidate);
        if (abi.decode(data, (bool))) {
            revert GovernanceTimelockAdminRetained(candidate, retainedAdmin);
        }
    }

    function _isLocalDevelopmentChain() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }

    function pause() public virtual onlyGovernance {
        _pause();
    }

    function unpause() public virtual onlyGovernance {
        _unpause();
    }

    /**
     * @dev Storage gap for future upgrades.
     * This ensures that future versions of this contract can add new storage variables
     * without colliding with storage variables in derived contracts.
     * Reserved 50 slots to follow OpenZeppelin's upgrade-safe pattern.
     */
    uint256[47] private __gap; // 47 slots because governance state uses 3 slots
}
