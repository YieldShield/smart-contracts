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
