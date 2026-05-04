import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FOUNDRY_DIR = join(__dirname, "..");
const DEPLOYMENT_PATH = join(FOUNDRY_DIR, "deployments", "31337.json");

const RPC_URL = process.env.LOCAL_RPC_URL || "http://127.0.0.1:8545";

const ACCOUNTS = [
  {
    addr: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    privateKey:
      "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  },
  {
    addr: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    privateKey:
      "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  },
  {
    addr: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    privateKey:
      "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  },
  {
    addr: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
    privateKey:
      "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  },
  {
    addr: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
    privateKey:
      "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
  },
  {
    addr: "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",
    privateKey:
      "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
  },
  {
    addr: "0x976EA74026E726554dB657fA54763abd0C3a0aa9",
    privateKey:
      "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
  },
  {
    addr: "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955",
    privateKey:
      "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356",
  },
  {
    addr: "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f",
    privateKey:
      "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97",
  },
  {
    addr: "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720",
    privateKey:
      "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6",
  },
];

const FACTORY_ABI = [
  "function poolCount() view returns (uint256)",
  "function getPools(uint256 offset,uint256 limit) view returns (address[])",
];

const POOL_ABI = [
  "function SHIELDED_TOKEN() view returns (address)",
  "function BACKING_TOKEN() view returns (address)",
  "function totalShieldedTokens() view returns (uint256)",
  "function totalProtectorTokens() view returns (uint256)",
  "function depositShieldedAsset(address,uint256,uint256) returns (uint256)",
  "function depositBackingAsset(address,uint256,uint256) returns (uint256)",
];

const ERC20_ABI = ["function approve(address,uint256) returns (bool)"];

function loadDeployment() {
  return JSON.parse(readFileSync(DEPLOYMENT_PATH, "utf8"));
}

function getFactoryAddress(deployment) {
  for (const [address, name] of Object.entries(deployment)) {
    if (name === "SplitRiskPoolFactory") {
      return ethers.utils.getAddress(address);
    }
  }

  throw new Error("SplitRiskPoolFactory not found in deployment file");
}

async function waitForTransaction(txPromise, label) {
  const tx = await txPromise;
  const receipt = await tx.wait();
  console.log(`  ${label} (${receipt.transactionHash})`);
  return receipt;
}

async function getHistoricalPools(factory) {
  const poolCount = await factory.poolCount();
  if (poolCount.lt(5)) {
    throw new Error(`Expected at least 5 pools, found ${poolCount.toString()}`);
  }

  return factory.getPools(0, 5);
}

async function createProtectorPosition(
  provider,
  account,
  pool,
  tokenAddress,
  amount,
  label
) {
  const wallet = new ethers.Wallet(account.privateKey, provider);
  const token = new ethers.Contract(tokenAddress, ERC20_ABI, wallet);
  const poolWithSigner = pool.connect(wallet);

  await waitForTransaction(
    token.approve(pool.address, amount),
    `${label}: approved backing token`
  );
  await waitForTransaction(
    poolWithSigner.depositBackingAsset(tokenAddress, amount, 0),
    `${label}: deposited backing asset ${ethers.utils.formatUnits(amount, 18)}`
  );
}

async function createShieldedPosition(
  provider,
  account,
  pool,
  tokenAddress,
  amount,
  label
) {
  const wallet = new ethers.Wallet(account.privateKey, provider);
  const token = new ethers.Contract(tokenAddress, ERC20_ABI, wallet);
  const poolWithSigner = pool.connect(wallet);

  await waitForTransaction(
    token.approve(pool.address, amount),
    `${label}: approved shielded token`
  );
  await waitForTransaction(
    poolWithSigner.depositShieldedAsset(tokenAddress, amount, 0),
    `${label}: deposited shielded asset ${ethers.utils.formatUnits(amount, 18)}`
  );
}

async function main() {
  const deployment = loadDeployment();
  const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
  const factoryAddress = getFactoryAddress(deployment);
  const factory = new ethers.Contract(factoryAddress, FACTORY_ABI, provider);
  const poolAddresses = await getHistoricalPools(factory);

  const pools = poolAddresses.map(
    (address) => new ethers.Contract(address, POOL_ABI, provider)
  );

  const existingInsured = await pools[0].totalShieldedTokens();
  const existingUnderwriter = await pools[0].totalProtectorTokens();
  if (!existingInsured.isZero() && !existingUnderwriter.isZero()) {
    console.log(
      `Positions already exist (insured=${existingInsured.toString()}, underwriter=${existingUnderwriter.toString()}), skipping.`
    );
    return;
  }

  const pool1 = pools[0];
  const pool2 = pools[1];
  const pool3 = pools[2];
  const pool4 = pools[3];
  const pool5 = pools[4];

  const susdeAddr = await pool1.SHIELDED_TOKEN();
  const gtusdcAddr = await pool1.BACKING_TOKEN();
  const sdaiAddr = await pool2.SHIELDED_TOKEN();
  const usdyAddr = await pool2.BACKING_TOKEN();
  const stethAddr = await pool3.SHIELDED_TOKEN();
  const stoneAddr = await pool3.BACKING_TOKEN();
  const jaaaAddr = await pool4.SHIELDED_TOKEN();
  const ustbAddr = await pool4.BACKING_TOKEN();

  console.log("=== Local Position Creation ===");

  await createProtectorPosition(
    provider,
    ACCOUNTS[2],
    pool1,
    gtusdcAddr,
    ethers.utils.parseUnits("200", 18),
    "Account #2 / Pool 1"
  );

  await createProtectorPosition(
    provider,
    ACCOUNTS[4],
    pool1,
    gtusdcAddr,
    ethers.utils.parseUnits("1000", 18),
    "Account #4 / Pool 1"
  );
  await createProtectorPosition(
    provider,
    ACCOUNTS[4],
    pool2,
    usdyAddr,
    ethers.utils.parseUnits("1000", 18),
    "Account #4 / Pool 2"
  );
  await createProtectorPosition(
    provider,
    ACCOUNTS[4],
    pool3,
    stoneAddr,
    ethers.utils.parseUnits("1000", 18),
    "Account #4 / Pool 3"
  );
  await createProtectorPosition(
    provider,
    ACCOUNTS[4],
    pool4,
    ustbAddr,
    ethers.utils.parseUnits("1000", 18),
    "Account #4 / Pool 4"
  );

  await createProtectorPosition(
    provider,
    ACCOUNTS[5],
    pool1,
    gtusdcAddr,
    ethers.utils.parseUnits("600", 18),
    "Account #5 / Pool 1 protector"
  );
  await createProtectorPosition(
    provider,
    ACCOUNTS[5],
    pool2,
    usdyAddr,
    ethers.utils.parseUnits("600", 18),
    "Account #5 / Pool 2 protector"
  );

  await createProtectorPosition(
    provider,
    ACCOUNTS[7],
    pool1,
    gtusdcAddr,
    ethers.utils.parseUnits("10000", 18),
    "Account #7 / Pool 1"
  );

  await createProtectorPosition(
    provider,
    ACCOUNTS[8],
    pool3,
    stoneAddr,
    ethers.utils.parseUnits("400", 18),
    "Account #8 / Pool 3 protector"
  );

  await createShieldedPosition(
    provider,
    ACCOUNTS[1],
    pool1,
    susdeAddr,
    ethers.utils.parseUnits("100", 18),
    "Account #1 / Pool 1"
  );

  await createShieldedPosition(
    provider,
    ACCOUNTS[3],
    pool1,
    susdeAddr,
    ethers.utils.parseUnits("500", 18),
    "Account #3 / Pool 1"
  );
  await createShieldedPosition(
    provider,
    ACCOUNTS[3],
    pool2,
    sdaiAddr,
    ethers.utils.parseUnits("500", 18),
    "Account #3 / Pool 2"
  );
  await createShieldedPosition(
    provider,
    ACCOUNTS[3],
    pool3,
    stethAddr,
    ethers.utils.parseUnits("500", 18),
    "Account #3 / Pool 3"
  );
  await createShieldedPosition(
    provider,
    ACCOUNTS[3],
    pool4,
    jaaaAddr,
    ethers.utils.parseUnits("500", 18),
    "Account #3 / Pool 4"
  );

  await createShieldedPosition(
    provider,
    ACCOUNTS[5],
    pool1,
    susdeAddr,
    ethers.utils.parseUnits("300", 18),
    "Account #5 / Pool 1 shielded"
  );
  await createShieldedPosition(
    provider,
    ACCOUNTS[5],
    pool2,
    sdaiAddr,
    ethers.utils.parseUnits("300", 18),
    "Account #5 / Pool 2 shielded"
  );

  await createShieldedPosition(
    provider,
    ACCOUNTS[6],
    pool1,
    susdeAddr,
    ethers.utils.parseUnits("8000", 18),
    "Account #6 / Pool 1"
  );

  await createShieldedPosition(
    provider,
    ACCOUNTS[8],
    pool3,
    stethAddr,
    ethers.utils.parseUnits("200", 18),
    "Account #8 / Pool 3 shielded"
  );

  console.log("\nPosition creation complete.");
}

main().catch((error) => {
  console.error("\nPosition creation failed:");
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
