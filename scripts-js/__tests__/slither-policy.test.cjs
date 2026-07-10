const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const root = join(__dirname, "..", "..");

test("Slither 0.11.5 is pinned in both jobs without detector-family exclusions", () => {
    const workflow = readFileSync(
        join(root, ".github", "workflows", "ci.yml"),
        "utf8",
    );
    const pins = workflow.match(/slither-analyzer==0\.11\.5/gu) || [];
    assert.equal(pins.length, 2, "both Slither jobs must pin 0.11.5");

    const gate = workflow.slice(
        workflow.indexOf("  slither-gate:"),
        workflow.indexOf("  aderyn:"),
    );
    assert.match(gate, /--fail-high/u);
    assert.doesNotMatch(gate, /--exclude(?:-|\s)/u);

    const config = JSON.parse(
        readFileSync(join(root, "slither.config.json"), "utf8"),
    );
    for (const detector of [
        "reentrancy-balance",
        "pyth-unchecked-confidence",
        "pyth-unchecked-publishtime",
    ]) {
        assert.equal(
            config.detectors_to_exclude.includes(detector),
            false,
            `${detector} must remain visible`,
        );
    }

    const pool = readFileSync(
        join(root, "contracts", "SplitRiskPool.sol"),
        "utf8",
    );
    const narrowSuppressions =
        pool.match(/slither-disable-next-line reentrancy-balance/gu) || [];
    assert.equal(
        narrowSuppressions.length,
        3,
        "only the three callback-tested balance paths may be suppressed",
    );
});
