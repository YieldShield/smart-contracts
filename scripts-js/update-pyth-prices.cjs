#!/usr/bin/env node

/**
 * Post-deployment script to update Pyth price feeds
 * Fetches price update data using Pyth EVM JS SDK and updates prices on-chain
 *
 * Usage:
 *   node scripts-js/update-pyth-prices.cjs [--oracle <oracle_address>] [--keystore <keystore_name>] [--rpcUrl <RPC_URL>]
 */

const { ethers } = require("ethers");
const { readdirSync, existsSync, readFileSync } = require("fs");
const { join } = require("path");
const readline = require("readline");
const {
    getDeploymentFilePath,
    resolveContractAddress,
    resolvePythTokenConfigs,
} = require("./pyth-token-registry.cjs");

// Load environment variables from .env file
// __dirname is automatically available in CommonJS
require("dotenv").config({ path: join(__dirname, "..", ".env") });

/**
 * Get Oracle address from the deployment file for the active chain
 */
function getOracleAddress({ rootDir, chainId }) {
    const deploymentFile = getDeploymentFilePath(rootDir, chainId);
    const oracleAddress = resolveContractAddress({
        rootDir,
        chainId,
        contractName: "PythOracle",
    });

    if (oracleAddress) {
        return oracleAddress;
    }

    throw new Error(
        `Could not find a deployed PythOracle in ${deploymentFile}. Pass --oracle <address> or redeploy first.`,
    );
}

function resolveRpcUrl(cliRpcUrl) {
    if (cliRpcUrl) {
        return cliRpcUrl;
    }

    if (process.env.RPC_URL) {
        return process.env.RPC_URL;
    }

    if (process.env.ARBITRUM_SEPOLIA_RPC_URL) {
        return process.env.ARBITRUM_SEPOLIA_RPC_URL;
    }

    if (process.env.ALCHEMY_API_KEY) {
        return `https://arb-sepolia.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`;
    }

    return null;
}

// Pyth Hermes endpoint for Arbitrum Sepolia (testnet)
const PYTH_HERMES_URL = "https://hermes.pyth.network/";

/**
 * List available keystores
 */
function listKeystores() {
    const keystorePath = getKeystoreDirectory();

    if (!existsSync(keystorePath)) {
        return [];
    }

    return readdirSync(keystorePath).filter(
        (keystore) => keystore !== "scaffold-eth-default",
    );
}

function getKeystoreDirectory() {
    if (!process.env.HOME) {
        throw new Error("HOME environment variable is not set");
    }

    return join(process.env.HOME, ".foundry", "keystores");
}

function getKeystorePath(keystoreName) {
    return join(getKeystoreDirectory(), keystoreName);
}

/**
 * Select a keystore interactively
 */
function selectKeystore() {
    return new Promise((resolve, reject) => {
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout,
        });

        const keystores = listKeystores();

        if (keystores.length === 0) {
            console.error("\n❌ No keystores found in ~/.foundry/keystores");
            console.error(
                "Please create a keystore by running: yarn account:generate",
            );
            rl.close();
            reject(new Error("No keystores found"));
            return;
        }

        console.log("\n🔑 Available keystores:");
        keystores.forEach((keystore, index) => {
            console.log(`${index + 1}. ${keystore}`);
        });

        rl.question("\nSelect a keystore (enter the number): ", (answer) => {
            rl.close();
            const selection = parseInt(answer);

            if (
                isNaN(selection) ||
                selection < 1 ||
                selection > keystores.length
            ) {
                reject(new Error("Invalid selection"));
                return;
            }

            resolve(keystores[selection - 1]);
        });
    });
}

/**
 * Prompt for a keystore password without echoing it back to the terminal
 */
function promptForSecret(prompt) {
    return new Promise((resolve, reject) => {
        if (!process.stdin.isTTY || !process.stdout.isTTY) {
            reject(
                new Error(
                    "Interactive terminal required to unlock a keystore",
                ),
            );
            return;
        }

        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout,
            terminal: true,
        });

        rl.stdoutMuted = false;
        rl._writeToOutput = function writeToOutput(stringToWrite) {
            if (rl.stdoutMuted) {
                rl.output.write("*");
                return;
            }

            rl.output.write(stringToWrite);
        };

        process.stdout.write(prompt);
        rl.stdoutMuted = true;
        rl.question("", (answer) => {
            rl.close();
            process.stdout.write("\n");
            resolve(answer);
        });
    });
}

/**
 * Decrypt a Foundry keystore without printing the raw private key
 */
async function unlockKeystore(keystoreName) {
    const keystorePath = getKeystorePath(keystoreName);
    if (!existsSync(keystorePath)) {
        throw new Error(`Keystore not found: ${keystoreName}`);
    }

    const encryptedJson = readFileSync(keystorePath, "utf8");
    const password = await promptForSecret(
        `Enter password for keystore '${keystoreName}': `,
    );

    try {
        return await ethers.Wallet.fromEncryptedJson(encryptedJson, password);
    } catch (error) {
        throw new Error(`Failed to decrypt keystore: ${error.message}`);
    }
}

/**
 * Fetch price update data using Pyth Hermes Client
 * Fetches separate updates for each feed ID to ensure correct format for updatePriceFeeds()
 * The contract expects an array where each element is a separate update for each feed
 */
async function fetchPriceUpdateData(priceIds, hermesUrl = PYTH_HERMES_URL) {
    console.log(`Connecting to Pyth Hermes: ${hermesUrl}`);
    console.log(`Fetching price updates for ${priceIds.length} feed(s)...`);

    try {
        // Create Hermes client connection with binary option enabled
        const { HermesClient } = await import("@pythnetwork/hermes-client");
        const client = new HermesClient(hermesUrl, {
            priceFeedRequestConfig: {
                binary: true,
            },
        });

        // Ensure price feed IDs are in the correct format (remove 0x prefix for API)
        const priceFeedIds = priceIds.map((id) => {
            // Remove 0x prefix if present (Hermes API expects IDs without 0x)
            const hexId = id.startsWith("0x") ? id.slice(2) : id;
            // Ensure it's exactly 64 hex characters (32 bytes)
            if (hexId.length !== 64) {
                throw new Error(
                    `Invalid price feed ID length: ${id} (expected 64 hex chars, got ${hexId.length})`,
                );
            }
            return hexId;
        });

        // Fetch updates separately for each feed ID
        // This ensures we get individual updates that the contract expects in the array
        const updatePromises = priceFeedIds.map(async (feedId, index) => {
            try {
                const response = await client.getLatestPriceUpdates([feedId]);

                if (
                    !response ||
                    !response.binary ||
                    !response.binary.data ||
                    !Array.isArray(response.binary.data)
                ) {
                    throw new Error(
                        `Invalid response format for feed ${index + 1}`,
                    );
                }

                if (response.binary.data.length === 0) {
                    throw new Error(
                        `No update data returned for feed ${index + 1}`,
                    );
                }

                // Get the first (and should be only) update for this feed
                const updateHex = response.binary.data[0];
                return updateHex.startsWith("0x")
                    ? updateHex
                    : "0x" + updateHex;
            } catch (error) {
                throw new Error(
                    `Failed to fetch update for feed ${index + 1} (${
                        priceIds[index]
                    }): ${error.message}`,
                );
            }
        });

        // Wait for all updates to be fetched
        const vaaBytes = await Promise.all(updatePromises);

        console.log(
            `Received ${vaaBytes.length} separate price update(s) from Pyth Hermes`,
        );

        // Validate that we have the expected number of updates
        if (vaaBytes.length !== priceIds.length) {
            throw new Error(
                `Mismatch: expected ${priceIds.length} updates, got ${vaaBytes.length}`,
            );
        }

        return vaaBytes;
    } catch (error) {
        console.error("Error fetching price update data from Pyth Hermes:");
        console.error(error.message);
        if (error.stack) {
            console.error(error.stack);
        }
        throw new Error(`Failed to fetch price update data: ${error.message}`);
    }
}

/**
 * Validate price update data format before sending to contract
 */
function validatePriceUpdateData(priceUpdateData) {
    if (!Array.isArray(priceUpdateData) || priceUpdateData.length === 0) {
        throw new Error("Price update data must be a non-empty array");
    }

    priceUpdateData.forEach((update, index) => {
        if (typeof update !== "string" || !update.startsWith("0x")) {
            throw new Error(`Update ${index + 1} is not a valid hex string`);
        }

        // Check minimum length (Pyth updates are typically at least 100 bytes)
        const byteLength = (update.length - 2) / 2;
        if (byteLength < 50) {
            throw new Error(
                `Update ${
                    index + 1
                } is too short (${byteLength} bytes, expected at least 50)`,
            );
        }

        // Check if it starts with PNAU (Pyth update format)
        const firstBytes = update.substring(2, 10);
        try {
            const ascii = Buffer.from(firstBytes, "hex").toString("ascii");
            if (ascii !== "PNAU") {
                console.warn(
                    `Update ${
                        index + 1
                    } does not start with PNAU (got: "${ascii}")`,
                );
            }
        } catch (e) {
            // Not critical, just a warning
        }
    });

    console.log(`✓ Validated ${priceUpdateData.length} price update(s)`);
}

/**
 * Update price feeds on-chain
 */
async function updatePriceFeeds(oracleContract, priceUpdateData, signer) {
    try {
        // Validate data format before proceeding
        console.log("\nValidating price update data format...");
        validatePriceUpdateData(priceUpdateData);

        // Get the required fee
        console.log("\nCalculating update fee...");
        const fee = await oracleContract.getUpdateFee(priceUpdateData);
        console.log(`Update fee: ${ethers.formatEther(fee)} ETH`);
        console.log(`Update fee (wei): ${fee.toString()}`);

        // Try to estimate gas, but if it fails, use a manual gas limit
        let gasLimit;
        try {
            console.log("\nEstimating gas...");
            const gasEstimate =
                await oracleContract.updatePriceFeeds.estimateGas(
                    priceUpdateData,
                    { value: fee },
                );
            console.log(`Estimated gas: ${gasEstimate.toString()}`);
            gasLimit = (gasEstimate * 120n) / 100n; // Add 20% buffer
            console.log(`Gas limit (with 20% buffer): ${gasLimit.toString()}`);
        } catch (estimateError) {
            console.warn("\n⚠ Gas estimation failed, using manual gas limit");
            console.warn("Error:", estimateError.message);
            if (estimateError.data) console.warn("Error data:", estimateError.data);
            // Use a large gas limit for price updates (typically 500k-1M)
            gasLimit = 1_000_000n;
            console.log(`Using manual gas limit: ${gasLimit.toString()}`);
        }

        // Send transaction
        console.log("\nSending transaction to update price feeds...");
        const tx = await oracleContract
            .connect(signer)
            .updatePriceFeeds(priceUpdateData, {
                value: fee,
                gasLimit: gasLimit,
            });

        console.log(`Transaction sent: ${tx.hash}`);
        console.log("Waiting for confirmation...");
        const receipt = await tx.wait();
        console.log(`✓ Transaction confirmed in block: ${receipt.blockNumber}`);
        console.log(`Gas used: ${receipt.gasUsed.toString()}`);

        return receipt;
    } catch (error) {
        console.error("\n❌ Error updating price feeds:");
        if (error.reason) {
            console.error("Reason:", error.reason);
        }
        if (error.data) console.error("Error data:", error.data);
        if (error.transaction) {
            console.error(
                "Transaction data length:",
                error.transaction.data?.length || "N/A",
            );
        }
        if (error.message) {
            console.error("Error message:", error.message);
        }
        throw error;
    }
}

/**
 * Main function
 */
async function main() {
    const args = process.argv.slice(2);
    const config = {};

    // Parse command line arguments
    for (let i = 0; i < args.length; i += 2) {
        const key = args[i]?.replace("--", "");
        const value = args[i + 1];
        if (key && value) {
            config[key] = value;
        }
    }

    const rpcUrl = resolveRpcUrl(config.rpcUrl);
    const keystoreName = config.keystore || process.env.ETH_KEYSTORE_ACCOUNT;

    if (!rpcUrl) {
        console.error("Error: RPC URL required");
        console.error(
            "Usage: node scripts-js/update-pyth-prices.cjs [--keystore <name>] [--rpcUrl <RPC_URL>]",
        );
        console.error("Options:");
        console.error("  1. Set RPC_URL in .env");
        console.error("  2. Pass --rpcUrl <URL> as argument");
        console.error("  3. Or set ALCHEMY_API_KEY for the Arbitrum Sepolia fallback");
        process.exit(1);
    }

    if (config.privateKey || process.env.PRIVATE_KEY) {
        console.error(
            "\n❌ Raw private key input is disabled for this script. Use a Foundry keystore instead.",
        );
        process.exit(1);
    }

    let selectedKeystore = keystoreName;
    if (!selectedKeystore) {
        try {
            selectedKeystore = await selectKeystore();
        } catch (error) {
            console.error("\n❌ Error selecting keystore:", error.message);
            process.exit(1);
        }
    }

    console.log(`\n🔓 Unlocking keystore: ${selectedKeystore}`);

    let signer;
    try {
        signer = await unlockKeystore(selectedKeystore);
        console.log("✅ Keystore unlocked successfully");
    } catch (error) {
        console.error("\n❌ Failed to unlock keystore:", error.message);
        process.exit(1);
    }

    // Setup provider and signer
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const network = await provider.getNetwork();
    const chainId = network.chainId.toString();
    const rootDir = join(__dirname, "..");
    const oracleAddress =
        config.oracle || getOracleAddress({ rootDir, chainId });
    signer = signer.connect(provider);

    // PythOracle ABI (minimal for updatePriceFeeds)
    const oracleAbi = [
        "function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable",
        "function getUpdateFee(bytes[] calldata priceUpdateData) external view returns (uint256 fee)",
        "function isTokenSupported(address) external view returns (bool)",
        "function tokenToPriceFeedId(address) external view returns (bytes32)",
        "function tokenToQuotePriceFeedId(address) external view returns (bytes32)",
    ];

    const oracleContract = new ethers.Contract(
        oracleAddress,
        oracleAbi,
        provider,
    );

    console.log("=== Updating Pyth Price Feeds ===");
    console.log("Oracle:", oracleAddress);
    console.log("Network:", network.name);
    console.log("Chain ID:", chainId);
    console.log("Signer:", await signer.getAddress());

    // Check token configuration
    console.log("Checking token configuration...");
    const tokensToCheck = resolvePythTokenConfigs({
        rootDir,
        chainId,
    });

    const missingConfigs = [];
    for (const token of tokensToCheck) {
        if (!token.address) {
            console.warn(
                `  ⚠ ${token.name}: no token address resolved; skipping config check`,
            );
            continue;
        }

        try {
            const [isSupported, feedId] = await Promise.all([
                oracleContract.isTokenSupported(token.address),
                oracleContract.tokenToPriceFeedId(token.address),
            ]);
            let quoteFeedId = ethers.ZeroHash;
            try {
                quoteFeedId = await oracleContract.tokenToQuotePriceFeedId(
                    token.address,
                );
            } catch (_) {
                quoteFeedId = ethers.ZeroHash;
            }

            const zeroHash =
                "0x0000000000000000000000000000000000000000000000000000000000000000";
            const expectedFeedId = token.feedId.toLowerCase();
            const actualFeedId = feedId.toLowerCase();
            const expectedQuoteFeedId = (
                token.quoteFeedId || zeroHash
            ).toLowerCase();
            const actualQuoteFeedId = (quoteFeedId || zeroHash).toLowerCase();
            if (
                !isSupported ||
                actualFeedId === zeroHash ||
                actualFeedId !== expectedFeedId ||
                actualQuoteFeedId !== expectedQuoteFeedId
            ) {
                console.warn(
                    `  ⚠ ${token.name} (${token.address}): NOT CONFIGURED`,
                );
                missingConfigs.push(token);
            } else {
                console.log(`  ✓ ${token.name} (${token.address}): configured`);
            }
        } catch (e) {
            console.warn(
                `  ⚠ ${token.name}: Could not check configuration (${e.message})`,
            );
        }
    }

    if (missingConfigs.length > 0) {
        console.warn(
            "\n⚠ WARNING: Some tokens are not configured in the Oracle!",
        );
        console.warn(
            "  This will cause TokenNotSupported() errors when using the Oracle.",
        );
        console.warn("\n  SOLUTION: Run the configuration script:");
        console.warn("    node scripts-js/configure-pyth-tokens.cjs");
        console.warn("\n  Missing configurations:");
        missingConfigs.forEach((token) => {
            const quoteSuffix = token.quoteFeedId
                ? `, Quote Feed ID: ${token.quoteFeedId}`
                : "";
            console.warn(
                `    - ${token.name} (${token.address}) → Feed ID: ${token.feedId}${quoteSuffix}`,
            );
        });
        console.warn(
            "\n  The deployment script should have configured these, but they may have been",
        );
        console.warn(
            "  lost if the Oracle was redeployed separately from the tokens.\n",
        );
    } else {
        console.log("\n✓ All tokens are properly configured\n");
    }

    const priceIds = [
        ...new Set(
            tokensToCheck.flatMap((token) =>
                token.quoteFeedId
                    ? [token.feedId, token.quoteFeedId]
                    : [token.feedId],
            ),
        ),
    ];
    console.log("\nFetching price update data from Pyth Hermes...");
    console.log("Feed IDs:", priceIds);

    try {
        const priceUpdateData = await fetchPriceUpdateData(
            priceIds,
            PYTH_HERMES_URL,
        );
        console.log(`Received ${priceUpdateData.length} price update(s)`);

        // Update prices on-chain
        console.log("\nUpdating prices on-chain...");
        await updatePriceFeeds(oracleContract, priceUpdateData, signer);

        console.log("\n✅ Price feeds updated successfully!");
        console.log("\nRefreshed Pyth feeds for:");
        tokensToCheck.forEach((token) => {
            console.log(`  - ${token.name}: ${token.feedId}`);
            if (token.quoteFeedId) {
                console.log(`    quote: ${token.quoteFeedId}`);
            }
        });
    } catch (error) {
        console.error("\n❌ Failed to update price feeds:", error.message);
        process.exit(1);
    }
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error);
        process.exit(1);
    });
}

module.exports = { fetchPriceUpdateData, updatePriceFeeds };
