import { spawnSync } from "child_process";

const RUNTIME_LIMIT = Number.parseInt(
    process.env.FOUNDRY_RUNTIME_SIZE_LIMIT || "24576",
    10,
);
const INITCODE_LIMIT = Number.parseInt(
    process.env.FOUNDRY_INITCODE_SIZE_LIMIT || "49152",
    10,
);
const WARNING_MARGIN = Number.parseInt(
    process.env.FOUNDRY_SIZE_WARNING_MARGIN || "512",
    10,
);
const REPORT_ONLY = process.env.CONTRACT_SIZE_REPORT_ONLY === "true";
const ACCEPTED_SIZE_EXCEPTIONS = {
    SplitRiskPool: {
        runtimeLimit: 43_000,
        initcodeLimit: INITCODE_LIMIT,
        reason: "tracked monolith pending module split",
    },
    SplitRiskPoolFactory: {
        runtimeLimit: 41_000,
        initcodeLimit: INITCODE_LIMIT,
        reason: "tracked monolith pending module split",
    },
};
const SIZE_LIMIT_ERROR_MARKERS = [
    "some contracts exceed the runtime size limit",
    "some contracts exceed the initcode size limit",
];

function stripAnsi(value) {
    return value.replace(/\u001b\[[0-9;]*m/g, "");
}

function stripSizeLimitErrorLines(value) {
    const hadTrailingNewline = value.endsWith("\n");
    const stripped = value
        .split(/\r?\n/)
        .filter((line) => {
            const plainLine = stripAnsi(line);
            return !SIZE_LIMIT_ERROR_MARKERS.some((marker) =>
                plainLine.includes(marker),
            );
        })
        .join("\n");

    return hadTrailingNewline && stripped.length > 0
        ? `${stripped}\n`
        : stripped;
}

function runForge(args) {
    const result = spawnSync("forge", args, {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
    });

    if (result.error) {
        throw result.error;
    }

    return result;
}

function parseNumber(value) {
    return Number.parseInt(value.replaceAll(",", ""), 10);
}

function parseSizeRows(output) {
    return output
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line.startsWith("|"))
        .map((line) => line.split("|").map((part) => part.trim()))
        .filter((parts) => parts.length >= 7)
        .map((parts) => ({
            contract: parts[1],
            runtimeSize: parseNumber(parts[2]),
            initcodeSize: parseNumber(parts[3]),
            runtimeMargin: parseNumber(parts[4]),
            initcodeMargin: parseNumber(parts[5]),
        }))
        .filter((row) => Number.isFinite(row.runtimeSize));
}

function isDeployableRow(contract) {
    return !contract.includes("(test/") && !contract.includes("(script/");
}

function formatRow(row) {
    return `${row.contract}: runtime ${row.runtimeSize} B (margin ${row.runtimeMargin} B), initcode ${row.initcodeSize} B (margin ${row.initcodeMargin} B)`;
}

function getAcceptedSizeException(row) {
    return ACCEPTED_SIZE_EXCEPTIONS[row.contract];
}

function isWithinAcceptedSizeException(row) {
    const exception = getAcceptedSizeException(row);
    if (!exception) return false;

    return (
        row.runtimeSize <= exception.runtimeLimit &&
        row.initcodeSize <= exception.initcodeLimit
    );
}

function exceedsEffectiveLimit(row) {
    const exception = getAcceptedSizeException(row);
    const runtimeLimit = exception?.runtimeLimit ?? RUNTIME_LIMIT;
    const initcodeLimit = exception?.initcodeLimit ?? INITCODE_LIMIT;

    return row.runtimeSize > runtimeLimit || row.initcodeSize > initcodeLimit;
}

function isSizeLimitOnlyFailure(result) {
    const output = stripAnsi(`${result.stdout}\n${result.stderr}`);
    // forge prints "Compiler run successful!" with no warnings, but
    // "Compiler run successful with warnings:" when warnings are present.
    // Match the common prefix so a clean compile that only trips the EIP-170
    // size limit is still treated as a size-only failure (and honored as
    // report-only), rather than being misclassified as a hard build error.
    return (
        output.includes("Compiler run successful") &&
        SIZE_LIMIT_ERROR_MARKERS.some((marker) => output.includes(marker))
    );
}

const cleanResult = runForge(["clean"]);
if (cleanResult.status !== 0) {
    process.stdout.write(cleanResult.stdout);
    process.stderr.write(cleanResult.stderr);
    process.exit(cleanResult.status || 1);
}

const buildResult = runForge([
    "build",
    "--sizes",
    "--skip",
    "test",
    "--skip",
    "script",
]);

const sizeLimitOnlyFailure =
    buildResult.status !== 0 && isSizeLimitOnlyFailure(buildResult);
process.stdout.write(
    sizeLimitOnlyFailure
        ? stripSizeLimitErrorLines(buildResult.stdout)
        : buildResult.stdout,
);
process.stderr.write(
    sizeLimitOnlyFailure
        ? stripSizeLimitErrorLines(buildResult.stderr)
        : buildResult.stderr,
);
if (buildResult.status !== 0 && !sizeLimitOnlyFailure) {
    process.exit(buildResult.status || 1);
}

const rows = parseSizeRows(stripAnsi(buildResult.stdout));
const deployableRows = rows.filter((row) => isDeployableRow(row.contract));

if (deployableRows.length === 0) {
    console.error(
        "No contract size rows were parsed from `forge build --sizes`.",
    );
    process.exit(1);
}

const violations = deployableRows.filter(
    (row) => exceedsEffectiveLimit(row),
);

const acceptedExceptionRows = deployableRows.filter(
    (row) =>
        (row.runtimeSize > RUNTIME_LIMIT || row.initcodeSize > INITCODE_LIMIT) &&
        isWithinAcceptedSizeException(row),
);

const nearLimitRows = deployableRows
    .filter(
        (row) => row.runtimeMargin >= 0 && row.runtimeMargin < WARNING_MARGIN,
    )
    .sort((left, right) => left.runtimeMargin - right.runtimeMargin);

if (nearLimitRows.length > 0) {
    console.warn(`Contracts within ${WARNING_MARGIN} B of the runtime limit:`);
    for (const row of nearLimitRows) {
        console.warn(`- ${formatRow(row)}`);
    }
}

if (acceptedExceptionRows.length > 0) {
    console.warn("Accepted contract size exceptions under tracked ceilings:");
    for (const row of acceptedExceptionRows) {
        const exception = getAcceptedSizeException(row);
        console.warn(
            `- ${formatRow(row)}; accepted ceiling runtime ${exception.runtimeLimit} B, initcode ${exception.initcodeLimit} B (${exception.reason})`,
        );
    }
}

if (violations.length > 0) {
    const logViolation = REPORT_ONLY ? console.warn : console.error;
    const suffix = REPORT_ONLY ? " (report-only)" : "";
    logViolation(`Contract size limit violations detected${suffix}:`);
    for (const row of violations) {
        logViolation(`- ${formatRow(row)}`);
    }
    if (REPORT_ONLY) {
        console.log(
            `Checked ${deployableRows.length} deployable contracts from a clean build. Size violations are reported above.`,
        );
    } else {
        process.exit(1);
    }
} else {
    console.log(
        `Checked ${deployableRows.length} deployable contracts from a clean build. No size limit violations detected.`,
    );
}
