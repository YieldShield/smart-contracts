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
