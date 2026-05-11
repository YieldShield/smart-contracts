//SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";

contract ScaffoldETHDeploy is Script {
    error InvalidChain();
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

        uint256 len = deployments.length;

        for (uint256 i = 0; i < len; i++) {
            vm.serializeString(jsonObjectKey, vm.toString(deployments[i].addr), deployments[i].name);
        }

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
                    vm.serializeString(jsonObjectKey, keys[i], value);
                } catch { }
            }
        } catch { }
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

    function findChainName() public returns (string memory) {
        uint256 thisChainId = block.chainid;
        string[2][] memory allRpcUrls = vm.rpcUrls();
        for (uint256 i = 0; i < allRpcUrls.length; i++) {
            try vm.createSelectFork(allRpcUrls[i][1]) {
                if (block.chainid == thisChainId) {
                    return allRpcUrls[i][0];
                }
            } catch {
                continue;
            }
        }
        revert InvalidChain();
    }
}
