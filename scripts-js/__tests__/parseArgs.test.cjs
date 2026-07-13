const assert = require("node:assert/strict");
const { test } = require("node:test");

const COMMON_RUNTIME_PIN_NAMES = [
    "YS_PRODUCTION_FACTORY_PROXY_CODEHASH",
    "YS_PRODUCTION_FACTORY_IMPLEMENTATION_CODEHASH",
    "YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH",
    "YS_PRODUCTION_YS_TOKEN_CODEHASH",
    "YS_PRODUCTION_TIMELOCK_CODEHASH",
    "YS_PRODUCTION_GOVERNOR_CODEHASH",
    "YS_PRODUCTION_COMPOSITE_ORACLE_CODEHASH",
    "YS_PRODUCTION_ERC4626_ORACLE_CODEHASH",
];
const CHAINLINK_RUNTIME_PIN_NAMES = [
    "YS_PRODUCTION_CHAINLINK_ORACLE_CODEHASH",
    "YS_PRODUCTION_US_MARKET_SESSION_GATE_CODEHASH",
];
const RUNTIME_PIN_ENV = Object.fromEntries(
    [...COMMON_RUNTIME_PIN_NAMES, ...CHAINLINK_RUNTIME_PIN_NAMES].map(
        (name, index) => [
            name,
            `0x${(index + 1).toString(16).padStart(64, "0")}`,
        ],
    ),
);

test("parseCliArgs parses public-network deploy options", async () => {
    const { parseCliArgs } = await import("../parseArgs.js");

    assert.deepEqual(
        parseCliArgs(["--network", "robinhoodTestnet", "--keystore", "test"]),
        {
            fileName: "Deploy.s.sol",
            fileWasProvided: false,
            help: false,
            keystoreArg: "test",
            network: "robinhoodTestnet",
        },
    );
});

test("parseCliArgs rejects positional arguments left by broken arg forwarding", async () => {
    const { parseCliArgs } = await import("../parseArgs.js");

    assert.throws(
        () => parseCliArgs(["robinhoodTestnet", "test"]),
        /Unexpected argument 'robinhoodTestnet'/u,
    );
});

test("resolveDeployScript defaults public networks to production deploy script", async () => {
    const { resolveDeployScript } = await import("../parseArgs.js");

    assert.deepEqual(
        resolveDeployScript({
            fileName: "Deploy.s.sol",
            fileWasProvided: false,
            network: "robinhoodTestnet",
        }),
        {
            fileName: "DeployYieldShieldProduction.s.sol",
            defaultedToProduction: true,
        },
    );
});

test("resolveDeployScript keeps explicit local scripts local-only", async () => {
    const { resolveDeployScript } = await import("../parseArgs.js");

    assert.throws(
        () =>
            resolveDeployScript({
                fileName: "Deploy.s.sol",
                fileWasProvided: true,
                network: "robinhoodTestnet",
            }),
        /local-only entrypoint/u,
    );
});

test("configuredKeystore prefers network-specific env defaults", async () => {
    const { configuredKeystore, keystoreEnvNames, networkEnvPrefix } =
        await import("../parseArgs.js");

    assert.equal(networkEnvPrefix("robinhoodTestnet"), "ROBINHOOD_TESTNET");
    assert.deepEqual(keystoreEnvNames("robinhoodTestnet"), [
        "ROBINHOOD_TESTNET_KEYSTORE_ACCOUNT",
        "ETH_KEYSTORE_ACCOUNT",
    ]);
    assert.deepEqual(
        configuredKeystore(
            { keystoreArg: null, network: "robinhoodTestnet" },
            {
                ETH_KEYSTORE_ACCOUNT: "fallback",
                ROBINHOOD_TESTNET_KEYSTORE_ACCOUNT: "test",
            },
        ),
        {
            keystoreName: "test",
            source: "ROBINHOOD_TESTNET_KEYSTORE_ACCOUNT",
        },
    );
});

test("missingProductionEnv keeps reviewed runtime pins mandatory in relaxed Robinhood mode", async () => {
    const { missingProductionEnv, usesRelaxedRobinhoodTestnetGuards } =
        await import("../parseArgs.js");

    assert.equal(
        usesRelaxedRobinhoodTestnetGuards("robinhoodTestnet", {}),
        true,
    );
    assert.deepEqual(
        missingProductionEnv(
            {
                fileName: "DeployYieldShieldProduction.s.sol",
                network: "robinhoodTestnet",
            },
            {},
        ),
        [
            ...COMMON_RUNTIME_PIN_NAMES,
            ...CHAINLINK_RUNTIME_PIN_NAMES,
            "YS_PRODUCTION_MARKET_SESSION_GUARDIAN",
        ],
    );
    assert.deepEqual(
        missingProductionEnv(
            {
                fileName: "DeployYieldShieldProduction.s.sol",
                network: "robinhoodTestnet",
            },
            {
                ...RUNTIME_PIN_ENV,
                YS_PRODUCTION_MARKET_SESSION_GUARDIAN:
                    "0x0000000000000000000000000000000000000009",
            },
        ),
        [],
    );
});

test("missingProductionEnv keeps Robinhood testnet strict mode fail-closed", async () => {
    const { missingProductionEnv, usesRelaxedRobinhoodTestnetGuards } =
        await import("../parseArgs.js");
    const env = {
        YS_ROBINHOOD_TESTNET_STRICT_PRODUCTION_GUARDS: "true",
    };

    assert.equal(
        usesRelaxedRobinhoodTestnetGuards("robinhoodTestnet", env),
        false,
    );
    assert.deepEqual(
        missingProductionEnv(
            {
                fileName: "DeployYieldShieldProduction.s.sol",
                network: "robinhoodTestnet",
            },
            env,
        ),
        [
            "YS_PRODUCTION_BOOTSTRAP_HOLDER",
            "YS_PRODUCTION_BOOTSTRAP_HOLDER_CODEHASH",
            "YS_PRODUCTION_BOOTSTRAP_HOLDER_SINGLETON",
            "YS_PRODUCTION_BOOTSTRAP_HOLDER_THRESHOLD",
            "YS_PRODUCTION_BOOTSTRAP_HOLDER_OWNERS_HASH",
            ...COMMON_RUNTIME_PIN_NAMES,
            ...CHAINLINK_RUNTIME_PIN_NAMES,
            "YS_PRODUCTION_MARKET_SESSION_GUARDIAN",
            "YS_ROBINHOOD_TESTNET_SEQUENCER_FEED or YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED=true",
        ],
    );
});

test("missingProductionEnv limits the missing-sequencer exception to Robinhood testnet", async () => {
    const { missingProductionEnv } = await import("../parseArgs.js");
    const productionEnv = {
        ...RUNTIME_PIN_ENV,
        YS_PRODUCTION_BOOTSTRAP_HOLDER:
            "0x0000000000000000000000000000000000000001",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_CODEHASH: `0x${"11".repeat(32)}`,
        YS_PRODUCTION_BOOTSTRAP_HOLDER_SINGLETON:
            "0x0000000000000000000000000000000000000002",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_THRESHOLD: "2",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_OWNERS_HASH: `0x${"22".repeat(32)}`,
        YS_PRODUCTION_FACTORY_IMPLEMENTATION_CODEHASH: `0x${"33".repeat(32)}`,
        YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH: `0x${"44".repeat(32)}`,
        YS_PRODUCTION_CHAINLINK_ORACLE_CODEHASH: `0x${"55".repeat(32)}`,
        YS_PRODUCTION_MARKET_SESSION_GUARDIAN:
            "0x0000000000000000000000000000000000000009",
        YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED: "true",
    };
    const productionDeploy = {
        fileName: "DeployYieldShieldProduction.s.sol",
    };

    assert.deepEqual(
        missingProductionEnv(
            { ...productionDeploy, network: "robinhoodTestnet" },
            {
                ...productionEnv,
                YS_ROBINHOOD_TESTNET_STRICT_PRODUCTION_GUARDS: "true",
            },
        ),
        [],
    );
    assert.deepEqual(
        missingProductionEnv(
            { ...productionDeploy, network: "robinhood" },
            productionEnv,
        ),
        [
            "YS_ROBINHOOD_SEQUENCER_FEED",
            "YS_ROBINHOOD_SEQUENCER_FEED_SOURCE",
            "YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH",
        ],
    );
});

test("missingProductionEnv requires nonblank mainnet sequencer provenance", async () => {
    const { missingProductionEnv } = await import("../parseArgs.js");
    const env = {
        ...RUNTIME_PIN_ENV,
        YS_PRODUCTION_BOOTSTRAP_HOLDER:
            "0x0000000000000000000000000000000000000001",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_CODEHASH: `0x${"11".repeat(32)}`,
        YS_PRODUCTION_BOOTSTRAP_HOLDER_SINGLETON:
            "0x0000000000000000000000000000000000000002",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_THRESHOLD: "2",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_OWNERS_HASH: `0x${"22".repeat(32)}`,
        YS_PRODUCTION_FACTORY_IMPLEMENTATION_CODEHASH: `0x${"33".repeat(32)}`,
        YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH: `0x${"44".repeat(32)}`,
        YS_PRODUCTION_CHAINLINK_ORACLE_CODEHASH: `0x${"55".repeat(32)}`,
        YS_PRODUCTION_MARKET_SESSION_GUARDIAN:
            "0x0000000000000000000000000000000000000009",
        YS_ROBINHOOD_SEQUENCER_FEED:
            "0x0000000000000000000000000000000000000003",
        YS_ROBINHOOD_SEQUENCER_FEED_SOURCE: "   ",
    };
    const request = {
        fileName: "DeployYieldShieldProduction.s.sol",
        network: "robinhood",
    };

    assert.deepEqual(missingProductionEnv(request, env), [
        "YS_ROBINHOOD_SEQUENCER_FEED_SOURCE",
        "YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH",
    ]);
    assert.deepEqual(
        missingProductionEnv(request, {
            ...env,
            YS_ROBINHOOD_SEQUENCER_FEED_SOURCE:
                "https://docs.example/sequencer-feed",
            YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH: `0x${"66".repeat(32)}`,
        }),
        [],
    );
});

test("missingProductionEnv requires explicit Arbitrum Pyth updater acceptance", async () => {
    const { missingProductionEnv } = await import("../parseArgs.js");
    const request = {
        fileName: "DeployYieldShieldProduction.s.sol",
        network: "arbitrum",
    };
    const env = {
        ...RUNTIME_PIN_ENV,
        YS_PRODUCTION_BOOTSTRAP_HOLDER:
            "0x0000000000000000000000000000000000000001",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_CODEHASH: `0x${"11".repeat(32)}`,
        YS_PRODUCTION_BOOTSTRAP_HOLDER_SINGLETON:
            "0x0000000000000000000000000000000000000002",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_THRESHOLD: "2",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_OWNERS_HASH: `0x${"22".repeat(32)}`,
        YS_PRODUCTION_PYTH_ORACLE_CODEHASH: `0x${"33".repeat(32)}`,
    };

    for (const value of [undefined, "false", "garbage", "1"]) {
        assert.deepEqual(
            missingProductionEnv(request, {
                ...env,
                YS_PRODUCTION_PYTH_UPDATER_CONFIRMED: value,
            }),
            ["YS_PRODUCTION_PYTH_UPDATER_CONFIRMED=true"],
        );
    }

    assert.deepEqual(
        missingProductionEnv(request, {
            ...env,
            YS_PRODUCTION_PYTH_UPDATER_CONFIRMED: " TRUE ",
        }),
        [],
    );
    assert.equal(
        missingProductionEnv(
            { ...request, network: "arbitrumSepolia" },
            env,
        ).includes("YS_PRODUCTION_PYTH_UPDATER_CONFIRMED=true"),
        false,
    );
});

test("Robinhood testnet deployment mode keeps demo seeding off by default", async () => {
    const {
        formatRobinhoodProductionDeploymentMode,
        robinhoodProductionDeploymentMode,
    } = await import("../parseArgs.js");
    const mode = robinhoodProductionDeploymentMode(
        {
            fileName: "DeployYieldShieldProduction.s.sol",
            network: "robinhoodTestnet",
        },
        {},
    );

    assert.deepEqual(mode, {
        codeSizeOverride: true,
        demoAssetsEnabled: false,
        demoAssetsSelection: "default-off",
        guardMode: "relaxed",
        network: "robinhoodTestnet",
        sequencerMode: "relaxed-testnet-exception",
    });
    assert.match(
        formatRobinhoodProductionDeploymentMode(mode),
        /Demo seeding: disabled \(default; explicit opt-in required\)/u,
    );
});

test("Robinhood testnet deployment mode reports explicit demo and strict settings", async () => {
    const { robinhoodProductionDeploymentMode } =
        await import("../parseArgs.js");
    const request = {
        fileName: "DeployYieldShieldProduction.s.sol",
        network: "robinhoodTestnet",
    };

    assert.deepEqual(
        robinhoodProductionDeploymentMode(request, {
            YS_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS: "true",
            YS_ROBINHOOD_TESTNET_SEQUENCER_FEED:
                "0x0000000000000000000000000000000000000001",
            YS_ROBINHOOD_TESTNET_STRICT_PRODUCTION_GUARDS: "true",
        }),
        {
            codeSizeOverride: true,
            demoAssetsEnabled: true,
            demoAssetsSelection: "explicit-on",
            guardMode: "strict",
            network: "robinhoodTestnet",
            sequencerMode: "configured-input",
        },
    );
    assert.equal(
        robinhoodProductionDeploymentMode(request, {
            YS_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS: "false",
        }).demoAssetsSelection,
        "explicit-off",
    );
});

test("Robinhood mainnet deployment mode exposes invalid demo opt-in", async () => {
    const {
        formatRobinhoodProductionDeploymentMode,
        robinhoodProductionDeploymentMode,
    } = await import("../parseArgs.js");
    const mode = robinhoodProductionDeploymentMode(
        {
            fileName: "DeployYieldShieldProduction.s.sol",
            network: "robinhood",
        },
        { YS_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS: "true" },
    );

    assert.equal(mode.demoAssetsEnabled, false);
    assert.equal(mode.demoAssetsSelection, "invalid-mainnet-on");
    assert.equal(mode.guardMode, "strict");
    assert.equal(mode.sequencerMode, "required-input-missing");
    assert.match(
        formatRobinhoodProductionDeploymentMode(mode),
        /Demo seeding: INVALID \(demo fixtures are testnet-only\)/u,
    );
});

test("forgeScriptArgsForNetwork applies the runner override to both Robinhood networks", async () => {
    const { forgeScriptArgsForNetwork } = await import("../parseArgs.js");

    assert.deepEqual(forgeScriptArgsForNetwork("robinhoodTestnet", {}), [
        "--disable-code-size-limit",
    ]);
    assert.deepEqual(
        forgeScriptArgsForNetwork("robinhoodTestnet", {
            YS_ROBINHOOD_TESTNET_STRICT_PRODUCTION_GUARDS: "true",
        }),
        ["--disable-code-size-limit"],
    );
    assert.deepEqual(forgeScriptArgsForNetwork("robinhood", {}), [
        "--disable-code-size-limit",
    ]);
    assert.deepEqual(forgeScriptArgsForNetwork("base", {}), []);
});

test("deployment target size preflight is scoped to Robinhood production deploys", async () => {
    const { requiresDeploymentTargetSizeCheck } =
        await import("../parseArgs.js");

    assert.equal(
        requiresDeploymentTargetSizeCheck({
            fileName: "DeployYieldShieldProduction.s.sol",
            network: "robinhoodTestnet",
        }),
        true,
    );
    assert.equal(
        requiresDeploymentTargetSizeCheck({
            fileName: "DeployYieldShieldProduction.s.sol",
            network: "robinhood",
        }),
        true,
    );
    assert.equal(
        requiresDeploymentTargetSizeCheck({
            fileName: "DeployYieldShieldProduction.s.sol",
            network: "base",
        }),
        false,
    );
    assert.equal(
        requiresDeploymentTargetSizeCheck({
            fileName: "RefreshRobinhoodTestnetDemoFeeds.s.sol",
            network: "robinhoodTestnet",
        }),
        false,
    );
});

test("production deployment finality policy supports only reviewed public aliases", async () => {
    const { deploymentFinalityPolicyForNetwork } =
        await import("../parseArgs.js");

    assert.equal(
        deploymentFinalityPolicyForNetwork("arbitrum").chainId,
        "42161",
    );
    assert.equal(
        deploymentFinalityPolicyForNetwork("arbitrumSepolia").chainId,
        "421614",
    );
    assert.equal(
        deploymentFinalityPolicyForNetwork("robinhood").chainId,
        "4663",
    );
    assert.equal(
        deploymentFinalityPolicyForNetwork("robinhoodTestnet").chainId,
        "46630",
    );
    assert.throws(
        () => deploymentFinalityPolicyForNetwork("base"),
        /has no unique checked-in deployment finality policy/u,
    );
});

test("Arbitrum sequencer input is only an exact policy assertion", async () => {
    const {
        deploymentFinalityPolicyForNetwork,
        validatePythSequencerPolicyInput,
    } = await import("../parseArgs.js");
    const canonicalFeed = "0xFdB631F5EE196F0ed6FAa767959853A9F217697D";
    const mainnet = deploymentFinalityPolicyForNetwork("arbitrum");
    const sepolia = deploymentFinalityPolicyForNetwork("arbitrumSepolia");

    assert.equal(
        validatePythSequencerPolicyInput(mainnet, {
            YS_ARBITRUM_SEQUENCER_FEED: canonicalFeed.toLowerCase(),
        }),
        canonicalFeed,
    );
    assert.throws(
        () =>
            validatePythSequencerPolicyInput(mainnet, {
                YS_ARBITRUM_SEQUENCER_FEED:
                    "0x0000000000000000000000000000000000000bad",
            }),
        /must exactly match the checked-in feed/u,
    );
    assert.equal(validatePythSequencerPolicyInput(sepolia, {}), null);
    assert.throws(
        () =>
            validatePythSequencerPolicyInput(sepolia, {
                YS_ARBITRUM_SEQUENCER_FEED: canonicalFeed,
            }),
        /must be unset for chain 421614/u,
    );
});

test("invalid Arbitrum sequencer input fails before RPC, size, or Make work", async () => {
    const { preflightPublicDeploymentPromotion, runDeploymentGatesAndSpawn } =
        await import("../parseArgs.js");
    const cases = [
        {
            network: "arbitrum",
            feed: "0x0000000000000000000000000000000000000bad",
            error: /must exactly match the checked-in feed/u,
        },
        {
            network: "arbitrumSepolia",
            feed: "0xFdB631F5EE196F0ed6FAa767959853A9F217697D",
            error: /must be unset for chain 421614/u,
        },
    ];

    for (const testCase of cases) {
        const calls = [];
        const request = {
            fileName: "DeployYieldShieldProduction.s.sol",
            network: testCase.network,
            env: {
                YS_ARBITRUM_SEQUENCER_FEED: testCase.feed,
            },
            makeArgs: ["deploy-and-generate-abis"],
            childEnv: {},
        };

        await assert.rejects(
            runDeploymentGatesAndSpawn(request, {
                preflight: async (preflightRequest) => {
                    calls.push("preflight");
                    return preflightPublicDeploymentPromotion(
                        preflightRequest,
                        {
                            resolveRpcUrlFn: () => {
                                calls.push("resolve-rpc");
                                return "https://must-not-run.example";
                            },
                            providerFactory: () => {
                                calls.push("provider");
                                return {};
                            },
                        },
                    );
                },
                runSizeCheck: () => {
                    calls.push("size");
                    return 0;
                },
                spawn: () => {
                    calls.push("make");
                    return { status: 0 };
                },
                log: () => {},
            }),
            testCase.error,
        );
        assert.deepEqual(calls, ["preflight"]);
    }
});

test("public deployment preflight verifies both chains and their agreed finalized block", async () => {
    const { preflightPublicDeploymentPromotion } =
        await import("../parseArgs.js");
    const primaryRpcUrl = "https://primary.example/v1";
    const validationRpcUrl = "https://validation.example/v1";
    const finalizedHash = `0x${"ab".repeat(32)}`;
    const destroyed = [];
    const makeProvider = (label, chainId = 421614n, hash = finalizedHash) => ({
        async getNetwork() {
            return { chainId };
        },
        async send(method, params) {
            assert.equal(method, "eth_getBlockByNumber");
            assert.deepEqual(params, ["finalized", false]);
            return { hash, number: "0x64" };
        },
        destroy() {
            destroyed.push(label);
        },
    });
    const providers = new Map([
        [primaryRpcUrl, makeProvider("primary")],
        [validationRpcUrl, makeProvider("validation")],
    ]);
    const request = {
        fileName: "DeployYieldShieldProduction.s.sol",
        network: "arbitrumSepolia",
        env: {
            YS_DEPLOYMENT_RPC_OPERATOR: "alchemy",
            YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR: "self-hosted-berlin",
            YS_DEPLOYMENT_VALIDATION_RPC_URL: validationRpcUrl,
        },
    };
    const dependencies = {
        providerFactory: (url) => providers.get(url),
        resolveRpcUrlFn: (input) =>
            input === "arbitrumSepolia" ? primaryRpcUrl : input,
    };

    const evidence = await preflightPublicDeploymentPromotion(
        request,
        dependencies,
    );
    assert.equal(evidence.blockHash, finalizedHash);
    assert.equal(evidence.blockNumber, "100");
    assert.deepEqual(evidence.rpcProviderOperators, {
        deployment: "alchemy",
        validation: "self-hosted-berlin",
    });
    assert.deepEqual(destroyed.sort(), ["primary", "validation"]);

    let invalidProviderConstructions = 0;
    await assert.rejects(
        preflightPublicDeploymentPromotion(
            {
                ...request,
                env: {
                    ...request.env,
                    YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR: "ALCHEMY",
                },
            },
            {
                ...dependencies,
                providerFactory: () => {
                    invalidProviderConstructions += 1;
                    return {};
                },
            },
        ),
        /must identify an operator distinct/u,
    );
    await assert.rejects(
        preflightPublicDeploymentPromotion(
            {
                ...request,
                env: {
                    ...request.env,
                    YS_DEPLOYMENT_VALIDATION_RPC_URL: "",
                },
            },
            {
                ...dependencies,
                providerFactory: () => {
                    invalidProviderConstructions += 1;
                    return {};
                },
            },
        ),
        /YS_DEPLOYMENT_VALIDATION_RPC_URL is required/u,
    );
    assert.equal(invalidProviderConstructions, 0);

    const wrongChainProviders = new Map([
        [primaryRpcUrl, makeProvider("wrong-primary", 42161n)],
        [validationRpcUrl, makeProvider("wrong-validation")],
    ]);
    await assert.rejects(
        preflightPublicDeploymentPromotion(request, {
            ...dependencies,
            providerFactory: (url) => wrongChainProviders.get(url),
        }),
        /do not match the candidate chain/u,
    );

    const disagreementProviders = new Map([
        [primaryRpcUrl, makeProvider("disagree-primary")],
        [
            validationRpcUrl,
            makeProvider(
                "disagree-validation",
                421614n,
                `0x${"cd".repeat(32)}`,
            ),
        ],
    ]);
    await assert.rejects(
        preflightPublicDeploymentPromotion(request, {
            ...dependencies,
            providerFactory: (url) => disagreementProviders.get(url),
        }),
        /disagree on the finalized block/u,
    );
});

test("unsupported aliases and failed preflights cannot reach size checks or Make", async () => {
    const { preflightPublicDeploymentPromotion, runDeploymentGatesAndSpawn } =
        await import("../parseArgs.js");
    const calls = [];
    const request = {
        fileName: "DeployYieldShieldProduction.s.sol",
        network: "base",
        env: {},
        makeArgs: ["deploy-and-generate-abis"],
        childEnv: {},
    };

    await assert.rejects(
        runDeploymentGatesAndSpawn(request, {
            preflight: async (preflightRequest) => {
                calls.push("preflight");
                return preflightPublicDeploymentPromotion(preflightRequest, {
                    providerFactory: () => {
                        calls.push("provider");
                        return {};
                    },
                });
            },
            runSizeCheck: () => {
                calls.push("size");
                return 0;
            },
            spawn: () => {
                calls.push("make");
                return { status: 0 };
            },
            log: () => {},
        }),
        /has no unique checked-in deployment finality policy/u,
    );
    assert.deepEqual(calls, ["preflight"]);

    const orderedCalls = [];
    const status = await runDeploymentGatesAndSpawn(
        {
            ...request,
            network: "robinhoodTestnet",
        },
        {
            preflight: async () => orderedCalls.push("preflight"),
            runSizeCheck: () => {
                orderedCalls.push("size");
                return 0;
            },
            spawn: (command) => {
                orderedCalls.push(command);
                return { status: 0 };
            },
            log: () => {},
        },
    );
    assert.equal(status, 0);
    assert.deepEqual(orderedCalls, ["preflight", "size", "make"]);
});

test("production deployment generations are deterministic for injected entropy", async () => {
    const { resolveDeploymentGeneration } = await import("../parseArgs.js");
    const request = {
        fileName: "DeployYieldShieldProduction.s.sol",
        network: "robinhoodTestnet",
    };
    const env = {
        YS_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS: "true",
        YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH: `0x${"12".repeat(32)}`,
    };

    const generation = resolveDeploymentGeneration(request, env, {
        now: () => 1_725_000_000_000,
        randomHex: () => "1234567890abcdef",
    });
    assert.equal(generation.generationId, "gen-1725000000000-1234567890abcdef");
    assert.match(generation.configurationDigest, /^0x[0-9a-f]{64}$/u);
    assert.equal(generation.recovery, false);
    assert.equal(
        resolveDeploymentGeneration(request, {
            ...env,
            YS_DEPLOYMENT_ID: generation.generationId,
        }).configurationDigest,
        generation.configurationDigest,
    );
});

test("deployment recovery requires and reuses the original generation ID", async () => {
    const { resolveDeploymentGeneration } = await import("../parseArgs.js");
    const request = {
        fileName: "DeployYieldShieldProduction.s.sol",
        network: "robinhood",
    };

    assert.throws(
        () =>
            resolveDeploymentGeneration(request, {
                YS_DEPLOYMENT_RECOVERY: "true",
            }),
        /requires the original YS_DEPLOYMENT_ID/u,
    );
    const recovery = resolveDeploymentGeneration(request, {
        YS_DEPLOYMENT_ID: "gen-recovery-0001",
        YS_DEPLOYMENT_RECOVERY: "true",
    });
    assert.equal(recovery.generationId, "gen-recovery-0001");
    assert.equal(recovery.recovery, true);
    assert.match(recovery.configurationDigest, /^0x[0-9a-f]{64}$/u);
});

test("deployment generation IDs reject path traversal", async () => {
    const { isValidDeploymentGenerationId, resolveDeploymentGeneration } =
        await import("../parseArgs.js");
    assert.equal(isValidDeploymentGenerationId("gen-valid-0001"), true);
    assert.equal(isValidDeploymentGenerationId("../escape"), false);
    assert.throws(
        () =>
            resolveDeploymentGeneration(
                {
                    fileName: "DeployYieldShieldProduction.s.sol",
                    network: "robinhoodTestnet",
                },
                { YS_DEPLOYMENT_ID: "../escape" },
            ),
        /must be 8-128 characters/u,
    );
});
