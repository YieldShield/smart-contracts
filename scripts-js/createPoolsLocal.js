import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FOUNDRY_DIR = join(__dirname, "..");
const BROADCAST_PATH = join(
    FOUNDRY_DIR,
    "broadcast",
    "DeployYieldShield.s.sol",
    "31337",
    "run-latest.json",
);
const DEPLOYMENT_PATH = join(FOUNDRY_DIR, "deployments", "31337.json");

const RPC_URL = process.env.LOCAL_RPC_URL || "http://127.0.0.1:8545";
const DEPLOYER_PRIVATE_KEY =
    process.env.DEPLOYER_PRIVATE_KEY ||
    "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";

const FACTORY_ABI = [
    "function createPool(address,string,address,string,uint256,uint256,uint256,uint256) returns (address)",
    "function poolCount() view returns (uint256)",
    "function getPools(uint256 offset,uint256 limit) view returns (address[])",
    "function minimumCreationBondUsd() view returns (uint256)",
    "function compositeOracle() view returns (address)",
];
const ERC20_ABI = [
    "function approve(address spender,uint256 amount) returns (bool)",
    "function decimals() view returns (uint8)",
];
const ORACLE_ABI = ["function getPrice(address token) view returns (uint256)"];

const POOL_CONFIGS = [
    {
        shieldedTokenSymbol: "SUSDE",
        backingTokenSymbol: "gtUSDC",
        commissionRate: 500,
        poolFee: 200,
        collateralRatio: 10000,
    },
    {
        shieldedTokenSymbol: "SDAI",
        backingTokenSymbol: "USDY",
        commissionRate: 500,
        poolFee: 200,
        collateralRatio: 10000,
    },
    {
        shieldedTokenSymbol: "STETH",
        backingTokenSymbol: "STONE",
        commissionRate: 500,
        poolFee: 200,
        collateralRatio: 15000,
    },
    {
        shieldedTokenSymbol: "JAAA",
        backingTokenSymbol: "USTB",
        commissionRate: 500,
        poolFee: 200,
        collateralRatio: 10000,
    },
    {
        shieldedTokenSymbol: "USYC",
        backingTokenSymbol: "RLP",
        commissionRate: 500,
        poolFee: 200,
        collateralRatio: 10000,
    },
];

function dedupeAddresses(addresses) {
    const seen = new Set();
    const result = [];

    for (const address of addresses) {
        if (!address) continue;
        const normalized = address.toLowerCase();
        if (seen.has(normalized)) continue;
        seen.add(normalized);
        result.push(ethers.getAddress(address));
    }

    return result;
}

function loadBroadcast() {
    return JSON.parse(readFileSync(BROADCAST_PATH, "utf8"));
}

function getDeploymentFactoryAddress() {
    try {
        const deployment = JSON.parse(readFileSync(DEPLOYMENT_PATH, "utf8"));
        for (const [address, name] of Object.entries(deployment)) {
            if (name === "SplitRiskPoolFactory") {
                return ethers.getAddress(address);
            }
        }
    } catch {
        return null;
    }

    return null;
}

function getFirstContractAddress(broadcast, contractName) {
    const tx = broadcast.transactions.find(
        (transaction) => transaction.contractName === contractName,
    );

    return tx?.contractAddress ? ethers.getAddress(tx.contractAddress) : null;
}

function getAllContractAddresses(broadcast, contractName) {
    return dedupeAddresses(
        broadcast.transactions
            .filter((transaction) => transaction.contractName === contractName)
            .map((transaction) => transaction.contractAddress),
    );
}

async function waitForTransaction(txPromise, label) {
    const tx = await txPromise;
    const receipt = await tx.wait();
    console.log(`  ${label} (${receipt.hash ?? receipt.transactionHash})`);
    return receipt;
}

async function getCreationBondAmount(factory, provider, tokenAddress) {
    const [minimumCreationBondUsd, oracleAddress] = await Promise.all([
        factory.minimumCreationBondUsd(),
        factory.compositeOracle(),
    ]);

    if (minimumCreationBondUsd === 0n) {
        return 0n;
    }

    const token = new ethers.Contract(tokenAddress, ERC20_ABI, provider);
    const oracle = new ethers.Contract(oracleAddress, ORACLE_ABI, provider);

    const [decimals, price] = await Promise.all([
        token.decimals(),
        oracle.getPrice(tokenAddress),
    ]);
    const scale = 10n ** BigInt(decimals);

    return (minimumCreationBondUsd * scale + price - 1n) / price;
}

async function getHistoricalPools(factory) {
    const poolCount = await factory.poolCount();
    if (poolCount === 0n) {
        return [];
    }

    return factory.getPools(0, poolCount);
}

async function main() {
    const broadcast = loadBroadcast();
    const provider = new ethers.JsonRpcProvider(RPC_URL);
    const wallet = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);

    const factoryAddress =
        getDeploymentFactoryAddress() ||
        getFirstContractAddress(broadcast, "ERC1967Proxy") ||
        getFirstContractAddress(broadcast, "SplitRiskPoolFactory");
    const mockERC20Addresses = getAllContractAddresses(broadcast, "MockERC20");
    const gtusdcAddress = getFirstContractAddress(
        broadcast,
        "MockGauntletUSDCPrime",
    );

    if (!factoryAddress) {
        throw new Error("SplitRiskPoolFactory not found");
    }
    if (!gtusdcAddress) {
        throw new Error("MockGauntletUSDCPrime not found");
    }
    if (mockERC20Addresses.length < 10) {
        throw new Error("Not enough MockERC20 tokens found");
    }

    const factory = new ethers.Contract(factoryAddress, FACTORY_ABI, wallet);
    const existingPools = await getHistoricalPools(factory);
    if (existingPools.length > 0) {
        console.log(
            `Pools already exist (${existingPools.length}), skipping creation.`,
        );
        return;
    }

    const [susde, sdai, usdy, steth, stone, jaaa, ustb, usyc, _lbtc, rlp] =
        mockERC20Addresses;

    const shieldedTokens = [susde, sdai, steth, jaaa, usyc];
    const backingTokens = [gtusdcAddress, usdy, stone, ustb, rlp];

    console.log("=== Local Pool Creation ===");
    console.log(`Factory: ${factoryAddress}`);

    for (let index = 0; index < POOL_CONFIGS.length; index += 1) {
        const poolConfig = POOL_CONFIGS[index];
        const backingToken = backingTokens[index];
        const creationBondAmount = await getCreationBondAmount(
            factory,
            provider,
            backingToken,
        );
        const backingTokenContract = new ethers.Contract(
            backingToken,
            ERC20_ABI,
            wallet,
        );

        if (creationBondAmount !== 0n) {
            await waitForTransaction(
                backingTokenContract.approve(
                    factoryAddress,
                    creationBondAmount,
                ),
                `Approved creation bond for ${poolConfig.backingTokenSymbol}`,
            );
        }

        await waitForTransaction(
            factory.createPool(
                shieldedTokens[index],
                poolConfig.shieldedTokenSymbol,
                backingToken,
                poolConfig.backingTokenSymbol,
                poolConfig.commissionRate,
                poolConfig.poolFee,
                poolConfig.collateralRatio,
                creationBondAmount,
            ),
            `Created pool #${index + 1} (${poolConfig.shieldedTokenSymbol}/${
                poolConfig.backingTokenSymbol
            })`,
        );
    }

    const pools = await getHistoricalPools(factory);
    console.log(`\nPool creation complete. Total pools: ${pools.length}`);
    for (let index = 0; index < pools.length; index += 1) {
        console.log(`  Pool #${index + 1}: ${pools[index]}`);
    }
}

main().catch((error) => {
    console.error("\nPool creation failed:");
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
});
