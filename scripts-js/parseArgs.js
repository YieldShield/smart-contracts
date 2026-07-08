import { spawnSync } from "child_process";
import { config } from "dotenv";
import { join, dirname } from "path";
import { readFileSync, existsSync } from "fs";
import { parse } from "toml";
import { fileURLToPath } from "url";
import {
    DEFAULT_KEYSTORE_ACCOUNT,
    isValidKeystoreName,
    keystoreExists,
} from "./foundryKeystore.js";
import { selectOrCreateKeystore } from "./selectOrCreateKeystore.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
config();

const LOCAL_DEPLOY_SCRIPT = "Deploy.s.sol";
const PRODUCTION_DEPLOY_SCRIPT = "DeployYieldShieldProduction.s.sol";
const DEFAULT_NETWORK = "localhost";
const ROBINHOOD_NETWORKS = new Set(["robinhood", "robinhoodTestnet"]);
const REQUIRED_PRODUCTION_ENV = [
    "YS_PRODUCTION_BOOTSTRAP_HOLDER",
    "YS_PRODUCTION_BOOTSTRAP_HOLDER_CODEHASH",
    "YS_PRODUCTION_BOOTSTRAP_HOLDER_SINGLETON",
    "YS_PRODUCTION_BOOTSTRAP_HOLDER_THRESHOLD",
    "YS_PRODUCTION_BOOTSTRAP_HOLDER_OWNERS_HASH",
    "YS_PRODUCTION_FACTORY_IMPLEMENTATION_CODEHASH",
    "YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH",
];
const REQUIRED_ROBINHOOD_ENV = ["YS_PRODUCTION_CHAINLINK_ORACLE_CODEHASH"];
const REQUIRED_PYTH_ENV = ["YS_PRODUCTION_PYTH_ORACLE_CODEHASH"];
const deployScriptFileNamePattern = /^[A-Za-z0-9_.-]+\.s\.sol$/u;

function usage() {
    console.log(`
Usage: yarn deploy [options]
Options:
  --file <filename>     Specify the deployment script file (default: Deploy.s.sol locally, DeployYieldShieldProduction.s.sol on public networks)
  --network <network>   Specify the network (default: localhost)
  --keystore <name>     Specify the keystore account to use (bypasses selection prompt)
  --help, -h           Show this help message
Examples:
  yarn deploy
  yarn deploy --file DeployYieldShield.s.sol --network localhost
  yarn deploy --network robinhoodTestnet --keystore test
  ROBINHOOD_TESTNET_KEYSTORE_ACCOUNT=test yarn deploy --network robinhoodTestnet
  `);
}

function requireOptionValue(args, index, optionName) {
    const value = args[index + 1];
    if (!value || value.startsWith("-")) {
        throw new Error(`${optionName} requires a value.`);
    }
    return value;
}

function parseCliArgs(args) {
    let fileName = LOCAL_DEPLOY_SCRIPT;
    let fileWasProvided = false;
    let network = DEFAULT_NETWORK;
    let keystoreArg = null;
    let help = false;

    for (let i = 0; i < args.length; i++) {
        if (args[i] === "--help" || args[i] === "-h") {
            help = true;
        } else if (args[i] === "--network") {
            network = requireOptionValue(args, i, "--network");
            i++;
        } else if (args[i] === "--file") {
            fileName = requireOptionValue(args, i, "--file");
            fileWasProvided = true;
            i++;
        } else if (args[i] === "--keystore") {
            keystoreArg = requireOptionValue(args, i, "--keystore");
            i++;
        } else {
            throw new Error(
                `Unexpected argument '${args[i]}'. Use --network <name>, --file <filename>, or --keystore <name>.`,
            );
        }
    }

    return { fileName, fileWasProvided, help, keystoreArg, network };
}

function isLocalNetwork(network) {
    return network === DEFAULT_NETWORK;
}

function resolveDeployScript({ fileName, fileWasProvided, network }) {
    if (isLocalNetwork(network)) {
        return { fileName, defaultedToProduction: false };
    }

    if (fileName === LOCAL_DEPLOY_SCRIPT) {
        if (fileWasProvided) {
            throw new Error(
                `Deploy.s.sol is a local-only entrypoint. Use ${PRODUCTION_DEPLOY_SCRIPT} for ${network}.`,
            );
        }

        return {
            fileName: PRODUCTION_DEPLOY_SCRIPT,
            defaultedToProduction: true,
        };
    }

    return { fileName, defaultedToProduction: false };
}

function networkEnvPrefix(network) {
    return network
        .replace(/([a-z0-9])([A-Z])/gu, "$1_$2")
        .replace(/[^A-Za-z0-9]+/gu, "_")
        .replace(/^_+|_+$/gu, "")
        .toUpperCase();
}

function keystoreEnvNames(network) {
    if (isLocalNetwork(network)) {
        return ["LOCALHOST_KEYSTORE_ACCOUNT"];
    }

    return [
        `${networkEnvPrefix(network)}_KEYSTORE_ACCOUNT`,
        "ETH_KEYSTORE_ACCOUNT",
    ];
}

function configuredKeystore({ keystoreArg, network }, env = process.env) {
    if (keystoreArg) {
        return { keystoreName: keystoreArg, source: "--keystore" };
    }

    for (const envName of keystoreEnvNames(network)) {
        if (env[envName]) {
            return { keystoreName: env[envName], source: envName };
        }
    }

    if (isLocalNetwork(network)) {
        return {
            keystoreName: DEFAULT_KEYSTORE_ACCOUNT,
            source: "default",
        };
    }

    return { keystoreName: null, source: null };
}

function envFlag(value) {
    return ["1", "true", "yes"].includes(String(value || "").toLowerCase());
}

function missingProductionEnv({ fileName, network }, env = process.env) {
    if (isLocalNetwork(network) || fileName !== PRODUCTION_DEPLOY_SCRIPT) {
        return [];
    }

    const missing = [...REQUIRED_PRODUCTION_ENV];
    if (ROBINHOOD_NETWORKS.has(network)) {
        missing.push(...REQUIRED_ROBINHOOD_ENV);
        const sequencerEnvName =
            network === "robinhoodTestnet"
                ? "YS_ROBINHOOD_TESTNET_SEQUENCER_FEED"
                : "YS_ROBINHOOD_SEQUENCER_FEED";
        if (
            !env[sequencerEnvName] &&
            !envFlag(env.YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED)
        ) {
            missing.push(
                `${sequencerEnvName} or YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED=true`,
            );
        }
    } else {
        missing.push(...REQUIRED_PYTH_ENV);
    }

    return missing.filter((name) => {
        if (name.includes(" or ")) {
            return true;
        }
        return !env[name];
    });
}

function printProductionEnvError(missingEnv) {
    console.log(
        "\n❌ Error: Missing production deployment environment values:",
    );
    for (const envName of missingEnv) {
        console.log(`   - ${envName}`);
    }
    console.log(
        "\nSet these in packages/foundry/.env, then rerun the deploy command.",
    );
}

// Function to check if a keystore exists
function validateKeystore(keystoreName) {
    if (!isValidKeystoreName(keystoreName)) {
        return false;
    }

    if (keystoreName === DEFAULT_KEYSTORE_ACCOUNT) {
        return true;
    }

    return keystoreExists(keystoreName);
}

function validateDeployScriptFileName(name, exitOnError = true) {
    if (
        !deployScriptFileNamePattern.test(name) ||
        name.includes("/") ||
        name.includes("\\")
    ) {
        const message = `Invalid deploy script filename '${name}'. Use a file like DeployYieldShieldProduction.s.sol from the script/ directory.`;
        if (!exitOnError) {
            throw new Error(message);
        }
        console.log(`\n❌ Error: ${message}`);
        process.exit(1);
    }

    const deployScriptPath = join(__dirname, "..", "script", name);
    if (!existsSync(deployScriptPath)) {
        const message = `Deploy script '${name}' not found in script/.`;
        if (!exitOnError) {
            throw new Error(message);
        }
        console.log(`\n❌ Error: ${message}`);
        process.exit(1);
    }
}

function validateNetworkExists(network, exitOnError = true) {
    try {
        const foundryTomlPath = join(__dirname, "..", "foundry.toml");
        const tomlString = readFileSync(foundryTomlPath, "utf-8");
        const parsedToml = parse(tomlString);

        if (!parsedToml.rpc_endpoints[network]) {
            const message = `Network '${network}' not found in foundry.toml!\nPlease check \`foundry.toml\` for available networks in the [rpc_endpoints] section or add a new network.`;
            if (!exitOnError) {
                throw new Error(message);
            }
            console.log(`\n❌ Error: ${message}`);
            process.exit(1);
        }
    } catch (error) {
        if (!exitOnError) {
            throw error;
        }
        console.error("\n❌ Error reading or parsing foundry.toml:", error);
        process.exit(1);
    }
}

async function main(rawArgs = process.argv.slice(2), env = process.env) {
    let parsedArgs;
    try {
        parsedArgs = parseCliArgs(rawArgs);
    } catch (error) {
        console.log(`\n❌ Error: ${error.message}`);
        usage();
        process.exit(1);
    }

    if (parsedArgs.help) {
        usage();
        process.exit(0);
    }

    const { network } = parsedArgs;
    let fileName;
    let defaultedToProduction;
    try {
        ({ fileName, defaultedToProduction } = resolveDeployScript(parsedArgs));
    } catch (error) {
        console.log(`\n❌ Error: ${error.message}`);
        console.log(
            `\nFor public-network deployments, run:\n  yarn deploy --network ${network} --keystore <name>`,
        );
        process.exit(1);
    }

    validateDeployScriptFileName(fileName);
    validateNetworkExists(network);

    if (defaultedToProduction) {
        console.log(
            `\n🛡️  Using ${PRODUCTION_DEPLOY_SCRIPT} for public network '${network}'`,
        );
    }

    const { keystoreName: configuredKeystoreName, source: keystoreSource } =
        configuredKeystore(parsedArgs, env);

    if (
        configuredKeystoreName !== DEFAULT_KEYSTORE_ACCOUNT &&
        isLocalNetwork(network) &&
        keystoreSource !== "default"
    ) {
        console.log(`
⚠️ Warning: Using ${configuredKeystoreName} keystore account on localhost.

You can either:
1. Enter the password for ${configuredKeystoreName} account
   OR
2. Set the localhost keystore account in your .env and re-run the command to skip password prompt:
   LOCALHOST_KEYSTORE_ACCOUNT='${DEFAULT_KEYSTORE_ACCOUNT}'
	`);
    }

    let selectedKeystore = configuredKeystoreName;
    if (!isLocalNetwork(network)) {
        if (configuredKeystoreName) {
            if (!validateKeystore(configuredKeystoreName)) {
                console.log(
                    `\n❌ Error: Keystore '${configuredKeystoreName}' is invalid or not found!`,
                );
                console.log(
                    `Use a keystore from ~/.foundry/keystores/ with letters, numbers, dots, underscores, or hyphens only.`,
                );
                process.exit(1);
            }
            selectedKeystore = configuredKeystoreName;
            console.log(
                `\n🔑 Using keystore: ${selectedKeystore}${
                    keystoreSource ? ` (${keystoreSource})` : ""
                }`,
            );
        } else {
            try {
                selectedKeystore = await selectOrCreateKeystore();
            } catch (error) {
                console.error("\n❌ Error selecting keystore:", error);
                process.exit(1);
            }
        }
    } else if (parsedArgs.keystoreArg) {
        // Allow overriding the localhost keystore with --keystore flag
        if (!validateKeystore(parsedArgs.keystoreArg)) {
            console.log(
                `\n❌ Error: Keystore '${parsedArgs.keystoreArg}' is invalid or not found!`,
            );
            console.log(
                `Use a keystore from ~/.foundry/keystores/ with letters, numbers, dots, underscores, or hyphens only.`,
            );
            process.exit(1);
        }
        selectedKeystore = parsedArgs.keystoreArg;
        console.log(
            `\n🔑 Using keystore: ${selectedKeystore} for localhost deployment`,
        );
    }

    // Check for default account on live network
    if (
        selectedKeystore === DEFAULT_KEYSTORE_ACCOUNT &&
        !isLocalNetwork(network)
    ) {
        console.log(`
❌ Error: Cannot deploy to live network using default keystore account!

To deploy to ${network}, please follow these steps:

1. If you haven't generated a keystore account yet:
   $ yarn account:generate

2. Run the deployment command again.

The default account (${DEFAULT_KEYSTORE_ACCOUNT}) can only be used for localhost deployments.
`);
        process.exit(1);
    }

    const missingEnv = missingProductionEnv({ fileName, network }, env);
    if (missingEnv.length > 0) {
        printProductionEnvError(missingEnv);
        process.exit(1);
    }

    const result = spawnSync(
        "make",
        [
            `DEPLOY_SCRIPT=script/${fileName}`,
            `RPC_URL=${network}`,
            `ETH_KEYSTORE_ACCOUNT=${selectedKeystore}`,
            "deploy-and-generate-abis",
        ],
        {
            stdio: "inherit",
        },
    );

    process.exit(result.status ?? 1);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    await main();
}

export {
    configuredKeystore,
    isLocalNetwork,
    keystoreEnvNames,
    missingProductionEnv,
    networkEnvPrefix,
    parseCliArgs,
    resolveDeployScript,
    validateDeployScriptFileName,
    validateNetworkExists,
};
