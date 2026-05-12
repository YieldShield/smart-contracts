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

// Get all arguments after the script name
const args = process.argv.slice(2);
let fileName = "Deploy.s.sol";
let network = "localhost";
let keystoreArg = null;
const deployScriptFileNamePattern = /^[A-Za-z0-9_.-]+\.s\.sol$/u;

// Show help message if --help is provided
if (args.includes("--help") || args.includes("-h")) {
    console.log(`
Usage: yarn deploy [options]
Options:
  --file <filename>     Specify the deployment script file (default: Deploy.s.sol)
  --network <network>   Specify the network (default: localhost)
  --keystore <name>     Specify the keystore account to use (bypasses selection prompt)
  --help, -h           Show this help message
Examples:
  yarn deploy
  yarn deploy --file DeployYieldShield.s.sol --network localhost
  yarn deploy --file DeployYieldShieldProduction.s.sol --network arbitrum --keystore my-account
  `);
    process.exit(0);
}

// Parse arguments
for (let i = 0; i < args.length; i++) {
    if (args[i] === "--network" && args[i + 1]) {
        network = args[i + 1];
        i++; // Skip next arg since we used it
    } else if (args[i] === "--file" && args[i + 1]) {
        fileName = args[i + 1];
        i++; // Skip next arg since we used it
    } else if (args[i] === "--keystore" && args[i + 1]) {
        keystoreArg = args[i + 1];
        i++; // Skip next arg since we used it
    }
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

function validateDeployScriptFileName(name) {
    if (
        !deployScriptFileNamePattern.test(name) ||
        name.includes("/") ||
        name.includes("\\")
    ) {
        console.log(
            `\n❌ Error: Invalid deploy script filename '${name}'. Use a file like DeployYieldShieldProduction.s.sol from the script/ directory.`,
        );
        process.exit(1);
    }

    const deployScriptPath = join(__dirname, "..", "script", name);
    if (!existsSync(deployScriptPath)) {
        console.log(
            `\n❌ Error: Deploy script '${name}' not found in script/.`,
        );
        process.exit(1);
    }
}

validateDeployScriptFileName(fileName);

// Check if the network exists in rpc_endpoints
try {
    const foundryTomlPath = join(__dirname, "..", "foundry.toml");
    const tomlString = readFileSync(foundryTomlPath, "utf-8");
    const parsedToml = parse(tomlString);

    if (!parsedToml.rpc_endpoints[network]) {
        console.log(
            `\n❌ Error: Network '${network}' not found in foundry.toml!`,
            "\nPlease check `foundry.toml` for available networks in the [rpc_endpoints] section or add a new network.",
        );
        process.exit(1);
    }
} catch (error) {
    console.error("\n❌ Error reading or parsing foundry.toml:", error);
    process.exit(1);
}

const localhostKeystoreAccount =
    process.env.LOCALHOST_KEYSTORE_ACCOUNT || DEFAULT_KEYSTORE_ACCOUNT;

if (
    localhostKeystoreAccount !== DEFAULT_KEYSTORE_ACCOUNT &&
    network === "localhost"
) {
    console.log(`
⚠️ Warning: Using ${localhostKeystoreAccount} keystore account on localhost.

You can either:
1. Enter the password for ${localhostKeystoreAccount} account
   OR
2. Set the localhost keystore account in your .env and re-run the command to skip password prompt:
   LOCALHOST_KEYSTORE_ACCOUNT='${DEFAULT_KEYSTORE_ACCOUNT}'
	`);
}

if (network !== "localhost" && fileName === "Deploy.s.sol") {
    console.log(`
❌ Error: Deploy.s.sol is a local-only entrypoint.

For public-network deployments, use the explicit production script instead:
  yarn deploy --file DeployYieldShieldProduction.s.sol --network ${network}
`);
    process.exit(1);
}

let selectedKeystore = localhostKeystoreAccount;
if (network !== "localhost") {
    if (keystoreArg) {
        // Use the keystore provided via command line argument
        if (!validateKeystore(keystoreArg)) {
            console.log(
                `\n❌ Error: Keystore '${keystoreArg}' is invalid or not found!`,
            );
            console.log(
                `Use a keystore from ~/.foundry/keystores/ with letters, numbers, dots, underscores, or hyphens only.`,
            );
            process.exit(1);
        }
        selectedKeystore = keystoreArg;
        console.log(`\n🔑 Using keystore: ${selectedKeystore}`);
    } else {
        try {
            selectedKeystore = await selectOrCreateKeystore();
        } catch (error) {
            console.error("\n❌ Error selecting keystore:", error);
            process.exit(1);
        }
    }
} else if (keystoreArg) {
    // Allow overriding the localhost keystore with --keystore flag
    if (!validateKeystore(keystoreArg)) {
        console.log(
            `\n❌ Error: Keystore '${keystoreArg}' is invalid or not found!`,
        );
        console.log(
            `Use a keystore from ~/.foundry/keystores/ with letters, numbers, dots, underscores, or hyphens only.`,
        );
        process.exit(1);
    }
    selectedKeystore = keystoreArg;
    console.log(
        `\n🔑 Using keystore: ${selectedKeystore} for localhost deployment`,
    );
}

// Check for default account on live network
if (selectedKeystore === DEFAULT_KEYSTORE_ACCOUNT && network !== "localhost") {
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
