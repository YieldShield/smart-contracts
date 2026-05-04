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
  "run-latest.json"
);

const RPC_URL = process.env.LOCAL_RPC_URL || "http://127.0.0.1:8545";
const DEPLOYER_PRIVATE_KEY =
  process.env.DEPLOYER_PRIVATE_KEY ||
  "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";

const ACCOUNTS = [
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
  "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
  "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
  "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",
  "0x976EA74026E726554dB657fA54763abd0C3a0aa9",
  "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955",
  "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f",
  "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720",
];

const DEPLOYER_ADDRESS = ACCOUNTS[9].toLowerCase();
const STANDARD_AMOUNT = ethers.utils.parseUnits("10000", 18);
const USDC_AMOUNT = ethers.utils.parseUnits("10000", 6);
const WHALE_MULTIPLIER = ethers.BigNumber.from(10);
const YS_STANDARD_AMOUNT = ethers.utils.parseUnits("10000", 18);

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address,uint256) returns (bool)",
  "function mint(address,uint256)",
];

const ERC4626_MINT_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function mintShares(address,uint256)",
];

function loadBroadcast() {
  return JSON.parse(readFileSync(BROADCAST_PATH, "utf8"));
}

function dedupeAddresses(addresses) {
  const seen = new Set();
  const result = [];

  for (const address of addresses) {
    if (!address) continue;
    const normalized = address.toLowerCase();
    if (seen.has(normalized)) continue;
    seen.add(normalized);
    result.push(ethers.utils.getAddress(address));
  }

  return result;
}

function getFirstContractAddress(broadcast, contractName) {
  const tx = broadcast.transactions.find(
    (transaction) => transaction.contractName === contractName
  );

  return tx?.contractAddress
    ? ethers.utils.getAddress(tx.contractAddress)
    : null;
}

function getAllContractAddresses(broadcast, contractName) {
  return dedupeAddresses(
    broadcast.transactions
      .filter((transaction) => transaction.contractName === contractName)
      .map((transaction) => transaction.contractAddress)
  );
}

function formatUnits(value, decimals) {
  return ethers.utils.commify(ethers.utils.formatUnits(value, decimals));
}

async function waitForTransaction(txPromise, label) {
  const tx = await txPromise;
  const receipt = await tx.wait();
  console.log(`  ${label} (${receipt.transactionHash})`);
  return receipt;
}

async function topUpTokenBalances({
  contract,
  accounts,
  whaleAmount,
  standardAmount,
  mintMethod,
  decimals,
  label,
}) {
  console.log(`\nSeeding ${label}...`);

  for (let index = 0; index < accounts.length; index += 1) {
    const account = accounts[index];
    const targetAmount = index === 0 ? whaleAmount : standardAmount;
    const currentBalance = await contract.balanceOf(account);

    if (currentBalance.gte(targetAmount)) {
      continue;
    }

    const topUpAmount = targetAmount.sub(currentBalance);
    await waitForTransaction(
      contract[mintMethod](account, topUpAmount),
      `${label}: topped up account #${index} by ${formatUnits(
        topUpAmount,
        decimals
      )}`
    );
  }
}

async function distributeYSTokens(ysToken, walletAddress) {
  console.log("\nSeeding YS token balances...");

  let requiredStandardTopUp = ethers.BigNumber.from(0);
  for (let index = 1; index < ACCOUNTS.length; index += 1) {
    const account = ACCOUNTS[index];
    if (account.toLowerCase() === walletAddress) continue;

    const currentBalance = await ysToken.balanceOf(account);
    if (currentBalance.lt(YS_STANDARD_AMOUNT)) {
      requiredStandardTopUp = requiredStandardTopUp.add(
        YS_STANDARD_AMOUNT.sub(currentBalance)
      );
    }
  }

  const deployerBalance = await ysToken.balanceOf(walletAddress);
  if (deployerBalance.lt(requiredStandardTopUp)) {
    throw new Error("Insufficient YS balance for standard accounts");
  }

  const governanceBalance = await ysToken.balanceOf(ACCOUNTS[0]);
  const governanceTarget = governanceBalance.add(
    deployerBalance.sub(requiredStandardTopUp)
  );

  if (governanceBalance.lt(governanceTarget)) {
    const amountToTransfer = governanceTarget.sub(governanceBalance);
    await waitForTransaction(
      ysToken.transfer(ACCOUNTS[0], amountToTransfer),
      `YS: funded account #0 with ${formatUnits(amountToTransfer, 18)}`
    );
  }

  for (let index = 1; index < ACCOUNTS.length; index += 1) {
    const account = ACCOUNTS[index];
    if (account.toLowerCase() === walletAddress) continue;

    const currentBalance = await ysToken.balanceOf(account);
    if (currentBalance.gte(YS_STANDARD_AMOUNT)) {
      continue;
    }

    const amountToTransfer = YS_STANDARD_AMOUNT.sub(currentBalance);
    await waitForTransaction(
      ysToken.transfer(account, amountToTransfer),
      `YS: topped up account #${index} by ${formatUnits(amountToTransfer, 18)}`
    );
  }
}

async function main() {
  const broadcast = loadBroadcast();
  const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(DEPLOYER_PRIVATE_KEY, provider);
  const walletAddress = wallet.address.toLowerCase();

  if (walletAddress !== DEPLOYER_ADDRESS) {
    throw new Error(
      `Expected local deployer ${DEPLOYER_ADDRESS}, got ${wallet.address}`
    );
  }

  const ysTokenAddress = getFirstContractAddress(broadcast, "YSToken");
  const usdcAddress = getFirstContractAddress(broadcast, "MockUSDC");
  const gtusdcAddress = getFirstContractAddress(
    broadcast,
    "MockGauntletUSDCPrime"
  );
  const mockERC20Addresses = getAllContractAddresses(broadcast, "MockERC20");

  if (!ysTokenAddress) throw new Error("YSToken not found in broadcast");
  if (!usdcAddress) throw new Error("MockUSDC not found in broadcast");
  if (!gtusdcAddress) {
    throw new Error("MockGauntletUSDCPrime not found in broadcast");
  }
  if (mockERC20Addresses.length < 11) {
    throw new Error("Not enough MockERC20 tokens found in broadcast");
  }

  const ysToken = new ethers.Contract(ysTokenAddress, ERC20_ABI, wallet);
  const usdc = new ethers.Contract(usdcAddress, ERC20_ABI, wallet);
  const gtusdc = new ethers.Contract(gtusdcAddress, ERC4626_MINT_ABI, wallet);

  console.log("=== Local Token Distribution ===");
  console.log(`RPC URL: ${RPC_URL}`);
  console.log(`Deployer: ${wallet.address}`);
  console.log(`YS Token: ${ysTokenAddress}`);
  console.log(`MockERC20 tokens: ${mockERC20Addresses.length}`);

  await distributeYSTokens(ysToken, walletAddress);

  for (let index = 0; index < mockERC20Addresses.length; index += 1) {
    const token = new ethers.Contract(
      mockERC20Addresses[index],
      ERC20_ABI,
      wallet
    );
    await topUpTokenBalances({
      contract: token,
      accounts: ACCOUNTS,
      whaleAmount: STANDARD_AMOUNT.mul(WHALE_MULTIPLIER),
      standardAmount: STANDARD_AMOUNT,
      mintMethod: "mint",
      decimals: 18,
      label: `MockERC20 #${index + 1}`,
    });
  }

  await topUpTokenBalances({
    contract: usdc,
    accounts: ACCOUNTS,
    whaleAmount: USDC_AMOUNT.mul(WHALE_MULTIPLIER),
    standardAmount: USDC_AMOUNT,
    mintMethod: "mint",
    decimals: 6,
    label: "MockUSDC",
  });

  await topUpTokenBalances({
    contract: gtusdc,
    accounts: ACCOUNTS,
    whaleAmount: STANDARD_AMOUNT.mul(WHALE_MULTIPLIER),
    standardAmount: STANDARD_AMOUNT,
    mintMethod: "mintShares",
    decimals: 18,
    label: "MockGauntletUSDCPrime",
  });

  console.log("\nToken distribution complete.");
}

main().catch((error) => {
  console.error("\nToken distribution failed:");
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
