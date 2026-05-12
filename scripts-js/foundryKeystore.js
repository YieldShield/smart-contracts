import { spawnSync } from "child_process";
import { existsSync, mkdirSync } from "fs";
import { join } from "path";

const DEFAULT_KEYSTORE_ACCOUNT = "scaffold-eth-default";
const KEYSTORE_NAME_PATTERN = /^[A-Za-z0-9_.-]+$/u;

function getFoundryKeystoreDir() {
    if (!process.env.HOME) {
        throw new Error("HOME environment variable is not set");
    }

    return join(process.env.HOME, ".foundry", "keystores");
}

function isValidKeystoreName(keystoreName) {
    return (
        typeof keystoreName === "string" &&
        keystoreName.length > 0 &&
        KEYSTORE_NAME_PATTERN.test(keystoreName)
    );
}

function getFoundryKeystorePath(keystoreName) {
    return join(getFoundryKeystoreDir(), keystoreName);
}

function keystoreExists(keystoreName) {
    return isValidKeystoreName(keystoreName)
        ? existsSync(getFoundryKeystorePath(keystoreName))
        : false;
}

function createFoundryKeystore(keystoreName) {
    if (!isValidKeystoreName(keystoreName)) {
        throw new Error(
            "Invalid keystore name. Use letters, numbers, dots, underscores, or hyphens only.",
        );
    }

    const keystoreDir = getFoundryKeystoreDir();
    mkdirSync(keystoreDir, { recursive: true });

    if (existsSync(join(keystoreDir, keystoreName))) {
        throw new Error(`Keystore '${keystoreName}' already exists.`);
    }

    const createResult = spawnSync(
        "cast",
        ["wallet", "new", keystoreDir, keystoreName],
        { stdio: "inherit" },
    );

    if (createResult.error) {
        throw createResult.error;
    }

    if (createResult.status !== 0) {
        throw new Error(
            `Failed to create keystore '${keystoreName}' (exit code ${createResult.status ?? "unknown"}).`,
        );
    }
}

export {
    DEFAULT_KEYSTORE_ACCOUNT,
    createFoundryKeystore,
    getFoundryKeystoreDir,
    getFoundryKeystorePath,
    isValidKeystoreName,
    keystoreExists,
};
