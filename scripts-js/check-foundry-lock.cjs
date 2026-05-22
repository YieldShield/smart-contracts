#!/usr/bin/env node

const { execFileSync } = require("node:child_process");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");

const rootDir = resolve(__dirname, "..");

function git(args) {
    return execFileSync("git", args, {
        cwd: rootDir,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
    }).trim();
}

function getSubmodulePaths() {
    const output = git([
        "config",
        "--file",
        ".gitmodules",
        "--get-regexp",
        "path",
    ]);
    if (!output) return [];

    return output
        .split("\n")
        .filter(Boolean)
        .map((line) => line.trim().split(/\s+/)[1])
        .filter(Boolean);
}

function getGitlinkRevision(submodulePath) {
    const output = git(["ls-tree", "HEAD", submodulePath]);
    const match = output.match(/^160000 commit ([0-9a-f]{40})\t(.+)$/);
    if (!match) {
        throw new Error(`${submodulePath} is not a git submodule in HEAD`);
    }
    return match[1];
}

const lock = JSON.parse(readFileSync(resolve(rootDir, "foundry.lock"), "utf8"));
const submodulePaths = getSubmodulePaths();
let hasError = false;

for (const submodulePath of submodulePaths) {
    const lockedRev = lock[submodulePath]?.tag?.rev;
    if (!lockedRev) {
        console.error(`foundry.lock is missing ${submodulePath}`);
        hasError = true;
        continue;
    }

    const gitlinkRev = getGitlinkRevision(submodulePath);
    if (lockedRev !== gitlinkRev) {
        console.error(`${submodulePath} revision mismatch`);
        console.error(`  foundry.lock: ${lockedRev}`);
        console.error(`  submodule:    ${gitlinkRev}`);
        hasError = true;
    }
}

for (const lockPath of Object.keys(lock)) {
    if (!submodulePaths.includes(lockPath)) {
        console.error(
            `foundry.lock contains ${lockPath}, but .gitmodules does not`,
        );
        hasError = true;
    }
}

if (hasError) {
    process.exit(1);
}

console.log(
    `foundry.lock matches ${submodulePaths.length} submodule revision(s).`,
);
