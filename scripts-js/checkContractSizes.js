import { spawnSync } from "child_process";

const RUNTIME_LIMIT = Number.parseInt(
  process.env.FOUNDRY_RUNTIME_SIZE_LIMIT || "24576",
  10
);
const INITCODE_LIMIT = Number.parseInt(
  process.env.FOUNDRY_INITCODE_SIZE_LIMIT || "49152",
  10
);
const WARNING_MARGIN = Number.parseInt(
  process.env.FOUNDRY_SIZE_WARNING_MARGIN || "512",
  10
);

function stripAnsi(value) {
  return value.replace(/\u001b\[[0-9;]*m/g, "");
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

const cleanResult = runForge(["clean"]);
if (cleanResult.status !== 0) {
  process.stdout.write(cleanResult.stdout);
  process.stderr.write(cleanResult.stderr);
  process.exit(cleanResult.status || 1);
}

const buildResult = runForge(["build", "--sizes"]);
process.stdout.write(buildResult.stdout);
process.stderr.write(buildResult.stderr);

if (buildResult.status !== 0) {
  process.exit(buildResult.status || 1);
}

const rows = parseSizeRows(stripAnsi(buildResult.stdout));
const deployableRows = rows.filter((row) => isDeployableRow(row.contract));

if (deployableRows.length === 0) {
  console.error(
    "No contract size rows were parsed from `forge build --sizes`."
  );
  process.exit(1);
}

const violations = deployableRows.filter(
  (row) =>
    row.runtimeSize > RUNTIME_LIMIT ||
    row.initcodeSize > INITCODE_LIMIT ||
    row.runtimeMargin < 0 ||
    row.initcodeMargin < 0
);

const nearLimitRows = deployableRows
  .filter((row) => row.runtimeMargin >= 0 && row.runtimeMargin < WARNING_MARGIN)
  .sort((left, right) => left.runtimeMargin - right.runtimeMargin);

if (nearLimitRows.length > 0) {
  console.warn(`Contracts within ${WARNING_MARGIN} B of the runtime limit:`);
  for (const row of nearLimitRows) {
    console.warn(`- ${formatRow(row)}`);
  }
}

if (violations.length > 0) {
  console.error("Contract size limit violations detected:");
  for (const row of violations) {
    console.error(`- ${formatRow(row)}`);
  }
  process.exit(1);
}

console.log(
  `Checked ${deployableRows.length} deployable contracts from a clean build. No size limit violations detected.`
);
