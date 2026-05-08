// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @notice One-shot remediation for the legacy Arbitrum Sepolia deployment in broadcast/Deploy.s.sol/421614.
 * @dev Run with the legacy deployer/admin key. This does not deploy new contracts.
 */
contract RenounceLegacySepoliaTimelockAdmin is Script {
    uint256 public constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;
    address public constant LEGACY_TIMELOCK = 0x59f92e9d745a9a18503564883E1b1437Ac6548A0;
    address public constant LEGACY_ADMIN = 0x013E743Eb3Ba6E468eCADf9dF659664Cf90eCe8A;
    address public constant LEGACY_GOVERNOR = 0xc3eC5370c700d75ACFdb7865C1535AcE79f9226F;

    error WrongChain(uint256 chainId);
    error BroadcasterMustBeLegacyAdmin(address broadcaster);
    error LegacyAdminMissing(address admin);
    error TimelockMissingSelfAdmin(address timelock);
    error GovernorMissingTimelockRole(bytes32 role, address governor);
    error TimelockRoleStillOpen(bytes32 role);
    error LegacyAdminStillPresent(address admin);

    function run() external {
        if (block.chainid != ARBITRUM_SEPOLIA_CHAIN_ID) {
            revert WrongChain(block.chainid);
        }

        TimelockController timelock = TimelockController(payable(LEGACY_TIMELOCK));
        _validatePreconditions(timelock);

        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        if (broadcaster != LEGACY_ADMIN) {
            revert BroadcasterMustBeLegacyAdmin(broadcaster);
        }

        _revokeOpenRoleIfPresent(timelock, timelock.PROPOSER_ROLE());
        _revokeOpenRoleIfPresent(timelock, timelock.EXECUTOR_ROLE());
        _revokeOpenRoleIfPresent(timelock, timelock.CANCELLER_ROLE());
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), LEGACY_ADMIN);

        vm.stopBroadcast();

        _validatePostconditions(timelock);
        console.log("Legacy Arbitrum Sepolia timelock admin removed:", LEGACY_ADMIN);
    }

    function _validatePreconditions(TimelockController timelock) internal view {
        if (!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), LEGACY_ADMIN)) {
            revert LegacyAdminMissing(LEGACY_ADMIN);
        }
        if (!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock))) {
            revert TimelockMissingSelfAdmin(address(timelock));
        }

        _requireGovernorRole(timelock, timelock.PROPOSER_ROLE());
        _requireGovernorRole(timelock, timelock.EXECUTOR_ROLE());
        _requireGovernorRole(timelock, timelock.CANCELLER_ROLE());
    }

    function _validatePostconditions(TimelockController timelock) internal view {
        if (timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), LEGACY_ADMIN)) {
            revert LegacyAdminStillPresent(LEGACY_ADMIN);
        }
        if (timelock.hasRole(timelock.PROPOSER_ROLE(), address(0))) {
            revert TimelockRoleStillOpen(timelock.PROPOSER_ROLE());
        }
        if (timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0))) {
            revert TimelockRoleStillOpen(timelock.EXECUTOR_ROLE());
        }
        if (timelock.hasRole(timelock.CANCELLER_ROLE(), address(0))) {
            revert TimelockRoleStillOpen(timelock.CANCELLER_ROLE());
        }
    }

    function _requireGovernorRole(TimelockController timelock, bytes32 role) internal view {
        if (!timelock.hasRole(role, LEGACY_GOVERNOR)) {
            revert GovernorMissingTimelockRole(role, LEGACY_GOVERNOR);
        }
    }

    function _revokeOpenRoleIfPresent(TimelockController timelock, bytes32 role) internal {
        if (timelock.hasRole(role, address(0))) {
            timelock.revokeRole(role, address(0));
        }
    }
}
