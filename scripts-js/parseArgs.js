import { spawnSync } from "child_process";
import { createHash, randomBytes } from "crypto";
import { config } from "dotenv";
import { join, dirname } from "path";
import { readFileSync, existsSync } from "fs";
import { parse } from "toml";
import { fileURLToPath } from "url";
import { JsonRpcProvider } from "ethers";
import {
    DEFAULT_KEYSTORE_ACCOUNT,
    isValidKeystoreName,
    keystoreExists,
} from "./foundryKeystore.js";
import { selectOrCreateKeystore } from "./selectOrCreateKeystore.js";
import {
    CHAIN_FINALITY_POLICY,
    chainFinalityPolicy,
    requireIndependentRpcOperators,
    requireIndependentRpcUrls,
    resolveFinalityEvidence,
    resolveRpcUrl,
} from "./finalizeDeploymentManifest.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
config();

const LOCAL_DEPLOY_SCRIPT = "Deploy.s.sol";
const PRODUCTION_DEPLOY_SCRIPT = "DeployYieldShieldProduction.s.sol";
const DEFAULT_NETWORK = "localhost";
const ROBINHOOD_TESTNET_NETWORK = "robinhoodTestnet";
const ROBINHOOD_NETWORKS = new Set(["robinhood", "robinhoodTestnet"]);
const DEPLOYMENT_TARGET_SIZE_CHECK_SCRIPT = join(
    __dirname,
    "checkDeploymentTargetSizes.js",
);
const REQUIRED_RUNTIME_CODEHASH_ENV = [
    "YS_PRODUCTION_FACTORY_PROXY_CODEHASH",
    "YS_PRODUCTION_FACTORY_IMPLEMENTATION_CODEHASH",
    "YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH",
    "YS_PRODUCTION_YS_TOKEN_CODEHASH",
    "YS_PRODUCTION_TIMELOCK_CODEHASH",
    "YS_PRODUCTION_GOVERNOR_CODEHASH",
    "YS_PRODUCTION_COMPOSITE_ORACLE_CODEHASH",
    "YS_PRODUCTION_ERC4626_ORACLE_CODEHASH",
];
const REQUIRED_PRODUCTION_ENV = [
    "YS_PRODUCTION_BOOTSTRAP_HOLDER",
    "YS_PRODUCTION_BOOTSTRAP_HOLDER_CODEHASH",
    "YS_PRODUCTION_BOOTSTRAP_HOLDER_SINGLETON",
    "YS_PRODUCTION_BOOTSTRAP_HOLDER_THRESHOLD",
    "YS_PRODUCTION_BOOTSTRAP_HOLDER_OWNERS_HASH",
    ...REQUIRED_RUNTIME_CODEHASH_ENV,
];
const REQUIRED_ROBINHOOD_ENV = [
    "YS_PRODUCTION_CHAINLINK_ORACLE_CODEHASH",
    "YS_PRODUCTION_US_MARKET_SESSION_GATE_CODEHASH",
    "YS_PRODUCTION_MARKET_SESSION_GUARDIAN",
];
const REQUIRED_PYTH_ENV = ["YS_PRODUCTION_PYTH_ORACLE_CODEHASH"];
const deployScriptFileNamePattern = /^[A-Za-z0-9_.-]+\.s\.sol$/u;

function usage() {
    console.log(`
Usage: yarn deploy [options]
Options:
  --file <filename>     Specify the deployment script file (default: Deploy.s.sol locally, DeployYieldShieldProduction.s.sol on public networks)
  --network <network>   Specify the network (default: localhost)
  --keystore <name>     Specify the keystore account to use (bypasses selection prompt)
  --help, -h           Show this help message
Examples:
  yarn deploy
  yarn deploy --file DeployYieldShield.s.sol --network localhost
  yarn deploy --network robinhoodTestnet --keystore test
  ROBINHOOD_TESTNET_KEYSTORE_ACCOUNT=test yarn deploy --network robinhoodTestnet
  `);
}

function requireOptionValue(args, index, optionName) {
    const value = args[index + 1];
    if (!value || value.startsWith("-")) {
        throw new Error(`${optionName} requires a value.`);
    }
    return value;
}

function parseCliArgs(args) {
    let fileName = LOCAL_DEPLOY_SCRIPT;
    let fileWasProvided = false;
    let network = DEFAULT_NETWORK;
    let keystoreArg = null;
    let help = false;

    for (let i = 0; i < args.length; i++) {
        if (args[i] === "--help" || args[i] === "-h") {
            help = true;
        } else if (args[i] === "--network") {
            network = requireOptionValue(args, i, "--network");
            i++;
        } else if (args[i] === "--file") {
            fileName = requireOptionValue(args, i, "--file");
            fileWasProvided = true;
            i++;
        } else if (args[i] === "--keystore") {
            keystoreArg = requireOptionValue(args, i, "--keystore");
            i++;
        } else {
            throw new Error(
                `Unexpected argument '${args[i]}'. Use --network <name>, --file <filename>, or --keystore <name>.`,
            );
        }
    }

    return { fileName, fileWasProvided, help, keystoreArg, network };
}

function isLocalNetwork(network) {
    return network === DEFAULT_NETWORK;
}

function resolveDeployScript({ fileName, fileWasProvided, network }) {
    if (isLocalNetwork(network)) {
        return { fileName, defaultedToProduction: false };
    }

    if (fileName === LOCAL_DEPLOY_SCRIPT) {
        if (fileWasProvided) {
            throw new Error(
                `Deploy.s.sol is a local-only entrypoint. Use ${PRODUCTION_DEPLOY_SCRIPT} for ${network}.`,
            );
        }

        return {
            fileName: PRODUCTION_DEPLOY_SCRIPT,
            defaultedToProduction: true,
        };
    }

    return { fileName, defaultedToProduction: false };
}

function networkEnvPrefix(network) {
    return network
        .replace(/([a-z0-9])([A-Z])/gu, "$1_$2")
        .replace(/[^A-Za-z0-9]+/gu, "_")
        .replace(/^_+|_+$/gu, "")
        .toUpperCase();
}

function keystoreEnvNames(network) {
    if (isLocalNetwork(network)) {
        return ["LOCALHOST_KEYSTORE_ACCOUNT"];
    }

    return [
        `${networkEnvPrefix(network)}_KEYSTORE_ACCOUNT`,
        "ETH_KEYSTORE_ACCOUNT",
    ];
}

function configuredKeystore({ keystoreArg, network }, env = process.env) {
    if (keystoreArg) {
        return { keystoreName: keystoreArg, source: "--keystore" };
    }

    for (const envName of keystoreEnvNames(network)) {
        if (env[envName]) {
            return { keystoreName: env[envName], source: envName };
        }
    }

    if (isLocalNetwork(network)) {
        return {
            keystoreName: DEFAULT_KEYSTORE_ACCOUNT,
            source: "default",
        };
    }

    return { keystoreName: null, source: null };
}

function envFlag(value) {
    return ["1", "true", "yes"].includes(String(value || "").toLowerCase());
}

function hasNonBlankEnvValue(value) {
    return typeof value === "string" && value.trim().length > 0;
}

function usesRelaxedRobinhoodTestnetGuards(network, env = process.env) {
    return (
        network === ROBINHOOD_TESTNET_NETWORK &&
        !envFlag(env.YS_ROBINHOOD_TESTNET_STRICT_PRODUCTION_GUARDS)
    );
}

function missingProductionEnv({ fileName, network }, env = process.env) {
    if (isLocalNetwork(network) || fileName !== PRODUCTION_DEPLOY_SCRIPT) {
        return [];
    }

    if (usesRelaxedRobinhoodTestnetGuards(network, env)) {
        return [
            ...REQUIRED_RUNTIME_CODEHASH_ENV,
            ...REQUIRED_ROBINHOOD_ENV,
        ].filter((name) => !hasNonBlankEnvValue(env[name]));
    }

    const missing = [...REQUIRED_PRODUCTION_ENV];
    if (ROBINHOOD_NETWORKS.has(network)) {
        missing.push(...REQUIRED_ROBINHOOD_ENV);
        if (network === ROBINHOOD_TESTNET_NETWORK) {
            const sequencerEnvName = "YS_ROBINHOOD_TESTNET_SEQUENCER_FEED";
            if (
                !hasNonBlankEnvValue(env[sequencerEnvName]) &&
                !envFlag(env.YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED)
            ) {
                missing.push(
                    `${sequencerEnvName} or YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED=true`,
                );
            }
        } else {
            if (!hasNonBlankEnvValue(env.YS_ROBINHOOD_SEQUENCER_FEED)) {
                missing.push("YS_ROBINHOOD_SEQUENCER_FEED");
            }
            if (!hasNonBlankEnvValue(env.YS_ROBINHOOD_SEQUENCER_FEED_SOURCE)) {
                missing.push("YS_ROBINHOOD_SEQUENCER_FEED_SOURCE");
            }
            if (
                !hasNonBlankEnvValue(env.YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH)
            ) {
                missing.push("YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH");
            }
        }
    } else {
        missing.push(...REQUIRED_PYTH_ENV);
    }

    return missing.filter((name) => {
        if (name.includes(" or ")) {
            return true;
        }
        return !hasNonBlankEnvValue(env[name]);
    });
}

function forgeScriptArgsForNetwork(network, env = process.env) {
    if (ROBINHOOD_NETWORKS.has(network)) {
        return ["--disable-code-size-limit"];
    }

    return [];
}

function robinhoodProductionDeploymentMode(
    { fileName, network },
    env = process.env,
) {
    if (
        fileName !== PRODUCTION_DEPLOY_SCRIPT ||
        !ROBINHOOD_NETWORKS.has(network)
    ) {
        return null;
    }

    const isTestnet = network === ROBINHOOD_TESTNET_NETWORK;
    const guardMode = usesRelaxedRobinhoodTestnetGuards(network, env)
        ? "relaxed"
        : "strict";
    const demoSettingIsExplicit = hasNonBlankEnvValue(
        env.YS_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS,
    );
    const demoAssetsEnabled =
        isTestnet && envFlag(env.YS_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS);
    let demoAssetsSelection;
    if (!isTestnet) {
        demoAssetsSelection = envFlag(env.YS_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS)
            ? "invalid-mainnet-on"
            : "not-supported";
    } else if (demoAssetsEnabled) {
        demoAssetsSelection = "explicit-on";
    } else {
        demoAssetsSelection = demoSettingIsExplicit
            ? "explicit-off"
            : "default-off";
    }

    const sequencerFeedEnvName = isTestnet
        ? "YS_ROBINHOOD_TESTNET_SEQUENCER_FEED"
        : "YS_ROBINHOOD_SEQUENCER_FEED";
    let sequencerMode;
    if (hasNonBlankEnvValue(env[sequencerFeedEnvName])) {
        sequencerMode = "configured-input";
    } else if (isTestnet && guardMode === "relaxed") {
        sequencerMode = "relaxed-testnet-exception";
    } else if (
        isTestnet &&
        envFlag(env.YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED)
    ) {
        sequencerMode = "explicit-testnet-exception";
    } else {
        sequencerMode = "required-input-missing";
    }

    return {
        codeSizeOverride: true,
        demoAssetsEnabled,
        demoAssetsSelection,
        guardMode,
        network,
        sequencerMode,
    };
}

function formatRobinhoodProductionDeploymentMode(mode) {
    const demoLabels = {
        "default-off": "disabled (default; explicit opt-in required)",
        "explicit-off": "disabled (explicit)",
        "explicit-on": "enabled (explicit testnet fixture mode)",
        "invalid-mainnet-on": "INVALID (demo fixtures are testnet-only)",
        "not-supported": "disabled (not supported on mainnet)",
    };
    const sequencerLabels = {
        "configured-input": "feed input configured; simulation will probe it",
        "explicit-testnet-exception": "explicit testnet-only exception",
        "relaxed-testnet-exception": "relaxed testnet exception",
        "required-input-missing": "required feed input missing",
    };

    return [
        "\n🚦 Robinhood production deployment mode",
        `   Network: ${mode.network}`,
        `   Guardrails: ${mode.guardMode}`,
        `   Demo seeding: ${demoLabels[mode.demoAssetsSelection]}`,
        `   Sequencer guard: ${sequencerLabels[mode.sequencerMode]}`,
        `   Runner code-size override: ${mode.codeSizeOverride ? "enabled" : "disabled"}`,
    ].join("\n");
}

function isValidDeploymentGenerationId(generationId) {
    return (
        typeof generationId === "string" &&
        /^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$/u.test(generationId)
    );
}

function deploymentConfigurationDigest(
    { fileName, network },
    env = process.env,
) {
    const configuration = Object.keys(env)
        .filter(
            (key) => key.startsWith("YS_") && !key.startsWith("YS_DEPLOYMENT_"),
        )
        .sort()
        .map((key) => [key, String(env[key])]);
    const canonical = JSON.stringify({ configuration, fileName, network });
    return `0x${createHash("sha256").update(canonical).digest("hex")}`;
}

function resolveDeploymentGeneration(
    { fileName, network },
    env = process.env,
    { now = Date.now, randomHex = () => randomBytes(8).toString("hex") } = {},
) {
    if (fileName !== PRODUCTION_DEPLOY_SCRIPT || isLocalNetwork(network)) {
        return null;
    }

    const recovery = envFlag(env.YS_DEPLOYMENT_RECOVERY);
    const providedGenerationId = hasNonBlankEnvValue(env.YS_DEPLOYMENT_ID)
        ? env.YS_DEPLOYMENT_ID.trim()
        : null;
    if (recovery && !providedGenerationId) {
        throw new Error(
            "YS_DEPLOYMENT_RECOVERY=true requires the original YS_DEPLOYMENT_ID.",
        );
    }

    const generationId = providedGenerationId || `gen-${now()}-${randomHex()}`;
    if (!isValidDeploymentGenerationId(generationId)) {
        throw new Error(
            "YS_DEPLOYMENT_ID must be 8-128 characters using letters, numbers, dots, underscores, or hyphens, and cannot start with a dot.",
        );
    }

    return {
        configurationDigest: deploymentConfigurationDigest(
            { fileName, network },
            env,
        ),
        generationId,
        recovery,
    };
}

function requiresDeploymentTargetSizeCheck({ fileName, network }) {
    return (
        fileName === PRODUCTION_DEPLOY_SCRIPT && ROBINHOOD_NETWORKS.has(network)
    );
}

function runDeploymentTargetSizeCheck() {
    const result = spawnSync(
        process.execPath,
        [DEPLOYMENT_TARGET_SIZE_CHECK_SCRIPT],
        { stdio: "inherit" },
    );

    if (result.error) {
        throw result.error;
    }

    return result.status ?? 1;
}

function deploymentFinalityPolicyForNetwork(
    network,
    finalityPolicy = CHAIN_FINALITY_POLICY,
) {
    if (
        finalityPolicy?.schemaVersion !== 2 ||
        !finalityPolicy.chains ||
        typeof network !== "string"
    ) {
        throw new Error("Deployment finality policy is invalid.");
    }

    const matches = Object.entries(finalityPolicy.chains).filter(
        ([, policy]) => policy?.rpcAlias === network,
    );
    if (matches.length !== 1) {
        throw new Error(
            `Public network alias '${network}' has no unique checked-in deployment finality policy.`,
        );
    }

    const [chainId, policy] = matches[0];
    chainFinalityPolicy(chainId, finalityPolicy);
    return { chainId, policy };
}

async function preflightPublicDeploymentPromotion(
    { fileName, network, env = process.env },
    {
        finalityPolicy = CHAIN_FINALITY_POLICY,
        providerFactory = (rpcUrl) => new JsonRpcProvider(rpcUrl),
        resolveRpcUrlFn = resolveRpcUrl,
    } = {},
) {
    if (fileName !== PRODUCTION_DEPLOY_SCRIPT || isLocalNetwork(network)) {
        return null;
    }

    const { chainId } = deploymentFinalityPolicyForNetwork(
        network,
        finalityPolicy,
    );
    const primaryRpcUrl = resolveRpcUrlFn(network, env);
    const validationRpcInput = env.YS_DEPLOYMENT_VALIDATION_RPC_URL;
    const validationRpcUrl = validationRpcInput
        ? resolveRpcUrlFn(validationRpcInput, env)
        : validationRpcInput;
    const canonicalRpcUrls = requireIndependentRpcUrls(
        primaryRpcUrl,
        validationRpcUrl,
    );
    const rpcProviderOperators = requireIndependentRpcOperators(
        env.YS_DEPLOYMENT_RPC_OPERATOR,
        env.YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR,
    );
    const provider = providerFactory(canonicalRpcUrls.primaryRpcUrl);
    const validationProvider = providerFactory(
        canonicalRpcUrls.validationRpcUrl,
    );

    try {
        return await resolveFinalityEvidence({
            chainId,
            provider,
            validationProvider,
            primaryRpcUrl: canonicalRpcUrls.primaryRpcUrl,
            validationRpcUrl: canonicalRpcUrls.validationRpcUrl,
            deploymentRpcOperator: rpcProviderOperators.deployment,
            validationRpcOperator: rpcProviderOperators.validation,
            finalityPolicy,
        });
    } finally {
        provider?.destroy?.();
        validationProvider?.destroy?.();
    }
}

async function runDeploymentGatesAndSpawn(
    { fileName, network, env, makeArgs, childEnv },
    {
        preflight = preflightPublicDeploymentPromotion,
        runSizeCheck = runDeploymentTargetSizeCheck,
        spawn = spawnSync,
        log = console.log,
    } = {},
) {
    await preflight({ fileName, network, env });

    if (requiresDeploymentTargetSizeCheck({ fileName, network })) {
        log(
            "\n📏 Validating every production deployment target against Robinhood code-size limits",
        );
        const sizeCheckStatus = runSizeCheck();
        if (sizeCheckStatus !== 0) return sizeCheckStatus;
    }

    const result = spawn("make", makeArgs, {
        env: childEnv,
        stdio: "inherit",
    });
    return result.status ?? 1;
}

function printProductionEnvError(missingEnv) {
    console.log(
        "\n❌ Error: Missing production deployment environment values:",
    );
    for (const envName of missingEnv) {
        console.log(`   - ${envName}`);
    }
    console.log(
        "\nSet these in packages/foundry/.env, then rerun the deploy command.",
    );
}

// Function to check if a keystore exists
function validateKeystore(keystoreName) {
    if (!isValidKeystoreName(keystoreName)) {
        return false;
    }

    if (keystoreName === DEFAULT_KEYSTORE_ACCOUNT) {
        return true;
    }

    return keystoreExists(keystoreName);
}

function validateDeployScriptFileName(name, exitOnError = true) {
    if (
        !deployScriptFileNamePattern.test(name) ||
        name.includes("/") ||
        name.includes("\\")
    ) {
        const message = `Invalid deploy script filename '${name}'. Use a file like DeployYieldShieldProduction.s.sol from the script/ directory.`;
        if (!exitOnError) {
            throw new Error(message);
        }
        console.log(`\n❌ Error: ${message}`);
        process.exit(1);
    }

    const deployScriptPath = join(__dirname, "..", "script", name);
    if (!existsSync(deployScriptPath)) {
        const message = `Deploy script '${name}' not found in script/.`;
        if (!exitOnError) {
            throw new Error(message);
        }
        console.log(`\n❌ Error: ${message}`);
        process.exit(1);
    }
}

function validateNetworkExists(network, exitOnError = true) {
    try {
        const foundryTomlPath = join(__dirname, "..", "foundry.toml");
        const tomlString = readFileSync(foundryTomlPath, "utf-8");
        const parsedToml = parse(tomlString);

        if (!parsedToml.rpc_endpoints[network]) {
            const message = `Network '${network}' not found in foundry.toml!\nPlease check \`foundry.toml\` for available networks in the [rpc_endpoints] section or add a new network.`;
            if (!exitOnError) {
                throw new Error(message);
            }
            console.log(`\n❌ Error: ${message}`);
            process.exit(1);
        }
    } catch (error) {
        if (!exitOnError) {
            throw error;
        }
        console.error("\n❌ Error reading or parsing foundry.toml:", error);
        process.exit(1);
    }
}

async function main(rawArgs = process.argv.slice(2), env = process.env) {
    let parsedArgs;
    try {
        parsedArgs = parseCliArgs(rawArgs);
    } catch (error) {
        console.log(`\n❌ Error: ${error.message}`);
        usage();
        process.exit(1);
    }

    if (parsedArgs.help) {
        usage();
        process.exit(0);
    }

    const { network } = parsedArgs;
    let fileName;
    let defaultedToProduction;
    try {
        ({ fileName, defaultedToProduction } = resolveDeployScript(parsedArgs));
    } catch (error) {
        console.log(`\n❌ Error: ${error.message}`);
        console.log(
            `\nFor public-network deployments, run:\n  yarn deploy --network ${network} --keystore <name>`,
        );
        process.exit(1);
    }

    validateDeployScriptFileName(fileName);
    validateNetworkExists(network);

    if (defaultedToProduction) {
        console.log(
            `\n🛡️  Using ${PRODUCTION_DEPLOY_SCRIPT} for public network '${network}'`,
        );
    }

    const deploymentMode = robinhoodProductionDeploymentMode(
        { fileName, network },
        env,
    );
    if (deploymentMode) {
        console.log(formatRobinhoodProductionDeploymentMode(deploymentMode));
    }

    let deploymentGeneration;
    try {
        deploymentGeneration = resolveDeploymentGeneration(
            { fileName, network },
            env,
        );
    } catch (error) {
        console.log(`\n❌ Error: ${error.message}`);
        process.exit(1);
    }
    if (deploymentGeneration) {
        console.log(
            `\n🧬 Deployment generation: ${deploymentGeneration.generationId}${
                deploymentGeneration.recovery ? " (recovery)" : ""
            }`,
        );
    }

    const { keystoreName: configuredKeystoreName, source: keystoreSource } =
        configuredKeystore(parsedArgs, env);

    if (
        configuredKeystoreName !== DEFAULT_KEYSTORE_ACCOUNT &&
        isLocalNetwork(network) &&
        keystoreSource !== "default"
    ) {
        console.log(`
⚠️ Warning: Using ${configuredKeystoreName} keystore account on localhost.

You can either:
1. Enter the password for ${configuredKeystoreName} account
   OR
2. Set the localhost keystore account in your .env and re-run the command to skip password prompt:
   LOCALHOST_KEYSTORE_ACCOUNT='${DEFAULT_KEYSTORE_ACCOUNT}'
	`);
    }

    let selectedKeystore = configuredKeystoreName;
    if (!isLocalNetwork(network)) {
        if (configuredKeystoreName) {
            if (!validateKeystore(configuredKeystoreName)) {
                console.log(
                    `\n❌ Error: Keystore '${configuredKeystoreName}' is invalid or not found!`,
                );
                console.log(
                    `Use a keystore from ~/.foundry/keystores/ with letters, numbers, dots, underscores, or hyphens only.`,
                );
                process.exit(1);
            }
            selectedKeystore = configuredKeystoreName;
            console.log(
                `\n🔑 Using keystore: ${selectedKeystore}${
                    keystoreSource ? ` (${keystoreSource})` : ""
                }`,
            );
        } else {
            try {
                selectedKeystore = await selectOrCreateKeystore();
            } catch (error) {
                console.error("\n❌ Error selecting keystore:", error);
                process.exit(1);
            }
        }
    } else if (parsedArgs.keystoreArg) {
        // Allow overriding the localhost keystore with --keystore flag
        if (!validateKeystore(parsedArgs.keystoreArg)) {
            console.log(
                `\n❌ Error: Keystore '${parsedArgs.keystoreArg}' is invalid or not found!`,
            );
            console.log(
                `Use a keystore from ~/.foundry/keystores/ with letters, numbers, dots, underscores, or hyphens only.`,
            );
            process.exit(1);
        }
        selectedKeystore = parsedArgs.keystoreArg;
        console.log(
            `\n🔑 Using keystore: ${selectedKeystore} for localhost deployment`,
        );
    }

    // Check for default account on live network
    if (
        selectedKeystore === DEFAULT_KEYSTORE_ACCOUNT &&
        !isLocalNetwork(network)
    ) {
        console.log(`
❌ Error: Cannot deploy to live network using default keystore account!

To deploy to ${network}, please follow these steps:

1. If you haven't generated a keystore account yet:
   $ yarn account:generate

2. Run the deployment command again.

The default account (${DEFAULT_KEYSTORE_ACCOUNT}) can only be used for localhost deployments.
`);
        process.exit(1);
    }

    const missingEnv = missingProductionEnv({ fileName, network }, env);
    if (missingEnv.length > 0) {
        printProductionEnvError(missingEnv);
        process.exit(1);
    }

    const makeArgs = [
        `DEPLOY_SCRIPT=script/${fileName}`,
        `RPC_URL=${network}`,
        `ETH_KEYSTORE_ACCOUNT=${selectedKeystore}`,
    ];
    const forgeScriptArgs = forgeScriptArgsForNetwork(network, env);
    if (deploymentGeneration?.recovery) {
        forgeScriptArgs.push("--resume");
    }
    if (forgeScriptArgs.length > 0) {
        makeArgs.push(`FORGE_SCRIPT_ARGS=${forgeScriptArgs.join(" ")}`);
    }
    makeArgs.push("deploy-and-generate-abis");

    const childEnv = deploymentGeneration
        ? {
              ...process.env,
              ...env,
              YS_DEPLOYMENT_CONFIGURATION_DIGEST:
                  deploymentGeneration.configurationDigest,
              YS_DEPLOYMENT_ID: deploymentGeneration.generationId,
              YS_PRODUCTION_DEPLOYMENT_CANDIDATE: "true",
          }
        : process.env;
    let deploymentStatus;
    try {
        deploymentStatus = await runDeploymentGatesAndSpawn({
            fileName,
            network,
            env,
            makeArgs,
            childEnv,
        });
    } catch (error) {
        console.error(
            `\n❌ Deployment promotion preflight failed: ${error.message}`,
        );
        process.exit(1);
    }

    process.exit(deploymentStatus);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    await main();
}

export {
    configuredKeystore,
    deploymentFinalityPolicyForNetwork,
    deploymentConfigurationDigest,
    forgeScriptArgsForNetwork,
    hasNonBlankEnvValue,
    isLocalNetwork,
    keystoreEnvNames,
    missingProductionEnv,
    networkEnvPrefix,
    parseCliArgs,
    preflightPublicDeploymentPromotion,
    resolveDeploymentGeneration,
    resolveDeployScript,
    requiresDeploymentTargetSizeCheck,
    runDeploymentGatesAndSpawn,
    isValidDeploymentGenerationId,
    formatRobinhoodProductionDeploymentMode,
    robinhoodProductionDeploymentMode,
    usesRelaxedRobinhoodTestnetGuards,
    validateDeployScriptFileName,
    validateNetworkExists,
};
