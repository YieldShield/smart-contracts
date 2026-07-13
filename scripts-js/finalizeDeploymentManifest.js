import { ethers } from "ethers";
import {
    existsSync,
    mkdirSync,
    readFileSync,
    renameSync,
    rmSync,
    writeFileSync,
} from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { parse as parseToml } from "toml";
import { resolveRpcEndpoint } from "./checkAccountBalance.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, "..");
const FINALITY_POLICY_PATH = join(
    PROJECT_ROOT,
    "config",
    "deployment-finality-policy.json",
);
const CHAIN_FINALITY_POLICY = Object.freeze(
    JSON.parse(readFileSync(FINALITY_POLICY_PATH, "utf8")),
);

const PYTH_CORE_INVENTORY = Object.freeze([
    "YSToken",
    "TimelockController",
    "YSGovernor",
    "PythOracle",
    "ERC4626OracleFeed",
    "CompositeOracle",
    "SplitRiskPoolFactoryImplementation",
    "SplitRiskPoolImplementation",
    "SplitRiskPoolFactory",
]);
const CHAINLINK_CORE_INVENTORY = Object.freeze([
    "YSToken",
    "TimelockController",
    "YSGovernor",
    "ChainlinkOracleFeed",
    "USMarketSessionGate",
    "RobinhoodStockOracleFeed",
    "ERC4626OracleFeed",
    "CompositeOracle",
    "SplitRiskPoolFactoryImplementation",
    "SplitRiskPoolImplementation",
    "SplitRiskPoolFactory",
]);
const COMMON_REVIEWED_CODEHASH_PINS = Object.freeze([
    ["SplitRiskPoolFactory", "YS_PRODUCTION_FACTORY_PROXY_CODEHASH"],
    [
        "SplitRiskPoolFactoryImplementation",
        "YS_PRODUCTION_FACTORY_IMPLEMENTATION_CODEHASH",
    ],
    [
        "SplitRiskPoolImplementation",
        "YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH",
    ],
    ["YSToken", "YS_PRODUCTION_YS_TOKEN_CODEHASH"],
    ["TimelockController", "YS_PRODUCTION_TIMELOCK_CODEHASH"],
    ["YSGovernor", "YS_PRODUCTION_GOVERNOR_CODEHASH"],
    ["CompositeOracle", "YS_PRODUCTION_COMPOSITE_ORACLE_CODEHASH"],
    ["ERC4626OracleFeed", "YS_PRODUCTION_ERC4626_ORACLE_CODEHASH"],
]);
const PYTH_REVIEWED_CODEHASH_PINS = Object.freeze([
    ["PythOracle", "YS_PRODUCTION_PYTH_ORACLE_CODEHASH"],
]);
const CHAINLINK_REVIEWED_CODEHASH_PINS = Object.freeze([
    ["ChainlinkOracleFeed", "YS_PRODUCTION_CHAINLINK_ORACLE_CODEHASH"],
    ["USMarketSessionGate", "YS_PRODUCTION_US_MARKET_SESSION_GATE_CODEHASH"],
    [
        "RobinhoodStockOracleFeed",
        "YS_PRODUCTION_ROBINHOOD_STOCK_ORACLE_CODEHASH",
    ],
]);

function reviewedCodehashPinSpecs(oracleMode) {
    if (oracleMode !== "pyth" && oracleMode !== "chainlink") {
        throw new Error(`Unsupported oracle mode ${oracleMode}.`);
    }
    return [
        ...COMMON_REVIEWED_CODEHASH_PINS,
        ...(oracleMode === "pyth"
            ? PYTH_REVIEWED_CODEHASH_PINS
            : CHAINLINK_REVIEWED_CODEHASH_PINS),
    ];
}

function requiredReviewedCodehashPinNames(oracleMode) {
    return reviewedCodehashPinSpecs(oracleMode).map(([name]) => name);
}
const DEMO_TOKEN_NAMES = Object.freeze([
    "RobinhoodTestUSDG",
    "RobinhoodTestWETH",
    "RobinhoodTestSGOV",
    "RobinhoodTestSPY",
    "RobinhoodTestQQQ",
    "RobinhoodTestTSLA",
    "RobinhoodTestAMZN",
    "RobinhoodTestPLTR",
    "RobinhoodTestNFLX",
    "RobinhoodTestAMD",
]);
const DEMO_FEEDS = Object.freeze({
    USDG: "RobinhoodUSDGMockChainlinkFeed",
    WETH: "RobinhoodWETHMockChainlinkFeed",
    SGOV: "RobinhoodSGOVMockChainlinkFeed",
    SPY: "RobinhoodSPYMockChainlinkFeed",
    QQQ: "RobinhoodQQQMockChainlinkFeed",
    TSLA: "RobinhoodTSLAMockChainlinkFeed",
    AMZN: "RobinhoodAMZNMockChainlinkFeed",
    PLTR: "RobinhoodPLTRMockChainlinkFeed",
    NFLX: "RobinhoodNFLXMockChainlinkFeed",
    AMD: "RobinhoodAMDMockChainlinkFeed",
});
const DEMO_POOL_NAMES = Object.freeze([
    "RobinhoodSGOVUSDGPool",
    "RobinhoodSPYUSDGPool",
    "RobinhoodQQQUSDGPool",
    "RobinhoodUSDGWETHPool",
    "RobinhoodTSLAUSDGPool",
    "RobinhoodAMZNUSDGPool",
    "RobinhoodPLTRUSDGPool",
    "RobinhoodNFLXUSDGPool",
    "RobinhoodAMDUSDGPool",
]);
const DEMO_EXTRA_INVENTORY = Object.freeze([
    ...DEMO_TOKEN_NAMES,
    ...Object.values(DEMO_FEEDS),
    "RobinhoodDemoAssetFaucet",
    ...DEMO_POOL_NAMES,
]);
const FEED_INTERFACE = new ethers.Interface([
    "function owner() view returns (address)",
    "function description() view returns (string)",
    "function decimals() view returns (uint8)",
    "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)",
]);
const FACTORY_INTERFACE = new ethers.Interface([
    "function splitRiskPoolImplementation() view returns (address)",
    "function governanceTimelock() view returns (address)",
    "function owner() view returns (address)",
    "function bootstrapModeEnabled() view returns (bool)",
    "function compositeOracle() view returns (address)",
    "function defaultProtocolFeeRecipient() view returns (address)",
    "function erc4626OracleFeed() view returns (address)",
    "function pythOracle() view returns (address)",
    "function poolCount() view returns (uint256)",
    "function getWhitelistedTokens() view returns (address[])",
    "function getPools(uint256,uint256) view returns (address[])",
    "function getPoolInfo(address) view returns ((address shieldedToken,address backingToken,string shieldedTokenSymbol,string backingTokenSymbol,uint256 commissionRate,uint256 poolFee,uint256 colleteralRatio,uint256 createdAt,address creator))",
]);
const GOVERNOR_INTERFACE = new ethers.Interface([
    "function token() view returns (address)",
    "function timelock() view returns (address)",
]);
const COMPOSITE_INTERFACE = new ethers.Interface([
    "function owner() view returns (address)",
    "function authorizedCallerCount() view returns (uint256)",
    "function robinhoodStockOracleFeed() view returns (address)",
]);
const ROBINHOOD_STOCK_ORACLE_INTERFACE = new ethers.Interface([
    "function innerFeed() view returns (address)",
    "function marketSessionGate() view returns (address)",
]);
const ERC4626_INTERFACE = new ethers.Interface([
    "function owner() view returns (address)",
    "function underlyingPriceOracle() view returns (address)",
    "function sequencerUptimeFeed() view returns (address)",
    "function sequencerUptimeFeedRequired() view returns (bool)",
]);
const SEQUENCER_GUARD_INTERFACE = new ethers.Interface([
    "function sequencerUptimeFeed() view returns (address)",
    "function sequencerUptimeFeedRequired() view returns (bool)",
]);
const OWNABLE_INTERFACE = new ethers.Interface([
    "function owner() view returns (address)",
]);
const MARKET_SESSION_GATE_INTERFACE = new ethers.Interface([
    "function emergencyGuardian() view returns (address)",
]);
const TIMELOCK_INTERFACE = new ethers.Interface([
    "function DEFAULT_ADMIN_ROLE() view returns (bytes32)",
    "function PROPOSER_ROLE() view returns (bytes32)",
    "function EXECUTOR_ROLE() view returns (bytes32)",
    "function CANCELLER_ROLE() view returns (bytes32)",
    "function getRoleMemberCount(bytes32) view returns (uint256)",
    "function getRoleMember(bytes32,uint256) view returns (address)",
]);
const ERC1967_IMPLEMENTATION_SLOT =
    "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const PREEXISTING_DEMO_INPUTS = new Set([
    "RobinhoodTestTSLA",
    "RobinhoodTestAMZN",
    "RobinhoodTestPLTR",
    "RobinhoodTestNFLX",
    "RobinhoodTestAMD",
]);
const DEMO_POOL_CONFIGS = Object.freeze({
    RobinhoodSGOVUSDGPool: [
        "RobinhoodTestSGOV",
        "RobinhoodTestUSDG",
        "SGOV",
        "USDG",
        12_500,
    ],
    RobinhoodSPYUSDGPool: [
        "RobinhoodTestSPY",
        "RobinhoodTestUSDG",
        "SPY",
        "USDG",
        20_000,
    ],
    RobinhoodQQQUSDGPool: [
        "RobinhoodTestQQQ",
        "RobinhoodTestUSDG",
        "QQQ",
        "USDG",
        22_500,
    ],
    RobinhoodUSDGWETHPool: [
        "RobinhoodTestUSDG",
        "RobinhoodTestWETH",
        "USDG",
        "WETH",
        20_000,
    ],
    RobinhoodTSLAUSDGPool: [
        "RobinhoodTestTSLA",
        "RobinhoodTestUSDG",
        "TSLA",
        "USDG",
        25_000,
    ],
    RobinhoodAMZNUSDGPool: [
        "RobinhoodTestAMZN",
        "RobinhoodTestUSDG",
        "AMZN",
        "USDG",
        25_000,
    ],
    RobinhoodPLTRUSDGPool: [
        "RobinhoodTestPLTR",
        "RobinhoodTestUSDG",
        "PLTR",
        "USDG",
        30_000,
    ],
    RobinhoodNFLXUSDGPool: [
        "RobinhoodTestNFLX",
        "RobinhoodTestUSDG",
        "NFLX",
        "USDG",
        25_000,
    ],
    RobinhoodAMDUSDGPool: [
        "RobinhoodTestAMD",
        "RobinhoodTestUSDG",
        "AMD",
        "USDG",
        30_000,
    ],
});

function addressEntries(manifest) {
    return Object.entries(manifest).filter(
        ([key, value]) => ethers.isAddress(key) && typeof value === "string",
    );
}

function inventoryByName(manifest) {
    const byName = new Map();
    for (const [address, name] of addressEntries(manifest)) {
        if (byName.has(name)) {
            throw new Error(`Duplicate deployment name in candidate: ${name}`);
        }
        byName.set(name, ethers.getAddress(address));
    }
    return byName;
}

function chainFinalityPolicy(chainId, policy = CHAIN_FINALITY_POLICY) {
    if (policy?.schemaVersion !== 2 || !policy.chains) {
        throw new Error("Deployment finality policy is invalid.");
    }
    const chainPolicy = policy.chains[String(chainId)];
    if (
        !chainPolicy ||
        chainPolicy.blockTag !== "finalized" ||
        chainPolicy.requireIndependentValidationRpc !== true
    ) {
        throw new Error(
            `Chain ${chainId} has no checked-in deployment finality policy.`,
        );
    }
    return chainPolicy;
}

function pythSequencerPolicyForChain(
    chainId,
    finalityPolicy = CHAIN_FINALITY_POLICY,
) {
    const chainPolicy = chainFinalityPolicy(chainId, finalityPolicy);
    const policy = chainPolicy.pythSequencerUptimeGuard;
    if (
        !policy ||
        !ethers.isAddress(policy.feed) ||
        typeof policy.required !== "boolean" ||
        typeof policy.source !== "string" ||
        policy.source.trim().length === 0
    ) {
        throw new Error(
            `Chain ${chainId} has no valid checked-in Pyth sequencer uptime policy.`,
        );
    }

    const feed = ethers.getAddress(policy.feed);
    const configured = policy.mode === "configured";
    const disabled = policy.mode === "disabled-no-canonical-feed";
    if (
        (!configured && !disabled) ||
        (configured && (feed === ethers.ZeroAddress || !policy.required)) ||
        (disabled && (feed !== ethers.ZeroAddress || policy.required))
    ) {
        throw new Error(
            `Chain ${chainId} has an inconsistent checked-in Pyth sequencer uptime policy.`,
        );
    }

    return {
        feed,
        mode: policy.mode,
        required: policy.required,
        source: policy.source,
    };
}

function canonicalRpcUrl(value, label) {
    if (typeof value !== "string" || value.trim() === "") {
        throw new Error(`${label} is required for public manifest promotion.`);
    }
    let parsed;
    try {
        parsed = new URL(value.trim());
    } catch {
        throw new Error(`${label} must be an HTTP(S) RPC URL.`);
    }
    if (!["http:", "https:"].includes(parsed.protocol)) {
        throw new Error(`${label} must be an HTTP(S) RPC URL.`);
    }
    parsed.hash = "";
    if (parsed.pathname !== "/") {
        parsed.pathname = parsed.pathname.replace(/\/+$/u, "");
    }
    return parsed.toString();
}

function requireIndependentRpcUrls(primaryRpcUrl, validationRpcUrl) {
    const primary = canonicalRpcUrl(primaryRpcUrl, "Deployment RPC URL");
    const validation = canonicalRpcUrl(
        validationRpcUrl,
        "YS_DEPLOYMENT_VALIDATION_RPC_URL",
    );
    if (
        primary === validation ||
        new URL(primary).hostname === new URL(validation).hostname
    ) {
        throw new Error(
            "YS_DEPLOYMENT_VALIDATION_RPC_URL must use a host distinct from the deployment RPC URL.",
        );
    }
    return { primaryRpcUrl: primary, validationRpcUrl: validation };
}

const RPC_OPERATOR_PATTERN = /^[a-z0-9][a-z0-9._-]{1,63}$/u;

function normalizeRpcOperator(value, label) {
    if (typeof value !== "string" || value.trim() === "") {
        throw new Error(`${label} is required for public manifest promotion.`);
    }

    const normalized = value.trim().toLowerCase();
    if (!RPC_OPERATOR_PATTERN.test(normalized)) {
        throw new Error(
            `${label} must be a 2-64 character lowercase operator slug using only letters, numbers, dots, underscores, or hyphens.`,
        );
    }
    return normalized;
}

function requireIndependentRpcOperators(
    deploymentRpcOperator,
    validationRpcOperator,
) {
    const deployment = normalizeRpcOperator(
        deploymentRpcOperator,
        "YS_DEPLOYMENT_RPC_OPERATOR",
    );
    const validation = normalizeRpcOperator(
        validationRpcOperator,
        "YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR",
    );
    if (deployment === validation) {
        throw new Error(
            "YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR must identify an operator distinct from YS_DEPLOYMENT_RPC_OPERATOR.",
        );
    }
    return { deployment, validation };
}

function parseRpcQuantity(value, label) {
    if (
        typeof value !== "string" ||
        !/^0x(?:0|[1-9a-f][0-9a-f]*)$/iu.test(value)
    ) {
        throw new Error(`${label} returned an invalid block number.`);
    }
    return BigInt(value);
}

async function readExplicitFinalizedBlock(provider, blockTag, label) {
    if (!provider || typeof provider.send !== "function") {
        throw new Error(
            `${label} does not support explicit JSON-RPC finality checks.`,
        );
    }
    const block = await provider.send("eth_getBlockByNumber", [
        blockTag,
        false,
    ]);
    if (!block || !ethers.isHexString(block.hash, 32)) {
        throw new Error(`${label} did not return a finalized block.`);
    }
    return {
        number: parseRpcQuantity(block.number, label),
        hash: block.hash.toLowerCase(),
    };
}

async function resolveFinalityEvidence({
    chainId,
    provider,
    validationProvider,
    primaryRpcUrl,
    validationRpcUrl,
    deploymentRpcOperator,
    validationRpcOperator,
    finalityPolicy = CHAIN_FINALITY_POLICY,
}) {
    const policy = chainFinalityPolicy(chainId, finalityPolicy);
    requireIndependentRpcUrls(primaryRpcUrl, validationRpcUrl);
    const rpcProviderOperators = requireIndependentRpcOperators(
        deploymentRpcOperator,
        validationRpcOperator,
    );
    if (!validationProvider || validationProvider === provider) {
        throw new Error(
            "An independent deployment validation provider is required for public manifest promotion.",
        );
    }
    const [primaryNetwork, validationNetwork] = await Promise.all([
        provider.getNetwork(),
        validationProvider.getNetwork(),
    ]);
    if (
        BigInt(primaryNetwork.chainId).toString() !== String(chainId) ||
        BigInt(validationNetwork.chainId).toString() !== String(chainId)
    ) {
        throw new Error(
            "Deployment RPC providers do not match the candidate chain.",
        );
    }
    const [primaryBlock, validationBlock] = await Promise.all([
        readExplicitFinalizedBlock(provider, policy.blockTag, "Deployment RPC"),
        readExplicitFinalizedBlock(
            validationProvider,
            policy.blockTag,
            "Validation RPC",
        ),
    ]);
    if (
        primaryBlock.number !== validationBlock.number ||
        primaryBlock.hash !== validationBlock.hash
    ) {
        throw new Error(
            "Deployment RPC providers disagree on the finalized block.",
        );
    }
    return {
        blockHash: primaryBlock.hash,
        blockNumber: primaryBlock.number.toString(),
        blockTag: policy.blockTag,
        independentValidationRpc: true,
        policySchemaVersion: finalityPolicy.schemaVersion,
        rpcProviderOperators,
    };
}

function providerAtBlock(provider, blockNumber) {
    return {
        call(transaction) {
            return provider.call({ ...transaction, blockTag: blockNumber });
        },
        getCode(address) {
            return provider.getCode(address, blockNumber);
        },
        getNetwork() {
            return provider.getNetwork();
        },
        getStorage(address, position) {
            return provider.getStorage(address, position, blockNumber);
        },
        getTransactionReceipt(hash) {
            return provider.getTransactionReceipt(hash);
        },
    };
}

function validateExactInventory(candidate) {
    const byName = inventoryByName(candidate);
    const hasPyth = byName.has("PythOracle");
    const hasChainlink = byName.has("ChainlinkOracleFeed");
    if (hasPyth === hasChainlink) {
        throw new Error(
            "Candidate must contain exactly one production oracle mode.",
        );
    }

    const demoEnabled = candidate.robinhoodDemoAssetsEnabled === "true";
    if (demoEnabled && !hasChainlink) {
        throw new Error(
            "Robinhood demo inventory requires the Chainlink production mode.",
        );
    }
    const expected = new Set(
        hasPyth ? PYTH_CORE_INVENTORY : CHAINLINK_CORE_INVENTORY,
    );
    if (demoEnabled) {
        for (const name of DEMO_EXTRA_INVENTORY) expected.add(name);
    }
    const actual = new Set(byName.keys());
    const missing = [...expected].filter((name) => !actual.has(name)).sort();
    const extra = [...actual].filter((name) => !expected.has(name)).sort();
    if (missing.length > 0 || extra.length > 0) {
        throw new Error(
            `Deployment inventory mismatch (missing: ${missing.join(", ") || "none"}; extra: ${extra.join(", ") || "none"}).`,
        );
    }
    return { byName, demoEnabled, oracleMode: hasPyth ? "pyth" : "chainlink" };
}

const ZERO_CODEHASH = `0x${"00".repeat(32)}`;
const ROBINHOOD_TESTNET_SEQUENCER_EXCEPTION_SOURCES = new Set([
    "robinhood-testnet-explicit-exception",
    "robinhood-testnet-relaxed-guards",
]);

function normalizedTestnetSequencerSource(value) {
    return typeof value === "string" && value.trim().length > 0
        ? value
        : "operator-supplied-testnet-feed";
}

function validateCandidateSequencerMetadata({ candidate, chainId, env }) {
    const normalizedChainId = String(chainId);
    const address = candidate.robinhoodSequencerUptimeFeed;
    const source = candidate.robinhoodSequencerUptimeFeedSource;
    const runtimeCodehash = candidate.robinhoodSequencerUptimeFeedCodehash;
    if (!ethers.isAddress(address)) {
        throw new Error(
            "Deployment candidate has an invalid Robinhood sequencer feed address.",
        );
    }
    if (typeof source !== "string" || source.trim().length === 0) {
        throw new Error(
            "Deployment candidate has invalid Robinhood sequencer provenance.",
        );
    }
    if (!/^0x[0-9a-f]{64}$/iu.test(runtimeCodehash ?? "")) {
        throw new Error(
            "Deployment candidate has an invalid Robinhood sequencer runtime codehash.",
        );
    }

    const checksumAddress = ethers.getAddress(address);
    const codehash = runtimeCodehash.toLowerCase();
    if (checksumAddress === ethers.ZeroAddress) {
        if (
            normalizedChainId !== "46630" ||
            codehash !== ZERO_CODEHASH ||
            !ROBINHOOD_TESTNET_SEQUENCER_EXCEPTION_SOURCES.has(source)
        ) {
            throw new Error(
                "Only Robinhood testnet may use the explicit missing-sequencer exception.",
            );
        }
        if (
            source === "robinhood-testnet-explicit-exception" &&
            !["1", "true", "yes"].includes(
                String(
                    env.YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED ?? "",
                ).toLowerCase(),
            )
        ) {
            throw new Error(
                "Robinhood testnet explicit sequencer exception is not enabled in the deployment environment.",
            );
        }
        if (
            source === "robinhood-testnet-relaxed-guards" &&
            candidate.productionGuardMode !== "relaxed"
        ) {
            throw new Error(
                "Robinhood testnet relaxed sequencer exception requires relaxed production guards.",
            );
        }
        return {
            address: checksumAddress,
            mode: "robinhood-testnet-exception",
            reviewedCodehashPin: null,
            runtimeCodehash: ZERO_CODEHASH,
            source,
        };
    }

    if (codehash === ZERO_CODEHASH) {
        throw new Error(
            "Configured Robinhood sequencer feed has a zero runtime codehash.",
        );
    }
    const addressEnvName =
        normalizedChainId === "46630"
            ? "YS_ROBINHOOD_TESTNET_SEQUENCER_FEED"
            : "YS_ROBINHOOD_SEQUENCER_FEED";
    const sourceEnvName =
        normalizedChainId === "46630"
            ? "YS_ROBINHOOD_TESTNET_SEQUENCER_FEED_SOURCE"
            : "YS_ROBINHOOD_SEQUENCER_FEED_SOURCE";
    if (
        !ethers.isAddress(env[addressEnvName] ?? "") ||
        ethers.getAddress(env[addressEnvName]) !== checksumAddress
    ) {
        throw new Error(
            `Deployment candidate sequencer address does not match ${addressEnvName}.`,
        );
    }
    const expectedSource =
        normalizedChainId === "46630"
            ? normalizedTestnetSequencerSource(env[sourceEnvName])
            : env[sourceEnvName];
    if (
        typeof expectedSource !== "string" ||
        expectedSource.trim().length === 0 ||
        source !== expectedSource
    ) {
        throw new Error(
            `Deployment candidate sequencer provenance does not match ${sourceEnvName}.`,
        );
    }

    let reviewedCodehashPin = null;
    if (normalizedChainId === "4663") {
        const expected = env.YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH;
        if (!/^0x[0-9a-f]{64}$/iu.test(expected ?? "")) {
            throw new Error(
                "YS_ROBINHOOD_SEQUENCER_FEED_CODEHASH is required as a bytes32 codehash.",
            );
        }
        if (expected.toLowerCase() !== codehash) {
            throw new Error(
                "Deployment candidate sequencer runtime codehash does not match the reviewed mainnet pin.",
            );
        }
        reviewedCodehashPin = expected.toLowerCase();
    }

    return {
        address: checksumAddress,
        mode: "configured",
        reviewedCodehashPin,
        runtimeCodehash: codehash,
        source,
    };
}

async function validateFinalizedSequencerCode({
    metadata,
    provider,
    validationProvider,
}) {
    if (metadata.mode !== "configured") return metadata;
    const [code, validationCode] = await Promise.all([
        provider.getCode(metadata.address),
        validationProvider.getCode(metadata.address),
    ]);
    if (typeof code !== "string" || code === "0x") {
        throw new Error(
            `No sequencer uptime feed code at ${metadata.address} in finalized state.`,
        );
    }
    if (code.toLowerCase() !== validationCode?.toLowerCase()) {
        throw new Error(
            "Deployment RPC providers disagree on finalized sequencer uptime feed code.",
        );
    }
    const actualCodehash = ethers.keccak256(code).toLowerCase();
    if (actualCodehash !== metadata.runtimeCodehash) {
        throw new Error(
            "Finalized sequencer uptime feed codehash does not match deployment metadata.",
        );
    }
    if (
        metadata.reviewedCodehashPin !== null &&
        actualCodehash !== metadata.reviewedCodehashPin
    ) {
        throw new Error(
            "Finalized sequencer uptime feed codehash does not match the reviewed mainnet pin.",
        );
    }
    return metadata;
}

async function buildPythSequencerUptimeGuardEvidence({
    policy,
    state,
    provider,
    validationProvider,
}) {
    let runtimeCodehash = ZERO_CODEHASH;
    if (policy.feed !== ethers.ZeroAddress) {
        const [code, validationCode] = await Promise.all([
            provider.getCode(policy.feed),
            validationProvider.getCode(policy.feed),
        ]);
        if (typeof code !== "string" || code === "0x") {
            throw new Error(
                `No Pyth sequencer uptime feed code at ${policy.feed} in finalized state.`,
            );
        }
        if (code.toLowerCase() !== validationCode?.toLowerCase()) {
            throw new Error(
                "Deployment RPC providers disagree on finalized Pyth sequencer uptime feed code.",
            );
        }
        runtimeCodehash = ethers.keccak256(code).toLowerCase();
    }

    return {
        erc4626Required: state.sequencer.erc4626Required,
        feed: policy.feed,
        mode: policy.mode,
        primaryOracle: "PythOracle",
        primaryOracleRequired: state.sequencer.primaryOracleRequired,
        runtimeCodehash,
        source: policy.source,
    };
}

async function contractCall(
    provider,
    contractInterface,
    address,
    functionName,
    args = [],
) {
    const data = contractInterface.encodeFunctionData(functionName, args);
    const result = await provider.call({ data, to: address });
    return contractInterface.decodeFunctionResult(functionName, result);
}

async function readLiveProtocolState(
    provider,
    { byName, demoEnabled, oracleMode },
) {
    const factory = byName.get("SplitRiskPoolFactory");
    const governor = byName.get("YSGovernor");
    const timelock = byName.get("TimelockController");
    const composite = byName.get("CompositeOracle");
    const erc4626 = byName.get("ERC4626OracleFeed");
    const implementationWord = await provider.getStorage(
        factory,
        ERC1967_IMPLEMENTATION_SLOT,
    );
    const implementation = ethers.getAddress(
        `0x${implementationWord.slice(-40)}`,
    );
    const [poolImplementation] = await contractCall(
        provider,
        FACTORY_INTERFACE,
        factory,
        "splitRiskPoolImplementation",
    );
    const [governanceTimelock] = await contractCall(
        provider,
        FACTORY_INTERFACE,
        factory,
        "governanceTimelock",
    );
    const [factoryOwner] = await contractCall(
        provider,
        FACTORY_INTERFACE,
        factory,
        "owner",
    );
    const [bootstrapModeEnabled] = await contractCall(
        provider,
        FACTORY_INTERFACE,
        factory,
        "bootstrapModeEnabled",
    );
    const [configuredComposite] = await contractCall(
        provider,
        FACTORY_INTERFACE,
        factory,
        "compositeOracle",
    );
    const [protocolFeeRecipient] = await contractCall(
        provider,
        FACTORY_INTERFACE,
        factory,
        "defaultProtocolFeeRecipient",
    );
    const [configuredERC4626] = await contractCall(
        provider,
        FACTORY_INTERFACE,
        factory,
        "erc4626OracleFeed",
    );
    const [configuredPyth] = await contractCall(
        provider,
        FACTORY_INTERFACE,
        factory,
        "pythOracle",
    );
    const [poolCount] = await contractCall(
        provider,
        FACTORY_INTERFACE,
        factory,
        "poolCount",
    );
    const [whitelistedTokens] = await contractCall(
        provider,
        FACTORY_INTERFACE,
        factory,
        "getWhitelistedTokens",
    );
    const [pools] = await contractCall(
        provider,
        FACTORY_INTERFACE,
        factory,
        "getPools",
        [0, poolCount],
    );
    const poolInfo = {};
    if (demoEnabled) {
        for (const [name] of Object.entries(DEMO_POOL_CONFIGS)) {
            const [info] = await contractCall(
                provider,
                FACTORY_INTERFACE,
                factory,
                "getPoolInfo",
                [byName.get(name)],
            );
            poolInfo[name] = {
                shieldedToken: info.shieldedToken,
                backingToken: info.backingToken,
                shieldedTokenSymbol: info.shieldedTokenSymbol,
                backingTokenSymbol: info.backingTokenSymbol,
                commissionRate: Number(info.commissionRate),
                poolFee: Number(info.poolFee),
                collateralRatio: Number(info.colleteralRatio),
            };
        }
    }
    const [governorToken] = await contractCall(
        provider,
        GOVERNOR_INTERFACE,
        governor,
        "token",
    );
    const [governorTimelock] = await contractCall(
        provider,
        GOVERNOR_INTERFACE,
        governor,
        "timelock",
    );
    const [compositeOwner] = await contractCall(
        provider,
        COMPOSITE_INTERFACE,
        composite,
        "owner",
    );
    const [authorizedCallerCount] = await contractCall(
        provider,
        COMPOSITE_INTERFACE,
        composite,
        "authorizedCallerCount",
    );
    const [robinhoodStockOracleFeed] = await contractCall(
        provider,
        COMPOSITE_INTERFACE,
        composite,
        "robinhoodStockOracleFeed",
    );
    const [erc4626Owner] = await contractCall(
        provider,
        ERC4626_INTERFACE,
        erc4626,
        "owner",
    );
    const [underlyingPriceOracle] = await contractCall(
        provider,
        ERC4626_INTERFACE,
        erc4626,
        "underlyingPriceOracle",
    );
    const primaryOracleName =
        oracleMode === "pyth" ? "PythOracle" : "ChainlinkOracleFeed";
    const primaryOracle = byName.get(primaryOracleName);
    const [primaryOracleFeed] = await contractCall(
        provider,
        SEQUENCER_GUARD_INTERFACE,
        primaryOracle,
        "sequencerUptimeFeed",
    );
    const [primaryOracleRequired] = await contractCall(
        provider,
        SEQUENCER_GUARD_INTERFACE,
        primaryOracle,
        "sequencerUptimeFeedRequired",
    );
    const [erc4626Feed] = await contractCall(
        provider,
        ERC4626_INTERFACE,
        erc4626,
        "sequencerUptimeFeed",
    );
    const [erc4626Required] = await contractCall(
        provider,
        ERC4626_INTERFACE,
        erc4626,
        "sequencerUptimeFeedRequired",
    );
    const sequencer = {
        primaryOracleName,
        primaryOracleFeed,
        primaryOracleRequired,
        erc4626Feed,
        erc4626Required,
    };
    const oracleOwners = {};
    for (const name of oracleMode === "pyth"
        ? ["PythOracle"]
        : ["ChainlinkOracleFeed", "USMarketSessionGate"]) {
        [oracleOwners[name]] = await contractCall(
            provider,
            OWNABLE_INTERFACE,
            byName.get(name),
            "owner",
        );
    }
    let marketSessionGuardian = null;
    let robinhoodStockOracle = null;
    if (oracleMode === "chainlink") {
        [marketSessionGuardian] = await contractCall(
            provider,
            MARKET_SESSION_GATE_INTERFACE,
            byName.get("USMarketSessionGate"),
            "emergencyGuardian",
        );
        const stockOracleAddress = byName.get("RobinhoodStockOracleFeed");
        const [innerFeed] = await contractCall(
            provider,
            ROBINHOOD_STOCK_ORACLE_INTERFACE,
            stockOracleAddress,
            "innerFeed",
        );
        const [marketSessionGate] = await contractCall(
            provider,
            ROBINHOOD_STOCK_ORACLE_INTERFACE,
            stockOracleAddress,
            "marketSessionGate",
        );
        robinhoodStockOracle = { innerFeed, marketSessionGate };
    }
    const timelockRoles = {};
    for (const [key, functionName] of [
        ["defaultAdmin", "DEFAULT_ADMIN_ROLE"],
        ["proposer", "PROPOSER_ROLE"],
        ["executor", "EXECUTOR_ROLE"],
        ["canceller", "CANCELLER_ROLE"],
    ]) {
        const [role] = await contractCall(
            provider,
            TIMELOCK_INTERFACE,
            timelock,
            functionName,
        );
        const [countValue] = await contractCall(
            provider,
            TIMELOCK_INTERFACE,
            timelock,
            "getRoleMemberCount",
            [role],
        );
        const count = Number(countValue);
        let member = null;
        if (count > 0) {
            [member] = await contractCall(
                provider,
                TIMELOCK_INTERFACE,
                timelock,
                "getRoleMember",
                [role, 0],
            );
        }
        timelockRoles[key] = { count, member };
    }
    return {
        factory: {
            implementation,
            poolImplementation,
            governanceTimelock,
            owner: factoryOwner,
            bootstrapModeEnabled,
            compositeOracle: configuredComposite,
            protocolFeeRecipient,
            erc4626OracleFeed: configuredERC4626,
            pythOracle: configuredPyth,
            poolCount: Number(poolCount),
            whitelistedTokens,
            pools,
            poolInfo,
        },
        governor: { token: governorToken, timelock: governorTimelock },
        composite: {
            owner: compositeOwner,
            authorizedCallerCount: Number(authorizedCallerCount),
            robinhoodStockOracleFeed,
        },
        erc4626: { owner: erc4626Owner, underlyingPriceOracle },
        sequencer,
        marketSessionGuardian,
        robinhoodStockOracle,
        oracleOwners,
        timelockRoles,
    };
}

function sameAddress(actual, expected) {
    return ethers.getAddress(actual) === ethers.getAddress(expected);
}

function requireAddress(actual, expected, label) {
    if (!sameAddress(actual, expected)) {
        throw new Error(`${label} wiring mismatch.`);
    }
}

function sortedAddresses(values) {
    return values.map((value) => ethers.getAddress(value)).sort();
}

function validateProtocolWiring(
    state,
    {
        byName,
        candidate,
        demoEnabled,
        oracleMode,
        pythSequencerPolicy,
        sequencerMetadata,
    },
) {
    const timelock = byName.get("TimelockController");
    const factory = byName.get("SplitRiskPoolFactory");
    requireAddress(
        state.factory.implementation,
        byName.get("SplitRiskPoolFactoryImplementation"),
        "Factory proxy implementation",
    );
    requireAddress(
        state.factory.poolImplementation,
        byName.get("SplitRiskPoolImplementation"),
        "Factory pool implementation",
    );
    requireAddress(
        state.factory.governanceTimelock,
        timelock,
        "Factory governance timelock",
    );
    requireAddress(state.factory.owner, timelock, "Factory owner");
    if (state.factory.bootstrapModeEnabled !== false)
        throw new Error("Factory bootstrap mode is still enabled.");
    requireAddress(
        state.factory.compositeOracle,
        byName.get("CompositeOracle"),
        "Factory composite oracle",
    );
    requireAddress(
        state.factory.protocolFeeRecipient,
        timelock,
        "Protocol fee recipient",
    );
    requireAddress(
        state.factory.erc4626OracleFeed,
        byName.get("ERC4626OracleFeed"),
        "Factory ERC4626 oracle",
    );
    requireAddress(
        state.governor.token,
        byName.get("YSToken"),
        "Governor token",
    );
    requireAddress(state.governor.timelock, timelock, "Governor timelock");
    for (const [roleName, expectedMember] of [
        ["defaultAdmin", timelock],
        ["proposer", byName.get("YSGovernor")],
        ["executor", byName.get("YSGovernor")],
        ["canceller", byName.get("YSGovernor")],
    ]) {
        const role = state.timelockRoles?.[roleName];
        if (
            role?.count !== 1 ||
            !role.member ||
            !sameAddress(role.member, expectedMember)
        ) {
            throw new Error(`Timelock ${roleName} role topology mismatch.`);
        }
    }
    requireAddress(state.composite.owner, factory, "Composite oracle owner");
    if (state.composite.authorizedCallerCount !== 0)
        throw new Error("Composite oracle retains authorized callers.");
    requireAddress(
        state.composite.robinhoodStockOracleFeed,
        oracleMode === "chainlink"
            ? byName.get("RobinhoodStockOracleFeed")
            : ethers.ZeroAddress,
        "Composite Robinhood stock oracle pin",
    );
    requireAddress(state.erc4626.owner, factory, "ERC4626 oracle owner");
    if (oracleMode === "pyth") {
        requireAddress(
            state.factory.pythOracle,
            byName.get("PythOracle"),
            "Factory Pyth oracle",
        );
        requireAddress(
            state.erc4626.underlyingPriceOracle,
            byName.get("PythOracle"),
            "ERC4626 underlying oracle",
        );
        requireAddress(
            state.oracleOwners.PythOracle,
            factory,
            "Pyth oracle owner",
        );
        if (!pythSequencerPolicy || !state.sequencer) {
            throw new Error(
                "Pyth sequencer uptime wiring evidence is missing.",
            );
        }
        if (state.sequencer.primaryOracleName !== "PythOracle") {
            throw new Error("Pyth primary oracle sequencer identity mismatch.");
        }
        requireAddress(
            state.sequencer.primaryOracleFeed,
            pythSequencerPolicy.feed,
            "Pyth sequencer uptime feed",
        );
        requireAddress(
            state.sequencer.erc4626Feed,
            pythSequencerPolicy.feed,
            "ERC4626 sequencer uptime feed",
        );
        if (
            state.sequencer.primaryOracleRequired !==
                pythSequencerPolicy.required ||
            state.sequencer.erc4626Required !== pythSequencerPolicy.required
        ) {
            throw new Error(
                "Pyth sequencer uptime requirement wiring mismatch.",
            );
        }
    } else {
        if (!state.robinhoodStockOracle) {
            throw new Error(
                "Robinhood stock oracle wiring evidence is missing.",
            );
        }
        requireAddress(
            state.robinhoodStockOracle.innerFeed,
            byName.get("ChainlinkOracleFeed"),
            "Robinhood stock oracle inner feed",
        );
        requireAddress(
            state.robinhoodStockOracle.marketSessionGate,
            byName.get("USMarketSessionGate"),
            "Robinhood stock oracle market-session gate",
        );
        requireAddress(
            state.factory.pythOracle,
            ethers.ZeroAddress,
            "Factory Pyth oracle",
        );
        requireAddress(
            state.erc4626.underlyingPriceOracle,
            byName.get("ChainlinkOracleFeed"),
            "ERC4626 underlying oracle",
        );
        requireAddress(
            state.oracleOwners.ChainlinkOracleFeed,
            timelock,
            "Chainlink oracle owner",
        );
        requireAddress(
            state.oracleOwners.USMarketSessionGate,
            timelock,
            "US market gate owner",
        );
        requireAddress(
            state.marketSessionGuardian,
            candidate.marketSessionGuardian,
            "US market gate emergency guardian",
        );
        if (!sequencerMetadata || !state.sequencer) {
            throw new Error("Robinhood sequencer wiring evidence is missing.");
        }
        if (state.sequencer.primaryOracleName !== "ChainlinkOracleFeed") {
            throw new Error(
                "Chainlink primary oracle sequencer identity mismatch.",
            );
        }
        requireAddress(
            state.sequencer.primaryOracleFeed,
            sequencerMetadata.address,
            "Chainlink sequencer uptime feed",
        );
        requireAddress(
            state.sequencer.erc4626Feed,
            sequencerMetadata.address,
            "ERC4626 sequencer uptime feed",
        );
        const expectedRequired = sequencerMetadata.mode === "configured";
        if (
            state.sequencer.primaryOracleRequired !== expectedRequired ||
            state.sequencer.erc4626Required !== expectedRequired
        ) {
            throw new Error(
                "Robinhood sequencer uptime requirement wiring mismatch.",
            );
        }
    }

    const expectedTokens = demoEnabled
        ? DEMO_TOKEN_NAMES.map((name) => byName.get(name))
        : [];
    const expectedPools = demoEnabled
        ? DEMO_POOL_NAMES.map((name) => byName.get(name))
        : [];
    if (state.factory.poolCount !== expectedPools.length)
        throw new Error("Factory demo pool count mismatch.");
    if (
        JSON.stringify(sortedAddresses(state.factory.whitelistedTokens)) !==
        JSON.stringify(sortedAddresses(expectedTokens))
    ) {
        throw new Error("Factory demo token identity mismatch.");
    }
    if (
        JSON.stringify(sortedAddresses(state.factory.pools)) !==
        JSON.stringify(sortedAddresses(expectedPools))
    ) {
        throw new Error("Factory demo pool identity mismatch.");
    }
    if (demoEnabled) {
        for (const [poolName, config] of Object.entries(DEMO_POOL_CONFIGS)) {
            const [
                shieldedName,
                backingName,
                shieldedSymbol,
                backingSymbol,
                collateralRatio,
            ] = config;
            const info = state.factory.poolInfo[poolName];
            requireAddress(
                info.shieldedToken,
                byName.get(shieldedName),
                `${poolName} shielded token`,
            );
            requireAddress(
                info.backingToken,
                byName.get(backingName),
                `${poolName} backing token`,
            );
            if (
                info.shieldedTokenSymbol !== shieldedSymbol ||
                info.backingTokenSymbol !== backingSymbol ||
                info.commissionRate !== 500 ||
                info.poolFee !== 200 ||
                info.collateralRatio !== collateralRatio
            ) {
                throw new Error(`${poolName} configuration mismatch.`);
            }
        }
    }
}

function receiptSucceeded(status) {
    if (status === 1 || status === "1") return true;
    return typeof status === "string" && /^0x0*1$/iu.test(status);
}

function broadcastChainId(broadcast) {
    const value = broadcast.chain ?? broadcast.chainId;
    if (value === undefined || value === null) return null;
    try {
        return BigInt(value).toString();
    } catch {
        return null;
    }
}

function receiptProjection(receipt, expectedHash) {
    if (!receipt) {
        throw new Error(
            `On-chain receipt ${expectedHash} is missing or failed.`,
        );
    }
    const transactionHash = String(
        receipt?.hash ?? receipt?.transactionHash ?? "",
    ).toLowerCase();
    if (transactionHash !== expectedHash) {
        throw new Error(
            `On-chain receipt ${expectedHash} returned an unexpected transaction hash.`,
        );
    }
    if (!receiptSucceeded(receipt?.status)) {
        throw new Error(
            `On-chain receipt ${expectedHash} is missing or failed.`,
        );
    }
    if (!receipt.from || !ethers.isAddress(receipt.from)) {
        throw new Error(
            `On-chain receipt ${expectedHash} has no valid deployer.`,
        );
    }
    if (!ethers.isHexString(receipt.blockHash, 32)) {
        throw new Error(
            `On-chain receipt ${expectedHash} has no valid block hash.`,
        );
    }
    let blockNumber;
    try {
        blockNumber = BigInt(receipt.blockNumber);
    } catch {
        throw new Error(
            `On-chain receipt ${expectedHash} has no valid block number.`,
        );
    }
    if (blockNumber < 0n) {
        throw new Error(
            `On-chain receipt ${expectedHash} has no valid block number.`,
        );
    }
    const contractAddress = receipt.contractAddress
        ? ethers.getAddress(receipt.contractAddress)
        : null;
    return {
        blockHash: receipt.blockHash.toLowerCase(),
        blockNumber: blockNumber.toString(),
        contractAddress,
        from: ethers.getAddress(receipt.from),
        status: 1,
        transactionHash,
    };
}

async function validateBroadcast({
    broadcast,
    candidate,
    chainId,
    provider,
    validationProvider,
    finalizedBlockHash,
    finalizedBlockNumber,
}) {
    if (broadcastChainId(broadcast) !== String(chainId)) {
        throw new Error("Broadcast chain does not match the candidate chain.");
    }
    if (
        !Array.isArray(broadcast.transactions) ||
        broadcast.transactions.length === 0
    ) {
        throw new Error("Broadcast contains no transactions.");
    }
    if (!Array.isArray(broadcast.receipts)) {
        throw new Error("Broadcast receipts are missing.");
    }
    if (Array.isArray(broadcast.pending) && broadcast.pending.length > 0) {
        throw new Error("Broadcast still contains pending transactions.");
    }

    const receiptByHash = new Map(
        broadcast.receipts.map((receipt) => [
            String(receipt.transactionHash || "").toLowerCase(),
            receipt,
        ]),
    );
    if (receiptByHash.size !== broadcast.transactions.length) {
        throw new Error(
            "Broadcast receipt count does not match its transaction count.",
        );
    }
    const expectedDeployer = ethers.getAddress(candidate.deployer);
    const transactionHashes = [];
    const seenTransactionHashes = new Set();
    const createdAddresses = new Set();
    for (const transaction of broadcast.transactions) {
        const hash = String(transaction.hash || "").toLowerCase();
        const from = transaction.transaction?.from;
        if (!/^0x[0-9a-f]{64}$/u.test(hash)) {
            throw new Error("Broadcast transaction is missing a valid hash.");
        }
        if (seenTransactionHashes.has(hash)) {
            throw new Error(
                `Broadcast transaction hash is duplicated: ${hash}.`,
            );
        }
        seenTransactionHashes.add(hash);
        if (!from || ethers.getAddress(from) !== expectedDeployer) {
            throw new Error(
                "Broadcast transaction deployer does not match the candidate.",
            );
        }
        const receipt = receiptByHash.get(hash);
        if (!receipt || !receiptSucceeded(receipt.status)) {
            throw new Error(
                `Broadcast transaction ${hash} is incomplete or failed.`,
            );
        }
        const [liveReceipt, validationReceipt] = await Promise.all([
            provider.getTransactionReceipt(hash),
            validationProvider.getTransactionReceipt(hash),
        ]);
        const liveProjection = receiptProjection(liveReceipt, hash);
        const validationProjection = receiptProjection(validationReceipt, hash);
        if (
            JSON.stringify(liveProjection) !==
            JSON.stringify(validationProjection)
        ) {
            throw new Error(
                `Deployment RPC providers disagree on transaction receipt ${hash}.`,
            );
        }
        if (BigInt(liveProjection.blockNumber) > finalizedBlockNumber) {
            throw new Error(
                `On-chain receipt ${hash} is not included in the agreed finalized state.`,
            );
        }
        if (
            BigInt(liveProjection.blockNumber) === finalizedBlockNumber &&
            liveProjection.blockHash !== finalizedBlockHash
        ) {
            throw new Error(
                `On-chain receipt ${hash} is not included in the agreed finalized block.`,
            );
        }
        if (liveProjection.from !== expectedDeployer) {
            throw new Error(
                `On-chain receipt ${hash} deployer does not match the candidate.`,
            );
        }
        const transactionType = String(
            transaction.transactionType || "",
        ).toUpperCase();
        if (transactionType === "CREATE" || transactionType === "CREATE2") {
            if (
                !transaction.contractAddress ||
                !ethers.isAddress(transaction.contractAddress)
            ) {
                throw new Error(
                    `Broadcast creation transaction ${hash} is missing a valid contract address.`,
                );
            }
            if (
                !liveProjection.contractAddress ||
                !ethers.isAddress(liveProjection.contractAddress)
            ) {
                throw new Error(
                    `On-chain creation receipt ${hash} is missing a valid contract address.`,
                );
            }
            const recordedAddress = ethers.getAddress(
                transaction.contractAddress,
            );
            const liveAddress = liveProjection.contractAddress;
            if (recordedAddress !== liveAddress) {
                throw new Error(
                    `Broadcast creation address does not match the on-chain receipt for ${hash}.`,
                );
            }
            createdAddresses.add(liveAddress);
        }
        transactionHashes.push(hash);
    }
    return { createdAddresses, transactionHashes };
}

async function readStandardMockFeed(provider, address) {
    async function call(name) {
        const data = FEED_INTERFACE.encodeFunctionData(name);
        const result = await provider.call({ data, to: address });
        return FEED_INTERFACE.decodeFunctionResult(name, result);
    }
    const [owner] = await call("owner");
    const [description] = await call("description");
    const [decimals] = await call("decimals");
    const [, , , updatedAt] = await call("latestRoundData");
    return {
        decimals: Number(decimals),
        description,
        owner: ethers.getAddress(owner),
        updatedAt: Number(updatedAt),
    };
}

async function buildFixtureMetadata({
    byName,
    codehashes,
    expectedDeployer,
    provider,
    readFeed = readStandardMockFeed,
}) {
    const feeds = {};
    let expectedOwner = null;
    let expectedRuntimeCodehash = null;
    let earliestExpiry = Number.MAX_SAFE_INTEGER;
    for (const [symbol, deploymentName] of Object.entries(DEMO_FEEDS)) {
        const address = byName.get(deploymentName);
        const metadata = await readFeed(provider, address);
        if (metadata.decimals !== 8) {
            throw new Error(`${deploymentName} must use 8 decimals.`);
        }
        const expectedDescription = `${symbol} / USD`;
        if (metadata.description !== expectedDescription) {
            throw new Error(`${deploymentName} description mismatch.`);
        }
        if (
            !Number.isSafeInteger(metadata.updatedAt) ||
            metadata.updatedAt <= 0
        ) {
            throw new Error(
                `${deploymentName} has an invalid update timestamp.`,
            );
        }
        expectedOwner ??= metadata.owner;
        if (metadata.owner !== expectedOwner) {
            throw new Error(
                "Standard demo feeds do not share one expected owner.",
            );
        }
        if (metadata.owner !== ethers.getAddress(expectedDeployer)) {
            throw new Error(
                "Standard demo feed owner does not match the deployment generation.",
            );
        }
        const runtimeCodehash = codehashes[address];
        expectedRuntimeCodehash ??= runtimeCodehash;
        if (runtimeCodehash !== expectedRuntimeCodehash) {
            throw new Error(
                "Standard demo feeds do not share one runtime codehash.",
            );
        }
        earliestExpiry = Math.min(earliestExpiry, metadata.updatedAt + 86_400);
        feeds[symbol] = {
            address,
            deploymentName,
            description: metadata.description,
            decimals: 8,
        };
    }
    return {
        robinhoodStandardMockFeeds: {
            schemaVersion: 1,
            fixtureId: "robinhood-standard-mock-feeds-v1",
            chainId: 46_630,
            synthetic: true,
            maxPriceAgeSeconds: 86_400,
            nearExpirySeconds: 3_600,
            expiresAt: earliestExpiry,
            expectedRuntimeCodehash,
            expectedOwner,
            feeds,
        },
    };
}

async function validateAndBuildManifest({
    candidate,
    broadcast,
    chainId,
    deploymentId,
    configurationDigest,
    provider,
    validationProvider,
    primaryRpcUrl,
    validationRpcUrl,
    finalityPolicy = CHAIN_FINALITY_POLICY,
    env = process.env,
    now = () => new Date(),
    readFeed,
    readProtocolState = readLiveProtocolState,
}) {
    if (
        candidate.status !== "candidate" ||
        String(candidate.schemaVersion) !== "2"
    ) {
        throw new Error("Deployment candidate schema or status is invalid.");
    }
    if (candidate.deploymentId !== deploymentId) {
        throw new Error("Deployment candidate generation ID mismatch.");
    }
    if (String(candidate.chainId) !== String(chainId)) {
        throw new Error("Deployment candidate chain ID mismatch.");
    }
    if (candidate.configurationDigest !== configurationDigest) {
        throw new Error("Deployment configuration digest mismatch.");
    }
    if (!ethers.isAddress(candidate.deployer)) {
        throw new Error("Deployment candidate has an invalid deployer.");
    }
    if (!["true", "false"].includes(candidate.robinhoodDemoAssetsEnabled)) {
        throw new Error(
            "Deployment candidate has invalid robinhoodDemoAssetsEnabled metadata.",
        );
    }
    if (!["strict", "relaxed"].includes(candidate.productionGuardMode)) {
        throw new Error(
            "Deployment candidate has invalid productionGuardMode metadata.",
        );
    }
    if (!["true", "false"].includes(candidate.recovery)) {
        throw new Error("Deployment candidate has invalid recovery metadata.");
    }
    if (
        String(chainId) !== "46630" &&
        (candidate.robinhoodDemoAssetsEnabled === "true" ||
            candidate.productionGuardMode === "relaxed")
    ) {
        throw new Error(
            "Relaxed production guards and Robinhood demo assets are valid only on chain 46630.",
        );
    }
    const { byName, demoEnabled, oracleMode } =
        validateExactInventory(candidate);
    if (
        oracleMode === "chainlink" &&
        !["4663", "46630"].includes(String(chainId))
    ) {
        throw new Error(
            "Chainlink production mode is valid only on Robinhood chain IDs 4663 and 46630.",
        );
    }
    if (oracleMode === "chainlink") {
        if (
            !ethers.isAddress(candidate.marketSessionGuardian) ||
            ethers.getAddress(candidate.marketSessionGuardian) ===
                ethers.ZeroAddress ||
            ethers.getAddress(candidate.marketSessionGuardian) ===
                ethers.getAddress(byName.get("TimelockController"))
        ) {
            throw new Error(
                "Deployment candidate has an invalid marketSessionGuardian.",
            );
        }
    }
    const sequencerMetadata =
        oracleMode === "chainlink"
            ? validateCandidateSequencerMetadata({ candidate, chainId, env })
            : null;
    const pythSequencerPolicy =
        oracleMode === "pyth"
            ? pythSequencerPolicyForChain(chainId, finalityPolicy)
            : null;
    const finalityEvidence = await resolveFinalityEvidence({
        chainId,
        provider,
        validationProvider,
        primaryRpcUrl,
        validationRpcUrl,
        deploymentRpcOperator: env.YS_DEPLOYMENT_RPC_OPERATOR,
        validationRpcOperator: env.YS_DEPLOYMENT_VALIDATION_RPC_OPERATOR,
        finalityPolicy,
    });
    const finalizedBlockNumber = BigInt(finalityEvidence.blockNumber);
    const finalizedProvider = providerAtBlock(provider, finalizedBlockNumber);
    const finalizedValidationProvider = providerAtBlock(
        validationProvider,
        finalizedBlockNumber,
    );
    const { createdAddresses, transactionHashes } = await validateBroadcast({
        broadcast,
        candidate,
        chainId,
        provider: finalizedProvider,
        validationProvider: finalizedValidationProvider,
        finalizedBlockHash: finalityEvidence.blockHash,
        finalizedBlockNumber,
    });
    const codehashes = {};
    for (const address of byName.values()) {
        const [code, validationCode] = await Promise.all([
            finalizedProvider.getCode(address),
            finalizedValidationProvider.getCode(address),
        ]);
        if (typeof code !== "string" || code === "0x") {
            throw new Error(
                `No deployed code at ${address} in finalized state.`,
            );
        }
        if (code.toLowerCase() !== validationCode?.toLowerCase()) {
            throw new Error(
                `Deployment RPC providers disagree on finalized code at ${address}.`,
            );
        }
        codehashes[address] = ethers.keccak256(code);
    }
    const sequencerUptimeFeedEvidence = sequencerMetadata
        ? await validateFinalizedSequencerCode({
              metadata: sequencerMetadata,
              provider: finalizedProvider,
              validationProvider: finalizedValidationProvider,
          })
        : null;
    const addressEvidence = {};
    for (const [name, address] of byName.entries()) {
        if (createdAddresses.has(address)) {
            addressEvidence[address] = "broadcast-create";
        } else if (demoEnabled && DEMO_POOL_NAMES.includes(name)) {
            addressEvidence[address] = "factory-created-output";
        } else if (demoEnabled && PREEXISTING_DEMO_INPUTS.has(name)) {
            addressEvidence[address] = "pre-existing-demo-input";
        } else {
            throw new Error(
                `${name} is not tied to the successful deployment generation.`,
            );
        }
    }

    const reviewedCodehashPins = {};
    for (const [name, envName] of reviewedCodehashPinSpecs(oracleMode)) {
        const expected = env[envName];
        if (!/^0x[0-9a-f]{64}$/iu.test(expected ?? "")) {
            throw new Error(`${envName} is required as a bytes32 codehash.`);
        }
        const address = byName.get(name);
        if (!address || !codehashes[address]) {
            throw new Error(`${name} is missing runtime-codehash evidence.`);
        }
        if (codehashes[address].toLowerCase() !== expected.toLowerCase()) {
            throw new Error(
                `${name} runtime codehash does not match the reviewed configuration.`,
            );
        }
        reviewedCodehashPins[name] = expected.toLowerCase();
    }

    const [protocolState, validationProtocolState] = await Promise.all([
        readProtocolState(finalizedProvider, {
            byName,
            demoEnabled,
            oracleMode,
        }),
        readProtocolState(finalizedValidationProvider, {
            byName,
            demoEnabled,
            oracleMode,
        }),
    ]);
    if (
        JSON.stringify(canonicalize(protocolState)) !==
        JSON.stringify(canonicalize(validationProtocolState))
    ) {
        throw new Error(
            "Deployment RPC providers disagree on finalized protocol wiring.",
        );
    }
    validateProtocolWiring(protocolState, {
        byName,
        candidate,
        demoEnabled,
        oracleMode,
        pythSequencerPolicy,
        sequencerMetadata,
    });
    const pythSequencerUptimeGuardEvidence = pythSequencerPolicy
        ? await buildPythSequencerUptimeGuardEvidence({
              policy: pythSequencerPolicy,
              state: protocolState,
              provider: finalizedProvider,
              validationProvider: finalizedValidationProvider,
          })
        : null;

    const manifest = {
        ...candidate,
        status: "active",
        validatedAt: now().toISOString(),
        transactionHashes,
        codehashEvidence: codehashes,
        addressEvidence,
        finalityEvidence,
        reviewedCodehashPins,
    };
    if (sequencerUptimeFeedEvidence) {
        manifest.sequencerUptimeFeedEvidence = sequencerUptimeFeedEvidence;
    }
    if (pythSequencerUptimeGuardEvidence) {
        manifest.pythSequencerUptimeGuardEvidence =
            pythSequencerUptimeGuardEvidence;
    }
    if (demoEnabled) {
        if (String(chainId) !== "46630") {
            throw new Error(
                "The standard Robinhood demo fixture is valid only on chain 46630.",
            );
        }
        manifest.fixtureMetadata = await buildFixtureMetadata({
            byName,
            codehashes,
            expectedDeployer: candidate.deployer,
            provider: finalizedProvider,
            readFeed,
        });
    }
    return manifest;
}

function canonicalize(value) {
    if (Array.isArray(value)) return value.map(canonicalize);
    if (value === null || typeof value !== "object") return value;
    return Object.fromEntries(
        Object.entries(value)
            .sort(([left], [right]) => left.localeCompare(right))
            .map(([key, entry]) => [key, canonicalize(entry)]),
    );
}

function immutableGenerationProjection(manifest) {
    const {
        finalityEvidence: _finalityEvidence,
        validatedAt: _validatedAt,
        ...immutable
    } = manifest;
    const standardMockFeeds =
        immutable.fixtureMetadata?.robinhoodStandardMockFeeds;
    if (standardMockFeeds) {
        const { expiresAt: _expiresAt, ...immutableStandardMockFeeds } =
            standardMockFeeds;
        immutable.fixtureMetadata = {
            ...immutable.fixtureMetadata,
            robinhoodStandardMockFeeds: immutableStandardMockFeeds,
        };
    }
    return canonicalize(immutable);
}

function sameGeneration(left, right) {
    return (
        JSON.stringify(immutableGenerationProjection(left)) ===
        JSON.stringify(immutableGenerationProjection(right))
    );
}

async function promoteDeploymentManifest({
    rootDir = PROJECT_ROOT,
    chainId,
    deploymentId,
    configurationDigest,
    scriptName = "DeployYieldShieldProduction.s.sol",
    provider,
    validationProvider,
    primaryRpcUrl,
    validationRpcUrl,
    finalityPolicy = CHAIN_FINALITY_POLICY,
    env = process.env,
    now,
    readFeed,
    readProtocolState = readLiveProtocolState,
    fs = {
        existsSync,
        mkdirSync,
        readFileSync,
        renameSync,
        rmSync,
        writeFileSync,
    },
}) {
    const candidatePath = join(
        rootDir,
        "deployments",
        ".candidates",
        String(chainId),
        `${deploymentId}.json`,
    );
    const broadcastPath = join(
        rootDir,
        "broadcast",
        scriptName,
        String(chainId),
        "run-latest.json",
    );
    const activePath = join(rootDir, "deployments", `${chainId}.json`);
    const historyDir = join(rootDir, "deployments", "history", String(chainId));
    const historyPath = join(historyDir, `${deploymentId}.json`);
    const candidate = JSON.parse(fs.readFileSync(candidatePath, "utf8"));
    const broadcast = JSON.parse(fs.readFileSync(broadcastPath, "utf8"));
    let manifest = await validateAndBuildManifest({
        candidate,
        broadcast,
        chainId,
        deploymentId,
        configurationDigest,
        provider,
        validationProvider,
        primaryRpcUrl,
        validationRpcUrl,
        finalityPolicy,
        env,
        now,
        readFeed,
        readProtocolState,
    });

    fs.mkdirSync(historyDir, { recursive: true });
    if (fs.existsSync(historyPath)) {
        const existingHistory = JSON.parse(
            fs.readFileSync(historyPath, "utf8"),
        );
        if (!sameGeneration(existingHistory, manifest)) {
            throw new Error("Immutable deployment history collision.");
        }
    } else {
        fs.writeFileSync(
            historyPath,
            `${JSON.stringify(manifest, null, 2)}\n`,
            { flag: "wx" },
        );
    }

    const temporaryPath = `${activePath}.tmp-${process.pid}-${deploymentId}`;
    fs.writeFileSync(temporaryPath, `${JSON.stringify(manifest, null, 2)}\n`, {
        flag: "wx",
    });
    try {
        fs.renameSync(temporaryPath, activePath);
    } catch (error) {
        fs.rmSync?.(temporaryPath, { force: true });
        throw error;
    }
    return { activePath, historyPath, manifest };
}

function parseCliArgs(args) {
    const values = {};
    for (let i = 0; i < args.length; i += 2) {
        const key = args[i];
        const value = args[i + 1];
        if (!key?.startsWith("--") || !value)
            throw new Error("Invalid finalizer arguments.");
        values[key.slice(2)] = value;
    }
    for (const required of ["chain-id", "deployment-id", "rpc-url", "script"]) {
        if (!values[required]) throw new Error(`--${required} is required.`);
    }
    return values;
}

function resolveRpcUrl(rpcInput, env = process.env, rootDir = PROJECT_ROOT) {
    if (/^https?:\/\//u.test(rpcInput)) return rpcInput;
    const foundry = parseToml(
        readFileSync(join(rootDir, "foundry.toml"), "utf8"),
    );
    const endpoint = foundry.rpc_endpoints?.[rpcInput];
    if (!endpoint) throw new Error(`Unknown Foundry RPC endpoint: ${rpcInput}`);
    const { url, missingVariables } = resolveRpcEndpoint(endpoint, env);
    if (!url)
        throw new Error(
            `RPC endpoint requires: ${missingVariables.join(", ")}`,
        );
    return url;
}

async function main() {
    const args = parseCliArgs(process.argv.slice(2));
    const configurationDigest = process.env.YS_DEPLOYMENT_CONFIGURATION_DIGEST;
    if (!configurationDigest)
        throw new Error("YS_DEPLOYMENT_CONFIGURATION_DIGEST is required.");
    const primaryRpcUrl = resolveRpcUrl(args["rpc-url"]);
    const validationRpcInput = process.env.YS_DEPLOYMENT_VALIDATION_RPC_URL;
    const validationRpcUrl = validationRpcInput
        ? resolveRpcUrl(validationRpcInput)
        : validationRpcInput;
    requireIndependentRpcUrls(primaryRpcUrl, validationRpcUrl);
    const provider = new ethers.JsonRpcProvider(primaryRpcUrl);
    const validationProvider = new ethers.JsonRpcProvider(validationRpcUrl);
    try {
        const result = await promoteDeploymentManifest({
            chainId: args["chain-id"],
            deploymentId: args["deployment-id"],
            configurationDigest,
            scriptName: args.script,
            provider,
            validationProvider,
            primaryRpcUrl,
            validationRpcUrl,
        });
        console.log(
            `Promoted deployment generation ${args["deployment-id"]} to ${result.activePath}`,
        );
    } finally {
        provider.destroy();
        validationProvider.destroy();
    }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    main().catch((error) => {
        console.error(`Deployment manifest promotion failed: ${error.message}`);
        process.exit(1);
    });
}

export {
    CHAIN_FINALITY_POLICY,
    CHAINLINK_CORE_INVENTORY,
    CHAINLINK_REVIEWED_CODEHASH_PINS,
    COMMON_REVIEWED_CODEHASH_PINS,
    DEMO_EXTRA_INVENTORY,
    DEMO_FEEDS,
    PYTH_CORE_INVENTORY,
    PYTH_REVIEWED_CODEHASH_PINS,
    buildFixtureMetadata,
    chainFinalityPolicy,
    pythSequencerPolicyForChain,
    promoteDeploymentManifest,
    requiredReviewedCodehashPinNames,
    reviewedCodehashPinSpecs,
    requireIndependentRpcOperators,
    requireIndependentRpcUrls,
    resolveFinalityEvidence,
    resolveRpcUrl,
    validateAndBuildManifest,
    validateExactInventory,
};
