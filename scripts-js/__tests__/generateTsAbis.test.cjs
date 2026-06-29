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

test("deploymentJsonNameForAddress matches deployment aliases case-insensitively", async () => {
    const { deploymentJsonNameForAddress } = await import(
        "../generateTsAbis.js"
    );

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
