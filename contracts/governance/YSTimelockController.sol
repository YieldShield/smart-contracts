// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title YSTimelockController
/// @notice Drop-in TimelockController with enumerable role membership so the
///         ProtocolAccessControl validator can enforce the H-8 invariant
///         (exactly one DEFAULT_ADMIN_ROLE member, equal to the timelock itself).
contract YSTimelockController is TimelockController, AccessControlEnumerable {
    uint256 public constant MIN_PUBLIC_DELAY = 2 days;

    error PublicTimelockDelayTooShort(uint256 providedDelay, uint256 minimumDelay);
    error DefaultAdminMustBeTimelock(address account);
    error TimelockDefaultAdminCannotBeRevoked();
    error TimelockOperationalRoleFrozen(bytes32 role, address account);

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {
        _validatePublicDelay(minDelay);
    }

    function grantRole(bytes32 role, address account) public virtual override(AccessControl, IAccessControl) {
        _validateRoleGrant(role, account);
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public virtual override(AccessControl, IAccessControl) {
        _validateRoleRevocation(role, account);
        super.revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address callerConfirmation)
        public
        virtual
        override(AccessControl, IAccessControl)
    {
        _validateRoleRevocation(role, callerConfirmation);
        super.renounceRole(role, callerConfirmation);
    }

    function updateDelay(uint256 newDelay) public virtual override {
        _validatePublicDelay(newDelay);
        super.updateDelay(newDelay);
    }

    function _grantRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControl, AccessControlEnumerable)
        returns (bool)
    {
        return super._grantRole(role, account);
    }

    function _revokeRole(bytes32 role, address account)
        internal
        virtual
        override(AccessControl, AccessControlEnumerable)
        returns (bool)
    {
        return super._revokeRole(role, account);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(TimelockController, AccessControlEnumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _validatePublicDelay(uint256 delay) internal view {
        if (!_isLocalDevelopmentChain() && delay < MIN_PUBLIC_DELAY) {
            revert PublicTimelockDelayTooShort(delay, MIN_PUBLIC_DELAY);
        }
    }

    function _validateRoleGrant(bytes32 role, address account) internal view {
        if (role == DEFAULT_ADMIN_ROLE && account != address(this)) {
            revert DefaultAdminMustBeTimelock(account);
        }
        if (_isTimelockManagedOperationalRole(role)) {
            revert TimelockOperationalRoleFrozen(role, account);
        }
    }

    function _validateRoleRevocation(bytes32 role, address account) internal view {
        if (role == DEFAULT_ADMIN_ROLE && account == address(this)) {
            revert TimelockDefaultAdminCannotBeRevoked();
        }
        if (_isTimelockManagedOperationalRole(role)) {
            revert TimelockOperationalRoleFrozen(role, account);
        }
    }

    function _isTimelockManagedOperationalRole(bytes32 role) internal view returns (bool) {
        return msg.sender == address(this) && (role == PROPOSER_ROLE || role == EXECUTOR_ROLE || role == CANCELLER_ROLE);
    }

    function _isLocalDevelopmentChain() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }
}
