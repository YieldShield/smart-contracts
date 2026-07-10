#!/usr/bin/env node

const { ethers } = require("ethers");
const {
    existsSync,
    readFileSync,
    readdirSync,
    renameSync,
    writeFileSync,
} = require("node:fs");
const { dirname, join } = require("node:path");
const readline = require("node:readline");

require("dotenv").config({ path: join(__dirname, "..", ".env") });

const ROBINHOOD_TESTNET_CHAIN_ID = 46_630n;
const FIXTURE_ID = "robinhood-standard-mock-feeds-v1";
const FIXTURE_METADATA_PATH = ["fixtureMetadata", "robinhoodStandardMockFeeds"];
const FEED_SPECS = Object.freeze({
    USDG: {
        deploymentName: "RobinhoodUSDGMockChainlinkFeed",
        description: "USDG / USD",
    },
    WETH: {
        deploymentName: "RobinhoodWETHMockChainlinkFeed",
        description: "WETH / USD",
    },
    SGOV: {
        deploymentName: "RobinhoodSGOVMockChainlinkFeed",
        description: "SGOV / USD",
    },
    SPY: {
        deploymentName: "RobinhoodSPYMockChainlinkFeed",
        description: "SPY / USD",
    },
    QQQ: {
        deploymentName: "RobinhoodQQQMockChainlinkFeed",
        description: "QQQ / USD",
    },
    TSLA: {
        deploymentName: "RobinhoodTSLAMockChainlinkFeed",
        description: "TSLA / USD",
    },
    AMZN: {
        deploymentName: "RobinhoodAMZNMockChainlinkFeed",
        description: "AMZN / USD",
    },
    PLTR: {
        deploymentName: "RobinhoodPLTRMockChainlinkFeed",
        description: "PLTR / USD",
    },
    NFLX: {
        deploymentName: "RobinhoodNFLXMockChainlinkFeed",
        description: "NFLX / USD",
    },
    AMD: {
        deploymentName: "RobinhoodAMDMockChainlinkFeed",
        description: "AMD / USD",
    },
});
const MOCK_FEED_ABI = [
    "function owner() external view returns (address)",
    "function decimals() external view returns (uint8)",
    "function description() external view returns (string)",
    "function latestRoundData() external view returns (uint80,int256,uint256,uint256,uint80)",
    "function setAnswer(int256 answer) external",
];
const KEYSTORE_NAME_PATTERN = /^[A-Za-z0-9_.-]+$/u;
const INT256_MAX = (1n << 255n) - 1n;

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requirePositiveSafeInteger(value, field) {
    if (!Number.isSafeInteger(value) || value <= 0) {
        throw new Error(`${field} must be a positive safe integer`);
    }
    return value;
}

function requireExactKeys(object, expectedKeys, field) {
    if (!isPlainObject(object)) {
        throw new Error(`${field} must be an object`);
    }
    const actual = Object.keys(object).sort();
    const expected = [...expectedKeys].sort();
    if (actual.join("\0") !== expected.join("\0")) {
        throw new Error(
            `${field} must contain exactly: ${expected.join(", ")}; found: ${actual.join(", ")}`,
        );
    }
}

function fixtureMetadataFromManifest(manifest) {
    let current = manifest;
    for (const key of FIXTURE_METADATA_PATH) {
        if (!isPlainObject(current) || !(key in current)) {
            throw new Error(
                `Manifest is missing ${FIXTURE_METADATA_PATH.join(".")}`,
            );
        }
        current = current[key];
    }
    return current;
}

function validateFixtureManifest(manifest) {
    const rawFixture = fixtureMetadataFromManifest(manifest);
    requireExactKeys(
        rawFixture,
        [
            "schemaVersion",
            "fixtureId",
            "chainId",
            "synthetic",
            "maxPriceAgeSeconds",
            "nearExpirySeconds",
            "expiresAt",
            "expectedRuntimeCodehash",
            "expectedOwner",
            "feeds",
        ],
        FIXTURE_METADATA_PATH.join("."),
    );
    if (rawFixture.schemaVersion !== 1) {
        throw new Error("Fixture schemaVersion must be 1");
    }
    if (rawFixture.fixtureId !== FIXTURE_ID) {
        throw new Error(`Fixture fixtureId must be ${FIXTURE_ID}`);
    }
    if (rawFixture.chainId !== Number(ROBINHOOD_TESTNET_CHAIN_ID)) {
        throw new Error("Fixture chainId must be 46630");
    }
    if (rawFixture.synthetic !== true) {
        throw new Error("Fixture synthetic must be true");
    }
    const maxPriceAgeSeconds = requirePositiveSafeInteger(
        rawFixture.maxPriceAgeSeconds,
        "Fixture maxPriceAgeSeconds",
    );
    const nearExpirySeconds = requirePositiveSafeInteger(
        rawFixture.nearExpirySeconds,
        "Fixture nearExpirySeconds",
    );
    if (nearExpirySeconds >= maxPriceAgeSeconds) {
        throw new Error(
            "Fixture nearExpirySeconds must be less than maxPriceAgeSeconds",
        );
    }
    requirePositiveSafeInteger(rawFixture.expiresAt, "Fixture expiresAt");
    if (!/^0x[0-9a-fA-F]{64}$/u.test(rawFixture.expectedRuntimeCodehash)) {
        throw new Error(
            "Fixture expectedRuntimeCodehash must be a 32-byte hex value",
        );
    }
    if (!ethers.isAddress(rawFixture.expectedOwner)) {
        throw new Error("Fixture expectedOwner must be an EVM address");
    }

    const symbols = Object.keys(FEED_SPECS);
    requireExactKeys(rawFixture.feeds, symbols, "Fixture feeds");
    const seenAddresses = new Set();
    const feeds = {};
    for (const symbol of symbols) {
        const feed = rawFixture.feeds[symbol];
        requireExactKeys(
            feed,
            ["address", "deploymentName", "description", "decimals"],
            `Fixture feeds.${symbol}`,
        );
        if (!ethers.isAddress(feed.address)) {
            throw new Error(`Fixture feeds.${symbol}.address is invalid`);
        }
        const normalizedAddress = ethers.getAddress(feed.address);
        if (seenAddresses.has(normalizedAddress)) {
            throw new Error(
                `Fixture feed address is duplicated: ${feed.address}`,
            );
        }
        seenAddresses.add(normalizedAddress);
        const expected = FEED_SPECS[symbol];
        if (feed.deploymentName !== expected.deploymentName) {
            throw new Error(
                `Fixture feeds.${symbol}.deploymentName must be ${expected.deploymentName}`,
            );
        }
        if (feed.description !== expected.description) {
            throw new Error(
                `Fixture feeds.${symbol}.description must be ${expected.description}`,
            );
        }
        if (feed.decimals !== 8) {
            throw new Error(`Fixture feeds.${symbol}.decimals must be 8`);
        }
        feeds[symbol] = { ...feed, address: normalizedAddress };
    }

    return {
        ...rawFixture,
        expectedOwner: ethers.getAddress(rawFixture.expectedOwner),
        expectedRuntimeCodehash:
            rawFixture.expectedRuntimeCodehash.toLowerCase(),
        feeds,
    };
}

function readManifest(manifestPath) {
    return JSON.parse(readFileSync(manifestPath, "utf8"));
}

async function requireRobinhoodTestnet(provider) {
    const network = await provider.getNetwork();
    if (BigInt(network.chainId) !== ROBINHOOD_TESTNET_CHAIN_ID) {
        throw new Error(
            `Robinhood mock-feed operator requires chain 46630; connected to ${network.chainId}`,
        );
    }
}

function defaultContractFactory(address, runner) {
    return new ethers.Contract(address, MOCK_FEED_ABI, runner);
}

async function inspectFixture({
    provider,
    fixture,
    contractFactory = defaultContractFactory,
    nowSeconds,
    checkManifestExpiry = true,
}) {
    await requireRobinhoodTestnet(provider);
    const currentTime =
        nowSeconds ?? Number((await provider.getBlock("latest")).timestamp);
    const results = {};
    const healthIssues = [];
    let earliestExpiry = Number.MAX_SAFE_INTEGER;

    for (const [symbol, expected] of Object.entries(fixture.feeds)) {
        const code = await provider.getCode(expected.address);
        if (code === "0x") {
            throw new Error(`${symbol} feed has no runtime code`);
        }
        const codehash = ethers.keccak256(code).toLowerCase();
        if (codehash !== fixture.expectedRuntimeCodehash) {
            throw new Error(
                `${symbol} feed runtime codehash mismatch: ${codehash}`,
            );
        }

        const contract = contractFactory(expected.address, provider);
        const [owner, description, decimals, round] = await Promise.all([
            contract.owner(),
            contract.description(),
            contract.decimals(),
            contract.latestRoundData(),
        ]);
        if (ethers.getAddress(owner) !== fixture.expectedOwner) {
            throw new Error(
                `${symbol} feed owner mismatch: expected ${fixture.expectedOwner}, found ${owner}`,
            );
        }
        if (description !== expected.description) {
            throw new Error(
                `${symbol} feed description mismatch: expected ${expected.description}, found ${description}`,
            );
        }
        if (Number(decimals) !== expected.decimals) {
            throw new Error(
                `${symbol} feed decimals mismatch: expected ${expected.decimals}, found ${decimals}`,
            );
        }

        const roundId = BigInt(round[0]);
        const answer = BigInt(round[1]);
        const updatedAt = Number(round[3]);
        const answeredInRound = BigInt(round[4]);
        const expiresAt = updatedAt + fixture.maxPriceAgeSeconds;
        earliestExpiry = Math.min(earliestExpiry, expiresAt);
        if (answer <= 0n) {
            healthIssues.push(`${symbol}: non-positive answer`);
        }
        if (updatedAt <= 0 || answeredInRound < roundId) {
            healthIssues.push(`${symbol}: incomplete round metadata`);
        } else if (expiresAt <= currentTime) {
            healthIssues.push(`${symbol}: stale since ${expiresAt}`);
        } else if (expiresAt <= currentTime + fixture.nearExpirySeconds) {
            healthIssues.push(`${symbol}: near expiry at ${expiresAt}`);
        }
        results[symbol] = {
            address: expected.address,
            answer,
            roundId,
            updatedAt,
            expiresAt,
        };
    }

    if (checkManifestExpiry && fixture.expiresAt !== earliestExpiry) {
        healthIssues.push(
            `manifest expiresAt ${fixture.expiresAt} does not match live earliest expiry ${earliestExpiry}`,
        );
    }

    return {
        ok: healthIssues.length === 0,
        currentTime,
        earliestExpiry,
        healthIssues,
        feeds: results,
    };
}

function normalizeAnswerUpdates(answerUpdates = {}) {
    if (!isPlainObject(answerUpdates)) {
        throw new Error("answerUpdates must be an object keyed by feed symbol");
    }
    const updates = {};
    for (const [symbol, rawAnswer] of Object.entries(answerUpdates)) {
        if (!(symbol in FEED_SPECS)) {
            throw new Error(`Unknown fixture feed symbol: ${symbol}`);
        }
        const answer = BigInt(rawAnswer);
        if (answer <= 0n || answer > INT256_MAX) {
            throw new Error(`${symbol} answer must be a positive int256`);
        }
        updates[symbol] = answer;
    }
    return updates;
}

async function refreshFixture({
    provider,
    signer,
    fixture,
    confirmation,
    answerUpdates,
    contractFactory = defaultContractFactory,
}) {
    if (confirmation !== fixture.fixtureId) {
        throw new Error(
            `Refresh requires --confirm-synthetic-fixture ${fixture.fixtureId}`,
        );
    }
    await requireRobinhoodTestnet(provider);
    const signerAddress = ethers.getAddress(await signer.getAddress());
    if (signerAddress !== fixture.expectedOwner) {
        throw new Error(
            `Refresh signer must be fixture owner ${fixture.expectedOwner}; received ${signerAddress}`,
        );
    }
    const updates = normalizeAnswerUpdates(answerUpdates);
    const before = await inspectFixture({
        provider,
        fixture,
        contractFactory,
        checkManifestExpiry: false,
    });
    const refreshed = {};

    for (const [symbol, state] of Object.entries(before.feeds)) {
        const answer = updates[symbol] ?? state.answer;
        const contract = contractFactory(state.address, signer);
        const transaction = await contract.setAnswer(answer);
        await transaction.wait();
        refreshed[symbol] = {
            previousAnswer: state.answer,
            answer,
            explicitlyUpdated: symbol in updates,
            transactionHash: transaction.hash,
        };
    }

    const after = await inspectFixture({
        provider,
        fixture,
        contractFactory,
        checkManifestExpiry: false,
    });
    return { refreshed, health: after, expiresAt: after.earliestExpiry };
}

function updateManifestExpiry(manifest, expiresAt, manifestPath) {
    manifest.fixtureMetadata.robinhoodStandardMockFeeds.expiresAt = expiresAt;
    const temporaryPath = join(
        dirname(manifestPath),
        `.${FIXTURE_ID}.${process.pid}.tmp`,
    );
    writeFileSync(temporaryPath, `${JSON.stringify(manifest, null, 2)}\n`, {
        mode: 0o644,
    });
    renameSync(temporaryPath, manifestPath);
}

function parseCliArgs(args) {
    const config = { answers: {} };
    if (args[0] !== "health" && args[0] !== "refresh") {
        throw new Error("First argument must be health or refresh");
    }
    config.command = args[0];
    for (let index = 1; index < args.length; index++) {
        const key = args[index];
        const value = args[index + 1];
        if (!value || value.startsWith("--")) {
            throw new Error(`${key} requires a value`);
        }
        if (key === "--manifest") config.manifest = value;
        else if (key === "--rpc-url") config.rpcUrl = value;
        else if (key === "--keystore") config.keystore = value;
        else if (key === "--confirm-synthetic-fixture")
            config.confirmation = value;
        else if (key === "--answer") {
            const separator = value.indexOf("=");
            if (separator <= 0) {
                throw new Error("--answer must use SYMBOL=INTEGER");
            }
            config.answers[value.slice(0, separator).toUpperCase()] =
                value.slice(separator + 1);
        } else throw new Error(`Unknown argument: ${key}`);
        index++;
    }
    return config;
}

function listKeystores() {
    const directory = join(process.env.HOME || "", ".foundry", "keystores");
    if (!process.env.HOME || !existsSync(directory)) return [];
    return readdirSync(directory).filter((name) =>
        KEYSTORE_NAME_PATTERN.test(name),
    );
}

function promptSecret(prompt) {
    return new Promise((resolve, reject) => {
        if (!process.stdin.isTTY || !process.stdout.isTTY) {
            reject(
                new Error("Interactive terminal required to unlock keystore"),
            );
            return;
        }
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout,
            terminal: true,
        });
        rl.stdoutMuted = false;
        rl._writeToOutput = function writeToOutput(value) {
            if (rl.stdoutMuted) rl.output.write("*");
            else rl.output.write(value);
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

async function unlockKeystore(name) {
    if (!KEYSTORE_NAME_PATTERN.test(name)) {
        throw new Error("Invalid keystore name");
    }
    const path = join(process.env.HOME || "", ".foundry", "keystores", name);
    if (!existsSync(path)) {
        throw new Error(
            `Keystore not found: ${name}. Available: ${listKeystores().join(", ") || "none"}`,
        );
    }
    const password = await promptSecret(
        `Enter password for keystore '${name}': `,
    );
    return ethers.Wallet.fromEncryptedJson(
        readFileSync(path, "utf8"),
        password,
    );
}

async function main() {
    const config = parseCliArgs(process.argv.slice(2));
    const rpcUrl = config.rpcUrl || process.env.ROBINHOOD_TESTNET_RPC_URL;
    if (!rpcUrl) {
        throw new Error(
            "Robinhood testnet RPC required via --rpc-url or ROBINHOOD_TESTNET_RPC_URL",
        );
    }
    if (config.command === "refresh" && process.env.PRIVATE_KEY) {
        throw new Error(
            "Raw PRIVATE_KEY input is disabled; use a Foundry keystore",
        );
    }
    const manifestPath =
        config.manifest || join(__dirname, "..", "deployments", "46630.json");
    const manifest = readManifest(manifestPath);
    const fixture = validateFixtureManifest(manifest);
    const provider = new ethers.JsonRpcProvider(rpcUrl);

    if (config.command === "health") {
        const health = await inspectFixture({ provider, fixture });
        for (const [symbol, state] of Object.entries(health.feeds)) {
            console.log(
                `${symbol}: answer=${state.answer} updatedAt=${state.updatedAt} expiresAt=${state.expiresAt}`,
            );
        }
        if (!health.ok) {
            throw new Error(
                `Mock-feed health failed:\n- ${health.healthIssues.join("\n- ")}`,
            );
        }
        console.log(`Healthy through ${health.earliestExpiry}`);
        return;
    }

    const keystore =
        config.keystore || process.env.ROBINHOOD_TESTNET_KEYSTORE_ACCOUNT;
    if (!keystore) {
        throw new Error(
            "Refresh requires --keystore or ROBINHOOD_TESTNET_KEYSTORE_ACCOUNT",
        );
    }
    const signer = (await unlockKeystore(keystore)).connect(provider);
    const result = await refreshFixture({
        provider,
        signer,
        fixture,
        confirmation: config.confirmation,
        answerUpdates: config.answers,
    });
    updateManifestExpiry(manifest, result.expiresAt, manifestPath);
    for (const [symbol, refresh] of Object.entries(result.refreshed)) {
        console.log(
            `${symbol}: answer=${refresh.answer} tx=${refresh.transactionHash}${
                refresh.explicitlyUpdated
                    ? " (explicit update)"
                    : " (preserved)"
            }`,
        );
    }
    console.log(`Manifest expiresAt updated to ${result.expiresAt}`);
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error.message);
        process.exitCode = 1;
    });
}

module.exports = {
    FEED_SPECS,
    FIXTURE_ID,
    inspectFixture,
    normalizeAnswerUpdates,
    parseCliArgs,
    refreshFixture,
    updateManifestExpiry,
    validateFixtureManifest,
};
