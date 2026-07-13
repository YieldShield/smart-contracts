const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { test } = require("node:test");

const workflow = readFileSync(
    join(__dirname, "..", "..", ".github", "workflows", "ci.yml"),
    "utf8",
);

test("coverage excludes instrumentation-sensitive gas benchmarks only", () => {
    const checks = workflow.slice(
        workflow.indexOf("  checks:"),
        workflow.indexOf("  fork-tests:"),
    );
    assert.match(checks, /run: forge test\n/u);
    assert.doesNotMatch(checks, /FactoryLinearScanGas/u);

    const coverage = workflow.slice(
        workflow.indexOf("  coverage:"),
        workflow.indexOf("  slither:"),
    );
    assert.match(
        coverage,
        /forge coverage .* --report lcov --exclude-tests --no-match-path "test\/FactoryLinearScanGas\.t\.sol"/u,
    );
    assert.match(coverage, /run: npm run coverage-check/u);
});

test("package exposes the enforcing coverage command", () => {
    const packageJson = JSON.parse(
        readFileSync(join(__dirname, "..", "..", "package.json"), "utf8"),
    );
    assert.equal(
        packageJson.scripts["coverage-check"],
        "node scripts-js/checkCoverage.js lcov.info",
    );
});
