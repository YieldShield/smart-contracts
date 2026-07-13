const assert = require("node:assert/strict");
const { test } = require("node:test");

async function makePromotedManifest(chainId = "46630") {
    const { CHAINLINK_CORE_INVENTORY, requiredReviewedCodehashPinNames } =
        await import("../generateTsAbis.js");
    const manifest = {
        schemaVersion: "2",
        status: "active",
        chainId,
        deploymentId: "generation-1",
        configurationDigest: "digest-1",
        validatedAt: "2026-07-13T00:00:00.000Z",
        finalityEvidence: {
            blockHash: `0x${"ab".repeat(32)}`,
            blockNumber: "1234",
            blockTag: "finalized",
            independentValidationRpc: true,
            policySchemaVersion: 1,
        },
        robinhoodDemoAssetsEnabled: "false",
        transactionHashes: ["0x01"],
        codehashEvidence: {},
        addressEvidence: {},
        reviewedCodehashPins: {},
    };
    CHAINLINK_CORE_INVENTORY.forEach((name, index) => {
        const address = `0x${(index + 1).toString(16).padStart(40, "0")}`;
        manifest[address] = name;
        manifest.codehashEvidence[address] = `0x${(index + 1)
            .toString(16)
            .padStart(64, "0")}`;
        manifest.addressEvidence[address] = "broadcast-create";
    });
    for (const name of requiredReviewedCodehashPinNames("chainlink")) {
        const [address] = Object.entries(manifest).find(
            ([key, value]) => /^0x[0-9a-f]{40}$/iu.test(key) && value === name,
        );
        manifest.reviewedCodehashPins[name] =
            manifest.codehashEvidence[address];
    }

    return manifest;
}

function manifestAddressFor(manifest, contractName) {
    return Object.entries(manifest).find(
        ([address, name]) =>
            /^0x[0-9a-f]{40}$/iu.test(address) && name === contractName,
    )?.[0];
}

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
    const { validateActiveDeploymentManifest } =
        await import("../generateTsAbis.js");
    const manifest = await makePromotedManifest();

    assert.equal(validateActiveDeploymentManifest("46630", manifest), manifest);

    const withoutFinalityEvidence = { ...manifest };
    delete withoutFinalityEvidence.finalityEvidence;
    assert.throws(
        () =>
            validateActiveDeploymentManifest("46630", withoutFinalityEvidence),
        /missing finalized-state promotion evidence/u,
    );

    const withoutTokenPin = structuredClone(manifest);
    delete withoutTokenPin.reviewedCodehashPins.YSToken;
    assert.throws(
        () => validateActiveDeploymentManifest("46630", withoutTokenPin),
        /incomplete reviewed codehash pins/u,
    );

    const withUnexpectedPin = structuredClone(manifest);
    withUnexpectedPin.reviewedCodehashPins.UnreviewedContract = `0x${"ff".repeat(32)}`;
    assert.throws(
        () => validateActiveDeploymentManifest("46630", withUnexpectedPin),
        /incomplete reviewed codehash pins/u,
    );

    const withMismatchedGovernorPin = structuredClone(manifest);
    withMismatchedGovernorPin.reviewedCodehashPins.YSGovernor = `0x${"ff".repeat(32)}`;
    assert.throws(
        () =>
            validateActiveDeploymentManifest(
                "46630",
                withMismatchedGovernorPin,
            ),
        /incomplete reviewed codehash pins/u,
    );

    delete manifest["0x0000000000000000000000000000000000000001"];
    assert.throws(
        () => validateActiveDeploymentManifest("46630", manifest),
        /does not match the reviewed production inventory/u,
    );
});

test("strict-chain broadcasts are excluded without a promoted manifest", async () => {
    const { constrainStrictChainContracts } =
        await import("../generateTsAbis.js");
    const localContracts = {
        SplitRiskPoolFactory: {
            address: "0x00000000000000000000000000000000000000a1",
        },
    };
    const strictContracts = {
        SplitRiskPoolFactory: {
            address: "0x00000000000000000000000000000000000000b1",
        },
    };

    assert.deepEqual(
        constrainStrictChainContracts(
            { 31337: localContracts, 46630: strictContracts },
            {},
        ),
        { 31337: localContracts },
    );
});

test("strict-chain emission permits only exact promoted name-address pairs", async () => {
    const { constrainStrictChainContracts } =
        await import("../generateTsAbis.js");
    const manifest = await makePromotedManifest();
    const factoryAddress = manifestAddressFor(manifest, "SplitRiskPoolFactory");
    const governorAddress = manifestAddressFor(manifest, "YSGovernor");
    const tokenAddress = manifestAddressFor(manifest, "YSToken");
    const strictContracts = {
        SplitRiskPoolFactory: {
            address: factoryAddress.toUpperCase().replace("0X", "0x"),
            source: "history",
        },
        YSGovernor: {
            address: governorAddress,
            source: "run-latest",
        },
        YSToken: {
            address: "0x0000000000000000000000000000000000000bad",
        },
        ExtraneousContract: {
            address: tokenAddress,
        },
    };

    assert.deepEqual(
        constrainStrictChainContracts(
            { 46630: strictContracts },
            { 46630: manifest },
        ),
        {
            46630: {
                SplitRiskPoolFactory: {
                    address: factoryAddress,
                    source: "history",
                },
                YSGovernor: {
                    address: governorAddress,
                    source: "run-latest",
                },
            },
        },
    );
});

test("strict-chain emission accepts a broadcast alias only at its promoted address", async () => {
    const { constrainStrictChainContracts, remapContractNamesByManifest } =
        await import("../generateTsAbis.js");
    const manifest = await makePromotedManifest();
    const factoryAddress = manifestAddressFor(manifest, "SplitRiskPoolFactory");
    const governorAddress = manifestAddressFor(manifest, "YSGovernor");
    const rawContracts = {
        ERC1967Proxy: {
            address: factoryAddress,
            source: "run-latest",
        },
        YSGovernor: {
            address: governorAddress,
            source: "history",
        },
    };
    const remappedContracts = remapContractNamesByManifest(
        rawContracts,
        manifest,
    );

    assert.deepEqual(
        constrainStrictChainContracts(
            { 46630: remappedContracts },
            { 46630: manifest },
        ),
        {
            46630: {
                SplitRiskPoolFactory: {
                    address: factoryAddress,
                    source: "run-latest",
                },
                YSGovernor: {
                    address: governorAddress,
                    source: "history",
                },
            },
        },
    );
});

test("an explicit strict-chain target requires a promoted manifest", async () => {
    const { requirePromotedManifestForStrictTarget } =
        await import("../generateTsAbis.js");

    assert.throws(
        () => requirePromotedManifestForStrictTarget("46630", {}),
        /raw broadcasts remain quarantined/u,
    );
    assert.equal(requirePromotedManifestForStrictTarget("31337", {}), null);
});

test("Ponder cannot select an unpromoted strict chain", async () => {
    const { selectPonderDeployment } = await import("../generateTsAbis.js");
    const allGeneratedContracts = {
        46630: {
            SplitRiskPoolFactory: {
                address: "0x00000000000000000000000000000000000000a1",
            },
            YSGovernor: {
                address: "0x00000000000000000000000000000000000000a2",
                deployedOnBlock: 1234,
            },
        },
    };

    assert.equal(
        selectPonderDeployment(["46630"], allGeneratedContracts, {}),
        null,
    );
});

test("Ponder selects strict-chain addresses only from the promoted manifest", async () => {
    const { selectPonderDeployment } = await import("../generateTsAbis.js");
    const manifest = await makePromotedManifest();
    const factoryAddress = manifestAddressFor(manifest, "SplitRiskPoolFactory");
    const governorAddress = manifestAddressFor(manifest, "YSGovernor");
    const allGeneratedContracts = {
        46630: {
            SplitRiskPoolFactory: {
                address: factoryAddress,
            },
            YSGovernor: {
                address: governorAddress,
                deployedOnBlock: 1234,
            },
        },
    };

    assert.deepEqual(
        selectPonderDeployment(["46630"], allGeneratedContracts, {
            46630: manifest,
        }),
        {
            chainId: "46630",
            factoryAddress,
            governorAddress,
            governorBlock: 1234,
        },
    );
});

test("Ponder rejects promoted strict-chain contracts that do not match the manifest", async () => {
    const { selectPonderDeployment } = await import("../generateTsAbis.js");
    const manifest = await makePromotedManifest();
    const allGeneratedContracts = {
        46630: {
            SplitRiskPoolFactory: {
                address: "0x0000000000000000000000000000000000000bad",
            },
            YSGovernor: {
                address: manifestAddressFor(manifest, "YSGovernor"),
                deployedOnBlock: 1234,
            },
        },
    };

    assert.equal(
        selectPonderDeployment(["46630"], allGeneratedContracts, {
            46630: manifest,
        }),
        null,
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
