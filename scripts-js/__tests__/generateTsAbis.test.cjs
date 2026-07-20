const assert = require("node:assert/strict");
const { test } = require("node:test");

async function makePromotedManifest(
    chainId = "46630",
    oracleMode = ["42161", "421614"].includes(chainId) ? "pyth" : "chainlink",
) {
    const {
        CHAINLINK_CORE_INVENTORY,
        PYTH_CORE_INVENTORY,
        requiredReviewedCodehashPinNames,
    } = await import("../generateTsAbis.js");
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
            policySchemaVersion: 2,
            rpcProviderOperators: {
                deployment: "deployment-operator",
                validation: "validation-operator",
            },
        },
        robinhoodDemoAssetsEnabled: "false",
        productionGuardMode: chainId === "46630" ? "relaxed" : "strict",
        transactionHashes: ["0x01"],
        codehashEvidence: {},
        addressEvidence: {},
        reviewedCodehashPins: {},
    };
    if (oracleMode === "pyth") {
        const isMainnet = chainId === "42161";
        manifest.pythSequencerUptimeGuardEvidence = {
            erc4626Required: isMainnet,
            feed: isMainnet
                ? "0xFdB631F5EE196F0ed6FAa767959853A9F217697D"
                : "0x0000000000000000000000000000000000000000",
            mode: isMainnet ? "configured" : "disabled-no-canonical-feed",
            primaryOracle: "PythOracle",
            primaryOracleRequired: isMainnet,
            runtimeCodehash: isMainnet
                ? `0x${"cc".repeat(32)}`
                : `0x${"00".repeat(32)}`,
            source: isMainnet
                ? "https://docs.chain.link/data-feeds/l2-sequencer-feeds"
                : "chainlink-no-arbitrum-sepolia-sequencer-feed",
        };
    } else if (chainId === "4663") {
        const sequencerAddress = "0x0000000000000000000000000000000000000abc";
        const sequencerCodehash = `0x${"cc".repeat(32)}`;
        manifest.robinhoodSequencerUptimeFeed = sequencerAddress;
        manifest.robinhoodSequencerUptimeFeedSource =
            "https://docs.example/feed";
        manifest.robinhoodSequencerUptimeFeedCodehash = sequencerCodehash;
        manifest.sequencerUptimeFeedEvidence = {
            address: sequencerAddress,
            mode: "configured",
            reviewedCodehashPin: sequencerCodehash,
            runtimeCodehash: sequencerCodehash,
            source: "https://docs.example/feed",
        };
    } else {
        const zeroAddress = "0x0000000000000000000000000000000000000000";
        const zeroCodehash = `0x${"00".repeat(32)}`;
        manifest.robinhoodSequencerUptimeFeed = zeroAddress;
        manifest.robinhoodSequencerUptimeFeedSource =
            "robinhood-testnet-relaxed-guards";
        manifest.robinhoodSequencerUptimeFeedCodehash = zeroCodehash;
        manifest.sequencerUptimeFeedEvidence = {
            address: zeroAddress,
            mode: "robinhood-testnet-exception",
            reviewedCodehashPin: null,
            runtimeCodehash: zeroCodehash,
            source: "robinhood-testnet-relaxed-guards",
        };
    }
    const inventory =
        oracleMode === "pyth" ? PYTH_CORE_INVENTORY : CHAINLINK_CORE_INVENTORY;
    inventory.forEach((name, index) => {
        const address = `0x${(index + 1).toString(16).padStart(40, "0")}`;
        manifest[address] = name;
        manifest.codehashEvidence[address] = `0x${(index + 1)
            .toString(16)
            .padStart(64, "0")}`;
        manifest.addressEvidence[address] = "broadcast-create";
    });
    if (manifest.productionGuardMode !== "relaxed") {
        for (const name of requiredReviewedCodehashPinNames(oracleMode)) {
            const [address] = Object.entries(manifest).find(
                ([key, value]) =>
                    /^0x[0-9a-f]{40}$/iu.test(key) && value === name,
            );
            manifest.reviewedCodehashPins[name] =
                manifest.codehashEvidence[address];
        }
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

    const withoutOperatorEvidence = structuredClone(manifest);
    delete withoutOperatorEvidence.finalityEvidence.rpcProviderOperators;
    assert.throws(
        () =>
            validateActiveDeploymentManifest("46630", withoutOperatorEvidence),
        /missing finalized-state promotion evidence/u,
    );

    const sameOperator = structuredClone(manifest);
    sameOperator.finalityEvidence.rpcProviderOperators.validation =
        sameOperator.finalityEvidence.rpcProviderOperators.deployment;
    assert.throws(
        () => validateActiveDeploymentManifest("46630", sameOperator),
        /missing finalized-state promotion evidence/u,
    );

    const nonCanonicalOperator = structuredClone(manifest);
    nonCanonicalOperator.finalityEvidence.rpcProviderOperators.deployment =
        "Deployment-Operator";
    assert.throws(
        () => validateActiveDeploymentManifest("46630", nonCanonicalOperator),
        /missing finalized-state promotion evidence/u,
    );

    const operatorEvidenceWithUrl = structuredClone(manifest);
    operatorEvidenceWithUrl.finalityEvidence.rpcProviderOperators.url =
        "https://do-not-persist.example/key";
    assert.throws(
        () =>
            validateActiveDeploymentManifest("46630", operatorEvidenceWithUrl),
        /missing finalized-state promotion evidence/u,
    );

    const withoutFactoryCodehash = structuredClone(manifest);
    const factoryAddress = manifestAddressFor(
        withoutFactoryCodehash,
        "SplitRiskPoolFactory",
    );
    delete withoutFactoryCodehash.codehashEvidence[factoryAddress];
    assert.throws(
        () => validateActiveDeploymentManifest("46630", withoutFactoryCodehash),
        /incomplete address or codehash evidence/u,
    );

    const withMalformedCodehash = structuredClone(manifest);
    withMalformedCodehash.codehashEvidence[factoryAddress] = "0x01";
    assert.throws(
        () => validateActiveDeploymentManifest("46630", withMalformedCodehash),
        /incomplete address or codehash evidence/u,
    );

    const withoutFactorySource = structuredClone(manifest);
    delete withoutFactorySource.addressEvidence[factoryAddress];
    assert.throws(
        () => validateActiveDeploymentManifest("46630", withoutFactorySource),
        /incomplete address or codehash evidence/u,
    );

    const withUnexpectedPin = structuredClone(manifest);
    withUnexpectedPin.reviewedCodehashPins.YSToken = `0x${"ff".repeat(32)}`;
    assert.throws(
        () => validateActiveDeploymentManifest("46630", withUnexpectedPin),
        /incomplete reviewed codehash pins/u,
    );

    const strictTestnet = structuredClone(manifest);
    strictTestnet.productionGuardMode = "strict";
    assert.throws(
        () => validateActiveDeploymentManifest("46630", strictTestnet),
        /incomplete reviewed codehash pins/u,
    );

    delete manifest["0x0000000000000000000000000000000000000001"];
    assert.throws(
        () => validateActiveDeploymentManifest("46630", manifest),
        /does not match the reviewed production inventory/u,
    );
});

test("strict manifests still require exact reviewed core codehash pins", async () => {
    const { validateActiveDeploymentManifest } =
        await import("../generateTsAbis.js");
    const strictManifest = await makePromotedManifest("4663");

    assert.equal(
        validateActiveDeploymentManifest("4663", strictManifest),
        strictManifest,
    );

    const withoutTokenPin = structuredClone(strictManifest);
    delete withoutTokenPin.reviewedCodehashPins.YSToken;
    assert.throws(
        () => validateActiveDeploymentManifest("4663", withoutTokenPin),
        /incomplete reviewed codehash pins/u,
    );

    const withUnexpectedPin = structuredClone(strictManifest);
    withUnexpectedPin.reviewedCodehashPins.UnreviewedContract = `0x${"ff".repeat(32)}`;
    assert.throws(
        () => validateActiveDeploymentManifest("4663", withUnexpectedPin),
        /incomplete reviewed codehash pins/u,
    );

    const withMismatchedGovernorPin = structuredClone(strictManifest);
    withMismatchedGovernorPin.reviewedCodehashPins.YSGovernor = `0x${"ff".repeat(32)}`;
    assert.throws(
        () =>
            validateActiveDeploymentManifest("4663", withMismatchedGovernorPin),
        /incomplete reviewed codehash pins/u,
    );

    const relaxedMainnet = structuredClone(strictManifest);
    relaxedMainnet.productionGuardMode = "relaxed";
    relaxedMainnet.reviewedCodehashPins = {};
    assert.throws(
        () => validateActiveDeploymentManifest("4663", relaxedMainnet),
        /incomplete reviewed codehash pins/u,
    );
});

test("Robinhood manifests require chain-appropriate sequencer evidence", async () => {
    const { validateActiveDeploymentManifest } =
        await import("../generateTsAbis.js");
    const testnet = await makePromotedManifest();
    const withoutEvidence = structuredClone(testnet);
    delete withoutEvidence.sequencerUptimeFeedEvidence;
    assert.throws(
        () => validateActiveDeploymentManifest("46630", withoutEvidence),
        /incomplete sequencer uptime feed evidence/u,
    );

    const mainnet = await makePromotedManifest("4663");
    assert.equal(validateActiveDeploymentManifest("4663", mainnet), mainnet);
    const mainnetException = structuredClone(mainnet);
    mainnetException.robinhoodSequencerUptimeFeed =
        "0x0000000000000000000000000000000000000000";
    mainnetException.robinhoodSequencerUptimeFeedCodehash = `0x${"00".repeat(32)}`;
    mainnetException.robinhoodSequencerUptimeFeedSource =
        "robinhood-testnet-explicit-exception";
    mainnetException.sequencerUptimeFeedEvidence = {
        address: mainnetException.robinhoodSequencerUptimeFeed,
        mode: "robinhood-testnet-exception",
        reviewedCodehashPin: null,
        runtimeCodehash: mainnetException.robinhoodSequencerUptimeFeedCodehash,
        source: mainnetException.robinhoodSequencerUptimeFeedSource,
    };
    assert.throws(
        () => validateActiveDeploymentManifest("4663", mainnetException),
        /mainnet requires a configured, reviewed sequencer uptime feed/u,
    );

    const tampered = structuredClone(mainnet);
    tampered.sequencerUptimeFeedEvidence.runtimeCodehash = `0x${"dd".repeat(32)}`;
    assert.throws(
        () => validateActiveDeploymentManifest("4663", tampered),
        /incomplete sequencer uptime feed evidence/u,
    );
});

test("schema-v2 Pyth manifests require exact chain-policy sequencer evidence", async () => {
    const { validateActiveDeploymentManifest } =
        await import("../generateTsAbis.js");
    const sepolia = await makePromotedManifest("421614");
    const mainnet = await makePromotedManifest("42161");

    assert.equal(validateActiveDeploymentManifest("421614", sepolia), sepolia);
    assert.equal(validateActiveDeploymentManifest("42161", mainnet), mainnet);

    const withoutEvidence = structuredClone(sepolia);
    delete withoutEvidence.pythSequencerUptimeGuardEvidence;
    assert.throws(
        () => validateActiveDeploymentManifest("421614", withoutEvidence),
        /incomplete Pyth sequencer uptime guard evidence/u,
    );

    const wrongFeed = structuredClone(sepolia);
    wrongFeed.pythSequencerUptimeGuardEvidence.feed =
        "0x0000000000000000000000000000000000000bad";
    assert.throws(
        () => validateActiveDeploymentManifest("421614", wrongFeed),
        /incomplete Pyth sequencer uptime guard evidence/u,
    );

    const wrongRequirement = structuredClone(mainnet);
    wrongRequirement.pythSequencerUptimeGuardEvidence.erc4626Required = false;
    assert.throws(
        () => validateActiveDeploymentManifest("42161", wrongRequirement),
        /incomplete Pyth sequencer uptime guard evidence/u,
    );

    const zeroMainnetCodehash = structuredClone(mainnet);
    zeroMainnetCodehash.pythSequencerUptimeGuardEvidence.runtimeCodehash = `0x${"00".repeat(32)}`;
    assert.throws(
        () => validateActiveDeploymentManifest("42161", zeroMainnetCodehash),
        /incomplete Pyth sequencer uptime guard evidence/u,
    );

    const unexpectedField = structuredClone(sepolia);
    unexpectedField.pythSequencerUptimeGuardEvidence.rpcUrl =
        "https://must-not-be-present.example";
    assert.throws(
        () => validateActiveDeploymentManifest("421614", unexpectedField),
        /incomplete Pyth sequencer uptime guard evidence/u,
    );
});

test("legacy public-chain address maps are rejected", async () => {
    const { validateActiveDeploymentManifest } =
        await import("../generateTsAbis.js");
    const legacy = {
        "0x0000000000000000000000000000000000000001": "PythOracle",
        networkName: "arbitrum-sepolia",
    };

    assert.throws(
        () => validateActiveDeploymentManifest("421614", legacy),
        /not a promoted schema-v2 active manifest/u,
    );
    assert.equal(validateActiveDeploymentManifest("31337", legacy), legacy);
    assert.equal(validateActiveDeploymentManifest("1337", legacy), legacy);
});

test("public-chain broadcasts are excluded without a promoted manifest", async () => {
    const { constrainPublicChainContracts } =
        await import("../generateTsAbis.js");
    const localContracts = {
        SplitRiskPoolFactory: {
            address: "0x00000000000000000000000000000000000000a1",
        },
    };
    const publicContracts = {
        SplitRiskPoolFactory: {
            address: "0x00000000000000000000000000000000000000b1",
        },
    };

    assert.deepEqual(
        constrainPublicChainContracts(
            {
                1337: localContracts,
                31337: localContracts,
                46630: publicContracts,
                421614: publicContracts,
            },
            {},
        ),
        { 1337: localContracts, 31337: localContracts },
    );
});

test("public-chain emission permits only exact promoted name-address pairs", async () => {
    const { constrainPublicChainContracts } =
        await import("../generateTsAbis.js");
    const manifest = await makePromotedManifest("421614");
    const factoryAddress = manifestAddressFor(manifest, "SplitRiskPoolFactory");
    const governorAddress = manifestAddressFor(manifest, "YSGovernor");
    const tokenAddress = manifestAddressFor(manifest, "YSToken");
    const publicContracts = {
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
        constrainPublicChainContracts(
            { 421614: publicContracts },
            { 421614: manifest },
        ),
        {
            421614: {
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

test("public-chain emission accepts a broadcast alias only at its promoted address", async () => {
    const { constrainPublicChainContracts, remapContractNamesByManifest } =
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
        constrainPublicChainContracts(
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

test("an explicit public-chain target requires a promoted manifest", async () => {
    const { requirePromotedManifestForPublicTarget } =
        await import("../generateTsAbis.js");

    assert.throws(
        () => requirePromotedManifestForPublicTarget("421614", {}),
        /raw broadcasts remain quarantined/u,
    );
    assert.equal(requirePromotedManifestForPublicTarget("31337", {}), null);
    assert.equal(requirePromotedManifestForPublicTarget("1337", {}), null);
});

test("Ponder cannot select an unpromoted public chain", async () => {
    const { selectPonderDeployment } = await import("../generateTsAbis.js");
    const allGeneratedContracts = {
        421614: {
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
        selectPonderDeployment(["421614"], allGeneratedContracts, {}),
        null,
    );
});

test("Ponder selects public-chain addresses only from the promoted manifest", async () => {
    const { selectPonderDeployment } = await import("../generateTsAbis.js");
    const manifest = await makePromotedManifest("421614");
    const factoryAddress = manifestAddressFor(manifest, "SplitRiskPoolFactory");
    const governorAddress = manifestAddressFor(manifest, "YSGovernor");
    const allGeneratedContracts = {
        421614: {
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
        selectPonderDeployment(["421614"], allGeneratedContracts, {
            421614: manifest,
        }),
        {
            chainId: "421614",
            factoryAddress,
            governorAddress,
            governorBlock: 1234,
        },
    );
});

test("Ponder rejects promoted public-chain contracts that do not match the manifest", async () => {
    const { selectPonderDeployment } = await import("../generateTsAbis.js");
    const manifest = await makePromotedManifest("421614");
    const allGeneratedContracts = {
        421614: {
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
        selectPonderDeployment(["421614"], allGeneratedContracts, {
            421614: manifest,
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
