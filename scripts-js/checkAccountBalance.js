import { listKeystores } from "./listKeystores.js";
import { spawnSync } from "child_process";
import dotenv from "dotenv";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { toString } from "qrcode";
import { readFileSync } from "fs";
import { parse } from "toml";
import { ethers } from "ethers";
import { isValidKeystoreName } from "./foundryKeystore.js";

// Load environment variables
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
dotenv.config({ path: join(__dirname, "..", ".env") });

const ENV_PLACEHOLDER_PATTERN = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/gu;

function resolveRpcEndpoint(input, env = process.env) {
    if (typeof input !== "string" || input.length === 0) {
        return { url: null, missingVariables: [] };
    }

    const missingVariables = new Set();
    const url = input.replace(
        ENV_PLACEHOLDER_PATTERN,
        (_placeholder, variableName) => {
            const value = env[variableName];
            if (!value) {
                missingVariables.add(variableName);
                return "";
            }

            return value;
        },
    );

    if (missingVariables.size > 0) {
        return {
            url: null,
            missingVariables: [...missingVariables],
        };
    }

    return { url, missingVariables: [] };
}

function getKeystoreAddress(keystoreName) {
    if (!isValidKeystoreName(keystoreName)) {
        throw new Error(
            "Invalid keystore name. Use letters, numbers, dots, underscores, or hyphens only.",
        );
    }

    const result = spawnSync(
        "cast",
        ["wallet", "address", "--account", keystoreName],
        {
            encoding: "utf-8",
            stdio: ["pipe", "pipe", "pipe"],
        },
    );

    if (result.error) {
        throw result.error;
    }

    if (result.status !== 0) {
        throw new Error(
            (result.stderr || result.stdout || "Unknown cast error").trim(),
        );
    }

    return result.stdout.trim();
}

async function getBalanceForEachNetwork(address) {
    try {
        // Read the foundry.toml file
        const foundryTomlPath = join(__dirname, "..", "foundry.toml");
        const tomlString = readFileSync(foundryTomlPath, "utf-8");

        // Parse the tomlString to get the JS object representation
        const parsedToml = parse(tomlString);

        // Extract rpc_endpoints from parsedToml
        const rpcEndpoints = parsedToml.rpc_endpoints;

        console.log(await toString(address, { type: "terminal", small: true }));
        console.log(`\n📊 Address: ${address}`);

        for (const networkName in rpcEndpoints) {
            console.log(`\n--${networkName}-- 📡`);
            const { url: networkUrl, missingVariables } = resolveRpcEndpoint(
                rpcEndpoints[networkName],
            );
            if (!networkUrl) {
                const envList = missingVariables.join(", ");
                const reason =
                    envList.length > 0
                        ? `set ${envList} in packages/foundry/.env to query this network`
                        : "configure a non-empty RPC URL in foundry.toml";
                console.log(`   Skipping: ${reason}`);
                continue;
            }

            let provider;
            try {
                provider = new ethers.JsonRpcProvider(networkUrl);

                // Get balance and format it
                const balance = await provider.getBalance(address);
                const formattedBalance = +ethers.formatUnits(balance);

                console.log("   Balance:", formattedBalance);
                console.log(
                    "   Nonce:",
                    await provider.getTransactionCount(address),
                );
            } catch (e) {
                console.log(
                    `   ❌ Can't connect to network ${networkName}: ${e.message}`,
                );
            } finally {
                provider?.destroy();
            }
        }
    } catch (error) {
        console.error("Error reading foundry.toml:", error);
    }
}

async function checkAccountBalance() {
    try {
        // Step 1: List accounts and let user select one
        console.log("📋 Listing available accounts...");
        const selectedKeystore = await listKeystores(
            "Select a keystore to display its balance (enter the number, e.g., 1): ",
        );

        if (!selectedKeystore) {
            console.error("❌ No keystore selected");
            process.exit(1);
        }

        // Step 2: Get the address of the selected account
        console.log(`\n🔍 Getting address for keystore: ${selectedKeystore}`);

        let address;
        try {
            address = getKeystoreAddress(selectedKeystore);
            console.log("\n💰 Checking balances across networks...");
            console.log("\n");
            await getBalanceForEachNetwork(address);
        } catch (error) {
            console.error(`❌ Error getting address: ${error.message}`);
            process.exit(1);
        }
    } catch (error) {
        console.error(`\n❌ Error: ${error.message}`);
        process.exit(1);
    }
}

// Run the function if this script is called directly
if (process.argv[1] === fileURLToPath(import.meta.url)) {
    checkAccountBalance().catch((error) => {
        console.error(error);
        process.exit(1);
    });
}

export { checkAccountBalance, resolveRpcEndpoint };
