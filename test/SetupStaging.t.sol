// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { PythConfig } from "../contracts/oracles/PythConfig.sol";
import { SetupStaging } from "../script/setup-staging.s.sol";

contract SetupStagingHarness is SetupStaging {
    bool internal useConfirmationOverride;
    bool internal confirmationOverride;

    function setConfirmationOverride(bool confirmed) external {
        useConfirmationOverride = true;
        confirmationOverride = confirmed;
    }

    function requireStagingSetupAllowedHarness() external view {
        _requireStagingSetupAllowed();
    }

    function _isStagingSetupConfirmed() internal view override returns (bool) {
        if (useConfirmationOverride) {
            return confirmationOverride;
        }
        return super._isStagingSetupConfirmed();
    }
}

contract SetupStagingTest is Test {
    SetupStagingHarness internal harness;

    function setUp() public {
        harness = new SetupStagingHarness();
        vm.setEnv("YS_STAGING_SETUP_CONFIRMED", "0");
    }

    function test_RequireStagingSetupAllowedRejectsWrongChain() public {
        vm.chainId(1);

        vm.expectRevert(abi.encodeWithSelector(SetupStaging.StagingChainRequired.selector, uint256(1)));
        harness.requireStagingSetupAllowedHarness();
    }

    function test_RequireStagingSetupAllowedRejectsUnconfirmedStagingChain() public {
        vm.chainId(PythConfig.ARBITRUM_SEPOLIA_CHAIN_ID);

        vm.expectRevert(SetupStaging.StagingSetupNotConfirmed.selector);
        harness.requireStagingSetupAllowedHarness();
    }

    function test_ZRequireStagingSetupAllowedAllowsConfirmedStagingChain() public {
        vm.chainId(PythConfig.ARBITRUM_SEPOLIA_CHAIN_ID);
        harness.setConfirmationOverride(true);

        harness.requireStagingSetupAllowedHarness();
    }
}
