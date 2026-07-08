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

test("missingProductionEnv allows Robinhood sequencer opt-out for testnet", async () => {
    const { missingProductionEnv } = await import("../parseArgs.js");
    const env = {
        YS_PRODUCTION_BOOTSTRAP_HOLDER: "0xholder",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_CODEHASH: "0xcodehash",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_SINGLETON: "0xsingleton",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_THRESHOLD: "2",
        YS_PRODUCTION_BOOTSTRAP_HOLDER_OWNERS_HASH: "0xowners",
        YS_PRODUCTION_FACTORY_IMPLEMENTATION_CODEHASH: "0xfactory",
        YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH: "0xpool",
        YS_PRODUCTION_CHAINLINK_ORACLE_CODEHASH: "0xchainlink",
        YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED: "true",
    };

    assert.deepEqual(
        missingProductionEnv(
            {
                fileName: "DeployYieldShieldProduction.s.sol",
                network: "robinhoodTestnet",
            },
            env,
        ),
        [],
    );
});
