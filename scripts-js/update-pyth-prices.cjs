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

const DEFAULT_KEYSTORE_ACCOUNT = "scaffold-eth-default";
const KEYSTORE_NAME_PATTERN = /^[A-Za-z0-9_.-]+$/u;
const LOCAL_CHAIN_IDS = new Set(["31337", "1337"]);
const DEFAULT_EVENT_SCAN_CHUNK_SIZE = 50_000;

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

function getFactoryAddress({ rootDir, chainId, cliFactory }) {
    if (cliFactory) {
        return cliFactory;
    }

    return resolveContractAddress({
        rootDir,
        chainId,
        contractName: "SplitRiskPoolFactory",
    });
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

function parseCliArgs(args) {
    const config = {};

    for (let i = 0; i < args.length;) {
        const rawKey = args[i];
        if (!rawKey?.startsWith("--")) {
            i++;
            continue;
        }
        const rawKeyName = rawKey.replace("--", "");
        const key = rawKeyName === "allow-partial" ? "allowPartial" : rawKeyName;
        const value = args[i + 1];
        if (value && !value.startsWith("--")) {
            config[key] = value;
            i += 2;
        } else {
            config[key] = true;
            i++;
        }
    }

    if (config.strict && config.allowPartial) {
        throw new Error("--strict and --allow-partial cannot be used together");
    }

    return config;
}

function shouldRequireAllPriceUpdates({ strict, allowPartial, chainId }) {
    if (strict) return true;
    if (allowPartial) return false;
    return !LOCAL_CHAIN_IDS.has(String(chainId));
}

function normalizeFeedId(feedId) {
    return String(feedId || "").toLowerCase();
}

function classifyConfiguredTokenRefreshes({
    configuredTokens,
    updates,
    failures = [],
}) {
    const updatedFeedIds = new Set(
        updates.map((entry) => normalizeFeedId(entry.feedId)),
    );
    const failedFeedIds = new Set(
        failures.map((entry) => normalizeFeedId(entry.feedId)),
    );

    const refreshedTokens = [];
    const skippedTokens = [];

    for (const token of configuredTokens) {
        const requiredFeedIds = [token.actualFeedId];
        if (token.actualQuoteFeedId) {
            requiredFeedIds.push(token.actualQuoteFeedId);
        }

        const missingFeedIds = requiredFeedIds.filter(
            (feedId) => !updatedFeedIds.has(normalizeFeedId(feedId)),
        );

        if (missingFeedIds.length === 0) {
            refreshedTokens.push(token);
        } else {
            skippedTokens.push({
                token,
                missingFeedIds,
                failedFeedIds: missingFeedIds.filter((feedId) =>
                    failedFeedIds.has(normalizeFeedId(feedId)),
                ),
            });
        }
    }

    return { refreshedTokens, skippedTokens };
}

function isZeroHash(value) {
    return !value || value.toLowerCase() === ethers.ZeroHash.toLowerCase();
}

function isZeroAddress(value) {
    return !value || value.toLowerCase() === ethers.ZeroAddress.toLowerCase();
}

function registryByAddress(registryTokens) {
    const byAddress = new Map();
    for (const token of registryTokens) {
        if (token.address) {
            byAddress.set(token.address.toLowerCase(), token);
        }
    }
    return byAddress;
}

async function queryPythTokenEvents(oracleContract) {
    const filters = [
        oracleContract.filters.TokenPriceFeedSet(),
        oracleContract.filters.TokenCompositePriceFeedSet(),
    ];
    const provider = oracleContract.runner?.provider || oracleContract.provider;
    const latestBlock = provider?.getBlockNumber
        ? await provider.getBlockNumber()
        : null;
    const chunkSize = Number(process.env.PYTH_EVENT_SCAN_CHUNK_SIZE || DEFAULT_EVENT_SCAN_CHUNK_SIZE);
    const events = [];

    for (const filter of filters) {
        if (!latestBlock || latestBlock <= chunkSize) {
            events.push(...(await oracleContract.queryFilter(filter, 0, "latest")));
            continue;
        }

        for (let fromBlock = 0; fromBlock <= latestBlock; fromBlock += chunkSize + 1) {
            const toBlock = Math.min(fromBlock + chunkSize, latestBlock);
            events.push(...(await oracleContract.queryFilter(filter, fromBlock, toBlock)));
        }
    }

    return events;
}

async function collectTokenCandidates({
    factoryContract,
    oracleContract,
    registryTokens,
    requireCompleteDiscovery = false,
}) {
    const candidates = new Map();
    const addCandidate = (address, source) => {
        if (!address || isZeroAddress(address)) return;
        const key = address.toLowerCase();
        const existing = candidates.get(key);
        candidates.set(key, {
            address,
            sources: existing ? [...existing.sources, source] : [source],
        });
    };

    if (factoryContract) {
        try {
            const whitelistedTokens = await factoryContract.getWhitelistedTokens();
            whitelistedTokens.forEach((address) => addCandidate(address, "factory"));
        } catch (error) {
            const message = `Could not read factory whitelist: ${error.message}`;
            if (requireCompleteDiscovery) throw new Error(message);
            console.warn(`  ⚠ ${message}`);
        }
    } else if (requireCompleteDiscovery) {
        throw new Error("Strict Pyth updates require a factory address for whitelist discovery");
    }

    for (const token of registryTokens) {
        addCandidate(token.address, "registry");
    }

    try {
        const pythEvents = await queryPythTokenEvents(oracleContract);
        pythEvents.forEach((event) => addCandidate(event.args?.token, "pyth-event"));
    } catch (error) {
        const message = `Could not scan Pyth token events: ${error.message}`;
        if (requireCompleteDiscovery) throw new Error(message);
        console.warn(`  ⚠ ${message}`);
    }

    return [...candidates.values()];
}

async function discoverConfiguredPythTokens({
    oracleContract,
    factoryContract,
    registryTokens,
    requireCompleteDiscovery = false,
}) {
    const registryLookup = registryByAddress(registryTokens);
    const candidates = await collectTokenCandidates({
        factoryContract,
        oracleContract,
        registryTokens,
        requireCompleteDiscovery,
    });

    const configuredTokens = [];
    const missingConfigs = [];

    for (const candidate of candidates) {
        const registryToken = registryLookup.get(candidate.address.toLowerCase());
        const name = registryToken?.name || candidate.address;

        try {
            const [isSupported, feedId] = await Promise.all([
                oracleContract.isTokenSupported(candidate.address),
                oracleContract.tokenToPriceFeedId(candidate.address),
            ]);
            let quoteFeedId = ethers.ZeroHash;
            try {
                quoteFeedId = await oracleContract.tokenToQuotePriceFeedId(candidate.address);
            } catch (_) {
                quoteFeedId = ethers.ZeroHash;
            }

            if (!isSupported || isZeroHash(feedId)) {
                missingConfigs.push({ ...candidate, name });
                continue;
            }

            if (registryToken && feedId.toLowerCase() !== registryToken.feedId.toLowerCase()) {
                console.warn(
                    `  ⚠ ${name}: using on-chain feed ${feedId}, registry expected ${registryToken.feedId}`,
                );
            }
            if (
                registryToken &&
                !isZeroHash(quoteFeedId) &&
                (registryToken.quoteFeedId || ethers.ZeroHash).toLowerCase() !== quoteFeedId.toLowerCase()
            ) {
                console.warn(
                    `  ⚠ ${name}: using on-chain quote ${quoteFeedId}, registry expected ${
                        registryToken.quoteFeedId || ethers.ZeroHash
                    }`,
                );
            }

            configuredTokens.push({
                ...registryToken,
                name,
                address: candidate.address,
                sources: candidate.sources,
                actualFeedId: feedId,
                actualQuoteFeedId: isZeroHash(quoteFeedId) ? null : quoteFeedId,
            });
        } catch (error) {
            missingConfigs.push({
                ...candidate,
                name,
                reason: error.message,
            });
        }
    }

    return { configuredTokens, missingConfigs };
}

async function verifyPythTokenFreshness({
    oracleContract,
    configuredTokens,
    refreshedTokens,
    requireAllPriceUpdates,
}) {
    const requiredAddresses = new Set(
        (requireAllPriceUpdates ? configuredTokens : refreshedTokens).map((token) =>
            token.address.toLowerCase()
        ),
    );
    const requiredFailures = [];
    const optionalFailures = [];

    for (const token of configuredTokens) {
        try {
            const [isStale, publishTime] = await oracleContract.isPriceStale(token.address);
            const failure = { token, publishTime: Number(publishTime), reason: "stale" };
            if (isStale) {
                if (requiredAddresses.has(token.address.toLowerCase())) {
                    requiredFailures.push(failure);
                } else {
                    optionalFailures.push(failure);
                }
            }
        } catch (error) {
            const failure = { token, reason: error.message };
            if (requiredAddresses.has(token.address.toLowerCase())) {
                requiredFailures.push(failure);
            } else {
                optionalFailures.push(failure);
            }
        }
    }

    if (optionalFailures.length > 0) {
        console.warn("\nConfigured Pyth tokens still stale or unreadable after partial update:");
        optionalFailures.forEach(({ token, reason }) => {
            console.warn(`  - ${token.name}: ${reason}`);
        });
    }

    if (requiredFailures.length > 0) {
        const names = requiredFailures.map(({ token, reason }) => `${token.name} (${reason})`).join(", ");
        throw new Error(`Pyth price freshness verification failed for: ${names}`);
    }

    return { staleTokens: optionalFailures };
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
        (keystore) =>
            keystore !== DEFAULT_KEYSTORE_ACCOUNT &&
            isValidKeystoreName(keystore),
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
                new Error("Interactive terminal required to unlock a keystore"),
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

async function fetchPriceUpdateDataBestEffort(
    priceIds,
    hermesUrl = PYTH_HERMES_URL,
) {
    console.log(`Connecting to Pyth Hermes: ${hermesUrl}`);
    console.log(`Fetching price updates for ${priceIds.length} feed(s)...`);

    const { HermesClient } = await import("@pythnetwork/hermes-client");
    const client = new HermesClient(hermesUrl, {
        priceFeedRequestConfig: {
            binary: true,
        },
    });

    const priceFeedIds = priceIds.map((id) => {
        const hexId = id.startsWith("0x") ? id.slice(2) : id;
        if (hexId.length !== 64) {
            throw new Error(
                `Invalid price feed ID length: ${id} (expected 64 hex chars, got ${hexId.length})`,
            );
        }
        return hexId;
    });

    const settled = await Promise.allSettled(
        priceFeedIds.map(async (feedId, index) => {
            const response = await client.getLatestPriceUpdates([feedId]);
            if (
                !response ||
                !response.binary ||
                !response.binary.data ||
                !Array.isArray(response.binary.data) ||
                response.binary.data.length === 0
            ) {
                throw new Error(`No update data returned for feed ${index + 1}`);
            }
            const updateHex = response.binary.data[0];
            return {
                feedId: priceIds[index],
                update: updateHex.startsWith("0x")
                    ? updateHex
                    : "0x" + updateHex,
            };
        }),
    );

    const updates = [];
    const failures = [];
    settled.forEach((result, index) => {
        if (result.status === "fulfilled") {
            updates.push(result.value);
        } else {
            failures.push({
                feedId: priceIds[index],
                reason: result.reason?.message || String(result.reason),
            });
        }
    });

    return { updates, failures };
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
            if (estimateError.data)
                console.warn("Error data:", estimateError.data);
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
    let config;
    try {
        config = parseCliArgs(args);
    } catch (error) {
        console.error(`Error: ${error.message}`);
        process.exit(1);
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
    } else if (!isValidKeystoreName(selectedKeystore)) {
        console.error(
            "\n❌ Invalid keystore name. Use letters, numbers, dots, underscores, or hyphens only.",
        );
        process.exit(1);
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
    const requireAllPriceUpdates = shouldRequireAllPriceUpdates({
        strict: Boolean(config.strict),
        allowPartial: Boolean(config.allowPartial),
        chainId,
    });
    const rootDir = join(__dirname, "..");
    signer = signer.connect(provider);

    // PythOracle ABI (minimal for updatePriceFeeds)
    const oracleAbi = [
        "function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable",
        "function getUpdateFee(bytes[] calldata priceUpdateData) external view returns (uint256 fee)",
        "function isPriceStale(address) external view returns (bool,uint64)",
        "function isTokenSupported(address) external view returns (bool)",
        "function tokenToPriceFeedId(address) external view returns (bytes32)",
        "function tokenToQuotePriceFeedId(address) external view returns (bytes32)",
        "event TokenPriceFeedSet(address indexed token, bytes32 indexed feedId)",
        "event TokenCompositePriceFeedSet(address indexed token, bytes32 indexed baseFeedId, bytes32 indexed quoteFeedId)",
    ];
    const factoryAbi = [
        "function pythOracle() external view returns (address)",
        "function getWhitelistedTokens() external view returns (address[] memory)",
    ];

    const factoryAddress = getFactoryAddress({
        rootDir,
        chainId,
        cliFactory: config.factory,
    });
    if (requireAllPriceUpdates && !factoryAddress) {
        throw new Error("Strict Pyth updates require a factory address for whitelist discovery");
    }
    let factoryContract = null;
    let oracleAddress = config.oracle || null;
    if (factoryAddress) {
        factoryContract = new ethers.Contract(factoryAddress, factoryAbi, provider);
        if (!oracleAddress) {
            try {
                const factoryPythOracle = await factoryContract.pythOracle();
                if (!isZeroAddress(factoryPythOracle)) {
                    oracleAddress = factoryPythOracle;
                }
            } catch (error) {
                console.warn(`  ⚠ Could not resolve factory Pyth oracle: ${error.message}`);
            }
        }
    }
    if (!oracleAddress) {
        oracleAddress = getOracleAddress({ rootDir, chainId });
    }

    const oracleContract = new ethers.Contract(
        oracleAddress,
        oracleAbi,
        provider,
    );

    console.log("=== Updating Pyth Price Feeds ===");
    console.log("Oracle:", oracleAddress);
    if (factoryAddress) {
        console.log("Factory:", factoryAddress);
    }
    console.log("Network:", network.name);
    console.log("Chain ID:", chainId);
    console.log(
        "Partial feed updates:",
        requireAllPriceUpdates ? "disabled" : "allowed",
    );
    console.log("Signer:", await signer.getAddress());

    // Check token configuration
    console.log("Discovering on-chain token configuration...");
    const registryTokens = resolvePythTokenConfigs({
        rootDir,
        chainId,
    });
    const { configuredTokens, missingConfigs } = await discoverConfiguredPythTokens({
        oracleContract,
        factoryContract,
        registryTokens,
        requireCompleteDiscovery: requireAllPriceUpdates,
    });
    configuredTokens.forEach((token) => {
        console.log(`  ✓ ${token.name} (${token.address}): configured`);
    });

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
            const feedSuffix = token.feedId ? ` → Feed ID: ${token.feedId}` : "";
            const quoteSuffix = token.quoteFeedId
                ? `, Quote Feed ID: ${token.quoteFeedId}`
                : "";
            console.warn(
                `    - ${token.name} (${token.address})${feedSuffix}${quoteSuffix}`,
            );
        });
        console.warn(
            "\n  The deployment script should have configured these, but they may have been",
        );
        console.warn(
            "  configured through governance after this updater's token discovery sources.\n",
        );
        if (requireAllPriceUpdates) {
            throw new Error(`${missingConfigs.length} discovered token(s) are missing Pyth oracle configuration`);
        }
    } else {
        console.log("\n✓ All tokens are properly configured\n");
    }

    const priceIds = [
        ...new Set(
            configuredTokens.flatMap((token) =>
                token.actualQuoteFeedId
                    ? [token.actualFeedId, token.actualQuoteFeedId]
                    : [token.actualFeedId],
            ),
        ),
    ];
    if (priceIds.length === 0) {
        console.error("\n❌ No on-chain configured Pyth feeds found to update");
        process.exit(1);
    }
    console.log("\nFetching price update data from Pyth Hermes...");
    console.log("Feed IDs:", priceIds);

    try {
        const { updates, failures } = await fetchPriceUpdateDataBestEffort(
            priceIds,
            PYTH_HERMES_URL,
        );
        failures.forEach((failure) => {
            console.warn(
                `  ⚠ Skipping feed ${failure.feedId}: ${failure.reason}`,
            );
        });
        if (failures.length > 0 && requireAllPriceUpdates) {
            throw new Error(
                `${failures.length} feed update(s) failed while partial updates are disabled`,
            );
        }
        const priceUpdateData = updates.map((entry) => entry.update);
        console.log(`Received ${priceUpdateData.length} price update(s)`);
        if (priceUpdateData.length === 0) {
            throw new Error("No price updates fetched successfully");
        }

        // Update prices on-chain
        console.log("\nUpdating prices on-chain...");
        await updatePriceFeeds(oracleContract, priceUpdateData, signer);

        const { refreshedTokens, skippedTokens } =
            classifyConfiguredTokenRefreshes({
                configuredTokens,
                updates,
                failures,
            });
        await verifyPythTokenFreshness({
            oracleContract,
            configuredTokens,
            refreshedTokens,
            requireAllPriceUpdates,
        });

        console.log("\n✅ Price feeds updated successfully!");
        console.log("\nRefreshed Pyth feeds for:");
        if (refreshedTokens.length === 0) {
            console.log("  (none)");
        }
        refreshedTokens.forEach((token) => {
            console.log(`  - ${token.name}: ${token.actualFeedId}`);
            if (token.actualQuoteFeedId) {
                console.log(`    quote: ${token.actualQuoteFeedId}`);
            }
        });
        if (skippedTokens.length > 0) {
            console.warn("\nSkipped configured token feeds:");
            skippedTokens.forEach(({ token, missingFeedIds, failedFeedIds }) => {
                const failedSuffix =
                    failedFeedIds.length > 0
                        ? ` (failed: ${failedFeedIds.join(", ")})`
                        : "";
                console.warn(
                    `  - ${token.name}: missing update for ${missingFeedIds.join(", ")}${failedSuffix}`,
                );
            });
        }
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

module.exports = {
    classifyConfiguredTokenRefreshes,
    collectTokenCandidates,
    discoverConfiguredPythTokens,
    fetchPriceUpdateData,
    fetchPriceUpdateDataBestEffort,
    getFactoryAddress,
    parseCliArgs,
    queryPythTokenEvents,
    shouldRequireAllPriceUpdates,
    updatePriceFeeds,
    verifyPythTokenFreshness,
};
