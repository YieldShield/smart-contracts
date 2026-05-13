const assert = require("node:assert/strict");
const { test } = require("node:test");
const { mkdtempSync, mkdirSync, writeFileSync, utimesSync } = require("fs");
const { tmpdir } = require("os");
const { dirname, join } = require("path");
const {
    readLatestBroadcast,
    resolveContractAddress,
    resolveDeploymentChainId,
    resolvePythTokenConfigs,
} = require("../pyth-token-registry.cjs");

function makeTempRoot() {
    return mkdtempSync(join(tmpdir(), "pyth-token-registry-"));
}

function writeJson(filePath, data, mtimeMs) {
    mkdirSync(dirname(filePath), { recursive: true });
    writeFileSync(filePath, JSON.stringify(data, null, 2));
    if (mtimeMs) {
        const when = new Date(mtimeMs);
        utimesSync(filePath, when, when);
    }
}

test("readLatestBroadcast picks the newest run-latest.json for a chain", () => {
    const rootDir = makeTempRoot();
    const older = Date.now() - 20_000;
    const newer = Date.now() - 10_000;

    writeJson(
        join(rootDir, "broadcast", "Deploy.s.sol", "421614", "run-latest.json"),
        {
            transactions: [
                {
                    transactionType: "CREATE",
                    contractName: "PythOracle",
                    contractAddress:
                        "0x0000000000000000000000000000000000000001",
                },
            ],
        },
        older,
    );
    writeJson(
        join(
            rootDir,
            "broadcast",
            "DeployYieldShieldProduction.s.sol",
            "421614",
            "run-latest.json",
        ),
        {
            transactions: [
                {
                    transactionType: "CREATE",
                    contractName: "PythOracle",
                    contractAddress:
                        "0x0000000000000000000000000000000000000002",
                },
            ],
        },
        newer,
    );

    const broadcast = readLatestBroadcast(rootDir, "421614");
    assert.equal(
        broadcast.transactions[0].contractAddress,
        "0x0000000000000000000000000000000000000002",
    );
});

test("resolveDeploymentChainId prefers explicit DEPLOY_CHAIN_ID, then the most recent deployment activity", () => {
    const rootDir = makeTempRoot();
    const older = Date.now() - 20_000;
    const newer = Date.now() - 10_000;

    writeJson(
        join(rootDir, "deployments", "31337.json"),
        {
            "0x0000000000000000000000000000000000000010":
                "SplitRiskPoolFactory",
        },
        older,
    );
    writeJson(
        join(
            rootDir,
            "broadcast",
            "DeployYieldShieldProduction.s.sol",
            "421614",
            "run-latest.json",
        ),
        { transactions: [] },
        newer,
    );

    assert.equal(
        resolveDeploymentChainId({
            rootDir,
            env: { DEPLOY_CHAIN_ID: "999" },
        }),
        "999",
    );
    assert.equal(resolveDeploymentChainId({ rootDir, env: {} }), "421614");
});

test("resolveContractAddress returns the newest deployment address when no newer broadcast exists", () => {
    const rootDir = makeTempRoot();

    writeJson(join(rootDir, "deployments", "421614.json"), {
        "0x00000000000000000000000000000000000000a1": "PythOracle",
        "0x00000000000000000000000000000000000000a2": "PythOracle",
    });

    assert.equal(
        resolveContractAddress({
            rootDir,
            chainId: "421614",
            contractName: "PythOracle",
            env: {},
        }),
        "0x00000000000000000000000000000000000000a2",
    );
});

test("resolveContractAddress prefers a newer broadcast over an older deployment file", () => {
    const rootDir = makeTempRoot();
    const older = Date.now() - 20_000;
    const newer = Date.now() - 10_000;

    writeJson(
        join(rootDir, "deployments", "421614.json"),
        {
            "0x00000000000000000000000000000000000000b1": "PythOracle",
        },
        older,
    );
    writeJson(
        join(
            rootDir,
            "broadcast",
            "DeployYieldShieldProduction.s.sol",
            "421614",
            "run-latest.json",
        ),
        {
            transactions: [
                {
                    transactionType: "CREATE",
                    contractName: "PythOracle",
                    contractAddress:
                        "0x00000000000000000000000000000000000000b2",
                },
            ],
        },
        newer,
    );

    assert.equal(
        resolveContractAddress({
            rootDir,
            chainId: "421614",
            contractName: "PythOracle",
            env: {},
        }),
        "0x00000000000000000000000000000000000000b2",
    );
});

test("resolvePythTokenConfigs prefers current broadcast addresses over stale env overrides", () => {
    const rootDir = makeTempRoot();

    writeJson(
        join(
            rootDir,
            "broadcast",
            "DeployYieldShieldProduction.s.sol",
            "421614",
            "run-latest.json",
        ),
        {
            transactions: [
                {
                    transactionType: "CREATE",
                    contractName: "MockERC20",
                    contractAddress:
                        "0x00000000000000000000000000000000000000c1",
                },
            ],
        },
    );

    const configs = resolvePythTokenConfigs({
        rootDir,
        chainId: "421614",
        env: {
            SUSDE_ADDRESS: "0x00000000000000000000000000000000000000ff",
        },
    });

    const susde = configs.find((config) => config.name === "SUSDE");
    assert.equal(susde.address, "0x00000000000000000000000000000000000000c1");
});
