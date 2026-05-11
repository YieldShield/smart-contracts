const { existsSync, readFileSync } = require("fs");
const { join } = require("path");

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

const PYTH_TOKEN_CONFIGS = [
    {
        name: "SUSDE",
        feedId: "0xca3ba9a619a4b3755c10ac7d5e760275aa95e9823d38a84fedd416856cdba37c",
        contractName: "MockERC20",
        broadcastIndex: 0,
        env: "SUSDE_ADDRESS",
        defaultAddress: "0x1d804cd133b3cf35cff4b2cc19d7e6deefcd644a",
    },
    {
        name: "SDAI",
        feedId: "0x710659c5a68e2416ce4264ca8d50d34acc20041d91289110eea152c52ff3dc39",
        contractName: "MockERC20",
        broadcastIndex: 1,
        env: "SDAI_ADDRESS",
        defaultAddress: "0x6D59F75Cb4367299B6887C726d46805D7acd8ad0",
    },
    {
        name: "USDY",
        feedId: "0xe393449f6aff8a4b6d3e1165a7c9ebec103685f3b41e60db4277b5b6d10e7326",
        contractName: "MockERC20",
        broadcastIndex: 2,
        env: "USDY_ADDRESS",
        defaultAddress: "0x4C53E534fD51127c1923d63261e5c1cd4a1d3580",
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

function readLatestBroadcast(rootDir, chainId = "421614") {
    const candidates = [
        join(
            rootDir,
            "broadcast",
            "DeployYieldShield.s.sol",
            chainId,
            "run-latest.json",
        ),
        join(rootDir, "broadcast", "Deploy.s.sol", chainId, "run-latest.json"),
    ];

    for (const candidate of candidates) {
        if (existsSync(candidate)) {
            return JSON.parse(readFileSync(candidate, "utf8"));
        }
    }

    return null;
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

function resolvePythTokenConfigs({
    rootDir,
    chainId = "421614",
    env = process.env,
} = {}) {
    const broadcast = rootDir ? readLatestBroadcast(rootDir, chainId) : null;

    return PYTH_TOKEN_CONFIGS.map((config) => {
        const broadcastAddress = getBroadcastAddresses(
            broadcast,
            config.contractName,
        )[config.broadcastIndex];
        return {
            ...config,
            address:
                env[config.env] ||
                broadcastAddress ||
                config.defaultAddress ||
                null,
        };
    });
}

module.exports = {
    PYTH_TOKEN_CONFIGS,
    resolvePythTokenConfigs,
};
