const assert = require("node:assert/strict");
const test = require("node:test");

async function loadPolicy() {
    return import("../contract-size-policy.js");
}

function row(contract, runtimeSize, initcodeSize) {
    return { contract, runtimeSize, initcodeSize };
}

test("report-only mode permits standard-limit violations", async () => {
    const { classifySizeRows, shouldFailSizeCheck } = await loadPolicy();
    const classification = classifySizeRows([
        row("OrdinaryContract", 24_577, 1_000),
    ]);

    assert.equal(classification.standardViolations.length, 1);
    assert.equal(
        shouldFailSizeCheck(classification, { reportOnly: true }),
        false,
    );
});

test("tracked budget violations fail even in report-only mode", async () => {
    const { classifySizeRows, shouldFailSizeCheck } = await loadPolicy();
    const classification = classifySizeRows([row("SplitRiskPool", 101, 100)], {
        trackedBudgets: {
            SplitRiskPool: { runtimeLimit: 100, initcodeLimit: 100 },
        },
    });

    assert.equal(classification.trackedBudgetViolations.length, 1);
    assert.equal(
        shouldFailSizeCheck(classification, { reportOnly: true }),
        true,
    );
});

test("artifact exactly at a tracked ceiling passes", async () => {
    const { classifySizeRows, shouldFailSizeCheck } = await loadPolicy();
    const classification = classifySizeRows([row("SplitRiskPool", 100, 200)], {
        runtimeLimit: 1_000,
        initcodeLimit: 1_000,
        trackedBudgets: {
            SplitRiskPool: { runtimeLimit: 100, initcodeLimit: 200 },
        },
    });

    assert.equal(classification.trackedBudgetViolations.length, 0);
    assert.equal(shouldFailSizeCheck(classification), false);
});

test("ordinary standard-limit violation fails outside report-only mode", async () => {
    const { classifySizeRows, shouldFailSizeCheck } = await loadPolicy();
    const classification = classifySizeRows([
        row("OrdinaryContract", 24_576, 49_153),
    ]);

    assert.equal(classification.standardViolations.length, 1);
    assert.equal(
        shouldFailSizeCheck(classification, { reportOnly: false }),
        true,
    );
});
