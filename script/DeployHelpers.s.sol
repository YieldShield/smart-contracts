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

    function _readDeploymentFile() internal view returns (bool found, string memory content) {
        try vm.readFile(_deploymentPath()) returns (string memory deploymentJson) {
            return (true, deploymentJson);
        } catch { }

        return (false, "");
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

    function _readLatestBroadcast() internal view returns (bool found, string memory content) {
        string[3] memory paths = _broadcastPathCandidates();

        for (uint256 i = 0; i < paths.length; i++) {
            try vm.readFile(paths[i]) returns (string memory broadcastJson) {
                return (true, broadcastJson);
            } catch { }
        }

        return (false, "");
    }

    function exportDeployments() internal {
        // fetch already existing contracts
        root = vm.projectRoot();
        path = string.concat(root, "/deployments/");
        string memory chainIdStr = vm.toString(block.chainid);
        path = string.concat(path, string.concat(chainIdStr, ".json"));

        string memory jsonObjectKey = string.concat("deployment-export-", chainIdStr, "-", vm.toString(gasleft()));

        try vm.readFile(path) returns (string memory existingJson) {
            _mergeExistingDeploymentEntries(jsonObjectKey, existingJson);
        } catch { }

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

    function _mergeExistingDeploymentEntries(string memory jsonObjectKey, string memory existingJson) internal {
        try vm.parseJsonKeys(existingJson, ".") returns (string[] memory keys) {
            for (uint256 i = 0; i < keys.length; i++) {
                if (keccak256(bytes(keys[i])) == keccak256(bytes("networkName"))) {
                    continue;
                }

                try vm.parseJsonString(existingJson, string.concat(".", keys[i])) returns (string memory value) {
                    if (_isShadowedByCurrentDeployment(value, keys[i])) {
                        continue;
                    }
                    vm.serializeString(jsonObjectKey, keys[i], value);
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

    function _isShadowedByCurrentDeployment(string memory existingName, string memory existingAddressKey)
        internal
        view
        returns (bool)
    {
        bytes32 existingNameHash = keccak256(bytes(existingName));
        address existingAddr = address(0);

        if (bytes(existingAddressKey).length == 42) {
            try vm.parseAddress(existingAddressKey) returns (address parsedAddress) {
                existingAddr = parsedAddress;
            } catch { }
        }

        for (uint256 i = 0; i < deployments.length; i++) {
            if (keccak256(bytes(deployments[i].name)) == existingNameHash || deployments[i].addr == existingAddr) {
                return true;
            }
        }

        return false;
    }

    function _resolveDeploymentAddress(string memory contractName) internal view returns (address) {
        (bool foundDeployment, string memory deploymentJson) = _readDeploymentFile();
        if (foundDeployment) {
            address deploymentAddr = _findAddressByName(deploymentJson, contractName);
            if (deploymentAddr != address(0)) {
                return deploymentAddr;
            }
        }

        (bool foundBroadcast, string memory broadcastJson) = _readLatestBroadcast();
        if (!foundBroadcast) {
            return address(0);
        }

        return _getAddressFromBroadcast(broadcastJson, contractName);
    }

    function _resolveDeploymentAddresses(string memory contractName) internal view returns (address[] memory) {
        (bool foundBroadcast, string memory broadcastJson) = _readLatestBroadcast();
        if (foundBroadcast) {
            address[] memory broadcastAddresses = _getAllAddressesFromBroadcast(broadcastJson, contractName);
            if (broadcastAddresses.length > 0) {
                return broadcastAddresses;
            }
        }

        (bool foundDeployment, string memory deploymentJson) = _readDeploymentFile();
        if (!foundDeployment) {
            return new address[](0);
        }

        return _findAllAddressesByName(deploymentJson, contractName);
    }

    function _resolveFactoryAddress() internal view returns (address) {
        (bool foundDeployment, string memory deploymentJson) = _readDeploymentFile();
        if (foundDeployment) {
            address deploymentFactoryAddr = _findAddressByName(deploymentJson, "SplitRiskPoolFactory");
            if (deploymentFactoryAddr != address(0)) {
                return deploymentFactoryAddr;
            }
        }

        (bool foundBroadcast, string memory broadcastJson) = _readLatestBroadcast();
        if (!foundBroadcast) {
            return address(0);
        }

        address proxyAddr = _getAddressFromBroadcast(broadcastJson, "ERC1967Proxy");
        if (proxyAddr != address(0)) {
            return proxyAddr;
        }

        return _getAddressFromBroadcast(broadcastJson, "SplitRiskPoolFactory");
    }

    function _getAddressFromBroadcast(string memory content, string memory contractName)
        internal
        pure
        returns (address)
    {
        uint96 idx = 0;
        address latestAddress = address(0);

        while (true) {
            string memory namePath = string.concat(".transactions[", vm.toString(idx), "].contractName");
            string memory addrPath = string.concat(".transactions[", vm.toString(idx), "].contractAddress");

            try vm.parseJson(content, namePath) returns (bytes memory nameBytes) {
                (bool validName, string memory name) = _tryDecodeJsonString(nameBytes);
                if (!validName) {
                    idx++;
                    continue;
                }

                if (keccak256(bytes(name)) == keccak256(bytes(contractName))) {
                    bytes memory addrBytes = vm.parseJson(content, addrPath);
                    latestAddress = abi.decode(addrBytes, (address));
                }
            } catch {
                break;
            }
            idx++;
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
        uint96 idx = 0;

        while (count < 20) {
            string memory namePath = string.concat(".transactions[", vm.toString(idx), "].contractName");
            string memory addrPath = string.concat(".transactions[", vm.toString(idx), "].contractAddress");

            try vm.parseJson(content, namePath) returns (bytes memory nameBytes) {
                (bool validName, string memory name) = _tryDecodeJsonString(nameBytes);
                if (!validName) {
                    idx++;
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
            } catch {
                break;
            }
            idx++;
        }

        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = found[i];
        }
        return result;
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

        bytes memory jsonBytes = bytes(json);
        bytes memory nameBytes = bytes(contractName);

        uint256 searchIndex = 0;
        while (searchIndex < jsonBytes.length && count < 20) {
            uint256 nameIndex = _indexOfFrom(jsonBytes, nameBytes, searchIndex);
            if (nameIndex == type(uint256).max) {
                break;
            }

            uint256 lowerBound = nameIndex > 100 ? nameIndex - 100 : 0;
            for (uint256 i = nameIndex; i > lowerBound; i--) {
                if (jsonBytes[i] == '"' && i >= 42) {
                    if (jsonBytes[i - 42] == "0" && jsonBytes[i - 41] == "x") {
                        bytes memory addrBytes = new bytes(42);
                        for (uint256 j = 0; j < 42; j++) {
                            addrBytes[j] = jsonBytes[i - 42 + j];
                        }
                        address addr = vm.parseAddress(string(addrBytes));

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
                        break;
                    }
                }
            }

            searchIndex = nameIndex + nameBytes.length;
        }

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
