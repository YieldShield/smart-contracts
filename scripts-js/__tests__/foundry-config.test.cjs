const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");
const toml = require("toml");

const rootDir = join(__dirname, "..", "..");

test("Robinhood operator aliases are env-backed and public RPCs are opt-in", () => {
    const foundryConfig = toml.parse(
        readFileSync(join(rootDir, "foundry.toml"), "utf8"),
    );

    assert.equal(
        foundryConfig.rpc_endpoints.robinhood,
        "${ROBINHOOD_RPC_URL}",
        "mainnet operator alias must resolve through its provider environment variable",
    );
    assert.equal(
        foundryConfig.rpc_endpoints.robinhoodTestnet,
        "${ROBINHOOD_TESTNET_RPC_URL}",
        "testnet operator alias must resolve through its provider environment variable",
    );
    assert.equal(
        foundryConfig.rpc_endpoints.robinhoodPublic,
        "https://rpc.mainnet.chain.robinhood.com",
        "rate-limited mainnet RPC must remain available only through its explicit alias",
    );
    assert.equal(
        foundryConfig.rpc_endpoints.robinhoodTestnetPublic,
        "https://rpc.testnet.chain.robinhood.com",
        "rate-limited public RPC must remain available only through its explicit alias",
    );
    assert.notEqual(
        foundryConfig.rpc_endpoints.robinhood,
        foundryConfig.rpc_endpoints.robinhoodPublic,
    );
    assert.notEqual(
        foundryConfig.rpc_endpoints.robinhoodTestnet,
        foundryConfig.rpc_endpoints.robinhoodTestnetPublic,
    );
});
