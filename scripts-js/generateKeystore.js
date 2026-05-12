import readline from "readline";
import { fileURLToPath } from "url";
import {
    createFoundryKeystore,
    isValidKeystoreName,
} from "./foundryKeystore.js";

async function createKeystore() {
    // Create readline interface
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
    });

    try {
        console.log("\n🔑 Creating encrypted keystore...");

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
    } catch (error) {
        console.error("\n❌ Error creating keystore:", error);
        process.exit(1);
    } finally {
        // Ensure readline is closed
        if (rl) rl.close();
    }
}

// Run the function if this script is called directly
if (process.argv[1] === fileURLToPath(import.meta.url)) {
    createKeystore()
        .then(() => {
            process.exit(0);
        })
        .catch((error) => {
            console.error(error);
            process.exit(1);
        });
}

export { createKeystore };
