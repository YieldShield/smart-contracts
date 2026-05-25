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

    function findAddressByName(string memory json, string memory contractName) external pure returns (address) {
        return _findAddressByName(json, contractName);
    }

    function resolveDeploymentAddressHarness(string memory contractName) external view returns (address) {
        return _resolveDeploymentAddress(contractName);
    }

    function resolveDeploymentAddressesHarness(string memory contractName) external view returns (address[] memory) {
        return _resolveDeploymentAddresses(contractName);
    }

    function resolveFactoryAddressHarness() external view returns (address) {
        return _resolveFactoryAddress();
    }

    function selectFreshestAddressHarness(
        address deploymentAddr,
        uint256 deploymentModifiedAt,
        address broadcastAddr,
        uint256 broadcastModifiedAt
    ) external pure returns (address) {
        return _selectFreshestAddress(deploymentAddr, deploymentModifiedAt, broadcastAddr, broadcastModifiedAt);
    }
}

contract DeploymentMetadataTest is Test {
    uint256 internal constant PRESERVE_TEST_CHAIN_ID = 777_777_777;
    uint256 internal constant OVERWRITE_TEST_CHAIN_ID = 777_777_778;
    uint256 internal constant PRUNE_TEST_CHAIN_ID = 777_777_779;
    uint256 internal constant CURRENT_RUN_DEDUPE_TEST_CHAIN_ID = 777_777_780;
    uint256 internal constant FRESHEST_RESOLUTION_TEST_CHAIN_ID = 777_777_782;
    uint256 internal constant EMPTY_EXPORT_TEST_CHAIN_ID = 777_777_783;
    uint256 internal constant EXACT_MATCH_TEST_CHAIN_ID = 777_777_784;

    function test_exportDeployments_PreservesExistingEntriesNotSupersededByCurrentRun() public {
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

    function test_exportDeployments_RemovesStaleDuplicateAddressForRedeployedContract() public {
        (DeployHelpersHarness deployHelpers, string memory deploymentPath) = _newDeployHelpers(PRUNE_TEST_CHAIN_ID);
        address staleFactory = address(0x5555);
        address currentFactory = address(0x6666);
        address compositeOracle = address(0x7777);
        string memory existingJson = "existing-prune";
        vm.serializeString(existingJson, vm.toString(staleFactory), "SplitRiskPoolFactory");
        vm.serializeString(existingJson, vm.toString(compositeOracle), "CompositeOracle");
        existingJson = vm.serializeString(existingJson, "networkName", "old-network-name");
        vm.writeJson(existingJson, deploymentPath);

        deployHelpers.addDeployment("SplitRiskPoolFactory", currentFactory);
        deployHelpers.exportDeploymentsHarness();

        string memory exportedJson = vm.readFile(deploymentPath);
        assertFalse(vm.keyExistsJson(exportedJson, string.concat(".", vm.toString(staleFactory))));
        assertEq(
            vm.parseJsonString(exportedJson, string.concat(".", vm.toString(currentFactory))), "SplitRiskPoolFactory"
        );
        assertEq(vm.parseJsonString(exportedJson, string.concat(".", vm.toString(compositeOracle))), "CompositeOracle");

        _removeDeploymentFileIfPresent(deploymentPath);
    }

    function test_exportDeployments_EmptyCurrentRunPreservesExistingEntries() public {
        (DeployHelpersHarness deployHelpers, string memory deploymentPath) =
            _newDeployHelpers(EMPTY_EXPORT_TEST_CHAIN_ID);
        address factory = address(0x1111);
        string memory existingJson = "existing-empty-run";
        vm.serializeString(existingJson, vm.toString(factory), "SplitRiskPoolFactory");
        existingJson = vm.serializeString(existingJson, "networkName", "old-network-name");
        vm.writeJson(existingJson, deploymentPath);

        deployHelpers.exportDeploymentsHarness();

        string memory exportedJson = vm.readFile(deploymentPath);
        assertEq(vm.parseJsonString(exportedJson, string.concat(".", vm.toString(factory))), "SplitRiskPoolFactory");
        assertEq(vm.parseJsonString(exportedJson, ".networkName"), "chain-777777783");

        _removeDeploymentFileIfPresent(deploymentPath);
    }

    function test_exportDeployments_UsesLastDeploymentForDuplicateNameInCurrentRun() public {
        (DeployHelpersHarness deployHelpers, string memory deploymentPath) =
            _newDeployHelpers(CURRENT_RUN_DEDUPE_TEST_CHAIN_ID);
        address initialOracle = address(0x8888);
        address redeployedOracle = address(0x9999);

        deployHelpers.addDeployment("PythOracle", initialOracle);
        deployHelpers.addDeployment("PythOracle", redeployedOracle);
        deployHelpers.exportDeploymentsHarness();

        string memory exportedJson = vm.readFile(deploymentPath);
        assertFalse(vm.keyExistsJson(exportedJson, string.concat(".", vm.toString(initialOracle))));
        assertEq(vm.parseJsonString(exportedJson, string.concat(".", vm.toString(redeployedOracle))), "PythOracle");

        _removeDeploymentFileIfPresent(deploymentPath);
    }

    function test_findAddressByName_ReturnsMostRecentSerializedAddressForDuplicateContractName() public {
        (DeployHelpersHarness deployHelpers,) = _newDeployHelpers(CURRENT_RUN_DEDUPE_TEST_CHAIN_ID + 1);
        string memory jsonObjectKey = "find-latest";
        address staleFactory = address(0xAAAA);
        address currentFactory = address(0xBBBB);

        vm.serializeString(jsonObjectKey, vm.toString(staleFactory), "SplitRiskPoolFactory");
        string memory json = vm.serializeString(jsonObjectKey, vm.toString(currentFactory), "SplitRiskPoolFactory");

        assertEq(deployHelpers.findAddressByName(json, "SplitRiskPoolFactory"), currentFactory);
    }

    function test_findAddressByName_IgnoresSubstringContractNameMatches() public {
        (DeployHelpersHarness deployHelpers,) = _newDeployHelpers(EXACT_MATCH_TEST_CHAIN_ID);
        string memory jsonObjectKey = "find-exact";
        address implementation = address(0xAAAA);
        address factory = address(0xBBBB);

        vm.serializeString(jsonObjectKey, vm.toString(implementation), "SplitRiskPoolFactoryImplementation");
        string memory json = vm.serializeString(jsonObjectKey, vm.toString(factory), "SplitRiskPoolFactory");

        assertEq(deployHelpers.findAddressByName(json, "SplitRiskPoolFactory"), factory);
    }

    function test_findAddressByName_IgnoresSubstringMatchesWhenImplementationSerializedLast() public {
        (DeployHelpersHarness deployHelpers,) = _newDeployHelpers(EXACT_MATCH_TEST_CHAIN_ID + 1);
        string memory jsonObjectKey = "find-exact-reversed";
        address factory = address(0xBBBB);
        address implementation = address(0xAAAA);

        vm.serializeString(jsonObjectKey, vm.toString(factory), "SplitRiskPoolFactory");
        string memory json =
            vm.serializeString(jsonObjectKey, vm.toString(implementation), "SplitRiskPoolFactoryImplementation");

        assertEq(deployHelpers.findAddressByName(json, "SplitRiskPoolFactory"), factory);
    }

    function test_selectFreshestAddress_PrefersDeploymentMetadataWhenBothSourcesExist() public {
        (DeployHelpersHarness deployHelpers,) = _newDeployHelpers(FRESHEST_RESOLUTION_TEST_CHAIN_ID);
        address deploymentAddr = address(0x1001);
        address broadcastAddr = address(0x1002);

        assertEq(deployHelpers.selectFreshestAddressHarness(deploymentAddr, 100, broadcastAddr, 200), deploymentAddr);
    }

    function test_selectFreshestAddress_PrefersNewerDeploymentWhenBroadcastIsOlder() public {
        (DeployHelpersHarness deployHelpers,) = _newDeployHelpers(FRESHEST_RESOLUTION_TEST_CHAIN_ID + 1);
        address deploymentAddr = address(0x2001);
        address broadcastAddr = address(0x2002);

        assertEq(deployHelpers.selectFreshestAddressHarness(deploymentAddr, 200, broadcastAddr, 100), deploymentAddr);
    }

    function test_resolveDeploymentAddresses_FallsBackToBroadcastWhenDeploymentFileLacksRequestedEntries() public {
        (DeployHelpersHarness deployHelpers, string memory deploymentPath) =
            _newDeployHelpers(FRESHEST_RESOLUTION_TEST_CHAIN_ID + 2);
        address mockA = address(0x4001);
        address mockB = address(0x4002);
        string memory broadcastPath = _broadcastPathForChain(FRESHEST_RESOLUTION_TEST_CHAIN_ID + 2);
        string memory existingJson = "deployment-without-mocks";

        _writeBroadcastJson(broadcastPath, _multiBroadcastJson("MockERC20", mockA, mockB));

        vm.serializeString(existingJson, vm.toString(address(0x4999)), "SplitRiskPoolFactory");
        existingJson = vm.serializeString(existingJson, "networkName", "fallback-network");
        vm.writeJson(existingJson, deploymentPath);

        address[] memory resolved = deployHelpers.resolveDeploymentAddressesHarness("MockERC20");
        assertEq(resolved.length, 2);
        assertEq(resolved[0], mockA);
        assertEq(resolved[1], mockB);

        _removeDeploymentFileIfPresent(deploymentPath);
        _removeBroadcastFileIfPresent(broadcastPath);
    }

    function test_resolveDeploymentAddresses_IgnoresBroadcastCallTransactions() public {
        (DeployHelpersHarness deployHelpers, string memory deploymentPath) =
            _newDeployHelpers(FRESHEST_RESOLUTION_TEST_CHAIN_ID + 3);
        address mockA = address(0x5001);
        string memory broadcastPath = _broadcastPathForChain(FRESHEST_RESOLUTION_TEST_CHAIN_ID + 3);

        _writeBroadcastJson(
            broadcastPath,
            string.concat(
                '{"transactions":[{"transactionType":"CALL","contractName":"MockERC20","contractAddress":"',
                vm.toString(mockA),
                '"}],"receipts":[]}'
            )
        );

        address[] memory resolved = deployHelpers.resolveDeploymentAddressesHarness("MockERC20");
        assertEq(resolved.length, 0);

        _removeDeploymentFileIfPresent(deploymentPath);
        _removeBroadcastFileIfPresent(broadcastPath);
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

    function _broadcastPathForChain(uint256 chainId) internal view returns (string memory) {
        return string.concat(
            vm.projectRoot(), "/broadcast/DeployYieldShieldProduction.s.sol/", vm.toString(chainId), "/run-latest.json"
        );
    }

    function _writeBroadcastJson(string memory broadcastPath, string memory json) internal {
        bytes memory pathBytes = bytes(broadcastPath);
        uint256 lastSlash;
        for (uint256 i = 0; i < pathBytes.length; i++) {
            if (pathBytes[i] == 0x2f) {
                lastSlash = i;
            }
        }

        bytes memory dirBytes = new bytes(lastSlash);
        for (uint256 i = 0; i < lastSlash; i++) {
            dirBytes[i] = pathBytes[i];
        }
        vm.createDir(string(dirBytes), true);
        vm.writeFile(broadcastPath, json);
    }

    function _removeBroadcastFileIfPresent(string memory broadcastPath) internal {
        if (vm.exists(broadcastPath)) {
            vm.removeFile(broadcastPath);
        }
    }

    function _multiBroadcastJson(string memory contractName, address contractAddressA, address contractAddressB)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"transactions":[',
            '{"transactionType":"CREATE","contractName":"',
            contractName,
            '","contractAddress":"',
            vm.toString(contractAddressA),
            '"},',
            '{"transactionType":"CREATE","contractName":"',
            contractName,
            '","contractAddress":"',
            vm.toString(contractAddressB),
            '"}',
            '],"receipts":[]}'
        );
    }
}
