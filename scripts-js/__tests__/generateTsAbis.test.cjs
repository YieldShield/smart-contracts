const assert = require("node:assert/strict");
const { test } = require("node:test");

test("selectPonderDeployment never mixes factory and governor chains", async () => {
    const { selectPonderDeployment } = await import("../generateTsAbis.js");
    const chainIds = ["421614", "31337"];
    const allGeneratedContracts = {
        421614: {
            SplitRiskPoolFactory: {
                address: "0x00000000000000000000000000000000000000a1",
            },
        },
        31337: {
            YSGovernor: {
                address: "0x00000000000000000000000000000000000000b1",
                deployedOnBlock: 1234,
            },
        },
    };

    assert.equal(
        selectPonderDeployment(chainIds, allGeneratedContracts, {}),
        null,
    );
});

test("Robinhood deployments must be promoted schema-v2 active manifests", async () => {
    const { validateActiveDeploymentManifest } =
        await import("../generateTsAbis.js");

    assert.throws(
        () =>
            validateActiveDeploymentManifest("46630", {
                "0x0000000000000000000000000000000000000001":
                    "SplitRiskPoolFactory",
                networkName: "robinhood-testnet",
            }),
        /not a promoted schema-v2 active manifest/u,
    );
});

test("Robinhood promoted manifests require exact inventory and evidence", async () => {
    const { CHAINLINK_CORE_INVENTORY, validateActiveDeploymentManifest } =
        await import("../generateTsAbis.js");
    const manifest = {
        schemaVersion: "2",
        status: "active",
        chainId: "46630",
        deploymentId: "generation-1",
        configurationDigest: "digest-1",
        validatedAt: "2026-07-13T00:00:00.000Z",
        robinhoodDemoAssetsEnabled: "false",
        transactionHashes: ["0x01"],
        codehashEvidence: {},
        addressEvidence: {},
        reviewedCodehashPins: {
            SplitRiskPoolFactoryImplementation: "0x01",
            SplitRiskPoolImplementation: "0x02",
            ChainlinkOracleFeed: "0x03",
        },
    };
    CHAINLINK_CORE_INVENTORY.forEach((name, index) => {
        const address = `0x${(index + 1).toString(16).padStart(40, "0")}`;
        manifest[address] = name;
        manifest.codehashEvidence[address] = `0x${(index + 1)
            .toString(16)
            .padStart(64, "0")}`;
        manifest.addressEvidence[address] = "broadcast-create";
    });

    assert.equal(validateActiveDeploymentManifest("46630", manifest), manifest);

    delete manifest["0x0000000000000000000000000000000000000001"];
    assert.throws(
        () => validateActiveDeploymentManifest("46630", manifest),
        /does not match the reviewed production inventory/u,
    );
});

test("deploymentJsonNameForAddress matches deployment aliases case-insensitively", async () => {
    const { deploymentJsonNameForAddress } =
        await import("../generateTsAbis.js");

    assert.equal(
        deploymentJsonNameForAddress(
            {
                "0xe1Aa25618fA0c7A1CFDab5d6B456af611873b629":
                    "TimelockController",
            },
            "0xe1aa25618fa0c7a1cfdab5d6b456af611873b629",
        ),
        "TimelockController",
    );
});

test("selectPonderDeployment selects both addresses from the first complete chain", async () => {
    const { selectPonderDeployment } = await import("../generateTsAbis.js");
    const chainIds = ["421614", "31337"];
    const allGeneratedContracts = {
        421614: {
            SplitRiskPoolFactory: {
                address: "0x00000000000000000000000000000000000000a1",
            },
        },
        31337: {
            SplitRiskPoolFactory: {
                address: "0x00000000000000000000000000000000000000c1",
            },
            YSGovernor: {
                address: "0x00000000000000000000000000000000000000c2",
                deployedOnBlock: 4321,
            },
        },
    };

    assert.deepEqual(
        selectPonderDeployment(chainIds, allGeneratedContracts, {}),
        {
            chainId: "31337",
            factoryAddress: "0x00000000000000000000000000000000000000c1",
            governorAddress: "0x00000000000000000000000000000000000000c2",
            governorBlock: 4321,
        },
    );
});
