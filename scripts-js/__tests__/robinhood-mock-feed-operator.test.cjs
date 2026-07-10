const assert = require("node:assert/strict");
const { test } = require("node:test");
const { ethers } = require("ethers");
const {
    FEED_SPECS,
    FIXTURE_ID,
    inspectFixture,
    refreshFixture,
    validateFixtureManifest,
} = require("../robinhood-mock-feed-operator.cjs");

const OWNER = "0x00000000000000000000000000000000000000A1";
const RUNTIME_CODE = "0x6001600055";

function addressForIndex(index) {
    return ethers.getAddress(`0x${index.toString(16).padStart(40, "0")}`);
}

function makeHarness({
    chainId = 46_630n,
    now = 100_000,
    updatedAt = 99_000,
} = {}) {
    const states = new Map();
    const feeds = {};
    let index = 1;
    for (const [symbol, spec] of Object.entries(FEED_SPECS)) {
        const address = addressForIndex(index++);
        feeds[symbol] = {
            address,
            deploymentName: spec.deploymentName,
            description: spec.description,
            decimals: 8,
        };
        states.set(address, {
            owner: OWNER,
            description: spec.description,
            decimals: 8,
            roundId: 1n,
            answer: BigInt(index) * 100_000_000n,
            updatedAt,
            setAnswers: [],
        });
    }

    const fixture = {
        schemaVersion: 1,
        fixtureId: FIXTURE_ID,
        chainId: 46_630,
        synthetic: true,
        maxPriceAgeSeconds: 86_400,
        nearExpirySeconds: 3_600,
        expiresAt: updatedAt + 86_400,
        expectedRuntimeCodehash: ethers.keccak256(RUNTIME_CODE),
        expectedOwner: OWNER,
        feeds,
    };
    const manifest = {
        fixtureMetadata: { robinhoodStandardMockFeeds: fixture },
    };
    const provider = {
        async getNetwork() {
            return { chainId };
        },
        async getBlock() {
            return { timestamp: now };
        },
        async getCode(address) {
            return states.has(ethers.getAddress(address)) ? RUNTIME_CODE : "0x";
        },
    };
    const contractFactory = (address) => {
        const state = states.get(ethers.getAddress(address));
        return {
            async owner() {
                return state.owner;
            },
            async description() {
                return state.description;
            },
            async decimals() {
                return state.decimals;
            },
            async latestRoundData() {
                return [
                    state.roundId,
                    state.answer,
                    BigInt(state.updatedAt),
                    BigInt(state.updatedAt),
                    state.roundId,
                ];
            },
            async setAnswer(answer) {
                state.setAnswers.push(BigInt(answer));
                state.answer = BigInt(answer);
                state.roundId++;
                state.updatedAt = now;
                return {
                    hash: `0x${state.roundId.toString(16).padStart(64, "0")}`,
                    async wait() {},
                };
            },
        };
    };

    return {
        manifest,
        fixture: validateFixtureManifest(manifest),
        provider,
        contractFactory,
        states,
        now,
    };
}

test("fixture validation rejects incomplete standard inventory", () => {
    const { manifest } = makeHarness();
    delete manifest.fixtureMetadata.robinhoodStandardMockFeeds.feeds.AMD;

    assert.throws(
        () => validateFixtureManifest(manifest),
        /Fixture feeds must contain exactly/u,
    );
});

test("health fails for stale and near-expiry fixture rounds", async () => {
    const stale = makeHarness({ now: 200_000, updatedAt: 100_000 });
    const staleHealth = await inspectFixture(stale);
    assert.equal(staleHealth.ok, false);
    assert.match(staleHealth.healthIssues[0], /stale/u);

    const nearExpiry = makeHarness({ now: 100_000, updatedAt: 17_000 });
    const nearExpiryHealth = await inspectFixture(nearExpiry);
    assert.equal(nearExpiryHealth.ok, false);
    assert.match(nearExpiryHealth.healthIssues[0], /near expiry/u);
});

test("inspection rejects wrong chain", async () => {
    const harness = makeHarness({ chainId: 46_631n });
    await assert.rejects(
        () => inspectFixture(harness),
        /requires chain 46630/u,
    );
});

test("inspection rejects unexpected owner", async () => {
    const harness = makeHarness();
    const amd = harness.fixture.feeds.AMD.address;
    harness.states.get(amd).owner =
        "0x00000000000000000000000000000000000000B2";

    await assert.rejects(
        () => inspectFixture(harness),
        /AMD feed owner mismatch/u,
    );
});

test("inspection rejects unexpected runtime codehash", async () => {
    const harness = makeHarness();
    const originalGetCode = harness.provider.getCode;
    harness.provider.getCode = async (address) =>
        ethers.getAddress(address) === harness.fixture.feeds.AMD.address
            ? "0x6002600055"
            : originalGetCode(address);

    await assert.rejects(
        () => inspectFixture(harness),
        /AMD feed runtime codehash mismatch/u,
    );
});

test("authorized refresh preserves answers except explicit feed updates", async () => {
    const harness = makeHarness({ now: 100_000, updatedAt: 99_000 });
    const before = Object.fromEntries(
        Object.entries(harness.fixture.feeds).map(([symbol, feed]) => [
            symbol,
            harness.states.get(feed.address).answer,
        ]),
    );
    const signer = {
        async getAddress() {
            return OWNER;
        },
    };
    const explicitTslaAnswer = before.TSLA + 123n;

    const result = await refreshFixture({
        provider: harness.provider,
        signer,
        fixture: harness.fixture,
        confirmation: FIXTURE_ID,
        answerUpdates: { TSLA: explicitTslaAnswer },
        contractFactory: harness.contractFactory,
    });

    assert.equal(result.expiresAt, harness.now + 86_400);
    for (const [symbol, feed] of Object.entries(harness.fixture.feeds)) {
        const state = harness.states.get(feed.address);
        assert.equal(state.setAnswers.length, 1);
        assert.equal(
            state.answer,
            symbol === "TSLA" ? explicitTslaAnswer : before[symbol],
        );
        assert.equal(
            result.refreshed[symbol].explicitlyUpdated,
            symbol === "TSLA",
        );
    }
});

test("refresh requires exact synthetic-fixture confirmation and owner signer", async () => {
    const harness = makeHarness();
    await assert.rejects(
        () =>
            refreshFixture({
                provider: harness.provider,
                signer: {
                    async getAddress() {
                        return OWNER;
                    },
                },
                fixture: harness.fixture,
                confirmation: "yes",
                contractFactory: harness.contractFactory,
            }),
        /confirm-synthetic-fixture/u,
    );
    await assert.rejects(
        () =>
            refreshFixture({
                provider: harness.provider,
                signer: {
                    async getAddress() {
                        return "0x00000000000000000000000000000000000000B2";
                    },
                },
                fixture: harness.fixture,
                confirmation: FIXTURE_ID,
                contractFactory: harness.contractFactory,
            }),
        /Refresh signer must be fixture owner/u,
    );
});
