const assert = require("node:assert/strict");
const { test } = require("node:test");

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

test("missingProductionEnv relaxes production pins for Robinhood testnet by default", async () => {
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
            "YS_PRODUCTION_FACTORY_IMPLEMENTATION_CODEHASH",
            "YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH",
            "YS_PRODUCTION_CHAINLINK_ORACLE_CODEHASH",
            "YS_ROBINHOOD_TESTNET_SEQUENCER_FEED or YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED=true",
        ],
    );
});

test("missingProductionEnv limits the missing-sequencer exception to Robinhood testnet", async () => {
    const { missingProductionEnv } = await import("../parseArgs.js");
    const productionEnv = {
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
        ["YS_ROBINHOOD_SEQUENCER_FEED", "YS_ROBINHOOD_SEQUENCER_FEED_SOURCE"],
    );
});

test("missingProductionEnv requires nonblank mainnet sequencer provenance", async () => {
    const { missingProductionEnv } = await import("../parseArgs.js");
    const env = {
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
    ]);
    assert.deepEqual(
        missingProductionEnv(request, {
            ...env,
            YS_ROBINHOOD_SEQUENCER_FEED_SOURCE:
                "https://docs.example/sequencer-feed",
        }),
        [],
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
