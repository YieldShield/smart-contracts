//SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { console } from "forge-std/console.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { MockGauntletUSDCPrime } from "../contracts/mocks/MockGauntletUSDCPrime.sol";
import { YSToken } from "../contracts/YSToken.sol";

/**
 * @notice Token distribution script for local development setup
 * @dev Distributes tokens to all Anvil accounts (0-9) with profile-based amounts
 *      Account #0 gets whale amounts (10x), others get standard amounts
 * Usage: forge script script/mint-tokens-to-accounts.s.sol:MintTokensToAccounts --rpc-url localhost --broadcast --legacy
 */
contract MintTokensToAccounts is ScaffoldETHDeploy {
    error LocalChainRequired(uint256 chainId);

    // Anvil default accounts (0-9)
    address[10] public accounts = [
        0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Account #0 - Governance Participant
        0x70997970C51812dc3A010C7d01b50e0d17dc79C8, // Account #1 - Small Shielded
        0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC, // Account #2 - Small Protector
        0x90F79bf6EB2c4f870365E785982E1f101E93b906, // Account #3 - Large Shielded
        0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65, // Account #4 - Large Protector
        0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc, // Account #5 - Mixed User
        0x976EA74026E726554dB657fA54763abd0C3a0aa9, // Account #6 - Whale Shielded
        0x14dC79964da2C08b23698B3D3cc7Ca32193d9955, // Account #7 - Whale Protector
        0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f, // Account #8 - Diversified (fixed address)
        0xa0Ee7A142d267C1f36714E4a8F75612F20a79720 // Account #9 - Deployer
    ];

    // Token amounts (standard, Account #0 gets 10x)
    uint256 constant STANDARD_AMOUNT = 10000e18; // 10,000 tokens (18 decimals)
    uint256 constant USDC_AMOUNT = 10000e6; // 10,000 USDC (6 decimals)
    uint256 constant WHALE_MULTIPLIER = 10; // Account #0 gets 10x

    // YS Token amounts
    uint256 constant YS_STANDARD_AMOUNT = 10000e18; // 10k YS tokens for non-governance participants

    function run() external ScaffoldEthDeployerRunner {
        if (block.chainid != 31337 && block.chainid != 1337) {
            revert LocalChainRequired(block.chainid);
        }

        console.log("\n=== Distributing Tokens to Accounts ===");

        // Get token addresses
        address ysTokenAddr = _resolveDeploymentAddress("YSToken");
        address usdcAddr = _resolveDeploymentAddress("MockUSDC");
        address gtusdcAddr = _resolveDeploymentAddress("MockGauntletUSDCPrime");
        address[] memory mockERC20Addresses = _resolveDeploymentAddresses("MockERC20");

        require(ysTokenAddr != address(0), "YSToken not found");
        require(usdcAddr != address(0), "MockUSDC not found");
        require(gtusdcAddr != address(0), "MockGauntletUSDCPrime not found");
        require(mockERC20Addresses.length >= 11, "Not enough MockERC20 tokens found");

        console.log("Found", mockERC20Addresses.length, "MockERC20 tokens");
        console.log("YS Token:", ysTokenAddr);
        console.log("USDC:", usdcAddr);
        console.log("gtUSDC:", gtusdcAddr);

        // Get YS Token
        YSToken ysToken = YSToken(ysTokenAddr);

        // Distribute YS tokens first
        console.log("\n=== Distributing YS Tokens ===");
        _distributeYSTokens(ysToken);

        // Distribute MockERC20 tokens (18 decimals)
        console.log("\n=== Distributing MockERC20 Tokens ===");
        for (uint256 i = 0; i < mockERC20Addresses.length; i++) {
            MockERC20 token = MockERC20(mockERC20Addresses[i]);
            _mintToAllAccounts(token, STANDARD_AMOUNT, WHALE_MULTIPLIER, 18);
            console.log("Distributed token at:", mockERC20Addresses[i]);
        }

        // Distribute USDC (6 decimals)
        console.log("\n=== Distributing USDC ===");
        MockUSDC usdc = MockUSDC(usdcAddr);
        _mintUSDCToAllAccounts(usdc, USDC_AMOUNT, WHALE_MULTIPLIER);

        // Distribute gtUSDC (ERC4626)
        console.log("\n=== Distributing gtUSDC ===");
        MockGauntletUSDCPrime gtusdc = MockGauntletUSDCPrime(payable(gtusdcAddr));
        _mintGTUSDCToAllAccounts(gtusdc, STANDARD_AMOUNT, WHALE_MULTIPLIER);

        console.log("\n=== Token Distribution Complete ===");
    }

    function _distributeYSTokens(YSToken ysToken) internal {
        uint256 requiredStandardTopUp = _requiredYSTopUpForStandardAccounts(ysToken);
        uint256 deployerBalance = ysToken.balanceOf(deployer);
        require(deployerBalance >= requiredStandardTopUp, "Insufficient YS balance for standard accounts");

        // Account #0 receives the remainder of the deployer's YS after the standard local allocations are reserved.
        uint256 currentGovernanceBalance = ysToken.balanceOf(accounts[0]);
        uint256 governanceTargetAmount = currentGovernanceBalance + (deployerBalance - requiredStandardTopUp);
        if (currentGovernanceBalance < governanceTargetAmount) {
            uint256 amountToTransfer = governanceTargetAmount - currentGovernanceBalance;
            require(ysToken.transfer(accounts[0], amountToTransfer), "YS transfer failed");
            console.log("Account #0: Transferred", amountToTransfer / 1e18, "YS tokens");
        }

        // The remaining local accounts each target 10k YS, while account #0 keeps the leftover governance balance.
        for (uint256 i = 1; i < accounts.length; i++) {
            if (accounts[i] == deployer) {
                continue;
            }

            if (ysToken.balanceOf(accounts[i]) < YS_STANDARD_AMOUNT) {
                uint256 amountToTransfer = YS_STANDARD_AMOUNT - ysToken.balanceOf(accounts[i]);
                if (amountToTransfer > 0) {
                    require(ysToken.balanceOf(deployer) >= amountToTransfer, "Insufficient YS balance");
                    require(ysToken.transfer(accounts[i], amountToTransfer), "YS transfer failed");
                }
            }
        }
        console.log("YS tokens distributed to all accounts");
    }

    function _requiredYSTopUpForStandardAccounts(YSToken ysToken) internal view returns (uint256 requiredAmount) {
        for (uint256 i = 1; i < accounts.length; i++) {
            if (accounts[i] == deployer) {
                continue;
            }

            uint256 currentBalance = ysToken.balanceOf(accounts[i]);
            if (currentBalance < YS_STANDARD_AMOUNT) {
                requiredAmount += YS_STANDARD_AMOUNT - currentBalance;
            }
        }
    }

    function _mintToAllAccounts(MockERC20 token, uint256 standardAmount, uint256 whaleMultiplier, uint8) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            uint256 amount = (i == 0) ? standardAmount * whaleMultiplier : standardAmount;
            if (token.balanceOf(accounts[i]) < amount) {
                uint256 toMint = amount - token.balanceOf(accounts[i]);
                if (toMint > 0) {
                    token.mint(accounts[i], toMint);
                }
            }
        }
    }

    function _mintUSDCToAllAccounts(MockUSDC token, uint256 standardAmount, uint256 whaleMultiplier) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            uint256 amount = (i == 0) ? standardAmount * whaleMultiplier : standardAmount;
            if (token.balanceOf(accounts[i]) < amount) {
                uint256 toMint = amount - token.balanceOf(accounts[i]);
                if (toMint > 0) {
                    token.mint(accounts[i], toMint);
                }
            }
        }
    }

    function _mintGTUSDCToAllAccounts(MockGauntletUSDCPrime vault, uint256 standardAmount, uint256 whaleMultiplier)
        internal
    {
        // gtUSDC is an ERC4626 vault with 18-decimal shares backed by 6-decimal USDC
        // We want to mint shares directly (standardAmount is already in 18 decimals)
        // Do NOT use convertToShares() as it expects 6-decimal USDC assets, causing overflow
        for (uint256 i = 0; i < accounts.length; i++) {
            uint256 targetShares = (i == 0) ? standardAmount * whaleMultiplier : standardAmount;
            uint256 currentShares = vault.balanceOf(accounts[i]);

            if (currentShares < targetShares) {
                uint256 sharesToMint = targetShares - currentShares;
                if (sharesToMint > 0) {
                    vault.mintShares(accounts[i], sharesToMint);
                }
            }
        }
    }

    // Helper function to check if tokens are already distributed
    function checkTokensDistributed() external view returns (bool) {
        address ysTokenAddr = _resolveDeploymentAddress("YSToken");

        if (ysTokenAddr == address(0)) {
            return false;
        }

        YSToken ysToken = YSToken(ysTokenAddr);
        if (ysToken.balanceOf(accounts[0]) < YS_STANDARD_AMOUNT) {
            return false;
        }

        for (uint256 i = 1; i < accounts.length; i++) {
            if (ysToken.balanceOf(accounts[i]) < YS_STANDARD_AMOUNT) {
                return false;
            }
        }

        return true;
    }
}
