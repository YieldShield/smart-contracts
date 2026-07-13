const assert = require("node:assert/strict");
const { test } = require("node:test");

function lcovRecord(sourcePath, { lineHit = true, branchHit = true } = {}) {
    return [
        "TN:",
        `SF:${sourcePath}`,
        `DA:1,${lineHit ? 1 : 0}`,
        `BRDA:1,0,0,${branchHit ? 1 : "-"}`,
        "LF:1",
        `LH:${lineHit ? 1 : 0}`,
        "BRF:1",
        `BRH:${branchHit ? 1 : 0}`,
        "end_of_record",
    ].join("\n");
}

async function coverageModule() {
    return import("../checkCoverage.js");
}

test("production scope excludes mocks, examples, interfaces, scripts, and tests", async () => {
    const { isProductionContract } = await coverageModule();
    assert.equal(isProductionContract("contracts/SplitRiskPool.sol"), true);
    assert.equal(
        isProductionContract("contracts/libraries/ErrorsLib.sol"),
        true,
    );
    assert.equal(isProductionContract("contracts/mocks/MockOracle.sol"), false);
    assert.equal(
        isProductionContract("contracts/examples/AccessControlExample.sol"),
        false,
    );
    assert.equal(
        isProductionContract("contracts/interfaces/IOracleFeed.sol"),
        false,
    );
    assert.equal(isProductionContract("script/Deploy.s.sol"), false);
    assert.equal(isProductionContract("test/CompositeOracle.t.sol"), false);
});

test("checker accepts complete production coverage above every floor", async () => {
    const { COVERAGE_POLICY, checkCoverage } = await coverageModule();
    const report = Object.keys(COVERAGE_POLICY.critical)
        .map((sourcePath) => lcovRecord(sourcePath))
        .concat([
            lcovRecord("contracts/libraries/ErrorsLib.sol"),
            lcovRecord("contracts/mocks/MockOracle.sol", {
                lineHit: false,
                branchHit: false,
            }),
            lcovRecord("test/CompositeOracle.t.sol", {
                lineHit: false,
                branchHit: false,
            }),
        ])
        .join("\n");

    const result = checkCoverage(report);
    assert.equal(
        result.production.size,
        Object.keys(COVERAGE_POLICY.critical).length + 1,
    );
    assert.deepEqual(result.violations, []);
});

test("security-critical production inventory and coverage floors stay synchronized", async () => {
    const {
        COVERAGE_POLICY,
        SECURITY_CRITICAL_CONTRACTS,
        validateCriticalCoverageInventory,
    } = await coverageModule();

    assert.deepEqual(
        validateCriticalCoverageInventory(),
        [...SECURITY_CRITICAL_CONTRACTS].sort(),
    );
    assert.deepEqual(
        Object.keys(COVERAGE_POLICY.critical).sort(),
        [...SECURITY_CRITICAL_CONTRACTS].sort(),
    );

    assert.throws(
        () =>
            validateCriticalCoverageInventory(COVERAGE_POLICY, [
                ...SECURITY_CRITICAL_CONTRACTS,
                "contracts/NewSecurityBoundary.sol",
            ]),
        /missing floors: contracts\/NewSecurityBoundary\.sol/u,
    );
    assert.throws(
        () =>
            validateCriticalCoverageInventory(
                {
                    ...COVERAGE_POLICY,
                    critical: {
                        ...COVERAGE_POLICY.critical,
                        "contracts/UnreviewedFloor.sol": {
                            lines: 1,
                            branches: 1,
                        },
                    },
                },
                SECURITY_CRITICAL_CONTRACTS,
            ),
        /floors outside security-critical inventory: contracts\/UnreviewedFloor\.sol/u,
    );
});

test("checker rejects zero-hit commission escrow coverage despite a passing aggregate", async () => {
    const { COVERAGE_POLICY, checkCoverage } = await coverageModule();
    const escrowPath = "contracts/ProtectorCommissionEscrow.sol";
    const report = Object.keys(COVERAGE_POLICY.critical)
        .map((sourcePath) =>
            lcovRecord(sourcePath, {
                lineHit: sourcePath !== escrowPath,
                branchHit: sourcePath !== escrowPath,
            }),
        )
        .join("\n");

    assert.throws(
        () => checkCoverage(report),
        /contracts\/ProtectorCommissionEscrow\.sol lines 0\.00% is below 90\.00%[\s\S]*branches 0\.00% is below 49\.00%/u,
    );
});

test("checker rejects zeroed receipt NFT line and branch coverage", async () => {
    const { COVERAGE_POLICY, checkCoverage } = await coverageModule();
    const receiptFloors = [
        {
            sourcePath: "contracts/ProtectorReceiptNFT.sol",
            lines: 85,
            branches: 59,
        },
        {
            sourcePath: "contracts/ShieldReceiptNFT.sol",
            lines: 94,
            branches: 69,
        },
    ];

    for (const { sourcePath, lines, branches } of receiptFloors) {
        for (const metricName of ["lines", "branches"]) {
            const report = Object.keys(COVERAGE_POLICY.critical)
                .map((criticalPath) =>
                    lcovRecord(criticalPath, {
                        lineHit:
                            criticalPath !== sourcePath ||
                            metricName !== "lines",
                        branchHit:
                            criticalPath !== sourcePath ||
                            metricName !== "branches",
                    }),
                )
                .join("\n");
            const floor = metricName === "lines" ? lines : branches;

            assert.throws(
                () => checkCoverage(report),
                new RegExp(
                    `${sourcePath.replaceAll("/", "\\/")} ${metricName} 0\\.00% is below ${floor}\\.00%`,
                    "u",
                ),
            );
        }
    }
});

test("checker fails closed for missing critical entries", async () => {
    const { COVERAGE_POLICY, checkCoverage } = await coverageModule();
    const critical = Object.keys(COVERAGE_POLICY.critical);
    const report = critical
        .slice(1)
        .map((sourcePath) => lcovRecord(sourcePath))
        .join("\n");

    assert.throws(
        () => checkCoverage(report),
        new RegExp(`missing critical coverage entry: ${critical[0]}`, "u"),
    );
});

test("checker enforces critical and aggregate line and branch floors", async () => {
    const { COVERAGE_POLICY, checkCoverage } = await coverageModule();
    const critical = Object.keys(COVERAGE_POLICY.critical);
    const criticalFailure = critical
        .map((sourcePath) =>
            lcovRecord(sourcePath, {
                lineHit: sourcePath !== "contracts/SplitRiskPool.sol",
                branchHit: sourcePath !== "contracts/SplitRiskPool.sol",
            }),
        )
        .join("\n");
    assert.throws(
        () => checkCoverage(criticalFailure),
        /contracts\/SplitRiskPool\.sol lines 0\.00% is below 84\.00%[\s\S]*branches 0\.00% is below 52\.00%/u,
    );

    const aggregateFailure = critical
        .map((sourcePath) => lcovRecord(sourcePath))
        .concat(
            Array.from({ length: critical.length }, (_unused, index) =>
                lcovRecord(`contracts/libraries/Uncovered${index}.sol`, {
                    lineHit: false,
                    branchHit: false,
                }),
            ),
        )
        .join("\n");
    assert.throws(
        () => checkCoverage(aggregateFailure),
        /aggregate production coverage lines 50\.00% is below 85\.00%[\s\S]*branches 50\.00% is below 53\.00%/u,
    );
});

test("checker rejects empty and malformed LCOV instead of silently passing", async () => {
    const { checkCoverage, parseLcov } = await coverageModule();
    assert.throws(() => parseLcov(""), /Coverage report is empty/u);
    assert.throws(
        () => parseLcov("SF:contracts/SplitRiskPool.sol\nDA:not-valid\n"),
        /Malformed DA record/u,
    );
    assert.throws(
        () =>
            parseLcov("SF:contracts/SplitRiskPool.sol\nDA:1,1\nBRDA:1,0,0,1\n"),
        /missing end_of_record/u,
    );
    assert.throws(
        () =>
            checkCoverage(
                lcovRecord("contracts/mocks/MockOracle.sol") +
                    "\n" +
                    lcovRecord("test/CompositeOracle.t.sol"),
            ),
        /contains no production contracts/u,
    );
});

test("checker merges duplicate source records without double-counting", async () => {
    const { parseLcov, summarize } = await coverageModule();
    const sourcePath = "contracts/SplitRiskPool.sol";
    const sources = parseLcov(
        [
            lcovRecord(sourcePath, { lineHit: false, branchHit: false }),
            lcovRecord(sourcePath),
        ].join("\n"),
    );
    assert.deepEqual(summarize([sources.get(sourcePath)]), {
        lines: { hit: 1, total: 1 },
        branches: { hit: 1, total: 1 },
    });
});
