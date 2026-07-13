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

async function fixture({ demo = false, oracleMode = "chainlink" } = {}) {
    const module = await import("../finalizeDeploymentManifest.js");
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
        chainId: CHAIN_ID,
        deployer: DEPLOYER,
        configurationDigest: CONFIGURATION_DIGEST,
        networkName: "robinhood-testnet",
        robinhoodDemoAssetsEnabled: demo ? "true" : "false",
        productionGuardMode: "relaxed",
        recovery: "false",
    };
    names.forEach((name, index) => {
        candidate[addressFor(index + 1)] = name;
    });
    if (oracleMode === "chainlink") {
        candidate.marketSessionGuardian = addressFor(900);
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
            { contractAddress, from: DEPLOYER, status: 1 },
        ]),
    );
    const broadcast = {
        chain: CHAIN_ID,
        transactions,
        receipts,
        pending: [],
    };
    const missingCode = new Set();
    const provider = {
        async getNetwork() {
            return { chainId: BigInt(CHAIN_ID) };
        },
        async getTransactionReceipt(hash) {
            return liveReceipts.get(hash) || null;
        },
        async getCode(address) {
            return missingCode.has(address.toLowerCase()) ? "0x" : "0x6000";
        },
    };
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
        candidate,
        liveReceipts,
        missingCode,
        provider,
        protocolState,
        readProtocolState: async () => structuredClone(protocolState),
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
        chainId: CHAIN_ID,
        deploymentId: DEPLOYMENT_ID,
        configurationDigest: CONFIGURATION_DIGEST,
        provider: item.provider,
        readProtocolState: item.readProtocolState,
        now: () => new Date("2026-07-10T12:00:00.000Z"),
        ...overrides,
    };
}

function validationArgs(item, overrides = {}) {
    return {
        candidate: item.candidate,
        broadcast: item.broadcast,
        chainId: CHAIN_ID,
        deploymentId: DEPLOYMENT_ID,
        configurationDigest: CONFIGURATION_DIGEST,
        provider: item.provider,
        readProtocolState: item.readProtocolState,
        now: () => new Date("2026-07-10T12:00:00.000Z"),
        ...overrides,
    };
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
        now: () => new Date("2026-07-10T12:00:00.000Z"),
        readProtocolState: item.readProtocolState,
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
    const item = await fixture();
    const candidate = {
        ...item.candidate,
        chainId: "4663",
        productionGuardMode: "strict",
    };
    const broadcast = { ...item.broadcast, chain: "4663" };
    const provider = {
        ...item.provider,
        async getNetwork() {
            return { chainId: 4663n };
        },
    };

    const manifest = await item.validateAndBuildManifest(
        validationArgs(item, {
            broadcast,
            candidate,
            chainId: "4663",
            provider,
        }),
    );
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
        from: DEPLOYER,
        status: 1,
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
            validationArgs(item, { provider: providerWithoutAddress }),
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
            validationArgs(item, { provider: providerWithMismatch }),
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
        contractAddress: changedAddress,
        from: DEPLOYER,
        status: 1,
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
