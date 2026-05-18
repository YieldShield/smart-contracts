// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { AccessControlEnumerable } from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title YSTimelockController
/// @notice Drop-in TimelockController with enumerable role membership so the
///         ProtocolAccessControl validator can enforce the H-8 invariant
///         (exactly one DEFAULT_ADMIN_ROLE member, equal to the timelock itself).
contract YSTimelockController is TimelockController, AccessControlEnumerable {
    uint256 public constant MIN_PUBLIC_DELAY = 2 days;

    error PublicTimelockDelayTooShort(uint256 providedDelay, uint256 minimumDelay);

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {
        _validatePublicDelay(minDelay);
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

    function _isLocalDevelopmentChain() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }
}
