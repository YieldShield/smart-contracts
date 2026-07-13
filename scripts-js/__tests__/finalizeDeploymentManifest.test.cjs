const assert = require("node:assert/strict");
const {
    existsSync,
    mkdirSync,
    mkdtempSync,
    readFileSync,
    renameSync,
    rmSync,
    writeFileSync,
} = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { test } = require("node:test");

const CHAIN_ID = "46630";
const DEPLOYMENT_ID = "gen-test-00000001";
const CONFIGURATION_DIGEST = `0x${"cd".repeat(32)}`;
const DEPLOYER = "0x000000000000000000000000000000000000dEaD";
const TX_HASH = `0x${"ab".repeat(32)}`;
const FINALIZED_BLOCK_NUMBER = 100n;
const FINALIZED_BLOCK_HASH = `0x${"fa".repeat(32)}`;
const RECEIPT_BLOCK_HASH = `0x${"bc".repeat(32)}`;
const PRIMARY_RPC_URL = "https://deployment-rpc.example/v1";
const VALIDATION_RPC_URL = "https://validation-rpc.example/v1";
const ARBITRUM_MAINNET_CHAIN_ID = "42161";
const ARBITRUM_SEPOLIA_CHAIN_ID = "421614";
const PYTH_MAINNET_SEQUENCER_FEED =
    "0xFdB631F5EE196F0ed6FAa767959853A9F217697D";
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const FACTORY_CREATED_OUTPUTS = new Set([
    "RobinhoodSGOVUSDGPool",
    "RobinhoodSPYUSDGPool",
    "RobinhoodQQQUSDGPool",
    "RobinhoodUSDGWETHPool",
    "RobinhoodTSLAUSDGPool",
    "RobinhoodAMZNUSDGPool",
    "RobinhoodPLTRUSDGPool",
    "RobinhoodNFLXUSDGPool",
    "RobinhoodAMDUSDGPool",
]);
const PREEXISTING_DEMO_INPUTS = new Set([
    "RobinhoodTestTSLA",
    "RobinhoodTestAMZN",
    "RobinhoodTestPLTR",
    "RobinhoodTestNFLX",
    "RobinhoodTestAMD",
]);

function addressFor(index) {
    return `0x${index.toString(16).padStart(40, "0")}`;
}

function transactionHashFor(index) {
    if (index === 0) return TX_HASH;
    return `0x${index.toString(16).padStart(64, "0")}`;
}

async function fixture({
    chainId,
    demo = false,
    oracleMode = "chainlink",
} = {}) {
    chainId ??= oracleMode === "pyth" ? ARBITRUM_SEPOLIA_CHAIN_ID : CHAIN_ID;
    const module = await import("../finalizeDeploymentManifest.js");
    const { keccak256 } = await import("ethers");
    const names = [
        ...(oracleMode === "pyth"
            ? module.PYTH_CORE_INVENTORY
            : module.CHAINLINK_CORE_INVENTORY),
    ];
    if (demo) names.push(...module.DEMO_EXTRA_INVENTORY);
    const candidate = {
        schemaVersion: "2",
        status: "candidate",
        deploymentId: DEPLOYMENT_ID,
        chainId,
        deployer: DEPLOYER,
        configurationDigest: CONFIGURATION_DIGEST,
        networkName:
            chainId === ARBITRUM_MAINNET_CHAIN_ID
                ? "arbitrum-mainnet"
                : chainId === ARBITRUM_SEPOLIA_CHAIN_ID
                  ? "arbitrum-sepolia"
                  : "robinhood-testnet",
        robinhoodDemoAssetsEnabled: demo ? "true" : "false",
        productionGuardMode: chainId === "46630" ? "relaxed" : "strict",
        recovery: "false",
    };
    names.forEach((name, index) => {
        candidate[addressFor(index + 1)] = name;
    });
    if (oracleMode === "chainlink") {
        candidate.marketSessionGuardian = addressFor(900);
        candidate.robinhoodSequencerUptimeFeed = addressFor(0);
        candidate.robinhoodSequencerUptimeFeedSource =
            "robinhood-testnet-relaxed-guards";
        candidate.robinhoodSequencerUptimeFeedCodehash = `0x${"00".repeat(32)}`;
    }
    const byName = new Map(
        Object.entries(candidate)
            .filter(([key]) => /^0x[0-9a-f]{40}$/iu.test(key))
            .map(([address, name]) => [name, address]),
    );
    const createdContracts = [...byName.entries()].filter(
        ([name]) =>
            !FACTORY_CREATED_OUTPUTS.has(name) &&
            !PREEXISTING_DEMO_INPUTS.has(name),
    );
    const transactions = createdContracts.map(([name, address], index) => ({
        hash: transactionHashFor(index),
        transaction: { from: DEPLOYER },
        transactionType: "CREATE",
        contractAddress: address,
        additionalContracts: [{ address: addressFor(999), name }],
    }));
    const receipts = transactions.map(({ contractAddress, hash }) => ({
        contractAddress,
        status: "0x1",
        transactionHash: hash,
    }));
    const liveReceipts = new Map(
        receipts.map(({ contractAddress, transactionHash }) => [
            transactionHash,
            {
                blockHash: RECEIPT_BLOCK_HASH,
                blockNumber: FINALIZED_BLOCK_NUMBER - 1n,
                contractAddress,
                from: DEPLOYER,
                status: 1,
                transactionHash,
            },
        ]),
    );
    const broadcast = {
        chain: chainId,
        transactions,
        receipts,
        pending: [],
    };
    const missingCode = new Set();
    const callBlockTags = [];
    const codeBlockTags = [];
    const runtimeCodehash = keccak256("0x6000");
    const env = Object.fromEntries(
        module
            .reviewedCodehashPinSpecs(oracleMode)
            .map(([, envName]) => [envName, runtimeCodehash]),
    );
    env.YS_DEPLOYMENT_RPC_OPERATOR = "deployment-operator";
    env.YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR = "validation-operator";
    const provider = {
        async call(transaction) {
            callBlockTags.push(transaction.blockTag);
            return "0x";
        },
        async getNetwork() {
            return { chainId: BigInt(chainId) };
        },
        async getTransactionReceipt(hash) {
            return liveReceipts.get(hash) || null;
        },
        async getCode(address, blockTag) {
            codeBlockTags.push(blockTag);
            return missingCode.has(address.toLowerCase()) ? "0x" : "0x6000";
        },
        async send(method, params) {
            assert.equal(method, "eth_getBlockByNumber");
            assert.deepEqual(params, ["finalized", false]);
            return {
                hash: FINALIZED_BLOCK_HASH,
                number: `0x${FINALIZED_BLOCK_NUMBER.toString(16)}`,
            };
        },
    };
    const validationProvider = { ...provider };
    const poolInfo = {};
    if (demo) {
        const configs = {
            RobinhoodSGOVUSDGPool: [
                "RobinhoodTestSGOV",
                "RobinhoodTestUSDG",
                "SGOV",
                "USDG",
                12_500,
            ],
            RobinhoodSPYUSDGPool: [
                "RobinhoodTestSPY",
                "RobinhoodTestUSDG",
                "SPY",
                "USDG",
                20_000,
            ],
            RobinhoodQQQUSDGPool: [
                "RobinhoodTestQQQ",
                "RobinhoodTestUSDG",
                "QQQ",
                "USDG",
                22_500,
            ],
            RobinhoodUSDGWETHPool: [
                "RobinhoodTestUSDG",
                "RobinhoodTestWETH",
                "USDG",
                "WETH",
                20_000,
            ],
            RobinhoodTSLAUSDGPool: [
                "RobinhoodTestTSLA",
                "RobinhoodTestUSDG",
                "TSLA",
                "USDG",
                25_000,
            ],
            RobinhoodAMZNUSDGPool: [
                "RobinhoodTestAMZN",
                "RobinhoodTestUSDG",
                "AMZN",
                "USDG",
                25_000,
            ],
            RobinhoodPLTRUSDGPool: [
                "RobinhoodTestPLTR",
                "RobinhoodTestUSDG",
                "PLTR",
                "USDG",
                30_000,
            ],
            RobinhoodNFLXUSDGPool: [
                "RobinhoodTestNFLX",
                "RobinhoodTestUSDG",
                "NFLX",
                "USDG",
                25_000,
            ],
            RobinhoodAMDUSDGPool: [
                "RobinhoodTestAMD",
                "RobinhoodTestUSDG",
                "AMD",
                "USDG",
                30_000,
            ],
        };
        for (const [poolName, config] of Object.entries(configs)) {
            const [
                shielded,
                backing,
                shieldedSymbol,
                backingSymbol,
                collateralRatio,
            ] = config;
            poolInfo[poolName] = {
                shieldedToken: byName.get(shielded),
                backingToken: byName.get(backing),
                shieldedTokenSymbol: shieldedSymbol,
                backingTokenSymbol: backingSymbol,
                commissionRate: 500,
                poolFee: 200,
                collateralRatio,
            };
        }
    }
    const protocolState = {
        factory: {
            implementation: byName.get("SplitRiskPoolFactoryImplementation"),
            poolImplementation: byName.get("SplitRiskPoolImplementation"),
            governanceTimelock: byName.get("TimelockController"),
            owner: byName.get("TimelockController"),
            bootstrapModeEnabled: false,
            compositeOracle: byName.get("CompositeOracle"),
            protocolFeeRecipient: byName.get("TimelockController"),
            erc4626OracleFeed: byName.get("ERC4626OracleFeed"),
            pythOracle:
                oracleMode === "pyth"
                    ? byName.get("PythOracle")
                    : "0x0000000000000000000000000000000000000000",
            poolCount: demo ? 9 : 0,
            whitelistedTokens: demo
                ? [
                      "RobinhoodTestUSDG",
                      "RobinhoodTestWETH",
                      "RobinhoodTestSGOV",
                      "RobinhoodTestSPY",
                      "RobinhoodTestQQQ",
                      "RobinhoodTestTSLA",
                      "RobinhoodTestAMZN",
                      "RobinhoodTestPLTR",
                      "RobinhoodTestNFLX",
                      "RobinhoodTestAMD",
                  ].map((name) => byName.get(name))
                : [],
            pools: demo
                ? [
                      "RobinhoodSGOVUSDGPool",
                      "RobinhoodSPYUSDGPool",
                      "RobinhoodQQQUSDGPool",
                      "RobinhoodUSDGWETHPool",
                      "RobinhoodTSLAUSDGPool",
                      "RobinhoodAMZNUSDGPool",
                      "RobinhoodPLTRUSDGPool",
                      "RobinhoodNFLXUSDGPool",
                      "RobinhoodAMDUSDGPool",
                  ].map((name) => byName.get(name))
                : [],
            poolInfo,
        },
        governor: {
            token: byName.get("YSToken"),
            timelock: byName.get("TimelockController"),
        },
        composite: {
            owner: byName.get("SplitRiskPoolFactory"),
            authorizedCallerCount: 0,
        },
        erc4626: {
            owner: byName.get("SplitRiskPoolFactory"),
            underlyingPriceOracle:
                oracleMode === "pyth"
                    ? byName.get("PythOracle")
                    : byName.get("ChainlinkOracleFeed"),
        },
        marketSessionGuardian:
            oracleMode === "chainlink" ? candidate.marketSessionGuardian : null,
        sequencer: {
            primaryOracleName:
                oracleMode === "pyth" ? "PythOracle" : "ChainlinkOracleFeed",
            primaryOracleFeed:
                oracleMode === "pyth" && chainId === ARBITRUM_MAINNET_CHAIN_ID
                    ? PYTH_MAINNET_SEQUENCER_FEED
                    : ZERO_ADDRESS,
            primaryOracleRequired:
                oracleMode === "pyth" && chainId === ARBITRUM_MAINNET_CHAIN_ID,
            erc4626Feed:
                oracleMode === "pyth" && chainId === ARBITRUM_MAINNET_CHAIN_ID
                    ? PYTH_MAINNET_SEQUENCER_FEED
                    : ZERO_ADDRESS,
            erc4626Required:
                oracleMode === "pyth" && chainId === ARBITRUM_MAINNET_CHAIN_ID,
        },
        oracleOwners:
            oracleMode === "pyth"
                ? { PythOracle: byName.get("SplitRiskPoolFactory") }
                : {
                      ChainlinkOracleFeed: byName.get("TimelockController"),
                      USMarketSessionGate: byName.get("TimelockController"),
                  },
        timelockRoles: {
            defaultAdmin: {
                count: 1,
                member: byName.get("TimelockController"),
            },
            proposer: { count: 1, member: byName.get("YSGovernor") },
            executor: { count: 1, member: byName.get("YSGovernor") },
            canceller: { count: 1, member: byName.get("YSGovernor") },
        },
    };
    return {
        ...module,
        broadcast,
        callBlockTags,
        candidate,
        chainId,
        codeBlockTags,
        env,
        liveReceipts,
        missingCode,
        provider,
        validationProvider,
        protocolState,
        runtimeCodehash,
        readProtocolState: async (scopedProvider) => {
            await scopedProvider.call({ data: "0x", to: addressFor(1) });
            return structuredClone(protocolState);
        },
    };
}

function writeAttempt(
    rootDir,
    candidate,
    broadcast,
    active = { sentinel: "previous-active" },
) {
    const candidateDir = join(rootDir, "deployments", ".candidates", CHAIN_ID);
    const broadcastDir = join(
        rootDir,
        "broadcast",
        "DeployYieldShieldProduction.s.sol",
        CHAIN_ID,
    );
    mkdirSync(candidateDir, { recursive: true });
    mkdirSync(broadcastDir, { recursive: true });
    writeFileSync(
        join(candidateDir, `${DEPLOYMENT_ID}.json`),
        JSON.stringify(candidate),
    );
    writeFileSync(
        join(broadcastDir, "run-latest.json"),
        JSON.stringify(broadcast),
    );
    writeFileSync(
        join(rootDir, "deployments", `${CHAIN_ID}.json`),
        JSON.stringify(active),
    );
}

function promotionArgs(rootDir, item, overrides = {}) {
    return {
        rootDir,
        chainId: item.chainId,
        deploymentId: DEPLOYMENT_ID,
        configurationDigest: CONFIGURATION_DIGEST,
        provider: item.provider,
        validationProvider: item.validationProvider,
        primaryRpcUrl: PRIMARY_RPC_URL,
        validationRpcUrl: VALIDATION_RPC_URL,
        readProtocolState: item.readProtocolState,
        env: item.env,
        now: () => new Date("2026-07-10T12:00:00.000Z"),
        ...overrides,
    };
}

function validationArgs(item, overrides = {}) {
    return {
        candidate: item.candidate,
        broadcast: item.broadcast,
        chainId: item.chainId,
        deploymentId: DEPLOYMENT_ID,
        configurationDigest: CONFIGURATION_DIGEST,
        provider: item.provider,
        validationProvider: item.validationProvider,
        primaryRpcUrl: PRIMARY_RPC_URL,
        validationRpcUrl: VALIDATION_RPC_URL,
        readProtocolState: item.readProtocolState,
        env: item.env,
        now: () => new Date("2026-07-10T12:00:00.000Z"),
        ...overrides,
    };
}

function configureSequencer(
    item,
    { source = "https://docs.example/feed" } = {},
) {
    const address = addressFor(950);
    const candidateSource =
        item.chainId === "46630" && source.trim().length === 0
            ? "operator-supplied-testnet-feed"
            : source;
    item.candidate.robinhoodSequencerUptimeFeed = address;
    item.candidate.robinhoodSequencerUptimeFeedSource = candidateSource;
    item.candidate.robinhoodSequencerUptimeFeedCodehash = item.runtimeCodehash;
    item.protocolState.sequencer = {
        primaryOracleName: "ChainlinkOracleFeed",
        primaryOracleFeed: address,
        primaryOracleRequired: true,
        erc4626Feed: address,
        erc4626Required: true,
    };
    if (item.chainId === "4663") {
        item.candidate.productionGuardMode = "strict";
        item.env.YS_ROBINHOOD_SEQUENCER_FEED = address;
        item.env.YS_ROBINHOOD_SEQUENCER_FEED_SOURCE = source;
        item.env.YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH = item.runtimeCodehash;
    } else {
        item.env.YS_ROBINHOOD_TESTNET_SEQUENCER_FEED = address;
        item.env.YS_ROBINHOOD_TESTNET_SEQUENCER_FEED_SOURCE = source;
    }
    return address;
}

function removeCreationEvidence(item, broadcast, deploymentName) {
    const address = Object.entries(item.candidate).find(
        ([, name]) => name === deploymentName,
    )[0];
    const transactionIndex = broadcast.transactions.findIndex(
        ({ contractAddress }) => contractAddress === address,
    );
    assert.notEqual(transactionIndex, -1);
    const [transaction] = broadcast.transactions.splice(transactionIndex, 1);
    const receiptIndex = broadcast.receipts.findIndex(
        ({ transactionHash }) => transactionHash === transaction.hash,
    );
    assert.notEqual(receiptIndex, -1);
    broadcast.receipts.splice(receiptIndex, 1);
    return { address, transaction };
}

test("complete generation promotes atomically and records exact demo fixture metadata", async (t) => {
    const item = await fixture({ demo: true });
    const rootDir = mkdtempSync(join(tmpdir(), "ys-manifest-success-"));
    t.after(() => rmSync(rootDir, { recursive: true, force: true }));
    writeAttempt(rootDir, item.candidate, item.broadcast);
    const feedIndex = new Map(
        Object.entries(item.DEMO_FEEDS).map(
            ([symbol, deploymentName], index) => [
                Object.entries(item.candidate)
                    .find(([, name]) => name === deploymentName)[0]
                    .toLowerCase(),
                { index, symbol },
            ],
        ),
    );

    const result = await item.promoteDeploymentManifest(
        promotionArgs(rootDir, item, {
            readFeed: async (_provider, address) => {
                const { index, symbol } = feedIndex.get(address.toLowerCase());
                return {
                    decimals: 8,
                    description: `${symbol} / USD`,
                    owner: DEPLOYER,
                    updatedAt: 1_000 + index,
                };
            },
        }),
    );

    assert.equal(result.manifest.status, "active");
    assert.equal(result.manifest.deploymentId, DEPLOYMENT_ID);
    assert.equal(result.manifest.transactionHashes[0], TX_HASH);
    assert.deepEqual(result.manifest.finalityEvidence, {
        blockHash: FINALIZED_BLOCK_HASH,
        blockNumber: FINALIZED_BLOCK_NUMBER.toString(),
        blockTag: "finalized",
        independentValidationRpc: true,
        policySchemaVersion: 2,
        rpcProviderOperators: {
            deployment: "deployment-operator",
            validation: "validation-operator",
        },
    });
    assert.deepEqual(result.manifest.sequencerUptimeFeedEvidence, {
        address: addressFor(0),
        mode: "robinhood-testnet-exception",
        reviewedCodehashPin: null,
        runtimeCodehash: `0x${"00".repeat(32)}`,
        source: "robinhood-testnet-relaxed-guards",
    });
    assert.ok(item.codeBlockTags.length > 0);
    assert.ok(
        item.codeBlockTags.every(
            (blockTag) => blockTag === FINALIZED_BLOCK_NUMBER,
        ),
    );
    assert.ok(item.callBlockTags.length > 0);
    assert.ok(
        item.callBlockTags.every(
            (blockTag) => blockTag === FINALIZED_BLOCK_NUMBER,
        ),
    );
    assert.equal(
        result.manifest.fixtureMetadata.robinhoodStandardMockFeeds.fixtureId,
        "robinhood-standard-mock-feeds-v1",
    );
    assert.equal(
        result.manifest.fixtureMetadata.robinhoodStandardMockFeeds.expiresAt,
        87_400,
    );
    assert.deepEqual(
        Object.keys(
            result.manifest.fixtureMetadata.robinhoodStandardMockFeeds.feeds,
        ),
        [
            "USDG",
            "WETH",
            "SGOV",
            "SPY",
            "QQQ",
            "TSLA",
            "AMZN",
            "PLTR",
            "NFLX",
            "AMD",
        ],
    );
    assert.equal(
        result.manifest.fixtureMetadata.robinhoodStandardMockFeeds
            .expectedOwner,
        DEPLOYER,
    );
    assert.match(
        result.manifest.fixtureMetadata.robinhoodStandardMockFeeds
            .expectedRuntimeCodehash,
        /^0x[0-9a-f]{64}$/u,
    );
    assert.deepEqual(
        JSON.parse(readFileSync(result.activePath)),
        result.manifest,
    );
    assert.deepEqual(
        JSON.parse(readFileSync(result.historyPath)),
        result.manifest,
    );
});

test("Robinhood mainnet promotion attests configured sequencer code and wiring at finalized state", async () => {
    const item = await fixture({ chainId: "4663" });
    configureSequencer(item);

    const manifest = await item.validateAndBuildManifest(validationArgs(item));

    assert.deepEqual(manifest.sequencerUptimeFeedEvidence, {
        address: "0x00000000000000000000000000000000000003B6",
        mode: "configured",
        reviewedCodehashPin: item.runtimeCodehash,
        runtimeCodehash: item.runtimeCodehash,
        source: "https://docs.example/feed",
    });
    assert.ok(item.codeBlockTags.length > 0);
    assert.ok(
        item.codeBlockTags.every(
            (blockTag) => blockTag === FINALIZED_BLOCK_NUMBER,
        ),
    );
    assert.ok(item.callBlockTags.length > 0);
    assert.ok(
        item.callBlockTags.every(
            (blockTag) => blockTag === FINALIZED_BLOCK_NUMBER,
        ),
    );
});

test("Robinhood mainnet promotion requires and enforces the reviewed sequencer codehash pin", async () => {
    const missing = await fixture({ chainId: "4663" });
    configureSequencer(missing);
    delete missing.env.YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH;
    await assert.rejects(
        missing.validateAndBuildManifest(validationArgs(missing)),
        /YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH is required/u,
    );

    const mismatched = await fixture({ chainId: "4663" });
    configureSequencer(mismatched);
    mismatched.env.YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH = `0x${"11".repeat(32)}`;
    await assert.rejects(
        mismatched.validateAndBuildManifest(validationArgs(mismatched)),
        /does not match the reviewed mainnet pin/u,
    );
});

test("sequencer attestation rejects finalized dual-RPC code and adapter-wiring disagreement", async () => {
    const codeMismatch = await fixture({ chainId: "4663" });
    const sequencerAddress = configureSequencer(codeMismatch);
    const validationProvider = {
        ...codeMismatch.validationProvider,
        async getCode(address, blockTag) {
            codeMismatch.codeBlockTags.push(blockTag);
            return address.toLowerCase() === sequencerAddress.toLowerCase()
                ? "0x6001"
                : "0x6000";
        },
    };
    await assert.rejects(
        codeMismatch.validateAndBuildManifest(
            validationArgs(codeMismatch, { validationProvider }),
        ),
        /disagree on finalized sequencer uptime feed code/u,
    );

    const wiringMismatch = await fixture({ chainId: "4663" });
    configureSequencer(wiringMismatch);
    wiringMismatch.protocolState.sequencer.erc4626Feed = addressFor(951);
    await assert.rejects(
        wiringMismatch.validateAndBuildManifest(validationArgs(wiringMismatch)),
        /ERC4626 sequencer uptime feed wiring mismatch/u,
    );
});

test("Robinhood testnet preserves both configured feeds and the explicit missing-feed exception without a mainnet pin", async () => {
    const configured = await fixture();
    configureSequencer(configured, { source: "" });
    const configuredManifest = await configured.validateAndBuildManifest(
        validationArgs(configured),
    );
    assert.deepEqual(configuredManifest.sequencerUptimeFeedEvidence, {
        address: "0x00000000000000000000000000000000000003B6",
        mode: "configured",
        reviewedCodehashPin: null,
        runtimeCodehash: configured.runtimeCodehash,
        source: "operator-supplied-testnet-feed",
    });

    const exception = await fixture();
    exception.candidate.productionGuardMode = "strict";
    exception.candidate.robinhoodSequencerUptimeFeedSource =
        "robinhood-testnet-explicit-exception";
    exception.env.YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED = "true";
    const exceptionManifest = await exception.validateAndBuildManifest(
        validationArgs(exception),
    );
    assert.equal(
        exceptionManifest.sequencerUptimeFeedEvidence.mode,
        "robinhood-testnet-exception",
    );
    assert.equal(
        exceptionManifest.sequencerUptimeFeedEvidence.reviewedCodehashPin,
        null,
    );
});

test("public promotion requires a distinct independent validation RPC", async () => {
    const item = await fixture();
    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, { validationRpcUrl: undefined }),
        ),
        /YS_DEPLOYMENT_VALIDATION_RPC_URL is required/u,
    );
    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                validationRpcUrl: `${PRIMARY_RPC_URL}/`,
            }),
        ),
        /host distinct/u,
    );
    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                validationRpcUrl:
                    "https://deployment-rpc.example/another-account",
            }),
        ),
        /host distinct/u,
    );
    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                validationProvider: item.provider,
            }),
        ),
        /independent deployment validation provider/u,
    );
});

test("public promotion requires distinct normalized RPC operator identities", async () => {
    const sameOperator = await fixture();
    sameOperator.env.YS_DEPLOYMENT_RPC_OPERATOR = " QuickNode ";
    sameOperator.env.YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR = "quicknode";
    await assert.rejects(
        sameOperator.validateAndBuildManifest(
            validationArgs(sameOperator, {
                primaryRpcUrl: "https://alpha.quiknode.pro/key-a",
                validationRpcUrl: "https://beta.quiknode.pro/key-b",
            }),
        ),
        /must identify an operator distinct/u,
    );

    const missingOperator = await fixture();
    delete missingOperator.env.YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR;
    await assert.rejects(
        missingOperator.validateAndBuildManifest(
            validationArgs(missingOperator),
        ),
        /YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR is required/u,
    );

    const malformedOperator = await fixture();
    malformedOperator.env.YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR =
        "https://validation.example/api-key";
    await assert.rejects(
        malformedOperator.validateAndBuildManifest(
            validationArgs(malformedOperator),
        ),
        /must be a 2-64 character lowercase operator slug/u,
    );
});

test("public promotion persists only normalized non-secret RPC operator slugs", async () => {
    const item = await fixture();
    item.env.YS_DEPLOYMENT_RPC_OPERATOR = " Alchemy ";
    item.env.YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR = "SELF-HOSTED-BERLIN";

    const manifest = await item.validateAndBuildManifest(validationArgs(item));

    assert.deepEqual(manifest.finalityEvidence.rpcProviderOperators, {
        deployment: "alchemy",
        validation: "self-hosted-berlin",
    });
    const serializedEvidence = JSON.stringify(manifest.finalityEvidence);
    assert.equal(serializedEvidence.includes(PRIMARY_RPC_URL), false);
    assert.equal(serializedEvidence.includes(VALIDATION_RPC_URL), false);
    assert.deepEqual(
        Object.keys(manifest.finalityEvidence.rpcProviderOperators).sort(),
        ["deployment", "validation"],
    );
});

test("promotion fails closed when RPCs disagree on finalized state", async () => {
    const item = await fixture();
    const validationProvider = {
        ...item.validationProvider,
        async send() {
            return {
                hash: `0x${"fb".repeat(32)}`,
                number: `0x${FINALIZED_BLOCK_NUMBER.toString(16)}`,
            };
        },
    };

    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, { validationProvider }),
        ),
        /disagree on the finalized block/u,
    );
});

test("head-only deployment state cannot be promoted", async () => {
    const item = await fixture();
    const headOnlyProvider = {
        ...item.provider,
        async getCode(_address, blockTag) {
            return blockTag === undefined ? "0x6000" : "0x";
        },
    };
    assert.equal(await headOnlyProvider.getCode(addressFor(1)), "0x6000");

    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, { provider: headOnlyProvider }),
        ),
        /No deployed code.*finalized state/u,
    );
});

test("promotion requires both RPCs to agree on finalized receipts", async () => {
    const item = await fixture();
    const validationProvider = {
        ...item.validationProvider,
        async getTransactionReceipt(hash) {
            const receipt =
                await item.validationProvider.getTransactionReceipt(hash);
            return { ...receipt, blockHash: `0x${"bd".repeat(32)}` };
        },
    };

    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, { validationProvider }),
        ),
        /disagree on transaction receipt/u,
    );
});

test("partial broadcast cannot replace the previous active manifest", async (t) => {
    const item = await fixture();
    item.broadcast.receipts = [];
    const rootDir = mkdtempSync(join(tmpdir(), "ys-manifest-partial-"));
    t.after(() => rmSync(rootDir, { recursive: true, force: true }));
    const previous = { sentinel: "keep-me" };
    writeAttempt(rootDir, item.candidate, item.broadcast, previous);

    await assert.rejects(
        item.promoteDeploymentManifest(promotionArgs(rootDir, item)),
        /receipt count/u,
    );
    assert.deepEqual(
        JSON.parse(
            readFileSync(join(rootDir, "deployments", `${CHAIN_ID}.json`)),
        ),
        previous,
    );
    assert.equal(
        existsSync(
            join(
                rootDir,
                "deployments",
                "history",
                CHAIN_ID,
                `${DEPLOYMENT_ID}.json`,
            ),
        ),
        false,
    );
});

test("candidate validation rejects wrong chain, deployer, digest, inventory, and missing code", async () => {
    const item = await fixture();
    const base = {
        candidate: item.candidate,
        broadcast: item.broadcast,
        chainId: CHAIN_ID,
        deploymentId: DEPLOYMENT_ID,
        configurationDigest: CONFIGURATION_DIGEST,
        provider: item.provider,
        validationProvider: item.validationProvider,
        primaryRpcUrl: PRIMARY_RPC_URL,
        validationRpcUrl: VALIDATION_RPC_URL,
        now: () => new Date("2026-07-10T12:00:00.000Z"),
        readProtocolState: item.readProtocolState,
        env: item.env,
    };

    await assert.rejects(
        item.validateAndBuildManifest({ ...base, chainId: "4663" }),
        /chain ID mismatch/u,
    );
    const wrongDeployer = structuredClone(item.broadcast);
    wrongDeployer.transactions[0].transaction.from = addressFor(999);
    await assert.rejects(
        item.validateAndBuildManifest({ ...base, broadcast: wrongDeployer }),
        /deployer/u,
    );
    await assert.rejects(
        item.validateAndBuildManifest({
            ...base,
            configurationDigest: `0x${"ef".repeat(32)}`,
        }),
        /digest/u,
    );
    const missingInventory = structuredClone(item.candidate);
    const factoryAddress = Object.entries(missingInventory).find(
        ([, name]) => name === "SplitRiskPoolFactory",
    )[0];
    delete missingInventory[factoryAddress];
    await assert.rejects(
        item.validateAndBuildManifest({ ...base, candidate: missingInventory }),
        /inventory mismatch/u,
    );
    item.missingCode.add(factoryAddress.toLowerCase());
    await assert.rejects(
        item.validateAndBuildManifest(base),
        /No deployed code/u,
    );
});

test("promotion requires and verifies every reviewed core runtime codehash pin", async () => {
    for (const oracleMode of ["chainlink", "pyth"]) {
        const item = await fixture({ oracleMode });
        const specs = item.reviewedCodehashPinSpecs(oracleMode);

        for (const [name, envName] of specs) {
            const missingEnv = { ...item.env };
            delete missingEnv[envName];
            await assert.rejects(
                item.validateAndBuildManifest(
                    validationArgs(item, { env: missingEnv }),
                ),
                new RegExp(`${envName} is required`, "u"),
                `${name} accepted without ${envName}`,
            );

            const mismatchedEnv = {
                ...item.env,
                [envName]: `0x${"ff".repeat(32)}`,
            };
            await assert.rejects(
                item.validateAndBuildManifest(
                    validationArgs(item, { env: mismatchedEnv }),
                ),
                new RegExp(`${name} runtime codehash does not match`, "u"),
                `${name} accepted a mismatched reviewed pin`,
            );
        }
    }
});

test("demo fixture metadata rejects an unexpected feed owner", async () => {
    const item = await fixture({ demo: true });
    await assert.rejects(
        item.validateAndBuildManifest({
            candidate: item.candidate,
            broadcast: item.broadcast,
            chainId: CHAIN_ID,
            deploymentId: DEPLOYMENT_ID,
            configurationDigest: CONFIGURATION_DIGEST,
            provider: item.provider,
            validationProvider: item.validationProvider,
            primaryRpcUrl: PRIMARY_RPC_URL,
            validationRpcUrl: VALIDATION_RPC_URL,
            env: item.env,
            readProtocolState: item.readProtocolState,
            readFeed: async () => ({
                decimals: 8,
                description: "USDG / USD",
                owner: addressFor(999),
                updatedAt: 1_000,
            }),
        }),
        /owner does not match/u,
    );
});

test("live protocol wiring mismatch preserves the previous active manifest", async (t) => {
    const item = await fixture();
    const rootDir = mkdtempSync(join(tmpdir(), "ys-manifest-wiring-"));
    t.after(() => rmSync(rootDir, { recursive: true, force: true }));
    const previous = { sentinel: "validated-previous-generation" };
    const wrongState = structuredClone(item.protocolState);
    wrongState.factory.owner = addressFor(999);
    writeAttempt(rootDir, item.candidate, item.broadcast, previous);

    await assert.rejects(
        item.promoteDeploymentManifest(
            promotionArgs(rootDir, item, {
                readProtocolState: async () => wrongState,
            }),
        ),
        /Factory owner wiring mismatch/u,
    );
    assert.deepEqual(
        JSON.parse(
            readFileSync(join(rootDir, "deployments", `${CHAIN_ID}.json`)),
        ),
        previous,
    );
});

test("timelock roles must each have their sole expected member", async () => {
    const item = await fixture();
    const wrongState = structuredClone(item.protocolState);
    wrongState.timelockRoles.proposer.count = 2;

    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                readProtocolState: async () => wrongState,
            }),
        ),
        /Timelock proposer role topology mismatch/u,
    );
});

test("market session guardian metadata must be distinct and match live wiring", async () => {
    const item = await fixture();
    const timelock = Object.entries(item.candidate).find(
        ([, name]) => name === "TimelockController",
    )[0];
    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                candidate: {
                    ...item.candidate,
                    marketSessionGuardian: timelock,
                },
            }),
        ),
        /invalid marketSessionGuardian/u,
    );

    const wrongState = structuredClone(item.protocolState);
    wrongState.marketSessionGuardian = addressFor(901);
    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                readProtocolState: async () => wrongState,
            }),
        ),
        /emergency guardian wiring mismatch/u,
    );
});

test("Pyth mode requires ERC4626 to use the Pyth oracle", async () => {
    const item = await fixture({ oracleMode: "pyth" });
    const wrongState = structuredClone(item.protocolState);
    wrongState.erc4626.underlyingPriceOracle = addressFor(999);

    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                readProtocolState: async () => wrongState,
            }),
        ),
        /ERC4626 underlying oracle wiring mismatch/u,
    );
});

test("Arbitrum Sepolia Pyth promotion attests the explicit disabled sequencer exception", async () => {
    const item = await fixture({
        chainId: ARBITRUM_SEPOLIA_CHAIN_ID,
        oracleMode: "pyth",
    });

    const manifest = await item.validateAndBuildManifest(validationArgs(item));

    assert.deepEqual(manifest.pythSequencerUptimeGuardEvidence, {
        erc4626Required: false,
        feed: ZERO_ADDRESS,
        mode: "disabled-no-canonical-feed",
        primaryOracle: "PythOracle",
        primaryOracleRequired: false,
        runtimeCodehash: `0x${"00".repeat(32)}`,
        source: "chainlink-no-arbitrum-sepolia-sequencer-feed",
    });
});

test("Arbitrum Sepolia Pyth promotion rejects missing, wrong, or enabled sequencer wiring", async () => {
    const missing = await fixture({ oracleMode: "pyth" });
    missing.protocolState.sequencer = null;
    await assert.rejects(
        missing.validateAndBuildManifest(validationArgs(missing)),
        /Pyth sequencer uptime wiring evidence is missing/u,
    );

    const wrongFeed = await fixture({ oracleMode: "pyth" });
    wrongFeed.protocolState.sequencer.primaryOracleFeed = addressFor(950);
    await assert.rejects(
        wrongFeed.validateAndBuildManifest(validationArgs(wrongFeed)),
        /Pyth sequencer uptime feed wiring mismatch/u,
    );

    const unexpectedlyRequired = await fixture({ oracleMode: "pyth" });
    unexpectedlyRequired.protocolState.sequencer.erc4626Required = true;
    await assert.rejects(
        unexpectedlyRequired.validateAndBuildManifest(
            validationArgs(unexpectedlyRequired),
        ),
        /Pyth sequencer uptime requirement wiring mismatch/u,
    );
});

test("Arbitrum mainnet Pyth promotion requires the exact documented feed on both adapters", async () => {
    const item = await fixture({
        chainId: ARBITRUM_MAINNET_CHAIN_ID,
        oracleMode: "pyth",
    });

    const manifest = await item.validateAndBuildManifest(validationArgs(item));
    assert.deepEqual(manifest.pythSequencerUptimeGuardEvidence, {
        erc4626Required: true,
        feed: PYTH_MAINNET_SEQUENCER_FEED,
        mode: "configured",
        primaryOracle: "PythOracle",
        primaryOracleRequired: true,
        runtimeCodehash: item.runtimeCodehash,
        source: "https://docs.chain.link/data-feeds/l2-sequencer-feeds",
    });

    const missingFeed = await fixture({
        chainId: ARBITRUM_MAINNET_CHAIN_ID,
        oracleMode: "pyth",
    });
    missingFeed.protocolState.sequencer.primaryOracleFeed = ZERO_ADDRESS;
    await assert.rejects(
        missingFeed.validateAndBuildManifest(validationArgs(missingFeed)),
        /Pyth sequencer uptime feed wiring mismatch/u,
    );

    const wrongAdapter = await fixture({
        chainId: ARBITRUM_MAINNET_CHAIN_ID,
        oracleMode: "pyth",
    });
    wrongAdapter.protocolState.sequencer.erc4626Feed = addressFor(951);
    await assert.rejects(
        wrongAdapter.validateAndBuildManifest(validationArgs(wrongAdapter)),
        /ERC4626 sequencer uptime feed wiring mismatch/u,
    );

    const disabled = await fixture({
        chainId: ARBITRUM_MAINNET_CHAIN_ID,
        oracleMode: "pyth",
    });
    disabled.protocolState.sequencer.primaryOracleRequired = false;
    await assert.rejects(
        disabled.validateAndBuildManifest(validationArgs(disabled)),
        /Pyth sequencer uptime requirement wiring mismatch/u,
    );
});

test("Arbitrum mainnet Pyth promotion rejects missing or disagreeing finalized sequencer code", async () => {
    const missingCode = await fixture({
        chainId: ARBITRUM_MAINNET_CHAIN_ID,
        oracleMode: "pyth",
    });
    missingCode.missingCode.add(PYTH_MAINNET_SEQUENCER_FEED.toLowerCase());
    await assert.rejects(
        missingCode.validateAndBuildManifest(validationArgs(missingCode)),
        /No Pyth sequencer uptime feed code/u,
    );

    const codeMismatch = await fixture({
        chainId: ARBITRUM_MAINNET_CHAIN_ID,
        oracleMode: "pyth",
    });
    const originalValidationGetCode =
        codeMismatch.validationProvider.getCode.bind(
            codeMismatch.validationProvider,
        );
    const validationProvider = {
        ...codeMismatch.validationProvider,
        async getCode(address, blockTag) {
            if (
                address.toLowerCase() ===
                PYTH_MAINNET_SEQUENCER_FEED.toLowerCase()
            ) {
                return "0x6001";
            }
            return originalValidationGetCode(address, blockTag);
        },
    };
    await assert.rejects(
        codeMismatch.validateAndBuildManifest(
            validationArgs(codeMismatch, { validationProvider }),
        ),
        /disagree on finalized Pyth sequencer uptime feed code/u,
    );
});

test("demo promotion rejects wrong feed descriptions and token identities", async () => {
    const item = await fixture({ demo: true });
    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                readFeed: async () => ({
                    decimals: 8,
                    description: "not-the-symbol / USD",
                    owner: DEPLOYER,
                    updatedAt: 1_000,
                }),
            }),
        ),
        /description mismatch/u,
    );

    const wrongState = structuredClone(item.protocolState);
    wrongState.factory.whitelistedTokens.pop();
    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                readProtocolState: async () => wrongState,
            }),
        ),
        /demo token identity mismatch/u,
    );
});

test("relaxed guards and demo mode are rejected outside Robinhood", async () => {
    const item = await fixture();
    const candidate = { ...item.candidate, chainId: "1" };
    const broadcast = { ...item.broadcast, chain: "1" };

    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                broadcast,
                candidate,
                chainId: "1",
            }),
        ),
        /only on chain 46630/u,
    );
});

test("Chainlink production mode is rejected outside Robinhood chains", async () => {
    const item = await fixture();
    const candidate = {
        ...item.candidate,
        chainId: "1",
        productionGuardMode: "strict",
    };
    const broadcast = { ...item.broadcast, chain: "1" };
    const provider = {
        ...item.provider,
        async getNetwork() {
            return { chainId: 1n };
        },
    };

    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                broadcast,
                candidate,
                chainId: "1",
                provider,
            }),
        ),
        /Chainlink production mode is valid only on Robinhood chain IDs 4663 and 46630/u,
    );
});

test("Chainlink production mode accepts Robinhood mainnet", async () => {
    const item = await fixture({ chainId: "4663" });
    configureSequencer(item);

    const manifest = await item.validateAndBuildManifest(validationArgs(item));
    assert.equal(manifest.chainId, "4663");
});

test("additional-contract metadata cannot bind an address to a deployment generation", async () => {
    const item = await fixture();
    const broadcast = structuredClone(item.broadcast);
    const { address } = removeCreationEvidence(
        item,
        broadcast,
        "CompositeOracle",
    );
    broadcast.transactions[0].additionalContracts = [
        { address, name: "CompositeOracle" },
    ];

    await assert.rejects(
        item.validateAndBuildManifest(validationArgs(item, { broadcast })),
        /CompositeOracle is not tied/u,
    );

    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                broadcast,
                candidate: { ...item.candidate, recovery: "true" },
            }),
        ),
        /CompositeOracle is not tied/u,
    );
});

test("CALL targets cannot bind an address to a deployment generation", async () => {
    const item = await fixture();
    const broadcast = structuredClone(item.broadcast);
    const { address, transaction } = removeCreationEvidence(
        item,
        broadcast,
        "CompositeOracle",
    );
    transaction.transactionType = "CALL";
    transaction.contractAddress = address;
    broadcast.transactions.push(transaction);
    broadcast.receipts.push({
        status: "0x1",
        transactionHash: transaction.hash,
    });
    item.liveReceipts.set(transaction.hash, {
        blockHash: RECEIPT_BLOCK_HASH,
        blockNumber: FINALIZED_BLOCK_NUMBER - 1n,
        from: DEPLOYER,
        status: 1,
        transactionHash: transaction.hash,
    });

    await assert.rejects(
        item.validateAndBuildManifest(validationArgs(item, { broadcast })),
        /CompositeOracle is not tied/u,
    );
});

test("CREATE provenance must match a live receipt contract address", async () => {
    const item = await fixture();
    const creationHash = item.broadcast.transactions[0].hash;
    const originalGetReceipt = item.provider.getTransactionReceipt.bind(
        item.provider,
    );
    const providerWithoutAddress = {
        ...item.provider,
        async getTransactionReceipt(hash) {
            const receipt = await originalGetReceipt(hash);
            return hash === creationHash
                ? { ...receipt, contractAddress: null }
                : receipt;
        },
    };
    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                provider: providerWithoutAddress,
                validationProvider: { ...providerWithoutAddress },
            }),
        ),
        /missing a valid contract address/u,
    );

    const providerWithMismatch = {
        ...item.provider,
        async getTransactionReceipt(hash) {
            const receipt = await originalGetReceipt(hash);
            return hash === creationHash
                ? { ...receipt, contractAddress: addressFor(999) }
                : receipt;
        },
    };
    await assert.rejects(
        item.validateAndBuildManifest(
            validationArgs(item, {
                provider: providerWithMismatch,
                validationProvider: { ...providerWithMismatch },
            }),
        ),
        /creation address does not match/u,
    );
});

test("atomic rename failure preserves the active manifest", async (t) => {
    const item = await fixture();
    const rootDir = mkdtempSync(join(tmpdir(), "ys-manifest-atomic-"));
    t.after(() => rmSync(rootDir, { recursive: true, force: true }));
    const previous = { sentinel: "still-active" };
    writeAttempt(rootDir, item.candidate, item.broadcast, previous);
    const fs = {
        existsSync,
        mkdirSync,
        readFileSync,
        rmSync,
        writeFileSync,
        renameSync() {
            throw new Error("injected rename failure");
        },
    };

    await assert.rejects(
        item.promoteDeploymentManifest(promotionArgs(rootDir, item, { fs })),
        /injected rename failure/u,
    );
    assert.deepEqual(
        JSON.parse(
            readFileSync(join(rootDir, "deployments", `${CHAIN_ID}.json`)),
        ),
        previous,
    );
});

test("same-generation recovery is idempotent and history collisions fail", async (t) => {
    const item = await fixture();
    const rootDir = mkdtempSync(join(tmpdir(), "ys-manifest-recovery-"));
    t.after(() => rmSync(rootDir, { recursive: true, force: true }));
    writeAttempt(rootDir, item.candidate, item.broadcast);
    const args = promotionArgs(rootDir, item);
    const first = await item.promoteDeploymentManifest(args);
    const second = await item.promoteDeploymentManifest(args);
    assert.deepEqual(second.manifest, first.manifest);

    const changedCandidate = structuredClone(item.candidate);
    const oldAddress = Object.entries(changedCandidate).find(
        ([, name]) => name === "CompositeOracle",
    )[0];
    const changedAddress = addressFor(500);
    delete changedCandidate[oldAddress];
    changedCandidate[changedAddress] = "CompositeOracle";
    const changedBroadcast = structuredClone(item.broadcast);
    const compositeTransaction = changedBroadcast.transactions.find(
        ({ contractAddress }) => contractAddress === oldAddress,
    );
    compositeTransaction.contractAddress = changedAddress;
    const compositeReceipt = changedBroadcast.receipts.find(
        ({ transactionHash }) => transactionHash === compositeTransaction.hash,
    );
    compositeReceipt.contractAddress = changedAddress;
    item.liveReceipts.set(compositeTransaction.hash, {
        blockHash: RECEIPT_BLOCK_HASH,
        blockNumber: FINALIZED_BLOCK_NUMBER - 1n,
        contractAddress: changedAddress,
        from: DEPLOYER,
        status: 1,
        transactionHash: compositeTransaction.hash,
    });
    const changedProtocolState = structuredClone(item.protocolState);
    changedProtocolState.factory.compositeOracle = changedAddress;
    writeAttempt(rootDir, changedCandidate, changedBroadcast, first.manifest);
    await assert.rejects(
        item.promoteDeploymentManifest({
            ...args,
            readProtocolState: async () => changedProtocolState,
        }),
        /history collision/u,
    );
});

test("same-generation recovery preserves fresh fixture health without rewriting history", async (t) => {
    const item = await fixture({ demo: true });
    const rootDir = mkdtempSync(join(tmpdir(), "ys-manifest-fresh-recovery-"));
    t.after(() => rmSync(rootDir, { recursive: true, force: true }));
    writeAttempt(rootDir, item.candidate, item.broadcast);

    const feedIndex = new Map(
        Object.entries(item.DEMO_FEEDS).map(
            ([symbol, deploymentName], index) => [
                Object.entries(item.candidate)
                    .find(([, name]) => name === deploymentName)[0]
                    .toLowerCase(),
                { index, symbol },
            ],
        ),
    );
    const readFeedAt = (startingTimestamp) => async (_provider, address) => {
        const { index, symbol } = feedIndex.get(address.toLowerCase());
        return {
            decimals: 8,
            description: `${symbol} / USD`,
            owner: DEPLOYER,
            updatedAt: startingTimestamp + index,
        };
    };

    const first = await item.promoteDeploymentManifest(
        promotionArgs(rootDir, item, {
            now: () => new Date("2026-07-10T12:00:00.000Z"),
            readFeed: readFeedAt(1_000),
        }),
    );
    const historicalContents = readFileSync(first.historyPath, "utf8");
    assert.equal(
        first.manifest.fixtureMetadata.robinhoodStandardMockFeeds.expiresAt,
        87_400,
    );

    const second = await item.promoteDeploymentManifest(
        promotionArgs(rootDir, item, {
            now: () => new Date("2026-07-11T12:00:00.000Z"),
            readFeed: readFeedAt(2_000),
        }),
    );

    assert.equal(second.manifest.validatedAt, "2026-07-11T12:00:00.000Z");
    assert.equal(
        second.manifest.fixtureMetadata.robinhoodStandardMockFeeds.expiresAt,
        88_400,
    );
    assert.deepEqual(
        JSON.parse(readFileSync(second.activePath, "utf8")),
        second.manifest,
    );
    assert.equal(readFileSync(second.historyPath, "utf8"), historicalContents);
    assert.deepEqual(
        JSON.parse(readFileSync(second.historyPath, "utf8")),
        first.manifest,
    );
});

test("deployment workflow promotes the manifest before ABI generation", () => {
    const makefile = readFileSync(
        join(__dirname, "..", "..", "Makefile"),
        "utf8",
    );
    const promotionIndex = makefile.indexOf("finalizeDeploymentManifest.js");
    const abiIndex = makefile.indexOf(
        'DEPLOY_CHAIN_ID="$$DEPLOY_CHAIN_ID" node scripts-js/generateTsAbis.js',
    );

    assert.notEqual(promotionIndex, -1);
    assert.notEqual(abiIndex, -1);
    assert.ok(promotionIndex < abiIndex);
});
