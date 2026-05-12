import { listKeystores } from "./listKeystores.js";
import { spawnSync } from "child_process";

const CONFIRM_EXPORT_FLAG = "--i-understand-this-exposes-the-private-key";

async function revealPk() {
    try {
        if (process.argv.includes("--help") || process.argv.includes("-h")) {
            console.log(`
Usage: yarn account:reveal-pk -- ${CONFIRM_EXPORT_FLAG}

This command is intentionally gated because it reveals a raw private key.
`);
            process.exit(0);
        }

        if (!process.argv.includes(CONFIRM_EXPORT_FLAG)) {
            console.error(`
❌ Raw private key export is disabled by default.

Use your keystore directly with Foundry commands instead:
  forge script ... --account <keystore-name>
  cast wallet address --account <keystore-name>

If you have a one-off recovery scenario and still need to reveal a private key,
re-run this command with:
  yarn account:reveal-pk -- ${CONFIRM_EXPORT_FLAG}
`);
            process.exit(1);
        }

        if (!process.stdin.isTTY || !process.stdout.isTTY) {
            console.error(
                "\n❌ Refusing to reveal a private key outside an interactive terminal.",
            );
            process.exit(1);
        }

        console.error(
            "👀 This will reveal your private key in this terminal session.",
        );

        const selectedKeystore = await listKeystores(
            "Select a keystore to reveal its private key (enter the number, e.g., 1): ",
        );

        if (!selectedKeystore) {
            console.error("❌ No keystore selected");
            process.exit(1);
        }

        const revealPkResult = spawnSync(
            "cast",
            ["wallet", "decrypt-keystore", selectedKeystore],
            {
                stdio: "inherit",
            },
        );

        if (revealPkResult.error || revealPkResult.status !== 0) {
            console.error("\n❌ Failed to decrypt keystore. Wrong password?");
            process.exit(1);
        }
    } catch (error) {
        console.error("\n❌ Error revealing private key:");
        console.error(error.message);
        process.exit(1);
    }
}

revealPk().catch((error) => {
    console.error("\n❌ Unexpected error:", error);
    process.exit(1);
});
