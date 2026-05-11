// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ScaffoldETHDeploy } from "../script/DeployHelpers.s.sol";

contract DeployHelpersHarness is ScaffoldETHDeploy {
    function addDeployment(string memory name, address addr) external {
        deployments.push(Deployment(name, addr));
    }

    function exportDeploymentsHarness() external {
        exportDeployments();
    }

    function deploymentPath() external view returns (string memory) {
        return _deploymentPath();
    }
}

contract DeploymentMetadataTest is Test {
    uint256 internal constant PRESERVE_TEST_CHAIN_ID = 777_777_777;
    uint256 internal constant OVERWRITE_TEST_CHAIN_ID = 777_777_778;

    function test_exportDeployments_PreservesExistingProtocolEntriesWhenFinalizingGovernance() public {
        (DeployHelpersHarness deployHelpers, string memory deploymentPath) = _newDeployHelpers(PRESERVE_TEST_CHAIN_ID);
        address factory = address(0x1111);
        address compositeOracle = address(0x2222);
        address governor = address(0x3333);
        string memory existingJson = "existing-preserve";
        vm.serializeString(existingJson, vm.toString(factory), "SplitRiskPoolFactory");
        vm.serializeString(existingJson, vm.toString(compositeOracle), "CompositeOracle");
        existingJson = vm.serializeString(existingJson, "networkName", "old-network-name");
        vm.writeJson(existingJson, deploymentPath);

        deployHelpers.addDeployment("YSGovernor", governor);
        deployHelpers.exportDeploymentsHarness();

        string memory exportedJson = vm.readFile(deploymentPath);
        assertEq(vm.parseJsonString(exportedJson, string.concat(".", vm.toString(factory))), "SplitRiskPoolFactory");
        assertEq(vm.parseJsonString(exportedJson, string.concat(".", vm.toString(compositeOracle))), "CompositeOracle");
        assertEq(vm.parseJsonString(exportedJson, string.concat(".", vm.toString(governor))), "YSGovernor");
        assertEq(vm.parseJsonString(exportedJson, ".networkName"), "chain-777777777");

        _removeDeploymentFileIfPresent(deploymentPath);
    }

    function test_exportDeployments_CurrentRunOverwritesMatchingExistingEntry() public {
        (DeployHelpersHarness deployHelpers, string memory deploymentPath) = _newDeployHelpers(OVERWRITE_TEST_CHAIN_ID);
        address redeployed = address(0x4444);
        string memory existingJson = "existing-overwrite";
        vm.serializeString(existingJson, vm.toString(redeployed), "OldContractName");
        existingJson = vm.serializeString(existingJson, "networkName", "old-network-name");
        vm.writeJson(existingJson, deploymentPath);

        deployHelpers.addDeployment("NewContractName", redeployed);
        deployHelpers.exportDeploymentsHarness();

        string memory exportedJson = vm.readFile(deploymentPath);
        assertEq(vm.parseJsonString(exportedJson, string.concat(".", vm.toString(redeployed))), "NewContractName");

        _removeDeploymentFileIfPresent(deploymentPath);
    }

    function _newDeployHelpers(uint256 chainId)
        internal
        returns (DeployHelpersHarness deployHelpers, string memory path)
    {
        vm.chainId(chainId);
        deployHelpers = new DeployHelpersHarness();
        path = deployHelpers.deploymentPath();
        _removeDeploymentFileIfPresent(path);
    }

    function _removeDeploymentFileIfPresent(string memory deploymentPath) internal {
        if (vm.exists(deploymentPath)) {
            vm.removeFile(deploymentPath);
        }
    }
}
