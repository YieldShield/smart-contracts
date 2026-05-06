#!/usr/bin/env node

/**
 * Pyth Keeper Service
 *
 * This script fetches price update data from Pyth's Hermes API and updates
 * prices on-chain when they become stale. It can be run as a standalone service
 * or integrated into transaction flows.
 *
 * Usage:
 *   node scripts-js/pyth-keeper.js --network arbitrumSepolia --oracle <address> --tokens <token1>,<token2>
 *   node scripts-js/pyth-keeper.js --check-stale --oracle <address> --tokens <token1>,<token2>
 */

const { ethers } = require("ethers");
const https = require("https");
const http = require("http");

// Pyth Hermes API endpoints
const PYTH_HERMES_MAINNET = "https://hermes.pyth.network";
const PYTH_HERMES_TESTNET = "https://hermes.pyth.network";

// Default configuration
const DEFAULT_MAX_PRICE_AGE = 60; // seconds
const DEFAULT_UPDATE_INTERVAL = 30; // seconds

/**
 * Fetch price update data from Pyth Hermes API
 * @param {string[]} priceIds - Array of price feed IDs (bytes32 hex strings)
 * @param {string} network - Network name (mainnet or testnet)
 * @returns {Promise<{vaaBytes: string[], publishTimes: number[]}>}
 */
async function fetchPriceUpdateData(priceIds, network = "testnet") {
    const baseUrl =
        network === "mainnet" ? PYTH_HERMES_MAINNET : PYTH_HERMES_TESTNET;
    const url = `${baseUrl}/api/get_vaas?ids=${priceIds.join(",")}`;

    return new Promise((resolve, reject) => {
        https
            .get(url, (res) => {
                let data = "";

                res.on("data", (chunk) => {
                    data += chunk;
                });

                res.on("end", () => {
                    try {
                        const response = JSON.parse(data);
                        if (response.vaas && Array.isArray(response.vaas)) {
                            const vaaBytes = response.vaas.map((vaa) =>
                                Buffer.from(vaa, "base64")
                            );
                            resolve({ vaaBytes, publishTimes: [] }); // Publish times would need to be parsed from VAA
                        } else {
                            reject(
                                new Error(
                                    "Invalid response format from Hermes API"
                                )
                            );
                        }
                    } catch (error) {
                        reject(error);
                    }
                });
            })
            .on("error", (error) => {
                reject(error);
            });
    });
}

/**
 * Check if prices are stale for given tokens
 * @param {ethers.Contract} oracleContract - PythOracle contract instance
 * @param {string[]} tokenAddresses - Array of token addresses to check
 * @returns {Promise<{stale: boolean, tokens: Array<{address: string, isStale: boolean, publishTime: number}>>}>}
 */
async function checkPriceStaleness(oracleContract, tokenAddresses) {
    const results = [];
    let hasStale = false;

    for (const tokenAddress of tokenAddresses) {
        try {
            const [isStale, publishTime] = await oracleContract.isPriceStale(
                tokenAddress
            );
            results.push({
                address: tokenAddress,
                isStale,
                publishTime: publishTime.toNumber(),
            });
            if (isStale) {
                hasStale = true;
            }
        } catch (error) {
            console.error(
                `Error checking staleness for ${tokenAddress}:`,
                error.message
            );
            results.push({
                address: tokenAddress,
                isStale: true,
                publishTime: 0,
                error: error.message,
            });
            hasStale = true;
        }
    }

    return { stale: hasStale, tokens: results };
}

/**
 * Update price feeds on-chain
 * @param {ethers.Contract} oracleContract - PythOracle contract instance
 * @param {string[]} priceUpdateData - Array of price update data (VAA bytes as hex strings)
 * @param {ethers.Signer} signer - Signer to send the transaction
 * @returns {Promise<ethers.TransactionReceipt>}
 */
async function updatePriceFeeds(oracleContract, priceUpdateData, signer) {
    try {
        // Get the required fee
        const fee = await oracleContract.getUpdateFee(priceUpdateData);
        console.log(`Update fee: ${ethers.utils.formatEther(fee)} ETH`);

        // Estimate gas
        const gasEstimate = await oracleContract.estimateGas.updatePriceFeeds(
            priceUpdateData,
            {
                value: fee,
            }
        );
        console.log(`Estimated gas: ${gasEstimate.toString()}`);

        // Send transaction
        const tx = await oracleContract
            .connect(signer)
            .updatePriceFeeds(priceUpdateData, {
                value: fee,
                gasLimit: gasEstimate.mul(120).div(100), // Add 20% buffer
            });

        console.log(`Transaction sent: ${tx.hash}`);
        const receipt = await tx.wait();
        console.log(`Transaction confirmed in block: ${receipt.blockNumber}`);

        return receipt;
    } catch (error) {
        console.error("Error updating price feeds:", error);
        throw error;
    }
}

/**
 * Main keeper function - monitors and updates prices
 */
async function runKeeper(config) {
    const {
        rpcUrl,
        oracleAddress,
        tokenAddresses,
        priceFeedIds,
        network,
        privateKey,
        updateInterval = DEFAULT_UPDATE_INTERVAL,
    } = config;

    // Setup provider and signer
    const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    const signer = new ethers.Wallet(privateKey, provider);

    // Load PythOracle ABI (simplified - in production, load from artifacts)
    const oracleAbi = [
        "function isPriceStale(address token) external view returns (bool isStale, uint64 publishTime)",
        "function updatePriceFeeds(bytes[] calldata priceUpdateData) external payable",
        "function getUpdateFee(bytes[] calldata priceUpdateData) external view returns (uint256 fee)",
        "function tokenToPriceFeedId(address) external view returns (bytes32)",
    ];

    const oracleContract = new ethers.Contract(
        oracleAddress,
        oracleAbi,
        provider
    );

    console.log("Pyth Keeper Service Started");
    console.log(`Oracle: ${oracleAddress}`);
    console.log(`Network: ${network}`);
    console.log(`Update interval: ${updateInterval} seconds`);

    // Main loop
    setInterval(async () => {
        try {
            console.log("\n--- Checking price staleness ---");
            const { stale, tokens } = await checkPriceStaleness(
                oracleContract,
                tokenAddresses
            );

            if (stale) {
                console.log("Stale prices detected:");
                tokens.forEach((token) => {
                    if (token.isStale) {
                        console.log(
                            `  - ${token.address}: stale (publishTime: ${token.publishTime})`
                        );
                    }
                });

                // Fetch price update data
                console.log("Fetching price update data from Hermes...");
                const { vaaBytes } = await fetchPriceUpdateData(
                    priceFeedIds,
                    network
                );

                // Convert to hex strings for contract call
                const priceUpdateData = vaaBytes.map((vaa) =>
                    ethers.utils.hexlify(vaa)
                );

                // Update prices on-chain
                console.log("Updating prices on-chain...");
                await updatePriceFeeds(oracleContract, priceUpdateData, signer);
                console.log("Prices updated successfully!");
            } else {
                console.log("All prices are fresh");
            }
        } catch (error) {
            console.error("Error in keeper loop:", error);
        }
    }, updateInterval * 1000);
}

/**
 * Check staleness without updating (for frontend integration)
 */
async function checkStalenessOnly(config) {
    const { rpcUrl, oracleAddress, tokenAddresses } = config;

    const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
    const oracleAbi = [
        "function isPriceStale(address token) external view returns (bool isStale, uint64 publishTime)",
    ];
    const oracleContract = new ethers.Contract(
        oracleAddress,
        oracleAbi,
        provider
    );

    const { stale, tokens } = await checkPriceStaleness(
        oracleContract,
        tokenAddresses
    );
    return { stale, tokens };
}

/**
 * Get price update data for frontend integration
 */
async function getPriceUpdateData(priceFeedIds, network = "testnet") {
    return await fetchPriceUpdateData(priceFeedIds, network);
}

// CLI interface
if (require.main === module) {
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

    // Validate required config
    if (!config.rpcUrl || !config.oracle || !config.tokens) {
        console.error(
            "Usage: node pyth-keeper.js --rpcUrl <url> --oracle <address> --tokens <token1>,<token2> [--network testnet] [--privateKey <key>]"
        );
        process.exit(1);
    }

    config.oracleAddress = config.oracle;
    config.tokenAddresses = config.tokens.split(",");
    config.network = config.network || "testnet";
    config.privateKey = config.privateKey || process.env.PRIVATE_KEY;

    if (!config.privateKey) {
        console.error(
            "Error: Private key required (--privateKey or PRIVATE_KEY env var)"
        );
        process.exit(1);
    }

    // Get price feed IDs from oracle contract (would need to query tokenToPriceFeedId mapping)
    // For now, assume they're provided or fetched separately
    config.priceFeedIds = config.priceFeedIds
        ? config.priceFeedIds.split(",")
        : []; // Would need to fetch from contract

    if (config["check-stale"]) {
        checkStalenessOnly(config).then((result) => {
            console.log(JSON.stringify(result, null, 2));
        });
    } else {
        runKeeper(config);
    }
}

module.exports = {
    fetchPriceUpdateData,
    checkPriceStaleness,
    updatePriceFeeds,
    checkStalenessOnly,
    getPriceUpdateData,
};
