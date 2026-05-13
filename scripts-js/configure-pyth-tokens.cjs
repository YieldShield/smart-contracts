#!/usr/bin/env node

/**
 * Script to configure token-to-price-feed mappings in PythOracle
 * Checks which tokens are configured and configures missing ones
 * Uses Foundry keystores from ~/.foundry/keystores/
 *
 * Usage:
 *   node scripts-js/configure-pyth-tokens.cjs [--oracle <oracle_address>] [--pool <pool_address>] [--keystore <keystore_name>] [--rpcUrl <RPC_URL>]
 *
 * Options:
 *   --oracle <address>: Use a specific PythOracle address (default: deployments/<current-chain-id>.json)
 *   --pool <address>  : Check tokens from a specific pool and configure them
 *   --keystore <name> : Use a specific keystore file (default: interactive selection)
 */

const { ethers } = require("ethers");
const { existsSync, readdirSync } = require("fs");
const { join } = require("path");
const { spawnSync } = require("child_process");
const readline = require("readline");
const {
    getDeploymentFilePath,
    resolveContractAddress,
    resolvePythTokenConfigs,
} = require("./pyth-token-registry.cjs");

require("dotenv").config({ path: join(__dirname, "..", ".env") });

const DEFAULT_KEYSTORE_ACCOUNT = "scaffold-eth-default";
const KEYSTORE_NAME_PATTERN = /^[A-Za-z0-9_.-]+$/u;

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

    return null;
}

function isValidKeystoreName(keystoreName) {
    return (
        typeof keystoreName === "string" &&
        keystoreName.length > 0 &&
        KEYSTORE_NAME_PATTERN.test(keystoreName)
    );
}

function runCast(args, stdio = ["pipe", "pipe", "pipe"]) {
    const result = spawnSync("cast", args, {
        encoding: "utf-8",
        stdio,
    });

    if (result.error) {
        throw result.error;
    }

    if (result.status !== 0) {
        throw new Error(
            (result.stderr || result.stdout || "Unknown cast error").trim(),
        );
    }

    return result.stdout.trim();
}

/**
 * Get tokens from a pool address
 */
async function getPoolTokens(poolAddress, provider) {
    const poolAbi = [
        "function SHIELDED_TOKEN() external view returns (address)",
        "function BACKING_TOKEN() external view returns (address)",
    ];

    try {
        const pool = new ethers.Contract(poolAddress, poolAbi, provider);
        const [shieldedToken, backingToken] = await Promise.all([
            pool.SHIELDED_TOKEN(),
            pool.BACKING_TOKEN(),
        ]);
        return [shieldedToken, backingToken];
    } catch (error) {
        console.error(`Error reading pool tokens: ${error.message}`);
        return null;
    }
}

/**
 * List available Foundry keystores from ~/.foundry/keystores/
 */
function listFoundryKeystores() {
    const keystorePath = join(process.env.HOME, ".foundry", "keystores");

    if (!existsSync(keystorePath)) {
        throw new Error(
            `Keystore directory not found: ${keystorePath}\nRun 'cast wallet new' to create a keystore.`,
        );
    }

    const keystores = readdirSync(keystorePath).filter(
        (keystore) =>
            keystore !== DEFAULT_KEYSTORE_ACCOUNT &&
            isValidKeystoreName(keystore),
    );

    if (keystores.length === 0) {
        throw new Error(
            "No keystores found in ~/.foundry/keystores\nRun 'cast wallet new' to create a keystore.",
        );
    }

    return keystores;
}

/**
 * Get keystore selection from user
 */
async function selectKeystore(keystoreName) {
    const keystores = listFoundryKeystores();

    if (keystoreName) {
        if (!isValidKeystoreName(keystoreName)) {
            throw new Error(
                "Invalid keystore name. Use letters, numbers, dots, underscores, or hyphens only.",
            );
        }
        if (keystores.includes(keystoreName)) {
            return keystoreName;
        }
        throw new Error(
            `Keystore not found: ${keystoreName}\nAvailable: ${keystores.join(
                ", ",
            )}`,
        );
    }

    // Interactive selection
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
    });

    console.log("\n💼 Available keystores:");
    keystores.forEach((k, i) => console.log(`  ${i + 1}. ${k}`));

    return new Promise((resolve, reject) => {
        rl.question("\nSelect a keystore (enter the number): ", (answer) => {
            rl.close();
            const index = parseInt(answer) - 1;
            if (index >= 0 && index < keystores.length) {
                resolve(keystores[index]);
            } else {
                reject(new Error("Invalid selection"));
            }
        });
    });
}

/**
 * Get address for a Foundry keystore using cast
 */
function getKeystoreAddress(keystoreName) {
    if (!isValidKeystoreName(keystoreName)) {
        throw new Error(
            "Invalid keystore name. Use letters, numbers, dots, underscores, or hyphens only.",
        );
    }

    try {
        return runCast(["wallet", "address", "--account", keystoreName]);
    } catch (error) {
        throw new Error(
            `Failed to get address for keystore ${keystoreName}: ${error.message}`,
        );
    }
}

/**
 * Check token configuration
 */
async function checkTokenConfig(oracle, tokenAddress) {
    try {
        const [isSupported, feedId, quoteFeedId] = await Promise.all([
            oracle.isTokenSupported(tokenAddress),
            oracle.tokenToPriceFeedId(tokenAddress),
            oracle.tokenToQuotePriceFeedId(tokenAddress),
        ]);
        return { isSupported, feedId, quoteFeedId };
    } catch (error) {
        return {
            isSupported: false,
            feedId: null,
            quoteFeedId: ethers.ZeroHash,
            error: error.message,
        };
    }
}

/**
 * Configure a token using cast send
 */
async function configureToken(
    oracleAddress,
    keystoreName,
    tokenAddress,
    feedId,
    quoteFeedId,
    tokenName,
    rpcUrl,
) {
    try {
        console.log(`  Configuring ${tokenName} (${tokenAddress})...`);

        const hasQuoteFeed =
            quoteFeedId &&
            quoteFeedId.toLowerCase() !== ethers.ZeroHash.toLowerCase();
        const signature = hasQuoteFeed
            ? "setTokenCompositePriceFeed(address,bytes32,bytes32)"
            : "setTokenPriceFeed(address,bytes32)";
        console.log(`    Sending transaction...`);
        const castArgs = [
            "send",
            oracleAddress,
            signature,
            tokenAddress,
            feedId,
        ];
        if (hasQuoteFeed) {
            castArgs.push(quoteFeedId);
        }
        castArgs.push("--account", keystoreName, "--rpc-url", rpcUrl);

        const output = runCast(castArgs, ["inherit", "pipe", "pipe"]);

        // Extract transaction hash from output
        const txHashMatch = output.match(/transactionHash\s+(0x[a-fA-F0-9]+)/);
        if (txHashMatch) {
            console.log(`    Transaction: ${txHashMatch[1]}`);
        }

        console.log(`    ✓ ${tokenName} configured successfully`);
        return true;
    } catch (error) {
        console.error(
            `    ✗ Failed to configure ${tokenName}: ${error.message}`,
        );
        return false;
    }
}

async function main() {
    // Parse command line arguments
    const args = process.argv.slice(2);
    let oracleAddress = null;
    let poolAddress = null;
    let keystoreName = null;

    for (let i = 0; i < args.length; i++) {
        if (args[i] === "--oracle" && i + 1 < args.length) {
            oracleAddress = args[i + 1];
        } else if (args[i] === "--pool" && i + 1 < args.length) {
            poolAddress = args[i + 1];
        } else if (args[i] === "--keystore" && i + 1 < args.length) {
            keystoreName = args[i + 1];
        }
    }

    // Get RPC URL
    const rpcUrl = resolveRpcUrl(
        args.includes("--rpcUrl") ? args[args.indexOf("--rpcUrl") + 1] : null,
    );
    if (!rpcUrl) {
        console.error(
            "Error: RPC URL required. Set RPC_URL or pass --rpcUrl <RPC_URL>.",
        );
        process.exit(1);
    }

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const network = await provider.getNetwork();
    const chainId = network.chainId.toString();
    const rootDir = join(__dirname, "..");
    oracleAddress = oracleAddress || getOracleAddress({ rootDir, chainId });

    // PythOracle ABI
    const oracleAbi = [
        "function setTokenPriceFeed(address token, bytes32 feedId) external",
        "function setTokenCompositePriceFeed(address token, bytes32 baseFeedId, bytes32 quoteUsdFeedId) external",
        "function isTokenSupported(address) external view returns (bool)",
        "function tokenToPriceFeedId(address) external view returns (bytes32)",
        "function tokenToQuotePriceFeedId(address) external view returns (bytes32)",
        "function owner() external view returns (address)",
    ];

    const oracle = new ethers.Contract(oracleAddress, oracleAbi, provider);

    console.log("=== PythOracle Token Configuration ===");
    console.log("Oracle:", oracleAddress);
    console.log("Network:", network.name);
    console.log("Chain ID:", chainId);

    const pythTokenConfigs = resolvePythTokenConfigs({
        rootDir,
        chainId,
    });

    // Check if we need to configure tokens from a pool
    let tokensToCheck = pythTokenConfigs
        .map((token) => token.address)
        .filter(Boolean);

    if (poolAddress) {
        console.log(`\nReading tokens from pool: ${poolAddress}`);
        const poolTokens = await getPoolTokens(poolAddress, provider);
        if (poolTokens) {
            tokensToCheck = poolTokens.filter(
                (t) => t && t !== ethers.ZeroAddress,
            );
            console.log(`  Found tokens: ${tokensToCheck.join(", ")}`);
        }
    }

    // Check current configuration
    console.log("\n=== Checking Token Configuration ===");
    const tokensToConfigure = [];

    // Normalize token config keys to lowercase for lookup
    const normalizedTokenConfig = {};
    for (const tokenConfig of pythTokenConfigs) {
        if (!tokenConfig.address) continue;
        normalizedTokenConfig[tokenConfig.address.toLowerCase()] = tokenConfig;
    }

    for (const tokenAddress of tokensToCheck) {
        const tokenInfo = normalizedTokenConfig[tokenAddress.toLowerCase()];
        if (!tokenInfo) {
            console.warn(
                `  ⚠ ${tokenAddress}: No configuration found (unknown token)`,
            );
            continue;
        }

        const { isSupported, feedId, quoteFeedId } = await checkTokenConfig(
            oracle,
            tokenAddress,
        );
        const expectedQuoteFeedId = (
            tokenInfo.quoteFeedId || ethers.ZeroHash
        ).toLowerCase();
        const actualQuoteFeedId = (
            quoteFeedId || ethers.ZeroHash
        ).toLowerCase();

        if (
            !isSupported ||
            feedId.toLowerCase() !== tokenInfo.feedId.toLowerCase() ||
            actualQuoteFeedId !== expectedQuoteFeedId ||
            feedId === ethers.ZeroHash
        ) {
            console.warn(
                `  ⚠ ${tokenInfo.name} (${tokenAddress}): NOT CONFIGURED`,
            );
            tokensToConfigure.push({ address: tokenAddress, ...tokenInfo });
        } else {
            console.log(`  ✓ ${tokenInfo.name} (${tokenAddress}): configured`);
            console.log(`    Feed ID: ${feedId}`);
            if (actualQuoteFeedId !== ethers.ZeroHash.toLowerCase()) {
                console.log(`    Quote Feed ID: ${quoteFeedId}`);
            }
        }
    }

    if (tokensToConfigure.length === 0) {
        console.log("\n✅ All tokens are properly configured!");
        return;
    }

    // Configure missing tokens
    console.log(
        `\n=== Configuring ${tokensToConfigure.length} Missing Token(s) ===`,
    );

    // Check if we're the owner
    let owner;
    try {
        owner = await oracle.owner();
        console.log(`Oracle owner: ${owner}`);
    } catch (error) {
        console.error("Could not read Oracle owner:", error.message);
        process.exit(1);
    }

    const factoryAddress = resolveContractAddress({
        rootDir,
        chainId,
        contractName: "SplitRiskPoolFactory",
    });
    if (factoryAddress && owner.toLowerCase() === factoryAddress.toLowerCase()) {
        console.error(
            "\n❌ PythOracle is owned by SplitRiskPoolFactory governance.",
        );
        console.error(
            "Submit a governance proposal that calls factory.setPythTokenPriceFeed(...) or factory.setPythTokenCompositePriceFeed(...).",
        );
        process.exit(1);
    }

    // Select keystore
    const selectedKeystore = await selectKeystore(keystoreName);
    console.log(`\n🔑 Using keystore: ${selectedKeystore}`);

    // Get signer address
    const signerAddress = getKeystoreAddress(selectedKeystore);
    console.log(`Signer: ${signerAddress}`);

    if (signerAddress.toLowerCase() !== owner.toLowerCase()) {
        console.error(`\n❌ Error: Signer is not the Oracle owner!`);
        console.error(`  Owner: ${owner}`);
        console.error(`  Signer: ${signerAddress}`);
        process.exit(1);
    }

    // Configure tokens
    let successCount = 0;
    for (const token of tokensToConfigure) {
        const success = await configureToken(
            oracleAddress,
            selectedKeystore,
            token.address,
            token.feedId,
            token.quoteFeedId,
            token.name,
            rpcUrl,
        );
        if (success) successCount++;
    }

    console.log(`\n=== Summary ===`);
    console.log(
        `Configured: ${successCount}/${tokensToConfigure.length} tokens`,
    );

    if (successCount === tokensToConfigure.length) {
        console.log("✅ All tokens configured successfully!");
    } else {
        console.warn(
            "⚠ Some tokens failed to configure. Check the errors above.",
        );
        process.exit(1);
    }
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error);
        process.exit(1);
    });
}

module.exports = { getOracleAddress, checkTokenConfig, configureToken };
