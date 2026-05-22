const { existsSync, readFileSync, readdirSync, statSync } = require("fs");
const { join } = require("path");

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

const PYTH_TOKEN_CONFIGS = [
    {
        name: "SUSDE",
        feedId: "0xca3ba9a619a4b3755c10ac7d5e760275aa95e9823d38a84fedd416856cdba37c",
        contractName: "MockERC20",
        broadcastIndex: 0,
        env: "SUSDE_ADDRESS",
    },
    {
        name: "SDAI",
        feedId: "0x710659c5a68e2416ce4264ca8d50d34acc20041d91289110eea152c52ff3dc39",
        contractName: "MockERC20",
        broadcastIndex: 1,
        env: "SDAI_ADDRESS",
    },
    {
        name: "USDY",
        feedId: "0xe393449f6aff8a4b6d3e1165a7c9ebec103685f3b41e60db4277b5b6d10e7326",
        contractName: "MockERC20",
        broadcastIndex: 2,
        env: "USDY_ADDRESS",
    },
    {
        name: "STETH",
        feedId: "0x846ae1bdb6300b817cee5fdee2a6da192775030db5615b94a465f53bd40850b5",
        contractName: "MockERC20",
        broadcastIndex: 3,
        env: "STETH_ADDRESS",
    },
    {
        name: "STONE",
        feedId: "0x4dcc2fb96fb89a802ef9712f6bd2246d3607cf95ca5540cb24490d37003f8c46",
        contractName: "MockERC20",
        broadcastIndex: 4,
        env: "STONE_ADDRESS",
    },
    {
        name: "JAAA",
        feedId: "0x5ca9c34d00214bf9416439970caf29eb7f379536fcb82ee21e7d7cf69acadf2a",
        contractName: "MockERC20",
        broadcastIndex: 5,
        env: "JAAA_ADDRESS",
    },
    {
        name: "USTB",
        feedId: "0xdea78edd10cd7ae4524cc1744216788746306623bc3553014eeab6062860795d",
        contractName: "MockERC20",
        broadcastIndex: 6,
        env: "USTB_ADDRESS",
    },
    {
        name: "USYC",
        feedId: "0x01cb900802d74a2e3d36bd9bf100523532b650c47dcac2e8202ba1e972eab305",
        contractName: "MockERC20",
        broadcastIndex: 7,
        env: "USYC_ADDRESS",
    },
    {
        name: "LBTC",
        feedId: "0x8f257aab6e7698bb92b15511915e593d6f8eae914452f781874754b03d0c612b",
        contractName: "MockERC20",
        broadcastIndex: 8,
        env: "LBTC_ADDRESS",
    },
    {
        name: "RLP",
        feedId: "0x796bcb684fdfbba2b071c165251511ab61f08c8949afd9e05665a26f69d9a839",
        contractName: "MockERC20",
        broadcastIndex: 9,
        env: "RLP_ADDRESS",
    },
    {
        name: "SUSDS",
        feedId: "0x6968a8641208463d17ae3b9cfa0e4841a7aa7a5d54122b9f692b84fe9ce3409f",
        quoteFeedId:
            "0x77f0971af11cc8bac224917275c1bf55f2319ed5c654a1ca955c82fa2d297ea1",
        contractName: "MockERC20",
        broadcastIndex: 10,
        env: "SUSDS_ADDRESS",
    },
    {
        name: "USDC",
        feedId: "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a",
        contractName: "MockUSDC",
        broadcastIndex: 0,
        env: "USDC_ADDRESS",
    },
    {
        name: "USD0",
        feedId: "0x5e8c65917af89ed66d03d082b1ae5ac93b8ed8e32363a61842c33f7d66cb2e00",
        contractName: "MockUSD0",
        broadcastIndex: 0,
        env: "USD0_ADDRESS",
    },
];

function normalizeChainId(chainId) {
    if (chainId === undefined || chainId === null || chainId === "") {
        return null;
    }

    if (typeof chainId === "bigint") {
        return chainId.toString();
    }

    if (typeof chainId === "number") {
        return Math.trunc(chainId).toString();
    }

    return String(chainId);
}

function getDeploymentFilePath(rootDir, chainId) {
    const normalizedChainId = normalizeChainId(chainId);
    if (!normalizedChainId) {
        return null;
    }

    return join(rootDir, "deployments", `${normalizedChainId}.json`);
}

function readJsonFileRecord(filePath) {
    if (!filePath || !existsSync(filePath)) {
        return null;
    }

    return {
        path: filePath,
        mtimeMs: statSync(filePath).mtimeMs,
        data: JSON.parse(readFileSync(filePath, "utf8")),
    };
}

function readDeploymentRecord(rootDir, chainId) {
    const deploymentPath = getDeploymentFilePath(rootDir, chainId);
    return readJsonFileRecord(deploymentPath);
}

function readDeployment(rootDir, chainId) {
    return readDeploymentRecord(rootDir, chainId)?.data || null;
}

function listLatestBroadcastRecords(rootDir, chainId) {
    const normalizedChainId = normalizeChainId(chainId);
    if (!normalizedChainId) {
        return [];
    }

    const broadcastDir = join(rootDir, "broadcast");
    if (!existsSync(broadcastDir)) {
        return [];
    }

    return readdirSync(broadcastDir)
        .map((scriptName) =>
            readJsonFileRecord(
                join(
                    broadcastDir,
                    scriptName,
                    normalizedChainId,
                    "run-latest.json",
                ),
            ),
        )
        .filter(Boolean)
        .sort((a, b) => {
            if (b.mtimeMs !== a.mtimeMs) {
                return b.mtimeMs - a.mtimeMs;
            }

            return a.path.localeCompare(b.path);
        });
}

function readLatestBroadcastRecord(rootDir, chainId) {
    return listLatestBroadcastRecords(rootDir, chainId)[0] || null;
}

function readLatestBroadcast(rootDir, chainId) {
    return readLatestBroadcastRecord(rootDir, chainId)?.data || null;
}

function getDeploymentAddresses(deploymentData, contractName) {
    if (!deploymentData) return [];

    const seen = new Set();
    const addresses = [];
    for (const [address, deployedName] of Object.entries(deploymentData)) {
        if (
            deployedName !== contractName ||
            typeof address !== "string" ||
            !address.startsWith("0x")
        ) {
            continue;
        }

        const normalized = address.toLowerCase();
        if (normalized === ZERO_ADDRESS || seen.has(normalized)) {
            continue;
        }

        seen.add(normalized);
        addresses.push(address);
    }

    return addresses;
}

function getBroadcastAddresses(broadcast, contractName) {
    if (!broadcast?.transactions) return [];

    const seen = new Set();
    const addresses = [];
    for (const transaction of broadcast.transactions) {
        if (
            transaction.contractName !== contractName ||
            !transaction.contractAddress
        )
            continue;
        const normalized = transaction.contractAddress.toLowerCase();
        if (normalized === ZERO_ADDRESS || seen.has(normalized)) continue;
        seen.add(normalized);
        addresses.push(transaction.contractAddress);
    }
    return addresses;
}

function getLatestDeploymentRecord(rootDir) {
    const deploymentsDir = join(rootDir, "deployments");
    if (!existsSync(deploymentsDir)) {
        return null;
    }

    const chainFiles = readdirSync(deploymentsDir)
        .filter((fileName) => /^\d+\.json$/.test(fileName))
        .map((fileName) => {
            const fullPath = join(deploymentsDir, fileName);
            const stats = statSync(fullPath);
            return {
                chainId: fileName.replace(/\.json$/, ""),
                mtimeMs: stats.mtimeMs,
            };
        })
        .sort((a, b) => b.mtimeMs - a.mtimeMs);

    return chainFiles[0] || null;
}

function getLatestDeploymentChainId(rootDir) {
    return getLatestDeploymentRecord(rootDir)?.chainId || null;
}

function getLatestBroadcastRecord(rootDir) {
    const broadcastDir = join(rootDir, "broadcast");
    if (!existsSync(broadcastDir)) {
        return null;
    }

    let latestRecord = null;
    for (const scriptName of readdirSync(broadcastDir)) {
        const scriptDir = join(broadcastDir, scriptName);
        if (!statSync(scriptDir).isDirectory()) {
            continue;
        }

        for (const chainId of readdirSync(scriptDir)) {
            const candidate = readJsonFileRecord(
                join(scriptDir, chainId, "run-latest.json"),
            );
            if (!candidate) {
                continue;
            }

            const record = { ...candidate, chainId };
            if (
                !latestRecord ||
                record.mtimeMs > latestRecord.mtimeMs ||
                (record.mtimeMs === latestRecord.mtimeMs &&
                    record.path.localeCompare(latestRecord.path) < 0)
            ) {
                latestRecord = record;
            }
        }
    }

    return latestRecord;
}

function getLatestBroadcastChainId(rootDir) {
    return getLatestBroadcastRecord(rootDir)?.chainId || null;
}

function getLatestKnownChainId(rootDir) {
    const latestDeployment = getLatestDeploymentRecord(rootDir);
    const latestBroadcast = getLatestBroadcastRecord(rootDir);

    if (!latestDeployment) {
        return latestBroadcast?.chainId || null;
    }

    if (!latestBroadcast) {
        return latestDeployment.chainId;
    }

    if (latestBroadcast.mtimeMs > latestDeployment.mtimeMs) {
        return latestBroadcast.chainId;
    }

    return latestDeployment.chainId;
}

function resolveDeploymentChainId({
    rootDir,
    chainId,
    env = process.env,
} = {}) {
    const explicitChainId = normalizeChainId(
        chainId || env.DEPLOY_CHAIN_ID || env.CHAIN_ID,
    );
    if (explicitChainId) {
        return explicitChainId;
    }

    return rootDir ? getLatestKnownChainId(rootDir) : null;
}

function resolveContractAddress({
    rootDir,
    chainId,
    contractName,
    env = process.env,
} = {}) {
    if (!rootDir || !contractName) {
        return null;
    }

    const resolvedChainId = resolveDeploymentChainId({ rootDir, chainId, env });
    if (!resolvedChainId) {
        return null;
    }

    const deploymentRecord = readDeploymentRecord(rootDir, resolvedChainId);
    const deploymentData = deploymentRecord?.data || null;
    const deploymentAddresses = getDeploymentAddresses(
        deploymentData,
        contractName,
    );
    const latestDeploymentAddress =
        deploymentAddresses[deploymentAddresses.length - 1] || null;

    const broadcastRecord = readLatestBroadcastRecord(rootDir, resolvedChainId);
    const broadcast = broadcastRecord?.data || null;
    const broadcastAddresses = getBroadcastAddresses(broadcast, contractName);
    const latestBroadcastAddress =
        broadcastAddresses[broadcastAddresses.length - 1] || null;

    if (latestBroadcastAddress && latestDeploymentAddress) {
        return broadcastRecord.mtimeMs >= deploymentRecord.mtimeMs
            ? latestBroadcastAddress
            : latestDeploymentAddress;
    }

    return latestBroadcastAddress || latestDeploymentAddress || null;
}

function resolvePythTokenConfigs({ rootDir, chainId, env = process.env } = {}) {
    const resolvedChainId = resolveDeploymentChainId({ rootDir, chainId, env });
    const deploymentRecord =
        rootDir && resolvedChainId
            ? readDeploymentRecord(rootDir, resolvedChainId)
            : null;
    const deploymentData = deploymentRecord?.data || null;
    const broadcastRecord =
        rootDir && resolvedChainId
            ? readLatestBroadcastRecord(rootDir, resolvedChainId)
            : null;
    const broadcast = broadcastRecord?.data || null;
    const preferDeployment =
        deploymentRecord &&
        (!broadcastRecord ||
            deploymentRecord.mtimeMs > broadcastRecord.mtimeMs);

    return PYTH_TOKEN_CONFIGS.map((config) => {
        const deploymentAddress = getDeploymentAddresses(
            deploymentData,
            config.contractName,
        )[config.broadcastIndex];
        const broadcastAddress = getBroadcastAddresses(
            broadcast,
            config.contractName,
        )[config.broadcastIndex];
        const envAddress = env[config.env] || null;
        return {
            ...config,
            chainId: resolvedChainId,
            address:
                envAddress ||
                (preferDeployment
                    ? deploymentAddress || broadcastAddress
                    : broadcastAddress || deploymentAddress) ||
                null,
        };
    });
}

module.exports = {
    PYTH_TOKEN_CONFIGS,
    getDeploymentAddresses,
    getDeploymentFilePath,
    getLatestBroadcastChainId,
    getLatestKnownChainId,
    readDeployment,
    readLatestBroadcast,
    resolveContractAddress,
    resolveDeploymentChainId,
    resolvePythTokenConfigs,
};
