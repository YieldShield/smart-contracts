const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
    classifyConfiguredTokenRefreshes,
    discoverConfiguredPythTokens,
    parseCliArgs,
    shouldRequireAllPriceUpdates,
    verifyPythTokenFreshness,
} = require("../update-pyth-prices.cjs");

const ZERO_HASH =
    "0x0000000000000000000000000000000000000000000000000000000000000000";

function makeOracleMock({ configured = {}, eventTokens = [], queryFails = false, stale = {} } = {}) {
    return {
        filters: {
            TokenPriceFeedSet: () => "TokenPriceFeedSet",
            TokenCompositePriceFeedSet: () => "TokenCompositePriceFeedSet",
        },
        async queryFilter(filterName) {
            if (queryFails) throw new Error("log range too large");
            if (filterName === "TokenPriceFeedSet") {
                return eventTokens.map((token) => ({ args: { token } }));
            }
            return [];
        },
        async isPriceStale(address) {
            const entry = stale[address.toLowerCase()] || {};
            if (entry.throws) throw new Error(entry.throws);
            return [Boolean(entry.isStale), BigInt(entry.publishTime || 123)];
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
            if (tokens instanceof Error) throw tokens;
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

test("classifyConfiguredTokenRefreshes separates refreshed and skipped feeds", () => {
    const baseA =
        "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const baseB =
        "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const quoteB =
        "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const baseC =
        "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const quoteC =
        "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    const baseD =
        "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

    const { refreshedTokens, skippedTokens } =
        classifyConfiguredTokenRefreshes({
            configuredTokens: [
                { name: "A", actualFeedId: baseA },
                { name: "B", actualFeedId: baseB, actualQuoteFeedId: quoteB },
                { name: "C", actualFeedId: baseC, actualQuoteFeedId: quoteC },
                { name: "D", actualFeedId: baseD },
            ],
            updates: [
                { feedId: baseA, update: "0x01" },
                { feedId: baseB.toUpperCase(), update: "0x02" },
                { feedId: baseC, update: "0x03" },
                { feedId: quoteC, update: "0x04" },
            ],
            failures: [
                { feedId: quoteB, reason: "missing quote" },
                { feedId: baseD, reason: "missing base" },
            ],
        });

    assert.deepEqual(
        refreshedTokens.map((token) => token.name),
        ["A", "C"],
    );
    assert.deepEqual(
        skippedTokens.map(({ token }) => token.name),
        ["B", "D"],
    );
    assert.deepEqual(skippedTokens[0].missingFeedIds, [quoteB]);
    assert.deepEqual(skippedTokens[0].failedFeedIds, [quoteB]);
    assert.deepEqual(skippedTokens[1].missingFeedIds, [baseD]);
    assert.deepEqual(skippedTokens[1].failedFeedIds, [baseD]);
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

test("discoverConfiguredPythTokens fails closed on strict factory discovery errors", async () => {
    const oracleContract = makeOracleMock();
    const factoryContract = makeFactoryMock(new Error("rpc unavailable"));

    await assert.rejects(
        () =>
            discoverConfiguredPythTokens({
                oracleContract,
                factoryContract,
                registryTokens: [],
                requireCompleteDiscovery: true,
            }),
        /Could not read factory whitelist/u,
    );
});

test("discoverConfiguredPythTokens allows relaxed event scan warnings", async () => {
    const token = "0x00000000000000000000000000000000000000dd";
    const feedId =
        "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const oracleContract = makeOracleMock({
        queryFails: true,
        configured: {
            [token]: { supported: true, feedId },
        },
    });

    const { configuredTokens } = await discoverConfiguredPythTokens({
        oracleContract,
        factoryContract: null,
        registryTokens: [{ name: "REG", address: token, feedId }],
        requireCompleteDiscovery: false,
    });

    assert.equal(configuredTokens.length, 1);
});

test("verifyPythTokenFreshness rejects refreshed tokens that remain stale", async () => {
    const token = "0x00000000000000000000000000000000000000ee";
    const configuredTokens = [{ name: "STALE", address: token }];
    const oracleContract = makeOracleMock({
        stale: {
            [token]: { isStale: true, publishTime: 42 },
        },
    });

    await assert.rejects(
        () =>
            verifyPythTokenFreshness({
                oracleContract,
                configuredTokens,
                refreshedTokens: configuredTokens,
                requireAllPriceUpdates: false,
            }),
        /Pyth price freshness verification failed/u,
    );
});

test("verifyPythTokenFreshness only warns for skipped stale tokens in partial mode", async () => {
    const refreshed = "0x00000000000000000000000000000000000000f1";
    const skipped = "0x00000000000000000000000000000000000000f2";
    const configuredTokens = [
        { name: "FRESH", address: refreshed },
        { name: "SKIPPED", address: skipped },
    ];
    const oracleContract = makeOracleMock({
        stale: {
            [skipped]: { isStale: true, publishTime: 42 },
        },
    });

    const { staleTokens } = await verifyPythTokenFreshness({
        oracleContract,
        configuredTokens,
        refreshedTokens: [configuredTokens[0]],
        requireAllPriceUpdates: false,
    });

    assert.equal(staleTokens.length, 1);
    assert.equal(staleTokens[0].token.name, "SKIPPED");
});
