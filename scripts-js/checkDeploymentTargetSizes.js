import { spawnSync } from "child_process";
import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, "..");

const ROBINHOOD_RUNTIME_SIZE_LIMIT = 96 * 1024;
const ROBINHOOD_INITCODE_SIZE_LIMIT = 192 * 1024;
const PRODUCTION_SCRIPT_PATH = join(
    PROJECT_ROOT,
    "script",
    "DeployYieldShieldProduction.s.sol",
);

// Keep this inventory exact. The source-inventory check fails when a contract
// construction is added to or removed from the production script without a
// corresponding artifact entry here.
const PRODUCTION_DEPLOYMENT_TARGETS = Object.freeze({
    ChainlinkOracleFeed: "out/ChainlinkOracleFeed.sol/ChainlinkOracleFeed.json",
    CompositeOracle: "out/CompositeOracle.sol/CompositeOracle.json",
    ConfigurableTokenFaucet:
        "out/ConfigurableTokenFaucet.sol/ConfigurableTokenFaucet.json",
    ERC1967Proxy: "out/ERC1967Proxy.sol/ERC1967Proxy.json",
    ERC4626OracleFeed: "out/ERC4626OracleFeed.sol/ERC4626OracleFeed.json",
    MockChainlinkAggregator:
        "out/MockChainlinkAggregator.sol/MockChainlinkAggregator.json",
    MockERC20Decimals: "out/MockERC20Decimals.sol/MockERC20Decimals.json",
    MockRobinhoodStockToken:
        "out/MockRobinhoodStockToken.sol/MockRobinhoodStockToken.json",
    PythOracle: "out/PythOracle.sol/PythOracle.json",
    RobinhoodStockOracleFeed:
        "out/RobinhoodStockOracleFeed.sol/RobinhoodStockOracleFeed.json",
    SplitRiskPool: "out/SplitRiskPool.sol/SplitRiskPool.json",
    SplitRiskPoolFactory:
        "out/SplitRiskPoolFactory.sol/SplitRiskPoolFactory.json",
    YSGovernor: "out/YSGovernor.sol/YSGovernor.json",
    YSTimelockController:
        "out/YSTimelockController.sol/YSTimelockController.json",
    YSToken: "out/YSToken.sol/YSToken.json",
});

function stripCommentsAndStrings(source) {
    let output = "";
    let state = "code";

    for (let index = 0; index < source.length; index++) {
        const current = source[index];
        const next = source[index + 1];

        if (state === "code") {
            if (current === "/" && next === "/") {
                output += "  ";
                index++;
                state = "line-comment";
            } else if (current === "/" && next === "*") {
                output += "  ";
                index++;
                state = "block-comment";
            } else if (current === '"' || current === "'") {
                output += " ";
                state = current === '"' ? "double-string" : "single-string";
            } else {
                output += current;
            }
            continue;
        }

        if (state === "line-comment") {
            if (current === "\n") {
                output += "\n";
                state = "code";
            } else {
                output += " ";
            }
            continue;
        }

        if (state === "block-comment") {
            if (current === "*" && next === "/") {
                output += "  ";
                index++;
                state = "code";
            } else {
                output += current === "\n" ? "\n" : " ";
            }
            continue;
        }

        const delimiter = state === "double-string" ? '"' : "'";
        if (current === "\\" && next !== undefined) {
            output += "  ";
            index++;
        } else if (current === delimiter) {
            output += " ";
            state = "code";
        } else {
            output += current === "\n" ? "\n" : " ";
        }
    }

    return output;
}

function isElementarySolidityType(typeName) {
    if (["address", "bool", "bytes", "string"].includes(typeName)) {
        return true;
    }

    if (
        /^(?:u?int)(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)?$/u.test(
            typeName,
        )
    ) {
        return true;
    }

    return /^bytes(?:[1-9]|[12][0-9]|3[0-2])$/u.test(typeName);
}

function extractConstructedContractNames(source) {
    const code = stripCommentsAndStrings(source);
    const names = new Set();
    const newExpressionPattern =
        /\bnew\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?=[([])/gu;

    for (const match of code.matchAll(newExpressionPattern)) {
        if (!isElementarySolidityType(match[1])) {
            names.add(match[1]);
        }
    }

    return [...names].sort();
}

function validateTargetInventory(
    source,
    inventory = PRODUCTION_DEPLOYMENT_TARGETS,
) {
    const constructedTargets = extractConstructedContractNames(source);
    const inventoriedTargets = Object.keys(inventory).sort();
    const constructedSet = new Set(constructedTargets);
    const inventoriedSet = new Set(inventoriedTargets);
    const missing = constructedTargets.filter(
        (target) => !inventoriedSet.has(target),
    );
    const unused = inventoriedTargets.filter(
        (target) => !constructedSet.has(target),
    );

    if (missing.length > 0 || unused.length > 0) {
        const details = [];
        if (missing.length > 0) {
            details.push(`missing: ${missing.join(", ")}`);
        }
        if (unused.length > 0) {
            details.push(`unused: ${unused.join(", ")}`);
        }
        throw new Error(
            `Production deployment target inventory mismatch (${details.join("; ")}).`,
        );
    }

    return constructedTargets;
}

function bytecodeSize(bytecode, target, field) {
    if (typeof bytecode !== "string") {
        throw new Error(`${target} artifact is missing ${field}.object.`);
    }

    const hex = bytecode.startsWith("0x") ? bytecode.slice(2) : bytecode;
    // Foundry leaves one 20-byte placeholder per linked-library reference in
    // artifact bytecode. Linking changes the bytes, not their length, so replace
    // only the canonical placeholder shape before validating and counting.
    const countableHex = hex.replace(
        /__\$[0-9a-fA-F]{34}\$__/gu,
        "0".repeat(40),
    );
    if (
        countableHex.length === 0 ||
        countableHex.length % 2 !== 0 ||
        !/^[0-9a-fA-F]+$/u.test(countableHex)
    ) {
        throw new Error(`${target} artifact has invalid ${field}.object.`);
    }

    return countableHex.length / 2;
}

function readTargetSize(target, artifact) {
    return {
        target,
        runtimeSize: bytecodeSize(
            artifact?.deployedBytecode?.object,
            target,
            "deployedBytecode",
        ),
        initcodeSize: bytecodeSize(
            artifact?.bytecode?.object,
            target,
            "bytecode",
        ),
    };
}

function validateTargetSizes(
    rows,
    {
        runtimeLimit = ROBINHOOD_RUNTIME_SIZE_LIMIT,
        initcodeLimit = ROBINHOOD_INITCODE_SIZE_LIMIT,
    } = {},
) {
    const violations = rows.filter(
        ({ runtimeSize, initcodeSize }) =>
            runtimeSize > runtimeLimit || initcodeSize > initcodeLimit,
    );

    if (violations.length > 0) {
        const details = violations
            .map(
                ({ target, runtimeSize, initcodeSize }) =>
                    `${target}: runtime ${runtimeSize} B / ${runtimeLimit} B, initcode ${initcodeSize} B / ${initcodeLimit} B`,
            )
            .join("\n- ");
        throw new Error(
            `Robinhood deployment target size limit exceeded:\n- ${details}`,
        );
    }

    return rows;
}

function checkDeploymentTargetSizes({
    source,
    inventory = PRODUCTION_DEPLOYMENT_TARGETS,
    readArtifact,
    runtimeLimit = ROBINHOOD_RUNTIME_SIZE_LIMIT,
    initcodeLimit = ROBINHOOD_INITCODE_SIZE_LIMIT,
}) {
    const targets = validateTargetInventory(source, inventory);
    const rows = targets.map((target) =>
        readTargetSize(target, readArtifact(target, inventory[target])),
    );
    return validateTargetSizes(rows, { runtimeLimit, initcodeLimit });
}

function runForgeBuild() {
    const result = spawnSync(
        "forge",
        ["build", "--offline", "--skip", "test"],
        {
            encoding: "utf8",
            stdio: ["ignore", "pipe", "pipe"],
        },
    );

    if (result.error) {
        throw result.error;
    }
    if (result.status !== 0) {
        process.stdout.write(result.stdout);
        process.stderr.write(result.stderr);
        throw new Error(
            `Forge build failed before deployment target size validation (exit ${result.status ?? 1}).`,
        );
    }
}

function main() {
    runForgeBuild();
    const source = readFileSync(PRODUCTION_SCRIPT_PATH, "utf8");
    const rows = checkDeploymentTargetSizes({
        source,
        readArtifact: (_target, relativeArtifactPath) =>
            JSON.parse(
                readFileSync(join(PROJECT_ROOT, relativeArtifactPath), "utf8"),
            ),
    });

    console.log(
        `Validated ${rows.length} production deployment targets against Robinhood limits (${ROBINHOOD_RUNTIME_SIZE_LIMIT} B runtime, ${ROBINHOOD_INITCODE_SIZE_LIMIT} B initcode).`,
    );
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    try {
        main();
    } catch (error) {
        console.error(
            `Deployment target size validation failed: ${error.message}`,
        );
        process.exit(1);
    }
}

export {
    PRODUCTION_DEPLOYMENT_TARGETS,
    ROBINHOOD_INITCODE_SIZE_LIMIT,
    ROBINHOOD_RUNTIME_SIZE_LIMIT,
    bytecodeSize,
    checkDeploymentTargetSizes,
    extractConstructedContractNames,
    readTargetSize,
    validateTargetInventory,
    validateTargetSizes,
};
