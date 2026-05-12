import { readdirSync, existsSync } from "fs";
import readline from "readline";
import { fileURLToPath } from "url";
import {
    createFoundryKeystore,
    DEFAULT_KEYSTORE_ACCOUNT,
    getFoundryKeystoreDir,
    isValidKeystoreName,
} from "./foundryKeystore.js";

async function selectOrCreateKeystore() {
    // Create readline interface only when function is called
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
    });

    const keystorePath = getFoundryKeystoreDir();

    try {
        const keystores = existsSync(keystorePath)
            ? readdirSync(keystorePath).filter(
                  (keystore) => keystore !== DEFAULT_KEYSTORE_ACCOUNT,
              )
            : [];

        if (keystores.length === 0) {
            console.log(
                "\n❌ No keystores found in ~/.foundry/keystores, please select 0 to create a new keystore",
            );
        }

        console.log("\n🔑 Available keystores:");
        console.log("0. Create new keystore");

        keystores.map((keystore, index) => {
            console.log(`${index + 1}. ${keystore}`);

            return { keystore };
        });

        const answer = await new Promise((resolve) => {
            rl.question(
                "\nSelect a keystore or create new (enter number): ",
                resolve,
            );
        });

        const selection = parseInt(answer);

        if (selection === 0) {
            const keystoreName = await new Promise((resolve) => {
                rl.question("\nEnter name for new keystore: ", resolve);
            });
            const trimmedKeystoreName = keystoreName.trim();

            if (!isValidKeystoreName(trimmedKeystoreName)) {
                console.error(
                    "\n❌ Invalid keystore name. Use letters, numbers, dots, underscores, or hyphens only.",
                );
                process.exit(1);
            }

            // Close readline before spawning process with inherited stdio
            rl.close();

            createFoundryKeystore(trimmedKeystoreName);
            console.log(
                "\n💰 Fund the address and re-run the deploy command to use this keystore.",
            );
            console.log(
                `\nTIP: Use \`yarn account\` and select \`${trimmedKeystoreName}\` keystore to check if the address is funded.`,
            );
            process.exit(0);
        }

        if (isNaN(selection) || selection < 1 || selection > keystores.length) {
            console.error("\n❌ Invalid selection");
            process.exit(1);
        }

        const selectedKeystore = keystores[selection - 1];
        // Close readline before returning
        rl.close();
        return selectedKeystore;
    } catch (error) {
        console.error("\n❌ Error reading keystores:", error);
        process.exit(1);
    } finally {
        // Ensure readline is closed
        rl.close();
    }
}

// Run the selection if this script is called directly
if (process.argv[1] === fileURLToPath(import.meta.url)) {
    selectOrCreateKeystore()
        .then((keystore) => {
            console.log("\n🔑 Selected keystore:", keystore);
        })
        .catch((error) => {
            console.error(error);
            process.exit(1);
        });
}

export { selectOrCreateKeystore };
