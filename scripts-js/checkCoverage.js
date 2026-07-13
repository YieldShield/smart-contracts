import { readFileSync } from "fs";
import { isAbsolute, relative, resolve } from "path";
import { fileURLToPath } from "url";

const PROJECT_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));

// Explicitly reviewed production security boundary. Keep this separate from the
// floor table so CI fails if a security-critical contract is inventoried without
// a corresponding per-contract coverage floor (or vice versa).
const SECURITY_CRITICAL_CONTRACTS = Object.freeze([
    "contracts/ProtectorCommissionEscrow.sol",
    "contracts/SplitRiskPool.sol",
    "contracts/SplitRiskPoolFactory.sol",
    "contracts/YSGovernor.sol",
    "contracts/YSToken.sol",
    "contracts/governance/YSTimelockController.sol",
    "contracts/oracles/ChainlinkOracleFeed.sol",
    "contracts/oracles/CompositeOracle.sol",
    "contracts/oracles/ERC4626OracleFeed.sol",
    "contracts/oracles/PythOracle.sol",
    "contracts/oracles/RobinhoodStockOracleFeed.sol",
    "contracts/oracles/SequencerUptimeGuard.sol",
    "contracts/oracles/USMarketSessionGate.sol",
]);

const COVERAGE_POLICY = Object.freeze({
    aggregate: Object.freeze({ lines: 85, branches: 53 }),
    critical: Object.freeze({
        // Reviewed 2026-07-13 LCOV: 91.30% lines / 50.00% branches.
        // These floors fail if any currently hit line or branch becomes unhit.
        "contracts/ProtectorCommissionEscrow.sol": Object.freeze({
            lines: 90,
            branches: 49,
        }),
        "contracts/SplitRiskPool.sol": Object.freeze({
            lines: 84,
            branches: 52,
        }),
        "contracts/SplitRiskPoolFactory.sol": Object.freeze({
            lines: 81,
            branches: 48,
        }),
        "contracts/YSGovernor.sol": Object.freeze({
            lines: 83,
            branches: 51,
        }),
        "contracts/YSToken.sol": Object.freeze({
            lines: 87,
            branches: 49,
        }),
        "contracts/governance/YSTimelockController.sol": Object.freeze({
            lines: 87,
            branches: 63,
        }),
        "contracts/oracles/ChainlinkOracleFeed.sol": Object.freeze({
            lines: 88,
            branches: 64,
        }),
        "contracts/oracles/CompositeOracle.sol": Object.freeze({
            lines: 87,
            branches: 56,
        }),
        "contracts/oracles/ERC4626OracleFeed.sol": Object.freeze({
            lines: 86,
            branches: 61,
        }),
        "contracts/oracles/PythOracle.sol": Object.freeze({
            lines: 89,
            branches: 57,
        }),
        "contracts/oracles/RobinhoodStockOracleFeed.sol": Object.freeze({
            lines: 94,
            branches: 90,
        }),
        // Reviewed 2026-07-13 LCOV: 78.57% lines / 52.17% branches.
        // These floors fail if any currently hit line or branch becomes unhit.
        "contracts/oracles/SequencerUptimeGuard.sol": Object.freeze({
            lines: 77,
            branches: 51,
        }),
        // Reviewed 2026-07-13 LCOV: 93.48% lines / 50.00% branches.
        // These floors fail if any currently hit line or branch becomes unhit.
        "contracts/oracles/USMarketSessionGate.sol": Object.freeze({
            lines: 92,
            branches: 49,
        }),
    }),
});

function normalizeSourcePath(sourcePath, projectRoot = PROJECT_ROOT) {
    const normalizedSource = sourcePath.replaceAll("\\", "/");
    if (!isAbsolute(normalizedSource)) {
        return normalizedSource.replace(/^\.\//u, "");
    }

    const projectRelative = relative(projectRoot, normalizedSource).replaceAll(
        "\\",
        "/",
    );
    return projectRelative.startsWith("../")
        ? normalizedSource
        : projectRelative;
}

function isProductionContract(sourcePath) {
    return (
        sourcePath.startsWith("contracts/") &&
        !/^contracts\/(?:examples|interfaces|mocks)\//u.test(sourcePath)
    );
}

function parseInteger(value, context) {
    if (!/^\d+$/u.test(value)) {
        throw new Error(
            `Malformed ${context}: expected a non-negative integer.`,
        );
    }
    return Number.parseInt(value, 10);
}

function parseLcov(contents, { projectRoot = PROJECT_ROOT } = {}) {
    if (typeof contents !== "string" || contents.trim() === "") {
        throw new Error("Coverage report is empty.");
    }

    const sources = new Map();
    let current;

    const finishRecord = (lineNumber) => {
        if (!current) {
            throw new Error(
                `Malformed LCOV at line ${lineNumber}: end_of_record without SF.`,
            );
        }

        const existing = sources.get(current.path) ?? {
            lines: new Map(),
            branches: new Map(),
        };
        for (const [line, hits] of current.lines) {
            existing.lines.set(
                line,
                Math.max(existing.lines.get(line) ?? 0, hits),
            );
        }
        for (const [branch, hits] of current.branches) {
            existing.branches.set(
                branch,
                Math.max(existing.branches.get(branch) ?? 0, hits),
            );
        }
        sources.set(current.path, existing);
        current = undefined;
    };

    const rows = contents.split(/\r?\n/u);
    rows.forEach((rawLine, index) => {
        const lineNumber = index + 1;
        const line = rawLine.trim();
        if (line === "") return;

        if (line.startsWith("SF:")) {
            if (current) {
                throw new Error(
                    `Malformed LCOV at line ${lineNumber}: SF before end_of_record.`,
                );
            }
            const sourcePath = line.slice(3);
            if (sourcePath === "") {
                throw new Error(
                    `Malformed LCOV at line ${lineNumber}: empty SF path.`,
                );
            }
            current = {
                path: normalizeSourcePath(sourcePath, projectRoot),
                lines: new Map(),
                branches: new Map(),
            };
            return;
        }

        if (line === "end_of_record") {
            finishRecord(lineNumber);
            return;
        }

        if (line.startsWith("DA:")) {
            if (!current) {
                throw new Error(
                    `Malformed LCOV at line ${lineNumber}: DA before SF.`,
                );
            }
            const match = /^DA:(\d+),(\d+)(?:,[^,]+)?$/u.exec(line);
            if (!match) {
                throw new Error(`Malformed DA record at line ${lineNumber}.`);
            }
            const sourceLine = parseInteger(match[1], "DA line number");
            const hits = parseInteger(match[2], "DA hit count");
            current.lines.set(
                sourceLine,
                Math.max(current.lines.get(sourceLine) ?? 0, hits),
            );
            return;
        }

        if (line.startsWith("BRDA:")) {
            if (!current) {
                throw new Error(
                    `Malformed LCOV at line ${lineNumber}: BRDA before SF.`,
                );
            }
            const match = /^BRDA:(\d+),([^,]+),([^,]+),(-|\d+)$/u.exec(line);
            if (!match) {
                throw new Error(`Malformed BRDA record at line ${lineNumber}.`);
            }
            const sourceLine = parseInteger(match[1], "BRDA line number");
            const hits =
                match[4] === "-" ? 0 : parseInteger(match[4], "BRDA hit count");
            const branchKey = `${sourceLine}:${match[2]}:${match[3]}`;
            current.branches.set(
                branchKey,
                Math.max(current.branches.get(branchKey) ?? 0, hits),
            );
            return;
        }

        if (/^(?:DA|BRDA):/u.test(line)) {
            throw new Error(`Malformed coverage record at line ${lineNumber}.`);
        }
    });

    if (current) {
        throw new Error(
            "Malformed LCOV: final source is missing end_of_record.",
        );
    }

    return sources;
}

function summarize(entries) {
    let lineTotal = 0;
    let lineHit = 0;
    let branchTotal = 0;
    let branchHit = 0;

    for (const entry of entries) {
        lineTotal += entry.lines.size;
        lineHit += [...entry.lines.values()].filter((hits) => hits > 0).length;
        branchTotal += entry.branches.size;
        branchHit += [...entry.branches.values()].filter(
            (hits) => hits > 0,
        ).length;
    }

    return {
        lines: { hit: lineHit, total: lineTotal },
        branches: { hit: branchHit, total: branchTotal },
    };
}

function percentage(metric) {
    return metric.total === 0 ? undefined : (metric.hit / metric.total) * 100;
}

function validateCriticalCoverageInventory(
    policy = COVERAGE_POLICY,
    inventory = SECURITY_CRITICAL_CONTRACTS,
) {
    const inventoried = new Set(inventory);
    const floored = new Set(Object.keys(policy.critical));
    const missingFloors = [...inventoried].filter(
        (sourcePath) => !floored.has(sourcePath),
    );
    const unreviewedFloors = [...floored].filter(
        (sourcePath) => !inventoried.has(sourcePath),
    );

    if (missingFloors.length > 0 || unreviewedFloors.length > 0) {
        const details = [];
        if (missingFloors.length > 0) {
            details.push(`missing floors: ${missingFloors.sort().join(", ")}`);
        }
        if (unreviewedFloors.length > 0) {
            details.push(
                `floors outside security-critical inventory: ${unreviewedFloors.sort().join(", ")}`,
            );
        }
        throw new Error(
            `Security-critical coverage inventory mismatch (${details.join("; ")}).`,
        );
    }

    return [...inventoried].sort();
}

function evaluateCoverage(
    sources,
    policy = COVERAGE_POLICY,
    securityCriticalContracts = SECURITY_CRITICAL_CONTRACTS,
) {
    validateCriticalCoverageInventory(policy, securityCriticalContracts);
    const production = new Map(
        [...sources].filter(([sourcePath]) => isProductionContract(sourcePath)),
    );
    if (production.size === 0) {
        throw new Error("Coverage report contains no production contracts.");
    }

    const aggregate = summarize(production.values());
    if (aggregate.lines.total === 0 || aggregate.branches.total === 0) {
        throw new Error(
            "Production coverage is missing line or branch instrumentation data.",
        );
    }

    const violations = [];
    const checkFloor = (label, summary, floor) => {
        for (const metricName of ["lines", "branches"]) {
            const actual = percentage(summary[metricName]);
            if (actual === undefined) {
                violations.push(`${label} has no ${metricName} data`);
            } else if (actual + Number.EPSILON < floor[metricName]) {
                violations.push(
                    `${label} ${metricName} ${actual.toFixed(2)}% is below ${floor[metricName].toFixed(2)}%`,
                );
            }
        }
    };

    checkFloor("aggregate production coverage", aggregate, policy.aggregate);

    const critical = new Map();
    for (const [sourcePath, floor] of Object.entries(policy.critical)) {
        const entry = production.get(sourcePath);
        if (!entry) {
            violations.push(`missing critical coverage entry: ${sourcePath}`);
            continue;
        }
        const summary = summarize([entry]);
        critical.set(sourcePath, summary);
        checkFloor(sourcePath, summary, floor);
    }

    return { aggregate, critical, production, violations };
}

function formatMetric(metric) {
    const value = percentage(metric);
    return `${value?.toFixed(2) ?? "n/a"}% (${metric.hit}/${metric.total})`;
}

function checkCoverage(contents, options = {}) {
    const sources = parseLcov(contents, options);
    const result = evaluateCoverage(
        sources,
        options.policy ?? COVERAGE_POLICY,
        options.securityCriticalContracts ?? SECURITY_CRITICAL_CONTRACTS,
    );
    if (result.violations.length > 0) {
        throw new Error(
            `Coverage policy failed:\n- ${result.violations.join("\n- ")}`,
        );
    }
    return result;
}

function main() {
    const reportPath = resolve(process.argv[2] ?? "lcov.info");
    const result = checkCoverage(readFileSync(reportPath, "utf8"));
    console.log(
        `Production coverage passed for ${result.production.size} contracts: lines ${formatMetric(result.aggregate.lines)}, branches ${formatMetric(result.aggregate.branches)}.`,
    );
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    try {
        main();
    } catch (error) {
        console.error(`Coverage validation failed: ${error.message}`);
        process.exit(1);
    }
}

export {
    COVERAGE_POLICY,
    SECURITY_CRITICAL_CONTRACTS,
    checkCoverage,
    evaluateCoverage,
    isProductionContract,
    normalizeSourcePath,
    parseLcov,
    percentage,
    summarize,
    validateCriticalCoverageInventory,
};
