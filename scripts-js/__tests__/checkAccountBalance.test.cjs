const assert = require("node:assert/strict");
const { test } = require("node:test");

test("resolveRpcEndpoint expands environment placeholders", async () => {
    const { resolveRpcEndpoint } = await import("../checkAccountBalance.js");

    assert.deepEqual(
        resolveRpcEndpoint(
            "https://robinhood-testnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}",
            { ALCHEMY_API_KEY: "test-key" },
        ),
        {
            url: "https://robinhood-testnet.g.alchemy.com/v2/test-key",
            missingVariables: [],
        },
    );
});

test("resolveRpcEndpoint reports missing placeholders instead of returning invalid URLs", async () => {
    const { resolveRpcEndpoint } = await import("../checkAccountBalance.js");

    assert.deepEqual(resolveRpcEndpoint("${ROBINHOOD_TESTNET_RPC_URL}", {}), {
        url: null,
        missingVariables: ["ROBINHOOD_TESTNET_RPC_URL"],
    });
});

test("resolveRpcEndpoint keeps public Robinhood RPCs unchanged", async () => {
    const { resolveRpcEndpoint } = await import("../checkAccountBalance.js");

    assert.deepEqual(
        resolveRpcEndpoint("https://rpc.mainnet.chain.robinhood.com", {}),
        {
            url: "https://rpc.mainnet.chain.robinhood.com",
            missingVariables: [],
        },
    );
    assert.deepEqual(
        resolveRpcEndpoint("https://rpc.testnet.chain.robinhood.com", {}),
        {
            url: "https://rpc.testnet.chain.robinhood.com",
            missingVariables: [],
        },
    );
});
