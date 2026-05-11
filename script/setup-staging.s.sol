//SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { console } from "forge-std/console.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { MockGauntletUSDCPrime } from "../contracts/mocks/MockGauntletUSDCPrime.sol";
import { IPriceOracle } from "../contracts/interfaces/IPriceOracle.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @notice Staging setup script for testnet deployments
 * @dev Creates pools and sample positions using the deployer account.
 *      Unlike local scripts, this does NOT use hardcoded Anvil accounts.
 *      The deployer acts as both shielded depositor and protector for demo data.
 *
 * Usage: forge script script/setup-staging.s.sol:SetupStaging \
 *          --rpc-url <RPC_URL> --private-key <KEY> --broadcast --ffi
 */
contract SetupStaging is ScaffoldETHDeploy {
    uint256 constant MINT_AMOUNT = 100_000e18; // 100k tokens (18 decimals)
    uint256 constant USDC_MINT_AMOUNT = 100_000e6; // 100k USDC (6 decimals)
    uint256 constant PROTECTOR_DEPOSIT = 20_000e18; // 20k tokens — must exceed shielded value at collateral ratio
    uint256 constant SHIELDED_DEPOSIT = 5_000e18; // 5k tokens — conservative to stay within collateral bounds

    function run() external {
        deployer = _startBroadcast();
        console.log("\n=== Staging Setup ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        // === STEP 1: Load deployed addresses ===
        address factoryAddr = _getFactoryAddress();
        require(factoryAddr != address(0), "Factory not found in deployments");

        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(factoryAddr));
        console.log("Factory:", factoryAddr);

        // Load token addresses from broadcast
        address[] memory mockERC20Addrs = _getAllAddresses("MockERC20");
        address usdcAddr = _getAddress("MockUSDC");
        address gtusdcAddr = _getAddress("MockGauntletUSDCPrime");

        require(mockERC20Addrs.length >= 11, "Not enough MockERC20 tokens");
        require(usdcAddr != address(0), "MockUSDC not found");
        require(gtusdcAddr != address(0), "gtUSDC not found");

        // Map by deployment order (same as DeployYieldShield)
        address susdeAddr = mockERC20Addrs[0]; // SUSDE
        address sdaiAddr = mockERC20Addrs[1]; // SDAI
        address usdyAddr = mockERC20Addrs[2]; // USDY
        address stethAddr = mockERC20Addrs[3]; // STETH
        address stoneAddr = mockERC20Addrs[4]; // STONE

        console.log("Tokens loaded");

        // === STEP 2: Mint tokens to deployer ===
        console.log("\n--- Minting tokens to deployer ---");

        _mintMockERC20(susdeAddr, MINT_AMOUNT);
        _mintMockERC20(sdaiAddr, MINT_AMOUNT);
        _mintMockERC20(usdyAddr, MINT_AMOUNT);
        _mintMockERC20(stethAddr, MINT_AMOUNT);
        _mintMockERC20(stoneAddr, MINT_AMOUNT);

        // gtUSDC is an ERC4626 vault — mint shares directly
        MockGauntletUSDCPrime(payable(gtusdcAddr)).mintShares(deployer, MINT_AMOUNT);
        console.log("Minted gtUSDC shares");

        console.log("Token minting complete");

        // === STEP 3: Create pools ===
        console.log("\n--- Creating pools ---");

        uint256 existingPoolCount = factory.poolCount();
        if (existingPoolCount > 0) {
            console.log("Pools already exist (", existingPoolCount, "), skipping creation");
        } else {
            uint256 gtusdcBondAmount = _creationBondAmount(factory, gtusdcAddr);
            uint256 usdyBondAmount = _creationBondAmount(factory, usdyAddr);
            uint256 stoneBondAmount = _creationBondAmount(factory, stoneAddr);

            IERC20(gtusdcAddr).approve(address(factory), gtusdcBondAmount);
            IERC20(usdyAddr).approve(address(factory), usdyBondAmount);
            IERC20(stoneAddr).approve(address(factory), stoneBondAmount);

            // Pool 1: SUSDE / gtUSDC (stablecoin pair)
            address pool1 = factory.createPool(
                susdeAddr,
                "SUSDE",
                gtusdcAddr,
                "gtUSDC",
                500,
                200,
                10000, // 5% commission, 2% fee, 100% collateral
                gtusdcBondAmount
            );
            console.log("Pool 1 (SUSDE/gtUSDC):", pool1);

            // Pool 2: SDAI / USDY (stablecoin pair)
            address pool2 = factory.createPool(sdaiAddr, "SDAI", usdyAddr, "USDY", 500, 200, 10000, usdyBondAmount);
            console.log("Pool 2 (SDAI/USDY):", pool2);

            // Pool 3: STETH / STONE (volatile pair, 150% collateral)
            address pool3 = factory.createPool(stethAddr, "STETH", stoneAddr, "STONE", 500, 200, 15000, stoneBondAmount);
            console.log("Pool 3 (STETH/STONE):", pool3);
        }

        // === STEP 4: Create sample positions ===
        console.log("\n--- Creating sample positions ---");

        uint256 poolCount = factory.poolCount();
        require(poolCount >= 3, "Need at least 3 pools");
        address[] memory pools = factory.getPools(0, 3);

        // Pool 1: protect with gtUSDC, shield with SUSDE
        _createProtectorPosition(pools[0], gtusdcAddr, PROTECTOR_DEPOSIT);
        _createShieldedPosition(pools[0], susdeAddr, SHIELDED_DEPOSIT);

        // Pool 2: protect with USDY, shield with SDAI
        _createProtectorPosition(pools[1], usdyAddr, PROTECTOR_DEPOSIT);
        _createShieldedPosition(pools[1], sdaiAddr, SHIELDED_DEPOSIT);

        console.log("\n=== Staging Setup Complete ===");
        _stopBroadcast();
    }

    // --- Helpers ---

    function _mintMockERC20(address tokenAddr, uint256 amount) internal {
        MockERC20 token = MockERC20(tokenAddr);
        token.mint(deployer, amount);
        console.log("Minted", amount / 1e18, token.symbol());
    }

    function _createProtectorPosition(address poolAddr, address tokenAddr, uint256 amount) internal {
        SplitRiskPool pool = SplitRiskPool(payable(poolAddr));
        IERC20(tokenAddr).approve(poolAddr, amount);
        pool.depositBackingAsset(tokenAddr, amount, 0);
        console.log("Protector position created in pool:", poolAddr);
    }

    function _createShieldedPosition(address poolAddr, address tokenAddr, uint256 amount) internal {
        SplitRiskPool pool = SplitRiskPool(payable(poolAddr));
        IERC20(tokenAddr).approve(poolAddr, amount);
        pool.depositShieldedAsset(tokenAddr, amount, 0);
        console.log("Shielded position created in pool:", poolAddr);
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
        // Try deployment file first
        try vm.readFile(_deploymentPath()) returns (string memory content) {
            address addr = _findAddressByName(content, "SplitRiskPoolFactory");
            if (addr != address(0)) return addr;
        } catch { }

        // Fallback to broadcast file. UUPS deployments include the implementation before
        // the ERC1967Proxy, so prefer the proxy when it is present.
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

    function _getAddress(string memory contractName) internal view returns (address) {
        (bool foundBroadcast, string memory content) = _readLatestBroadcast();
        if (foundBroadcast) {
            return _getAddressFromBroadcast(content, contractName);
        }

        string memory deploymentJson = vm.readFile(_deploymentPath());
        return _findAddressByName(deploymentJson, contractName);
    }

    function _getAllAddresses(string memory contractName) internal view returns (address[] memory) {
        (bool foundBroadcast, string memory content) = _readLatestBroadcast();
        if (foundBroadcast) {
            return _getAllAddressesFromBroadcast(content, contractName);
        }

        string memory deploymentJson = vm.readFile(_deploymentPath());
        return _findAllAddressesByName(deploymentJson, contractName);
    }

    // --- Broadcast/deployment JSON parsing (same pattern as setup-pools.s.sol) ---

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
        if (nameIndex == type(uint256).max) return address(0);

        uint256 lowerBound = nameIndex > 100 ? nameIndex - 100 : 0;
        for (uint256 i = nameIndex; i > lowerBound; i--) {
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

            uint256 lowerBound2 = nameIndex > 100 ? nameIndex - 100 : 0;
            for (uint256 i = nameIndex; i > lowerBound2; i--) {
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
        if (needle.length > haystack.length || from >= haystack.length) return type(uint256).max;
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
