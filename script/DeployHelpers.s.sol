//SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";

contract ScaffoldETHDeploy is Script {
    error DeployerHasNoBalance();
    error InvalidPrivateKey(string);

    event AnvilSetBalance(address account, uint256 amount);
    event FailedAnvilRequest();

    struct Deployment {
        string name;
        address addr;
    }

    string root;
    string path;
    Deployment[] public deployments;
    uint256 constant ANVIL_BASE_BALANCE = 10000 ether;

    /// @notice The deployer address for every run
    address deployer;

    /// @notice Use this modifier on your run() function on your deploy scripts
    modifier ScaffoldEthDeployerRunner() {
        deployer = _startBroadcast();
        if (deployer == address(0)) {
            revert InvalidPrivateKey("Invalid private key");
        }
        _;
        _stopBroadcast();
        exportDeployments();
    }

    function _startBroadcast() internal returns (address) {
        vm.startBroadcast();
        (, address _deployer,) = vm.readCallers();

        if (block.chainid == 31337 && _deployer.balance == 0) {
            try vm.deal(_deployer, ANVIL_BASE_BALANCE) {
                emit AnvilSetBalance(_deployer, ANVIL_BASE_BALANCE);
            } catch {
                emit FailedAnvilRequest();
            }
        }
        return _deployer;
    }

    function _stopBroadcast() internal {
        vm.stopBroadcast();
    }

    function _deploymentPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
    }

    function _readDeploymentRecord() internal view returns (bool found, string memory content, uint256 modifiedAt) {
        string memory deploymentPath = _deploymentPath();
        try vm.fsMetadata(deploymentPath) returns (Vm.FsMetadata memory metadata) {
            if (!metadata.isDir && metadata.length > 0) {
                return (true, vm.readFile(deploymentPath), metadata.modified);
            }
        } catch { }

        return (false, "", 0);
    }

    function _readDeploymentFile() internal view returns (bool found, string memory content) {
        (found, content,) = _readDeploymentRecord();
    }

    function _broadcastPathCandidates() internal view returns (string[3] memory paths) {
        string memory projectRoot = vm.projectRoot();
        string memory chainId = vm.toString(block.chainid);

        // Prefer the explicit public-network deploy flow, then the local-only flow, then the legacy wrapper.
        paths[0] =
            string.concat(projectRoot, "/broadcast/DeployYieldShieldProduction.s.sol/", chainId, "/run-latest.json");
        paths[1] = string.concat(projectRoot, "/broadcast/DeployYieldShield.s.sol/", chainId, "/run-latest.json");
        paths[2] = string.concat(projectRoot, "/broadcast/Deploy.s.sol/", chainId, "/run-latest.json");
    }

    function _readLatestBroadcastRecord()
        internal
        view
        returns (bool found, string memory content, uint256 modifiedAt)
    {
        string[3] memory paths = _broadcastPathCandidates();
        uint256 latestModified;
        string memory latestPath;

        for (uint256 i = 0; i < paths.length; i++) {
            try vm.fsMetadata(paths[i]) returns (Vm.FsMetadata memory metadata) {
                if (!metadata.isDir && metadata.length > 0 && metadata.modified >= latestModified) {
                    latestModified = metadata.modified;
                    latestPath = paths[i];
                }
            } catch { }
        }

        if (bytes(latestPath).length == 0) {
            return (false, "", 0);
        }

        return (true, vm.readFile(latestPath), latestModified);
    }

    function _readLatestBroadcast() internal view returns (bool found, string memory content) {
        (found, content,) = _readLatestBroadcastRecord();
    }

    function exportDeployments() internal {
        root = vm.projectRoot();
        path = string.concat(root, "/deployments/");
        string memory chainIdStr = vm.toString(block.chainid);
        path = string.concat(path, string.concat(chainIdStr, ".json"));

        string memory jsonObjectKey = string.concat("deployment-export-", chainIdStr, "-", vm.toString(gasleft()));

        (bool foundExisting, string memory existingJson) = _readDeploymentFile();
        if (foundExisting) {
            _serializeExistingDeployments(jsonObjectKey, existingJson);
        }
        _serializeCurrentDeployments(jsonObjectKey);

        string memory chainName;

        try vm.getChain(block.chainid) returns (Vm.Chain memory chain) {
            chainName = chain.name;
        } catch {
            chainName = _fallbackChainName(block.chainid);
        }
        string memory jsonWrite = vm.serializeString(jsonObjectKey, "networkName", chainName);
        vm.writeFile(path, jsonWrite);
    }

    function _serializeExistingDeployments(string memory jsonObjectKey, string memory existingJson) internal {
        try vm.parseJsonKeys(existingJson, ".") returns (string[] memory keys) {
            for (uint256 i = 0; i < keys.length; i++) {
                if (!_isAddressJsonKey(keys[i])) {
                    continue;
                }

                string memory jsonPath = string.concat(".", keys[i]);
                try vm.parseJsonString(existingJson, jsonPath) returns (string memory name) {
                    address addr = vm.parseAddress(keys[i]);
                    if (_currentRunSupersedesDeployment(name, addr)) {
                        continue;
                    }
                    vm.serializeString(jsonObjectKey, keys[i], name);
                } catch { }
            }
        } catch { }
    }

    function _serializeCurrentDeployments(string memory jsonObjectKey) internal {
        uint256 len = deployments.length;

        for (uint256 i = 0; i < len; i++) {
            if (_hasNewerCurrentDeployment(i)) {
                continue;
            }

            vm.serializeString(jsonObjectKey, vm.toString(deployments[i].addr), deployments[i].name);
        }
    }

    function _hasNewerCurrentDeployment(uint256 index) internal view returns (bool) {
        bytes32 deploymentNameHash = keccak256(bytes(deployments[index].name));
        address deploymentAddr = deployments[index].addr;

        for (uint256 i = index + 1; i < deployments.length; i++) {
            if (keccak256(bytes(deployments[i].name)) == deploymentNameHash || deployments[i].addr == deploymentAddr) {
                return true;
            }
        }

        return false;
    }

    function _currentRunSupersedesDeployment(string memory name, address addr) internal view returns (bool) {
        bytes32 nameHash = keccak256(bytes(name));
        for (uint256 i = 0; i < deployments.length; i++) {
            if (_hasNewerCurrentDeployment(i)) {
                continue;
            }
            if (deployments[i].addr == addr || keccak256(bytes(deployments[i].name)) == nameHash) {
                return true;
            }
        }
        return false;
    }

    function _isAddressJsonKey(string memory key) internal pure returns (bool) {
        bytes memory keyBytes = bytes(key);
        return keyBytes.length == 42 && keyBytes[0] == "0" && (keyBytes[1] == "x" || keyBytes[1] == "X");
    }

    function _resolveDeploymentAddress(string memory contractName) internal view returns (address) {
        (bool foundDeployment, string memory deploymentJson, uint256 deploymentModifiedAt) = _readDeploymentRecord();
        address deploymentAddr = address(0);
        if (foundDeployment) {
            deploymentAddr = _findAddressByName(deploymentJson, contractName);
        }

        (bool foundBroadcast, string memory broadcastJson, uint256 broadcastModifiedAt) = _readLatestBroadcastRecord();
        address broadcastAddr = address(0);
        if (foundBroadcast) {
            broadcastAddr = _getAddressFromBroadcast(broadcastJson, contractName);
        }

        return _selectFreshestAddress(deploymentAddr, deploymentModifiedAt, broadcastAddr, broadcastModifiedAt);
    }

    function _resolveDeploymentAddresses(string memory contractName) internal view returns (address[] memory) {
        (bool foundDeployment, string memory deploymentJson, uint256 deploymentModifiedAt) = _readDeploymentRecord();
        address[] memory deploymentAddresses = new address[](0);
        if (foundDeployment) {
            deploymentAddresses = _findAllAddressesByName(deploymentJson, contractName);
        }

        (bool foundBroadcast, string memory broadcastJson, uint256 broadcastModifiedAt) = _readLatestBroadcastRecord();
        address[] memory broadcastAddresses = new address[](0);
        if (foundBroadcast) {
            broadcastAddresses = _getAllAddressesFromBroadcast(broadcastJson, contractName);
        }

        return _selectFreshestAddressList(
            deploymentAddresses, deploymentModifiedAt, broadcastAddresses, broadcastModifiedAt
        );
    }

    function _resolveFactoryAddress() internal view returns (address) {
        (bool foundDeployment, string memory deploymentJson, uint256 deploymentModifiedAt) = _readDeploymentRecord();
        address deploymentFactoryAddr = address(0);
        if (foundDeployment) {
            deploymentFactoryAddr = _findAddressByName(deploymentJson, "SplitRiskPoolFactory");
        }

        (bool foundBroadcast, string memory broadcastJson, uint256 broadcastModifiedAt) = _readLatestBroadcastRecord();
        address broadcastFactoryAddr = address(0);
        if (foundBroadcast) {
            broadcastFactoryAddr = _factoryAddressFromBroadcast(broadcastJson);
        }

        return _selectFreshestAddress(
            deploymentFactoryAddr, deploymentModifiedAt, broadcastFactoryAddr, broadcastModifiedAt
        );
    }

    function _factoryAddressFromBroadcast(string memory content) internal pure returns (address) {
        address proxyAddr = _getAddressFromBroadcast(content, "ERC1967Proxy");
        if (proxyAddr != address(0)) {
            return proxyAddr;
        }

        return _getAddressFromBroadcast(content, "SplitRiskPoolFactory");
    }

    function _selectFreshestAddress(
        address deploymentAddr,
        uint256 deploymentModifiedAt,
        address broadcastAddr,
        uint256 broadcastModifiedAt
    ) internal pure returns (address) {
        deploymentModifiedAt;
        broadcastModifiedAt;

        if (deploymentAddr != address(0) && broadcastAddr != address(0)) {
            return deploymentAddr;
        }

        if (deploymentAddr != address(0)) {
            return deploymentAddr;
        }

        return broadcastAddr;
    }

    function _selectFreshestAddressList(
        address[] memory deploymentAddresses,
        uint256 deploymentModifiedAt,
        address[] memory broadcastAddresses,
        uint256 broadcastModifiedAt
    ) internal pure returns (address[] memory) {
        deploymentModifiedAt;
        broadcastModifiedAt;

        if (deploymentAddresses.length > 0 && broadcastAddresses.length > 0) {
            return deploymentAddresses;
        }

        if (deploymentAddresses.length > 0) {
            return deploymentAddresses;
        }

        return broadcastAddresses;
    }

    function _getAddressFromBroadcast(string memory content, string memory contractName)
        internal
        pure
        returns (address)
    {
        address latestAddress = address(0);
        uint256 transactionCount = _broadcastTransactionCount(content);

        for (uint256 idx = 0; idx < transactionCount; idx++) {
            if (!_broadcastTransactionIsCreate(content, idx)) {
                continue;
            }

            string memory namePath = string.concat(".transactions[", vm.toString(idx), "].contractName");
            string memory addrPath = string.concat(".transactions[", vm.toString(idx), "].contractAddress");

            try vm.parseJson(content, namePath) returns (bytes memory nameBytes) {
                (bool validName, string memory name) = _tryDecodeJsonString(nameBytes);
                if (!validName) {
                    continue;
                }

                if (keccak256(bytes(name)) == keccak256(bytes(contractName))) {
                    bytes memory addrBytes = vm.parseJson(content, addrPath);
                    latestAddress = abi.decode(addrBytes, (address));
                }
            } catch { }
        }

        return latestAddress;
    }

    function _getAllAddressesFromBroadcast(string memory content, string memory contractName)
        internal
        pure
        returns (address[] memory)
    {
        address[] memory found = new address[](20);
        uint256 count = 0;
        uint256 transactionCount = _broadcastTransactionCount(content);

        for (uint256 idx = 0; idx < transactionCount && count < 20; idx++) {
            if (!_broadcastTransactionIsCreate(content, idx)) {
                continue;
            }

            string memory namePath = string.concat(".transactions[", vm.toString(idx), "].contractName");
            string memory addrPath = string.concat(".transactions[", vm.toString(idx), "].contractAddress");

            try vm.parseJson(content, namePath) returns (bytes memory nameBytes) {
                (bool validName, string memory name) = _tryDecodeJsonString(nameBytes);
                if (!validName) {
                    continue;
                }

                if (keccak256(bytes(name)) == keccak256(bytes(contractName))) {
                    bytes memory addrBytes = vm.parseJson(content, addrPath);
                    address addr = abi.decode(addrBytes, (address));

                    bool exists = false;
                    for (uint256 i = 0; i < count; i++) {
                        if (found[i] == addr) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) {
                        found[count] = addr;
                        count++;
                    }
                }
            } catch { }
        }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = found[i];
        }
        return result;
    }

    function _broadcastTransactionIsCreate(string memory content, uint256 idx) internal pure returns (bool) {
        string memory txTypePath = string.concat(".transactions[", vm.toString(idx), "].transactionType");
        try vm.parseJson(content, txTypePath) returns (bytes memory typeBytes) {
            (bool validType, string memory transactionType) = _tryDecodeJsonString(typeBytes);
            return validType && keccak256(bytes(transactionType)) == keccak256(bytes("CREATE"));
        } catch {
            return false;
        }
    }

    function _broadcastTransactionCount(string memory content) internal pure returns (uint256) {
        for (uint256 idx = 0; idx < 256; idx++) {
            string memory transactionPath = string.concat(".transactions[", vm.toString(idx), "]");
            try vm.parseJsonKeys(content, transactionPath) returns (string[] memory transactionKeys) {
                if (transactionKeys.length == 0) {
                    return idx;
                }
            } catch {
                return idx;
            }
        }

        return 256;
    }

    function _tryDecodeJsonString(bytes memory raw) internal pure returns (bool ok, string memory value) {
        if (raw.length < 64 || raw.length % 32 != 0) {
            return (false, "");
        }

        uint256 offset;
        uint256 stringLength;
        assembly ("memory-safe") {
            offset := mload(add(raw, 0x20))
            stringLength := mload(add(raw, 0x40))
        }

        if (offset != 0x20) {
            return (false, "");
        }

        uint256 paddedLength = ((stringLength + 31) / 32) * 32;
        if (raw.length < 64 + paddedLength) {
            return (false, "");
        }

        return (true, abi.decode(raw, (string)));
    }

    function _findAddressByName(string memory json, string memory contractName) internal pure returns (address) {
        address[] memory addresses = _findAllAddressesByName(json, contractName);
        if (addresses.length == 0) {
            return address(0);
        }

        return addresses[0];
    }

    function _findAllAddressesByName(string memory json, string memory contractName)
        internal
        pure
        returns (address[] memory)
    {
        address[] memory found = new address[](20);
        uint256 count = 0;
        bytes32 targetNameHash = keccak256(bytes(contractName));

        try vm.parseJsonKeys(json, ".") returns (string[] memory keys) {
            for (uint256 i = 0; i < keys.length && count < 20; i++) {
                if (!_isAddressJsonKey(keys[i])) {
                    continue;
                }

                string memory jsonPath = string.concat(".", keys[i]);
                try vm.parseJsonString(json, jsonPath) returns (string memory name) {
                    if (keccak256(bytes(name)) != targetNameHash) {
                        continue;
                    }

                    address addr = vm.parseAddress(keys[i]);
                    bool exists = false;
                    for (uint256 k = 0; k < count; k++) {
                        if (found[k] == addr) {
                            exists = true;
                            break;
                        }
                    }
                    if (!exists) {
                        found[count] = addr;
                        count++;
                    }
                } catch { }
            }
        } catch { }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = found[i];
        }
        return result;
    }

    function _indexOf(bytes memory haystack, bytes memory needle) internal pure returns (uint256) {
        return _indexOfFrom(haystack, needle, 0);
    }

    function _indexOfFrom(bytes memory haystack, bytes memory needle, uint256 from) internal pure returns (uint256) {
        if (needle.length > haystack.length || from >= haystack.length) {
            return type(uint256).max;
        }

        for (uint256 i = from; i <= haystack.length - needle.length; i++) {
            bool isMatch = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    isMatch = false;
                    break;
                }
            }
            if (isMatch) {
                return i;
            }
        }

        return type(uint256).max;
    }

    function _fallbackChainName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 31337 || chainId == 1337) {
            return "anvil-hardhat";
        }

        return string.concat("chain-", _uintToString(chainId));
    }

    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }

        uint256 digits;
        uint256 temp = value;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }

        return string(buffer);
    }
}
