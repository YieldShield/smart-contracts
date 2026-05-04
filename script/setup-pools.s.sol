//SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { console } from "forge-std/console.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { IPriceOracle } from "../contracts/interfaces/IPriceOracle.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @notice Pool creation script for local development setup
 * @dev Creates 5 pools with different token pairs and configurations
 * Usage: forge script script/setup-pools.s.sol:SetupPools --rpc-url localhost --broadcast --legacy
 */
contract SetupPools is ScaffoldETHDeploy {
    // Pool configurations
    struct PoolConfig {
        string shieldedTokenName;
        string shieldedTokenSymbol;
        string backingTokenName;
        string backingTokenSymbol;
        uint256 commissionRate; // in basis points
        uint256 poolFee; // in basis points
        uint256 collateralRatio; // in basis points
    }

    // Pool addresses (stored for position creation)
    address[] public poolAddresses;

    function run() external ScaffoldEthDeployerRunner {
        console.log("\n=== Creating Pools ===");

        // Get factory address
        address factoryAddr = _getFactoryAddress();
        require(factoryAddr != address(0), "Factory not found");

        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(factoryAddr));
        console.log("Factory address:", factoryAddr);

        // Check if pools already exist
        uint256 existingPoolCount = factory.poolCount();
        if (existingPoolCount > 0) {
            console.log("Pools already exist (", existingPoolCount, " pools), skipping creation");
            return;
        }

        // Get token addresses in deployment order
        // Order from DeployYieldShield: susde, sdai, usdy, steth, stone, jaaa, ustb, usyc, lbtc, rlp, susds, usdc, gtusdc
        address[] memory mockERC20Addrs = _getAllTokenAddresses("MockERC20");
        address gtusdcAddr = _getTokenAddress("MockGauntletUSDCPrime", 0);

        require(mockERC20Addrs.length >= 11, "Not enough MockERC20 tokens found");

        // Map tokens by deployment order
        address susdeAddr = mockERC20Addrs[0]; // SUSDE
        address sdaiAddr = mockERC20Addrs[1]; // SDAI
        address usdyAddr = mockERC20Addrs[2]; // USDY
        address stethAddr = mockERC20Addrs[3]; // STETH
        address stoneAddr = mockERC20Addrs[4]; // STONE
        address jaaaAddr = mockERC20Addrs[5]; // JAAA
        address ustbAddr = mockERC20Addrs[6]; // USTB
        address usycAddr = mockERC20Addrs[7]; // USYC
        address rlpAddr = mockERC20Addrs[9]; // RLP (skip index 8 = LBTC)

        require(susdeAddr != address(0), "SUSDE not found");
        require(sdaiAddr != address(0), "SDAI not found");
        require(usdyAddr != address(0), "USDY not found");
        require(stethAddr != address(0), "STETH not found");
        require(stoneAddr != address(0), "STONE not found");
        require(jaaaAddr != address(0), "JAAA not found");
        require(ustbAddr != address(0), "USTB not found");
        require(usycAddr != address(0), "USYC not found");
        require(rlpAddr != address(0), "RLP not found");
        require(gtusdcAddr != address(0), "gtUSDC not found");

        console.log("Token addresses loaded");

        // Define pool configurations
        PoolConfig[5] memory poolConfigs = [
            PoolConfig({
                shieldedTokenName: "Staked USDe",
                shieldedTokenSymbol: "SUSDE",
                backingTokenName: "Gauntlet USDC Prime",
                backingTokenSymbol: "gtUSDC",
                commissionRate: 500, // 5%
                poolFee: 200, // 2%
                collateralRatio: 10000 // 100%
            }),
            PoolConfig({
                shieldedTokenName: "Savings DAI",
                shieldedTokenSymbol: "SDAI",
                backingTokenName: "Ondo USD Yield",
                backingTokenSymbol: "USDY",
                commissionRate: 500,
                poolFee: 200,
                collateralRatio: 10000
            }),
            PoolConfig({
                shieldedTokenName: "Lido Staked Ether",
                shieldedTokenSymbol: "STETH",
                backingTokenName: "Stargate Finance",
                backingTokenSymbol: "STONE",
                commissionRate: 500,
                poolFee: 200,
                collateralRatio: 15000 // 150% for volatile assets
            }),
            PoolConfig({
                shieldedTokenName: "Janus Henderson Anemoy AAA CLO Fund",
                shieldedTokenSymbol: "JAAA",
                backingTokenName: "U.S. Government Securities Fund",
                backingTokenSymbol: "USTB",
                commissionRate: 500,
                poolFee: 200,
                collateralRatio: 10000
            }),
            PoolConfig({
                shieldedTokenName: "Circle Yield Fund",
                shieldedTokenSymbol: "USYC",
                backingTokenName: "Resolv Liquidity Provider Token",
                backingTokenSymbol: "RLP",
                commissionRate: 500,
                poolFee: 200,
                collateralRatio: 10000
            })
        ];

        // Token address arrays matching pool configs
        address[5] memory shieldedTokens = [susdeAddr, sdaiAddr, stethAddr, jaaaAddr, usycAddr];
        address[5] memory backingTokens = [gtusdcAddr, usdyAddr, stoneAddr, ustbAddr, rlpAddr];

        // Create pools
        for (uint256 i = 0; i < poolConfigs.length; i++) {
            console.log("\nCreating Pool", i + 1, ":");
            console.log("  Shielded:", poolConfigs[i].shieldedTokenSymbol);
            console.log("  Backing:", poolConfigs[i].backingTokenSymbol);

            uint256 creationBondAmount = _creationBondAmount(factory, backingTokens[i]);
            IERC20(backingTokens[i]).approve(address(factory), creationBondAmount);

            address poolAddr = factory.createPool(
                shieldedTokens[i],
                poolConfigs[i].shieldedTokenSymbol,
                backingTokens[i],
                poolConfigs[i].backingTokenSymbol,
                poolConfigs[i].commissionRate,
                poolConfigs[i].poolFee,
                poolConfigs[i].collateralRatio,
                creationBondAmount
            );

            poolAddresses.push(poolAddr);
            console.log("  Pool created at:", poolAddr);
        }

        console.log("\n=== Pool Creation Complete ===");
        console.log("Total pools created:", poolAddresses.length);
    }

    function _creationBondAmount(SplitRiskPoolFactory factory, address token) internal view returns (uint256) {
        uint256 minimumCreationBondUsd = factory.minimumCreationBondUsd();
        if (minimumCreationBondUsd == 0) {
            return 0;
        }

        uint256 price = IPriceOracle(factory.compositeOracle()).getPrice(token);
        uint256 scale = 10 ** IERC20Metadata(token).decimals();
        return (minimumCreationBondUsd * scale + price - 1) / price;
    }

    function _getFactoryAddress() internal view returns (address) {
        // Try deployment file first (has correct proxy address if populated)
        try vm.readFile(_deploymentPath()) returns (string memory content) {
            address deploymentFactoryAddr = _findAddressByName(content, "SplitRiskPoolFactory");
            if (deploymentFactoryAddr != address(0)) {
                return deploymentFactoryAddr;
            }
        } catch { }

        // Fallback to broadcast file. New deployments write SplitRiskPoolFactory directly,
        // while older local broadcasts used an ERC1967Proxy wrapper.
        (bool foundBroadcast, string memory broadcastJson) = _readLatestBroadcast();
        if (!foundBroadcast) {
            return address(0);
        }

        address broadcastFactoryAddr = _getAddressFromBroadcast(broadcastJson, "SplitRiskPoolFactory");
        if (broadcastFactoryAddr != address(0)) {
            return broadcastFactoryAddr;
        }

        return _getAddressFromBroadcast(broadcastJson, "ERC1967Proxy");
    }

    function _getTokenAddress(string memory contractName, uint256 index) internal view returns (address) {
        address[] memory addresses = _getAllTokenAddresses(contractName);
        if (index < addresses.length) {
            return addresses[index];
        }
        return address(0);
    }

    function _getAllTokenAddresses(string memory contractName) internal view returns (address[] memory) {
        // Get all addresses of this contract type
        address[] memory addresses;
        (bool foundBroadcast, string memory content) = _readLatestBroadcast();
        if (foundBroadcast) {
            addresses = _getAllAddressesFromBroadcast(content, contractName);
        } else {
            // Fallback to deployment file
            string memory deploymentJson = vm.readFile(_deploymentPath());
            addresses = _findAllAddressesByName(deploymentJson, contractName);
        }

        return addresses;
    }

    function _getAddressFromBroadcast(string memory content, string memory contractName)
        internal
        pure
        returns (address)
    {
        uint96 idx = 0;
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
                    return abi.decode(addrBytes, (address));
                }
            } catch {
                break;
            }
            idx++;
        }
        return address(0);
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
        bytes memory jsonBytes = bytes(json);
        bytes memory nameBytes = bytes(contractName);

        uint256 nameIndex = _indexOf(jsonBytes, nameBytes);
        if (nameIndex == type(uint256).max) {
            return address(0);
        }

        for (uint256 i = nameIndex; i > 0 && i > nameIndex - 100; i--) {
            if (jsonBytes[i] == '"' && i >= 42) {
                if (jsonBytes[i - 42] == "0" && jsonBytes[i - 41] == "x") {
                    bytes memory addrBytes = new bytes(42);
                    for (uint256 j = 0; j < 42; j++) {
                        addrBytes[j] = jsonBytes[i - 42 + j];
                    }
                    return vm.parseAddress(string(addrBytes));
                }
            }
        }
        return address(0);
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
            if (nameIndex == type(uint256).max) break;

            for (uint256 i = nameIndex; i > 0 && i > nameIndex - 100; i--) {
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
            if (isMatch) return i;
        }
        return type(uint256).max;
    }
}
