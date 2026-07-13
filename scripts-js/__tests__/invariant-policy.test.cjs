const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const test = require("node:test");

const root = join(__dirname, "..", "..");
const workflow = readFileSync(
    join(root, ".github", "workflows", "ci.yml"),
    "utf8",
);
const invariantTest = readFileSync(
    join(root, "test", "SplitRiskPoolInvariant.t.sol"),
    "utf8",
);
const expiredBackingInvariantTest = readFileSync(
    join(root, "test", "SplitRiskPoolExpiredBackingInvariant.t.sol"),
    "utf8",
);
const retirementInvariantTest = readFileSync(
    join(root, "test", "SplitRiskPoolRetirementInvariant.t.sol"),
    "utf8",
);

const checksJob = workflow.slice(
    workflow.indexOf("  checks:"),
    workflow.indexOf("  arbitrum-public-fork-smokes:"),
);

test("deterministic seeding is included in handler reachability metrics", () => {
    const enableIndex = invariantTest.indexOf("handler.enableMetrics();");
    const seedIndex = invariantTest.indexOf("_seedReachableHandlerPaths();");
    assert.ok(enableIndex >= 0, "handler metrics are never enabled");
    assert.ok(seedIndex >= 0, "deterministic handler seed is missing");
    assert.ok(
        enableIndex < seedIndex,
        "handler metrics must be enabled before seeding",
    );

    assert.match(
        invariantTest,
        /vm\.envOr\("INVARIANT_REQUIRE_HANDLER_REACHABILITY", false\)/u,
    );
    assert.doesNotMatch(
        invariantTest,
        /INVARIANT_REQUIRE_RANDOM_REACHABILITY/u,
    );
    assert.match(
        invariantTest,
        /test_seedProvesRequiredHandlerPathReachability/u,
    );
    assert.equal(
        invariantTest.match(/_assertSeededHandlerMetrics\(/gu)?.length ?? 0,
        14,
        "all 13 required selectors plus the helper definition must remain present",
    );
    assert.match(invariantTest, /if \(requireHandlerReachability\)/u);
    assert.match(invariantTest, /_assertHandlerCoverage\(/u);

    for (const source of [
        expiredBackingInvariantTest,
        retirementInvariantTest,
    ]) {
        assert.match(
            source,
            /vm\.envOr\("INVARIANT_REQUIRE_HANDLER_REACHABILITY", false\)/u,
        );
        assert.doesNotMatch(source, /INVARIANT_REQUIRE_RANDOM_REACHABILITY/u);
        assert.match(source, /if \(requireHandlerReachability\)/u);
        assert.match(source, /_assertReached\(/u);
    }
});

test("CI runs reviewed invariant seeds and always uploads diagnostic logs", () => {
    assert.match(checksJob, /INVARIANT_REQUIRE_HANDLER_REACHABILITY: "true"/u);
    assert.doesNotMatch(checksJob, /INVARIANT_REQUIRE_RANDOM_REACHABILITY/u);
    assert.match(checksJob, /for seed in 0x01 0x02 0x03/u);
    assert.match(checksJob, /--fuzz-seed "\$\{seed\}" -vv/u);
    assert.match(checksJob, /2>&1 \| tee "\$\{log_file\}"/u);
    assert.match(
        checksJob,
        /name: Upload deterministic invariant reachability logs[\s\S]*?if: always\(\)/u,
    );
    assert.match(checksJob, /path: invariant-reachability-\*\.log/u);

    assert.match(checksJob, /run: npm test/u);
    assert.doesNotMatch(checksJob, /npm test[^\n]*--fuzz-seed/u);
});
