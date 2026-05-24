const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
    discoverConfiguredPythTokens,
    parseCliArgs,
    shouldRequireAllPriceUpdates,
} = require("../update-pyth-prices.cjs");

const ZERO_HASH =
    "0x0000000000000000000000000000000000000000000000000000000000000000";

function makeOracleMock({ configured = {}, eventTokens = [] } = {}) {
    return {
        filters: {
            TokenPriceFeedSet: () => "TokenPriceFeedSet",
            TokenCompositePriceFeedSet: () => "TokenCompositePriceFeedSet",
        },
        async queryFilter(filterName) {
            if (filterName === "TokenPriceFeedSet") {
                return eventTokens.map((token) => ({ args: { token } }));
            }
            return [];
        },
        async isTokenSupported(address) {
            return Boolean(configured[address.toLowerCase()]?.supported);
        },
        async tokenToPriceFeedId(address) {
            return configured[address.toLowerCase()]?.feedId || ZERO_HASH;
        },
        async tokenToQuotePriceFeedId(address) {
            return configured[address.toLowerCase()]?.quoteFeedId || ZERO_HASH;
        },
    };
}

function makeFactoryMock(tokens) {
    return {
        async getWhitelistedTokens() {
            return tokens;
        },
    };
}

test("parseCliArgs rejects conflicting strict and allow-partial flags", () => {
    assert.throws(
        () => parseCliArgs(["--strict", "--allow-partial"]),
        /cannot be used together/u,
    );
});

test("shouldRequireAllPriceUpdates defaults to relaxed local chains", () => {
    assert.equal(
        shouldRequireAllPriceUpdates({ chainId: "31337" }),
        false,
    );
    assert.equal(
        shouldRequireAllPriceUpdates({ chainId: "1337" }),
        false,
    );
});

test("shouldRequireAllPriceUpdates defaults to strict non-local chains", () => {
    assert.equal(
        shouldRequireAllPriceUpdates({ chainId: "421614" }),
        true,
    );
});

test("shouldRequireAllPriceUpdates honors explicit flags", () => {
    assert.equal(
        shouldRequireAllPriceUpdates({
            strict: true,
            allowPartial: false,
            chainId: "31337",
        }),
        true,
    );
    assert.equal(
        shouldRequireAllPriceUpdates({
            strict: false,
            allowPartial: true,
            chainId: "421614",
        }),
        false,
    );
});

test("discoverConfiguredPythTokens includes governance-added factory tokens absent from registry", async () => {
    const token = "0x00000000000000000000000000000000000000aa";
    const feedId =
        "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const oracleContract = makeOracleMock({
        configured: {
            [token]: { supported: true, feedId },
        },
    });
    const factoryContract = makeFactoryMock([token]);

    const { configuredTokens, missingConfigs } = await discoverConfiguredPythTokens({
        oracleContract,
        factoryContract,
        registryTokens: [],
    });

    assert.equal(missingConfigs.length, 0);
    assert.equal(configuredTokens.length, 1);
    assert.equal(configuredTokens[0].address, token);
    assert.equal(configuredTokens[0].actualFeedId, feedId);
});

test("discoverConfiguredPythTokens keeps on-chain composite quote feeds", async () => {
    const token = "0x00000000000000000000000000000000000000bb";
    const feedId =
        "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const quoteFeedId =
        "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const oracleContract = makeOracleMock({
        configured: {
            [token]: { supported: true, feedId, quoteFeedId },
        },
        eventTokens: [token],
    });

    const { configuredTokens } = await discoverConfiguredPythTokens({
        oracleContract,
        factoryContract: null,
        registryTokens: [],
    });

    assert.equal(configuredTokens.length, 1);
    assert.equal(configuredTokens[0].actualFeedId, feedId);
    assert.equal(configuredTokens[0].actualQuoteFeedId, quoteFeedId);
});

test("discoverConfiguredPythTokens reports unsupported registry tokens as missing", async () => {
    const token = "0x00000000000000000000000000000000000000cc";
    const oracleContract = makeOracleMock();

    const { configuredTokens, missingConfigs } = await discoverConfiguredPythTokens({
        oracleContract,
        factoryContract: null,
        registryTokens: [{ name: "MISSING", address: token, feedId: ZERO_HASH }],
    });

    assert.equal(configuredTokens.length, 0);
    assert.equal(missingConfigs.length, 1);
    assert.equal(missingConfigs[0].name, "MISSING");
});
