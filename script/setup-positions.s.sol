//SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { console } from "forge-std/console.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Position creation script for local development setup
 * @dev Creates positions according to account profiles
 * Usage: forge script script/setup-positions.s.sol:SetupPositions --rpc-url localhost --broadcast --legacy
 */
contract SetupPositions is ScaffoldETHDeploy {
    error LocalChainRequired(uint256 chainId);

    // Anvil default accounts (0-9) with private keys
    struct AccountInfo {
        address addr;
        uint256 privateKey;
    }

    AccountInfo[10] public accounts = [
        AccountInfo(
            0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
        ), // Account #0
        AccountInfo(
            0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
        ), // Account #1
        AccountInfo(
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
        ), // Account #2
        AccountInfo(
            0x90F79bf6EB2c4f870365E785982E1f101E93b906,
            0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
        ), // Account #3
        AccountInfo(
            0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65,
            0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a
        ), // Account #4
        AccountInfo(
            0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc,
            0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
        ), // Account #5
        AccountInfo(
            0x976EA74026E726554dB657fA54763abd0C3a0aa9,
            0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
        ), // Account #6
        AccountInfo(
            0x14dC79964da2C08b23698B3D3cc7Ca32193d9955,
            0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356
        ), // Account #7
        AccountInfo(
            0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f,
            0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97
        ), // Account #8 (fixed address and key)
        AccountInfo(
            0xa0Ee7A142d267C1f36714E4a8F75612F20a79720,
            0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6
        ) // Account #9
    ];

    function run() external {
        if (block.chainid != 31337 && block.chainid != 1337) {
            revert LocalChainRequired(block.chainid);
        }
        console.log("\n=== Creating Positions ===");

        // Get factory address
        address factoryAddr = _getFactoryAddress();
        require(factoryAddr != address(0), "Factory not found");

        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(factoryAddr));

        uint256 poolCount = factory.poolCount();
        require(poolCount >= 5, "Not enough pools created");
        address[] memory pools = factory.getPools(0, 5);

        console.log("Found", poolCount, "pools");

        // Get pool instances
        SplitRiskPool pool1 = SplitRiskPool(payable(pools[0])); // SUSDE/SUSDS
        SplitRiskPool pool2 = SplitRiskPool(payable(pools[1])); // SDAI/USDY
        SplitRiskPool pool3 = SplitRiskPool(payable(pools[2])); // STETH/STONE
        SplitRiskPool pool4 = SplitRiskPool(payable(pools[3])); // JAAA/USTB
        // Get token addresses from pools
        address susdeAddr = pool1.SHIELDED_TOKEN();
        address susdsAddr = pool1.BACKING_TOKEN();
        address sdaiAddr = pool2.SHIELDED_TOKEN();
        address usdyAddr = pool2.BACKING_TOKEN();
        address stethAddr = pool3.SHIELDED_TOKEN();
        address stoneAddr = pool3.BACKING_TOKEN();
        address jaaaAddr = pool4.SHIELDED_TOKEN();
        address ustbAddr = pool4.BACKING_TOKEN();
        console.log("Token addresses loaded from pools");

        // ============================================================
        // PHASE 1: CREATE ALL PROTECTOR POSITIONS FIRST
        // Pools require protector collateral before shielded deposits
        // ============================================================
        console.log("\n========== PHASE 1: PROTECTOR POSITIONS ==========");

        // Account #2: Small Protector - Pool 1: 200 SUSDS
        console.log("\n=== Account #2: Small Protector (Pool 1) ===");
        _createProtectorPosition(accounts[2], pool1, susdsAddr, 200e18);

        // Account #4: Large Protector - 4 pools, 1000 each
        console.log("\n=== Account #4: Large Protector (Pools 1-4) ===");
        _createProtectorPosition(accounts[4], pool1, susdsAddr, 1000e18);
        _createProtectorPosition(accounts[4], pool2, usdyAddr, 1000e18);
        _createProtectorPosition(accounts[4], pool3, stoneAddr, 1000e18);
        _createProtectorPosition(accounts[4], pool4, ustbAddr, 1000e18);

        // Account #5: Mixed User - Protector positions first
        console.log("\n=== Account #5: Mixed User - Protector (Pools 1-2) ===");
        _createProtectorPosition(accounts[5], pool1, susdsAddr, 600e18);
        _createProtectorPosition(accounts[5], pool2, usdyAddr, 600e18);

        // Account #7: Whale Protector - Pool 1: 10k SUSDS (uses full 10k balance)
        // Sized to cover shielded deposits at realistic oracle prices (sUSDe=$1.22, SUSDS=$1.10)
        console.log("\n=== Account #7: Whale Protector (Pool 1) ===");
        _createProtectorPosition(accounts[7], pool1, susdsAddr, 10000e18);

        // Account #8: Diversified - Protector position first
        console.log("\n=== Account #8: Diversified - Protector (Pool 3) ===");
        _createProtectorPosition(accounts[8], pool3, stoneAddr, 400e18);

        // ============================================================
        // PHASE 2: CREATE ALL SHIELDED POSITIONS
        // Now that pools have protector collateral, shielded deposits can succeed
        // ============================================================
        console.log("\n========== PHASE 2: SHIELDED POSITIONS ==========");

        // Account #1: Small Shielded - Pool 1: 100 SUSDE
        console.log("\n=== Account #1: Small Shielded (Pool 1) ===");
        _createShieldedPosition(accounts[1], pool1, susdeAddr, 100e18);

        // Account #3: Large Shielded - 4 pools, 500 each
        console.log("\n=== Account #3: Large Shielded (Pools 1-4) ===");
        _createShieldedPosition(accounts[3], pool1, susdeAddr, 500e18);
        _createShieldedPosition(accounts[3], pool2, sdaiAddr, 500e18);
        _createShieldedPosition(accounts[3], pool3, stethAddr, 500e18);
        _createShieldedPosition(accounts[3], pool4, jaaaAddr, 500e18);

        // Account #5: Mixed User - Shielded positions
        console.log("\n=== Account #5: Mixed User - Shielded (Pools 1-2) ===");
        _createShieldedPosition(accounts[5], pool1, susdeAddr, 300e18);
        _createShieldedPosition(accounts[5], pool2, sdaiAddr, 300e18);

        // Account #6: Whale Shielded - Pool 1: 8k SUSDE (reduced to fit within protector capacity)
        console.log("\n=== Account #6: Whale Shielded (Pool 1) ===");
        _createShieldedPosition(accounts[6], pool1, susdeAddr, 8000e18);

        // Account #8: Diversified - Shielded position
        console.log("\n=== Account #8: Diversified - Shielded (Pool 3) ===");
        _createShieldedPosition(accounts[8], pool3, stethAddr, 200e18);

        console.log("\n=== Position Creation Complete ===");
    }

    function _createShieldedPosition(AccountInfo memory account, SplitRiskPool pool, address tokenAddr, uint256 amount)
        internal
    {
        IERC20 token = IERC20(tokenAddr);

        // Use account's private key for this transaction
        vm.startBroadcast(account.privateKey);

        // Approve token
        token.approve(address(pool), amount);

        // Deposit shielded asset
        try pool.depositShieldedAsset(tokenAddr, amount, 0) returns (uint256 tokenId) {
            console.log("  Created shielded position: Token ID", tokenId, "Amount:", amount / 1e18);
        } catch Error(string memory reason) {
            console.log("  Failed to create shielded position:", reason);
        } catch (bytes memory) {
            console.log("  Failed to create shielded position (unknown error)");
        }

        vm.stopBroadcast();
    }

    function _createProtectorPosition(AccountInfo memory account, SplitRiskPool pool, address tokenAddr, uint256 amount)
        internal
    {
        IERC20 token = IERC20(tokenAddr);

        // Use account's private key for this transaction
        vm.startBroadcast(account.privateKey);

        // Approve token
        token.approve(address(pool), amount);

        // Deposit backing asset
        try pool.depositBackingAsset(tokenAddr, amount, 0) returns (uint256 tokenId) {
            console.log("  Created protector position: Token ID", tokenId, "Amount:", amount / 1e18);
        } catch Error(string memory reason) {
            console.log("  Failed to create protector position:", reason);
        } catch (bytes memory) {
            console.log("  Failed to create protector position (unknown error)");
        }

        vm.stopBroadcast();
    }

    function _getFactoryAddress() internal view returns (address) {
        return _resolveFactoryAddress();
    }
}
