import { constants, copyFileSync } from "node:fs";

// Create the local template once; an existing file or symlink must stay untouched.
try {
    copyFileSync(
        new URL("../.env.example", import.meta.url),
        new URL("../.env", import.meta.url),
        constants.COPYFILE_EXCL,
    );
} catch (error) {
    if (error.code !== "EEXIST") throw error;
}
