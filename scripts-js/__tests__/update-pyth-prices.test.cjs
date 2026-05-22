const assert = require("node:assert/strict");
const { test } = require("node:test");
const {
    parseCliArgs,
    shouldRequireAllPriceUpdates,
} = require("../update-pyth-prices.cjs");

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
