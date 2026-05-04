#!/usr/bin/env node

/**
 * Script to configure token-to-price-feed mappings in PythOracle
 * Checks which tokens are configured and configures missing ones
 * Uses Foundry keystores from ~/.foundry/keystores/
 * 
 * Usage:
 *   node scripts-js/configure-pyth-tokens.cjs [--pool <pool_address>] [--keystore <keystore_name>]
 * 
 * Options:
 *   --pool <address>  : Check tokens from a specific pool and configure them
 *   --keystore <name> : Use a specific keystore file (default: interactive selection)
 */

const { ethers } = require("ethers");
const { existsSync, readdirSync } = require("fs");
const { join } = require("path");
const { execSync } = require("child_process");
const readline = require("readline");

require("dotenv").config({ path: join(__dirname, "..", ".env") });

// Token configuration mapping
const TOKEN_CONFIG = {
  // SUSDE mock token
  "0x1d804cd133b3cf35cff4b2cc19d7e6deefcd644a": {
    name: "SUSDE",
    feedId: "0xca3ba9a619a4b3755c10ac7d5e760275aa95e9823d38a84fedd416856cdba37c",
  },
  // SDAI mock token
  "0x6D59F75Cb4367299B6887C726d46805D7acd8ad0": {
    name: "SDAI",
    feedId: "0x710659c5a68e2416ce4264ca8d50d34acc20041d91289110eea152c52ff3dc39",
  },
  // USDY mock token (if needed)
  "0x4C53E534fD51127c1923d63261e5c1cd4a1d3580": {
    name: "USDY",
    feedId: "0xe393449f6aff8a4b6d3e1165a7c9ebec103685f3b41e60db4277b5b6d10e7326",
  },
  // gtUSDC mock token (Gauntlet USDC Prime vault)
  // Uses USDC/USD feed since it's a vault backed by USDC
  "0xa20bca225ec2251d60e995a1613790d8a3511b39": {
    name: "gtUSDC",
    feedId: "0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a", // USDC/USD feed
  },
};

/**
 * Get Oracle address from deployment file
 */
function getOracleAddress() {
  const deploymentFile = join(__dirname, "..", "deployments", "421614.json");
  if (existsSync(deploymentFile)) {
    try {
      const deploymentData = require(deploymentFile);
      for (const [address, contractName] of Object.entries(deploymentData)) {
        if (contractName === "PythOracle" && address.startsWith("0x")) {
          return address;
        }
      }
    } catch (error) {
      console.warn(`Warning: Could not read deployment file: ${error.message}`);
    }
  }
  return "0x286d1116C2428f49d081c43a60113aB36e7912c5"; // Fallback
}

/**
 * Get tokens from a pool address
 */
async function getPoolTokens(poolAddress, provider) {
  const poolAbi = [
    "function INSURED_TOKEN() external view returns (address)",
    "function UNDERWRITER_TOKEN() external view returns (address)",
  ];
  
  try {
    const pool = new ethers.Contract(poolAddress, poolAbi, provider);
    const [insuredToken, underwriterToken] = await Promise.all([
      pool.INSURED_TOKEN(),
      pool.UNDERWRITER_TOKEN(),
    ]);
    return [insuredToken, underwriterToken];
  } catch (error) {
    console.error(`Error reading pool tokens: ${error.message}`);
    return null;
  }
}

/**
 * List available Foundry keystores from ~/.foundry/keystores/
 */
function listFoundryKeystores() {
  const keystorePath = join(process.env.HOME, ".foundry", "keystores");
  
  if (!existsSync(keystorePath)) {
    throw new Error(`Keystore directory not found: ${keystorePath}\nRun 'cast wallet new' to create a keystore.`);
  }

  const keystores = readdirSync(keystorePath).filter(
    (keystore) => keystore !== "scaffold-eth-default"
  );

  if (keystores.length === 0) {
    throw new Error("No keystores found in ~/.foundry/keystores\nRun 'cast wallet new' to create a keystore.");
  }

  return keystores;
}

/**
 * Get keystore selection from user
 */
async function selectKeystore(keystoreName) {
  const keystores = listFoundryKeystores();

  if (keystoreName) {
    if (keystores.includes(keystoreName)) {
      return keystoreName;
    }
    throw new Error(`Keystore not found: ${keystoreName}\nAvailable: ${keystores.join(", ")}`);
  }

  // Interactive selection
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  console.log("\n💼 Available keystores:");
  keystores.forEach((k, i) => console.log(`  ${i + 1}. ${k}`));

  return new Promise((resolve, reject) => {
    rl.question("\nSelect a keystore (enter the number): ", (answer) => {
      rl.close();
      const index = parseInt(answer) - 1;
      if (index >= 0 && index < keystores.length) {
        resolve(keystores[index]);
      } else {
        reject(new Error("Invalid selection"));
      }
    });
  });
}

/**
 * Get address for a Foundry keystore using cast
 */
function getKeystoreAddress(keystoreName) {
  try {
    const address = execSync(`cast wallet address --account ${keystoreName}`, {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    return address;
      } catch (error) {
    throw new Error(`Failed to get address for keystore ${keystoreName}: ${error.message}`);
      }
}

/**
 * Check token configuration
 */
async function checkTokenConfig(oracle, tokenAddress) {
  try {
    const [isSupported, feedId] = await Promise.all([
      oracle.isTokenSupported(tokenAddress),
      oracle.tokenToPriceFeedId(tokenAddress),
    ]);
    return { isSupported, feedId };
  } catch (error) {
    return { isSupported: false, feedId: null, error: error.message };
  }
}

/**
 * Configure a token using cast send
 */
async function configureToken(oracleAddress, keystoreName, tokenAddress, feedId, tokenName, rpcUrl) {
  try {
    console.log(`  Configuring ${tokenName} (${tokenAddress})...`);
    
    // Use cast send with the keystore
    const cmd = `cast send ${oracleAddress} "setTokenPriceFeed(address,bytes32)" ${tokenAddress} ${feedId} --account ${keystoreName} --rpc-url "${rpcUrl}"`;
    
    console.log(`    Sending transaction...`);
    const output = execSync(cmd, {
      encoding: "utf-8",
      stdio: ["inherit", "pipe", "pipe"],
    });
    
    // Extract transaction hash from output
    const txHashMatch = output.match(/transactionHash\s+(0x[a-fA-F0-9]+)/);
    if (txHashMatch) {
      console.log(`    Transaction: ${txHashMatch[1]}`);
    }
    
    console.log(`    ✓ ${tokenName} configured successfully`);
    return true;
  } catch (error) {
    console.error(`    ✗ Failed to configure ${tokenName}: ${error.message}`);
    return false;
  }
}

async function main() {
  // Parse command line arguments
  const args = process.argv.slice(2);
  let poolAddress = null;
  let keystoreName = null;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--pool" && i + 1 < args.length) {
      poolAddress = args[i + 1];
    } else if (args[i] === "--keystore" && i + 1 < args.length) {
      keystoreName = args[i + 1];
    }
  }

  // Get RPC URL
  let rpcUrl = process.env.ARBITRUM_SEPOLIA_RPC_URL;
  if (!rpcUrl && process.env.ALCHEMY_API_KEY) {
    rpcUrl = `https://arb-sepolia.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`;
  }
  if (!rpcUrl) {
    console.error("Error: RPC URL required. Set ARBITRUM_SEPOLIA_RPC_URL or ALCHEMY_API_KEY");
    process.exit(1);
  }

  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const oracleAddress = getOracleAddress();

  // PythOracle ABI
  const oracleAbi = [
    "function setTokenPriceFeed(address token, bytes32 feedId) external",
    "function isTokenSupported(address) external view returns (bool)",
    "function tokenToPriceFeedId(address) external view returns (bytes32)",
    "function owner() external view returns (address)",
  ];

  const oracle = new ethers.Contract(oracleAddress, oracleAbi, provider);

  console.log("=== PythOracle Token Configuration ===");
  console.log("Oracle:", oracleAddress);
  console.log("Network:", (await provider.getNetwork()).name);

  // Check if we need to configure tokens from a pool
  let tokensToCheck = Object.keys(TOKEN_CONFIG);
  
  if (poolAddress) {
    console.log(`\nReading tokens from pool: ${poolAddress}`);
    const poolTokens = await getPoolTokens(poolAddress, provider);
    if (poolTokens) {
      tokensToCheck = poolTokens.filter(t => t && t !== ethers.constants.AddressZero);
      console.log(`  Found tokens: ${tokensToCheck.join(", ")}`);
    }
  }

  // Check current configuration
  console.log("\n=== Checking Token Configuration ===");
  const tokensToConfigure = [];

  // Normalize TOKEN_CONFIG keys to lowercase for lookup
  const normalizedTokenConfig = {};
  for (const [key, value] of Object.entries(TOKEN_CONFIG)) {
    normalizedTokenConfig[key.toLowerCase()] = value;
  }

  for (const tokenAddress of tokensToCheck) {
    const tokenInfo = normalizedTokenConfig[tokenAddress.toLowerCase()];
    if (!tokenInfo) {
      console.warn(`  ⚠ ${tokenAddress}: No configuration found (unknown token)`);
      continue;
    }

    const { isSupported, feedId } = await checkTokenConfig(oracle, tokenAddress);
    
    if (!isSupported || feedId === ethers.constants.HashZero) {
      console.warn(`  ⚠ ${tokenInfo.name} (${tokenAddress}): NOT CONFIGURED`);
      tokensToConfigure.push({ address: tokenAddress, ...tokenInfo });
    } else {
      console.log(`  ✓ ${tokenInfo.name} (${tokenAddress}): configured`);
      console.log(`    Feed ID: ${feedId}`);
    }
  }

  if (tokensToConfigure.length === 0) {
    console.log("\n✅ All tokens are properly configured!");
    return;
  }

  // Configure missing tokens
  console.log(`\n=== Configuring ${tokensToConfigure.length} Missing Token(s) ===`);
  
  // Check if we're the owner
  let owner;
  try {
    owner = await oracle.owner();
    console.log(`Oracle owner: ${owner}`);
  } catch (error) {
    console.error("Could not read Oracle owner:", error.message);
    process.exit(1);
  }

  // Select keystore
  const selectedKeystore = await selectKeystore(keystoreName);
  console.log(`\n🔑 Using keystore: ${selectedKeystore}`);
  
  // Get signer address
  const signerAddress = getKeystoreAddress(selectedKeystore);
  console.log(`Signer: ${signerAddress}`);

  if (signerAddress.toLowerCase() !== owner.toLowerCase()) {
    console.error(`\n❌ Error: Signer is not the Oracle owner!`);
    console.error(`  Owner: ${owner}`);
    console.error(`  Signer: ${signerAddress}`);
    process.exit(1);
  }

  // Configure tokens
  let successCount = 0;
  for (const token of tokensToConfigure) {
    const success = await configureToken(
      oracleAddress,
      selectedKeystore,
      token.address,
      token.feedId,
      token.name,
      rpcUrl
    );
    if (success) successCount++;
  }

  console.log(`\n=== Summary ===`);
  console.log(`Configured: ${successCount}/${tokensToConfigure.length} tokens`);
  
  if (successCount === tokensToConfigure.length) {
    console.log("✅ All tokens configured successfully!");
  } else {
    console.warn("⚠ Some tokens failed to configure. Check the errors above.");
    process.exit(1);
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}

module.exports = { getOracleAddress, checkTokenConfig, configureToken };
