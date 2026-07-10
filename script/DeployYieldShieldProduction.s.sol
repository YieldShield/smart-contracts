// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { console } from "forge-std/console.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { PythConfig } from "../contracts/oracles/PythConfig.sol";
import { ChainlinkOracleFeed } from "../contracts/oracles/ChainlinkOracleFeed.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { RobinhoodStockOracleFeed } from "../contracts/oracles/RobinhoodStockOracleFeed.sol";
import { USMarketSessionGate } from "../contracts/oracles/USMarketSessionGate.sol";
import { ConfigurableTokenFaucet } from "../contracts/mocks/ConfigurableTokenFaucet.sol";
import { MockChainlinkAggregator } from "../contracts/mocks/MockChainlinkAggregator.sol";
import { MockERC20Decimals } from "../contracts/mocks/MockERC20Decimals.sol";
import { MockRobinhoodStockToken } from "../contracts/mocks/MockRobinhoodStockToken.sol";
import { YSToken } from "../contracts/YSToken.sol";
import { YSGovernor } from "../contracts/YSGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { YSTimelockController } from "../contracts/governance/YSTimelockController.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC1822Proxiable } from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IProductionOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IProductionCompositeOracle is IProductionOwnable {
    function authorizedCallerCount() external view returns (uint256);
}

interface IProductionERC4626OracleFeed is IProductionOwnable {
    function underlyingPriceOracle() external view returns (address);
}

interface IProductionMintableERC20 {
    function mint(address to, uint256 amount) external;
}

/**
 * @notice Production deployment script for public networks
 * @dev Deploys only governance and core protocol contracts. Token whitelisting and launch assets
 *      must be configured later through governance, after oracle coverage has been reviewed.
 *
 * Example:
 * yarn deploy --file DeployYieldShieldProduction.s.sol --network arbitrum
 */
contract DeployYieldShieldProduction is ScaffoldETHDeploy {
    /// @dev Bundles the production protocol addresses so the finalize/validate
    /// helpers take a single memory struct instead of 8+ stack arguments. Passing
    /// them individually pushes those helpers one slot past the EVM stack limit
    /// when compiled with `forge coverage --ir-minimum` (optimizer disabled).
    struct ProtocolDeployment {
        address factoryAddr;
        address factoryImplementationAddr;
        address poolImplementationAddr;
        address compositeOracleAddr;
        address pythOracleAddr;
        address chainlinkOracleFeedAddr;
        address marketSessionGateAddr;
        address erc4626OracleFeedAddr;
        address timelockAddr;
        address governorAddr;
    }

    struct RobinhoodDemoAssets {
        address usdg;
        address weth;
        address sgov;
        address spy;
        address qqq;
        address tsla;
        address amzn;
        address pltr;
        address nflx;
        address amd;
        bool tslaExternal;
        bool amznExternal;
        bool pltrExternal;
        bool nflxExternal;
        bool amdExternal;
    }

    struct RobinhoodDemoFeeds {
        address usdg;
        address weth;
        address sgov;
        address spy;
        address qqq;
        address tsla;
        address amzn;
        address pltr;
        address nflx;
        address amd;
    }

    struct RobinhoodDemoPools {
        address sgovUsdg;
        address spyUsdg;
        address qqqUsdg;
        address usdgWeth;
        address tslaUsdg;
        address amznUsdg;
        address pltrUsdg;
        address nflxUsdg;
        address amdUsdg;
    }

    uint256 internal constant ROBINHOOD_MAINNET_CHAIN_ID = 4663;
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;
    uint256 internal constant MIN_PRODUCTION_TIMELOCK_DELAY = 2 days;
    uint256 internal constant DEFAULT_PRODUCTION_TIMELOCK_DELAY = 2 days;
    uint256 internal constant DEFAULT_CHAINLINK_MAX_PRICE_AGE = 86_400;
    uint256 internal constant MIN_PRODUCTION_BOOTSTRAP_OWNERS = 2;
    uint256 internal constant MIN_PRODUCTION_BOOTSTRAP_THRESHOLD = 2;
    address internal constant ROBINHOOD_TESTNET_TSLA_TOKEN = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address internal constant ROBINHOOD_TESTNET_AMZN_TOKEN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    address internal constant ROBINHOOD_TESTNET_PLTR_TOKEN = 0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0;
    address internal constant ROBINHOOD_TESTNET_NFLX_TOKEN = 0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93;
    address internal constant ROBINHOOD_TESTNET_AMD_TOKEN = 0x71178BAc73cBeb415514eB542a8995b82669778d;
    uint256 internal constant ROBINHOOD_DEMO_FAUCET_USDG_DRIP = 10_000e6;
    uint256 internal constant ROBINHOOD_DEMO_FAUCET_WETH_DRIP = 10e18;
    uint256 internal constant ROBINHOOD_DEMO_FAUCET_EQUITY_DRIP = 25e18;
    uint256 internal constant ROBINHOOD_DEMO_FAUCET_REFILL_MULTIPLIER = 1_000;
    bytes4 private constant GET_THRESHOLD_SELECTOR = bytes4(keccak256("getThreshold()"));
    bytes4 private constant GET_OWNERS_SELECTOR = bytes4(keccak256("getOwners()"));
    bytes4 private constant VERSION_SELECTOR = bytes4(keccak256("VERSION()"));
    bytes4 private constant NONCE_SELECTOR = bytes4(keccak256("nonce()"));
    bytes4 private constant DOMAIN_SEPARATOR_SELECTOR = bytes4(keccak256("domainSeparator()"));
    bytes4 private constant MASTER_COPY_SELECTOR = bytes4(keccak256("masterCopy()"));
    bytes4 private constant GET_MODULES_PAGINATED_SELECTOR = bytes4(keccak256("getModulesPaginated(address,uint256)"));
    bytes4 private constant GET_STORAGE_AT_SELECTOR = bytes4(keccak256("getStorageAt(uint256,uint256)"));
    bytes4 private constant PYTH_VALID_TIME_PERIOD_SELECTOR = bytes4(keccak256("getValidTimePeriod()"));
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant SAFE_GUARD_STORAGE_SLOT =
        0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 private constant SAFE_FALLBACK_HANDLER_STORAGE_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;
    bytes32 private constant SAFE_MODULE_GUARD_STORAGE_SLOT =
        0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947;
    bytes32 private constant NAME_FACTORY = "SplitRiskPoolFactory";
    bytes32 private constant NAME_FACTORY_IMPLEMENTATION = "FactoryImplementation";
    bytes32 private constant NAME_POOL_IMPLEMENTATION = "PoolImplementation";
    bytes32 private constant NAME_COMPOSITE_ORACLE = "CompositeOracle";
    bytes32 private constant NAME_PYTH_ORACLE = "PythOracle";
    bytes32 private constant NAME_CHAINLINK_ORACLE_FEED = "ChainlinkOracleFeed";
    bytes32 private constant NAME_US_MARKET_SESSION_GATE = "USMarketSessionGate";
    bytes32 private constant NAME_ERC4626_ORACLE_FEED = "ERC4626OracleFeed";
    bytes32 private constant NAME_TIMELOCK = "TimelockController";
    bytes32 private constant NAME_GOVERNOR = "YSGovernor";
    bytes32 private constant NAME_ROBINHOOD_STOCK_TOKEN = "RobinhoodStockToken";
    string private constant ENV_FACTORY_IMPLEMENTATION_CODEHASH = "YS_PRODUCTION_FACTORY_IMPLEMENTATION_CODEHASH";
    string private constant ENV_POOL_IMPLEMENTATION_CODEHASH = "YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH";
    string private constant ENV_PYTH_ORACLE_CODEHASH = "YS_PRODUCTION_PYTH_ORACLE_CODEHASH";
    string private constant ENV_CHAINLINK_ORACLE_CODEHASH = "YS_PRODUCTION_CHAINLINK_ORACLE_CODEHASH";
    string private constant ENV_CHAINLINK_MAX_PRICE_AGE = "YS_PRODUCTION_CHAINLINK_MAX_PRICE_AGE";
    string private constant ENV_ROBINHOOD_SEQUENCER_FEED = "YS_ROBINHOOD_SEQUENCER_FEED";
    string private constant ENV_ROBINHOOD_SEQUENCER_FEED_SOURCE = "YS_ROBINHOOD_SEQUENCER_FEED_SOURCE";
    string private constant ENV_ROBINHOOD_TESTNET_SEQUENCER_FEED = "YS_ROBINHOOD_TESTNET_SEQUENCER_FEED";
    string private constant ENV_ROBINHOOD_TESTNET_SEQUENCER_FEED_SOURCE = "YS_ROBINHOOD_TESTNET_SEQUENCER_FEED_SOURCE";
    string private constant ENV_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED = "YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED";
    string private constant ENV_ROBINHOOD_TESTNET_STRICT_PRODUCTION_GUARDS =
        "YS_ROBINHOOD_TESTNET_STRICT_PRODUCTION_GUARDS";
    string private constant ENV_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS = "YS_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS";
    string private constant ENV_ROBINHOOD_TESTNET_TEST_WALLET = "YS_ROBINHOOD_TESTNET_TEST_WALLET";
    string private constant ENV_ROBINHOOD_TESTNET_TSLA_TOKEN = "YS_ROBINHOOD_TESTNET_TSLA_TOKEN";
    string private constant ENV_ROBINHOOD_TESTNET_AMZN_TOKEN = "YS_ROBINHOOD_TESTNET_AMZN_TOKEN";
    string private constant ENV_ROBINHOOD_TESTNET_PLTR_TOKEN = "YS_ROBINHOOD_TESTNET_PLTR_TOKEN";
    string private constant ENV_ROBINHOOD_TESTNET_NFLX_TOKEN = "YS_ROBINHOOD_TESTNET_NFLX_TOKEN";
    string private constant ENV_ROBINHOOD_TESTNET_AMD_TOKEN = "YS_ROBINHOOD_TESTNET_AMD_TOKEN";
    string private constant ENV_BOOTSTRAP_HOLDER_GUARD = "YS_PRODUCTION_BOOTSTRAP_HOLDER_GUARD";
    string private constant ENV_BOOTSTRAP_HOLDER_FALLBACK_HANDLER = "YS_PRODUCTION_BOOTSTRAP_HOLDER_FALLBACK_HANDLER";
    string private constant ENV_BOOTSTRAP_HOLDER_MODULE_GUARD = "YS_PRODUCTION_BOOTSTRAP_HOLDER_MODULE_GUARD";
    bytes32 private constant FIELD_COMPOSITE_ORACLE = "factory.compositeOracle";
    bytes32 private constant FIELD_PYTH_ORACLE = "factory.pythOracle";
    bytes32 private constant FIELD_ERC4626_ORACLE_FEED = "factory.erc4626OracleFeed";
    bytes32 private constant FIELD_ERC4626_UNDERLYING_PRICE_ORACLE = "erc4626.underlyingOracle";
    bytes32 private constant FIELD_PROTOCOL_FEE_RECIPIENT = "factory.feeRecipient";
    bytes32 private constant FIELD_FACTORY_GOVERNANCE_TIMELOCK = "factory.governanceTimelock";
    bytes32 private constant FIELD_FACTORY_IMPLEMENTATION = "factory.proxyImplementation";
    bytes32 private constant FIELD_POOL_IMPLEMENTATION = "factory.poolImplementation";
    string private constant METADATA_ROBINHOOD_SEQUENCER_FEED = "robinhoodSequencerUptimeFeed";
    string private constant METADATA_ROBINHOOD_SEQUENCER_FEED_SOURCE = "robinhoodSequencerUptimeFeedSource";

    error LocalChainRequiresLocalDeployment(uint256 chainId);
    error ProductionTimelockTooShort(uint256 providedDelay, uint256 minimumDelay);
    error InvalidProductionBootstrapHolder(address holder);
    error InvalidProductionBootstrapHolderCodehash(address holder, bytes32 actualCodehash, bytes32 expectedCodehash);
    error InvalidProductionBootstrapHolderSingleton(address holder, address actualSingleton, address expectedSingleton);
    error InvalidProductionBootstrapHolderThreshold(address holder, uint256 actualThreshold, uint256 expectedThreshold);
    error InvalidProductionBootstrapHolderThresholdRatio(address holder, uint256 threshold, uint256 ownerCount);
    error InvalidProductionBootstrapHolderOwnersHash(
        address holder, bytes32 actualOwnersHash, bytes32 expectedOwnersHash
    );
    error InvalidProductionBootstrapHolderModule(address holder, address module);
    error InvalidProductionBootstrapHolderGuard(address holder, address actualGuard, address expectedGuard);
    error InvalidProductionBootstrapHolderFallbackHandler(
        address holder, address actualFallbackHandler, address expectedFallbackHandler
    );
    error InvalidProductionBootstrapHolderModuleGuard(
        address holder, address actualModuleGuard, address expectedModuleGuard
    );
    error InvalidProductionPythContract(address pythAddress);
    error ProductionPythUpdaterNotConfirmed(uint256 chainId, uint256 maxPriceAge);
    error InvalidProductionProtocolContract(bytes32 name, address contractAddress);
    error ProductionProtocolOwnerMismatch(bytes32 name, address actualOwner, address expectedOwner);
    error ProductionProtocolAddressMismatch(bytes32 field, address actualAddress, address expectedAddress);
    error ProductionProtocolAuthorizedCallersPresent(address compositeOracle, uint256 count);
    error ProductionProtocolBootstrapModeOpen(address factory);
    error ProductionProtocolLaunchAssetsPresent(address factory);
    error ProductionProtocolCodehashRequired(bytes32 name, string envName);
    error ProductionProtocolCodehashMismatch(bytes32 name, address contractAddress, bytes32 actual, bytes32 expected);
    error ProductionProtocolUUPSImplementationInvalid(bytes32 name, address implementation, bytes32 actualSlot);
    error ProductionProtocolGovernorTimelockMismatch(
        address governor, address actualTimelock, address expectedTimelock
    );
    error ProductionProtocolTimelockRoleCountMismatch(bytes32 role, uint256 actualCount, uint256 expectedCount);
    error ProductionProtocolTimelockRoleMismatch(bytes32 role, address actualMember, address expectedMember);
    error ProductionRobinhoodTestnetDemoAssetsMissing(address factory);
    error ProductionRobinhoodTestnetDemoAssetsUnsupported(uint256 chainId);
    error ProductionRobinhoodSequencerFeedRequired(uint256 chainId, string envName);
    error ProductionRobinhoodSequencerFeedSourceRequired(uint256 chainId, string envName);
    error ProductionRobinhoodSequencerFeedInvalid(address feed);
    error ProductionRobinhoodUnsupportedChain(uint256 chainId);

    function run() external ScaffoldEthDeployerRunner {
        if (_isLocalNetwork()) revert LocalChainRequiresLocalDeployment(block.chainid);
        if (_requiresStrictProductionGuards()) {
            _readRequiredProductionCodehash(NAME_FACTORY_IMPLEMENTATION, ENV_FACTORY_IMPLEMENTATION_CODEHASH);
            _readRequiredProductionCodehash(NAME_POOL_IMPLEMENTATION, ENV_POOL_IMPLEMENTATION_CODEHASH);
            if (_usesChainlinkNativeOracle()) {
                _readRequiredProductionCodehash(NAME_CHAINLINK_ORACLE_FEED, ENV_CHAINLINK_ORACLE_CODEHASH);
            } else {
                _readRequiredProductionCodehash(NAME_PYTH_ORACLE, ENV_PYTH_ORACLE_CODEHASH);
            }
        }
        _requireRobinhoodTestnetDemoAssetsAllowed();

        (address ysTokenAddr, address timelockAddr, address governorAddr, address bootstrapHolder) = deployGovernance();
        (
            address factoryAddr,
            address compositeOracleAddr,
            address pythOracleAddr,
            address chainlinkOracleFeedAddr,
            address erc4626OracleFeedAddr
        ) = deployProtocol(timelockAddr, governorAddr);

        logDeploymentSummary(
            ysTokenAddr,
            timelockAddr,
            governorAddr,
            bootstrapHolder,
            factoryAddr,
            compositeOracleAddr,
            pythOracleAddr,
            chainlinkOracleFeedAddr,
            erc4626OracleFeedAddr
        );
    }

    function finalizeProductionProtocolBootstrap(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address pythOracleAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr
    ) external ScaffoldEthDeployerRunner {
        if (_isLocalNetwork()) revert LocalChainRequiresLocalDeployment(block.chainid);
        if (_requiresStrictProductionGuards()) {
            _readRequiredProductionCodehash(NAME_FACTORY_IMPLEMENTATION, ENV_FACTORY_IMPLEMENTATION_CODEHASH);
            _readRequiredProductionCodehash(NAME_POOL_IMPLEMENTATION, ENV_POOL_IMPLEMENTATION_CODEHASH);
            _readRequiredProductionCodehash(NAME_PYTH_ORACLE, ENV_PYTH_ORACLE_CODEHASH);
        }
        _finalizeProductionProtocolBootstrap(
            ProtocolDeployment({
                factoryAddr: factoryAddr,
                factoryImplementationAddr: factoryImplementationAddr,
                poolImplementationAddr: poolImplementationAddr,
                compositeOracleAddr: compositeOracleAddr,
                pythOracleAddr: pythOracleAddr,
                chainlinkOracleFeedAddr: address(0),
                marketSessionGateAddr: address(0),
                erc4626OracleFeedAddr: erc4626OracleFeedAddr,
                timelockAddr: timelockAddr,
                governorAddr: governorAddr
            }),
            deployer
        );

        deployments.push(Deployment("PythOracle", pythOracleAddr));
        deployments.push(Deployment("ERC4626OracleFeed", erc4626OracleFeedAddr));
        deployments.push(Deployment("CompositeOracle", compositeOracleAddr));
        deployments.push(Deployment("SplitRiskPoolFactoryImplementation", factoryImplementationAddr));
        deployments.push(Deployment("SplitRiskPoolImplementation", poolImplementationAddr));
        deployments.push(Deployment("SplitRiskPoolFactory", factoryAddr));
    }

    function finalizeProductionChainlinkProtocolBootstrap(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address chainlinkOracleFeedAddr,
        address marketSessionGateAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr
    ) external ScaffoldEthDeployerRunner {
        if (_isLocalNetwork()) revert LocalChainRequiresLocalDeployment(block.chainid);
        if (_requiresStrictProductionGuards()) {
            _readRequiredProductionCodehash(NAME_FACTORY_IMPLEMENTATION, ENV_FACTORY_IMPLEMENTATION_CODEHASH);
            _readRequiredProductionCodehash(NAME_POOL_IMPLEMENTATION, ENV_POOL_IMPLEMENTATION_CODEHASH);
            _readRequiredProductionCodehash(NAME_CHAINLINK_ORACLE_FEED, ENV_CHAINLINK_ORACLE_CODEHASH);
        }
        _finalizeProductionProtocolBootstrap(
            ProtocolDeployment({
                factoryAddr: factoryAddr,
                factoryImplementationAddr: factoryImplementationAddr,
                poolImplementationAddr: poolImplementationAddr,
                compositeOracleAddr: compositeOracleAddr,
                pythOracleAddr: address(0),
                chainlinkOracleFeedAddr: chainlinkOracleFeedAddr,
                marketSessionGateAddr: marketSessionGateAddr,
                erc4626OracleFeedAddr: erc4626OracleFeedAddr,
                timelockAddr: timelockAddr,
                governorAddr: governorAddr
            }),
            deployer
        );

        deployments.push(Deployment("ChainlinkOracleFeed", chainlinkOracleFeedAddr));
        deployments.push(Deployment("USMarketSessionGate", marketSessionGateAddr));
        deployments.push(Deployment("ERC4626OracleFeed", erc4626OracleFeedAddr));
        deployments.push(Deployment("CompositeOracle", compositeOracleAddr));
        deployments.push(Deployment("SplitRiskPoolFactoryImplementation", factoryImplementationAddr));
        deployments.push(Deployment("SplitRiskPoolImplementation", poolImplementationAddr));
        deployments.push(Deployment("SplitRiskPoolFactory", factoryAddr));
    }

    function validateProductionProtocolFinalized(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address pythOracleAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr
    ) external view {
        _validateProductionProtocolFinalized(
            ProtocolDeployment({
                factoryAddr: factoryAddr,
                factoryImplementationAddr: factoryImplementationAddr,
                poolImplementationAddr: poolImplementationAddr,
                compositeOracleAddr: compositeOracleAddr,
                pythOracleAddr: pythOracleAddr,
                chainlinkOracleFeedAddr: address(0),
                marketSessionGateAddr: address(0),
                erc4626OracleFeedAddr: erc4626OracleFeedAddr,
                timelockAddr: timelockAddr,
                governorAddr: governorAddr
            })
        );
    }

    function validateProductionChainlinkProtocolFinalized(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address chainlinkOracleFeedAddr,
        address marketSessionGateAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr
    ) external view {
        _validateProductionProtocolFinalized(
            ProtocolDeployment({
                factoryAddr: factoryAddr,
                factoryImplementationAddr: factoryImplementationAddr,
                poolImplementationAddr: poolImplementationAddr,
                compositeOracleAddr: compositeOracleAddr,
                pythOracleAddr: address(0),
                chainlinkOracleFeedAddr: chainlinkOracleFeedAddr,
                marketSessionGateAddr: marketSessionGateAddr,
                erc4626OracleFeedAddr: erc4626OracleFeedAddr,
                timelockAddr: timelockAddr,
                governorAddr: governorAddr
            })
        );
    }

    function deployGovernance()
        internal
        returns (address ysTokenAddr, address timelockAddr, address governorAddr, address bootstrapHolder)
    {
        console.log("\n=== Deploying Production Governance ===");

        uint256 timelockDelay = vm.envOr("YS_PRODUCTION_TIMELOCK_DELAY", DEFAULT_PRODUCTION_TIMELOCK_DELAY);
        if (timelockDelay < MIN_PRODUCTION_TIMELOCK_DELAY) {
            revert ProductionTimelockTooShort(timelockDelay, MIN_PRODUCTION_TIMELOCK_DELAY);
        }
        if (_requiresStrictProductionGuards()) {
            bootstrapHolder = vm.envAddress("YS_PRODUCTION_BOOTSTRAP_HOLDER");
            bytes32 expectedBootstrapHolderCodehash = vm.envBytes32("YS_PRODUCTION_BOOTSTRAP_HOLDER_CODEHASH");
            address expectedBootstrapHolderSingleton = vm.envAddress("YS_PRODUCTION_BOOTSTRAP_HOLDER_SINGLETON");
            uint256 expectedBootstrapHolderThreshold = vm.envUint("YS_PRODUCTION_BOOTSTRAP_HOLDER_THRESHOLD");
            bytes32 expectedBootstrapHolderOwnersHash = vm.envBytes32("YS_PRODUCTION_BOOTSTRAP_HOLDER_OWNERS_HASH");
            address expectedBootstrapHolderGuard = vm.envOr(ENV_BOOTSTRAP_HOLDER_GUARD, address(0));
            address expectedBootstrapHolderFallbackHandler = vm.envOr(ENV_BOOTSTRAP_HOLDER_FALLBACK_HANDLER, address(0));
            address expectedBootstrapHolderModuleGuard = vm.envOr(ENV_BOOTSTRAP_HOLDER_MODULE_GUARD, address(0));
            _validateProductionBootstrapHolder(
                bootstrapHolder,
                expectedBootstrapHolderCodehash,
                expectedBootstrapHolderSingleton,
                expectedBootstrapHolderThreshold,
                expectedBootstrapHolderOwnersHash,
                expectedBootstrapHolderGuard,
                expectedBootstrapHolderFallbackHandler,
                expectedBootstrapHolderModuleGuard
            );
        } else {
            bootstrapHolder = vm.envOr("YS_PRODUCTION_BOOTSTRAP_HOLDER", deployer);
            console.log("Robinhood testnet relaxed bootstrap holder:", bootstrapHolder);
        }

        address[] memory emptyAccounts = new address[](0);
        TimelockController timelock = TimelockController(
            payable(address(new YSTimelockController(timelockDelay, emptyAccounts, emptyAccounts, deployer)))
        );
        timelockAddr = address(timelock);
        console.log("Timelock Controller deployed at:", timelockAddr);
        console.log("Timelock delay set to:", timelockDelay, "seconds");

        YSToken ysToken = new YSToken(bootstrapHolder);
        ysTokenAddr = address(ysToken);
        console.log("YS Token deployed at:", ysTokenAddr);
        console.log("Bootstrap holder:", bootstrapHolder);

        YSGovernor governor = new YSGovernor(ysToken, timelock, deployer);
        governorAddr = address(governor);
        console.log("YS Governor deployed at:", governorAddr);

        timelock.grantRole(timelock.PROPOSER_ROLE(), governorAddr);
        timelock.grantRole(timelock.EXECUTOR_ROLE(), governorAddr);
        timelock.grantRole(timelock.CANCELLER_ROLE(), governorAddr);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer), "Deployer timelock admin not cleared");
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), bootstrapHolder), "Bootstrap timelock admin retained");
        require(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), timelockAddr), "Timelock self-admin missing");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), governorAddr), "Governor proposer role missing");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), governorAddr), "Governor executor role missing");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), governorAddr), "Governor canceller role missing");
        require(ysToken.balanceOf(bootstrapHolder) == ysToken.INITIAL_SUPPLY(), "YS supply not assigned to bootstrap");

        deployments.push(Deployment("YSToken", ysTokenAddr));
        deployments.push(Deployment("TimelockController", timelockAddr));
        deployments.push(Deployment("YSGovernor", governorAddr));
    }

    function deployProtocol(address timelockAddr, address governorAddr)
        internal
        returns (
            address factoryAddr,
            address compositeOracleAddr,
            address pythOracleAddr,
            address chainlinkOracleFeedAddr,
            address erc4626OracleFeedAddr
        )
    {
        console.log("\n=== Deploying Production Protocol ===");

        if (_usesChainlinkNativeOracle()) {
            return deployChainlinkProtocol(timelockAddr, governorAddr);
        }

        address pythAddress = PythConfig.getPythAddress(block.chainid);
        uint256 maxPriceAge = PythConfig.getDefaultMaxPriceAge(block.chainid);
        bool pythUpdaterConfirmed = vm.envOr("YS_PRODUCTION_PYTH_UPDATER_CONFIRMED", false);
        _validateProductionPythConfig(pythAddress, maxPriceAge, pythUpdaterConfirmed);

        PythOracle pythOracle = new PythOracle(pythAddress, maxPriceAge);
        pythOracleAddr = address(pythOracle);
        console.log("PythOracle deployed at:", pythOracleAddr);

        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(pythOracleAddr);
        erc4626OracleFeedAddr = address(erc4626OracleFeed);
        console.log("ERC4626OracleFeed deployed at:", erc4626OracleFeedAddr);

        // SEC-01: PythOracle and ERC4626OracleFeed inherit SequencerUptimeGuard,
        // which defaults sequencerUptimeFeedRequired = true on known L2s (Arbitrum
        // One 42161 / Sepolia 421614). Configure the gate while the deployer is
        // still the owner — otherwise every subsequent price read reverts.
        if (block.chainid == PythConfig.ARBITRUM_MAINNET_CHAIN_ID) {
            // Chainlink Arbitrum One sequencer uptime feed. Verify against
            // Chainlink docs before mainnet; override with YS_ARBITRUM_SEQUENCER_FEED.
            address sequencerFeed =
                vm.envOr("YS_ARBITRUM_SEQUENCER_FEED", address(0xFdB631F5EE196F0ed6FAa767959853A9F217697D));
            pythOracle.setSequencerUptimeFeed(sequencerFeed);
            erc4626OracleFeed.setSequencerUptimeFeed(sequencerFeed);
            console.log("Sequencer uptime feed set:", sequencerFeed);
        } else {
            // Arbitrum Sepolia has no official Chainlink sequencer-uptime feed.
            // Disable the requirement so testnet pricing is usable; an operator can
            // enable it later via setSequencerUptimeFeed once a feed is available.
            pythOracle.setSequencerUptimeFeedRequired(false);
            erc4626OracleFeed.setSequencerUptimeFeedRequired(false);
            console.log("Sequencer uptime requirement disabled (no feed on this chain)");
        }

        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracleAddr = address(compositeOracle);
        console.log("CompositeOracle deployed at:", compositeOracleAddr);

        SplitRiskPoolFactory factoryImplementation = new SplitRiskPoolFactory();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPoolFactory.initialize.selector, deployer, timelockAddr, address(poolImplementation)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImplementation), initData);
        factoryAddr = address(proxy);
        console.log("SplitRiskPoolFactory proxy deployed at:", factoryAddr);
        console.log("Factory implementation:", address(factoryImplementation));
        console.log("Pool implementation:", address(poolImplementation));

        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(factoryAddr));
        uint256 actualMinimumCreationBondUsd = factory.minimumCreationBondUsd();
        console.log("Factory minimum creation bond USD:", actualMinimumCreationBondUsd);
        require(
            actualMinimumCreationBondUsd == factory.DEFAULT_MINIMUM_CREATION_BOND_USD(),
            "Factory minimum creation bond not set correctly"
        );
        _finalizeProductionProtocolBootstrap(
            ProtocolDeployment({
                factoryAddr: factoryAddr,
                factoryImplementationAddr: address(factoryImplementation),
                poolImplementationAddr: address(poolImplementation),
                compositeOracleAddr: compositeOracleAddr,
                pythOracleAddr: pythOracleAddr,
                chainlinkOracleFeedAddr: address(0),
                marketSessionGateAddr: address(0),
                erc4626OracleFeedAddr: erc4626OracleFeedAddr,
                timelockAddr: timelockAddr,
                governorAddr: governorAddr
            }),
            deployer
        );

        deployments.push(Deployment("PythOracle", pythOracleAddr));
        deployments.push(Deployment("ERC4626OracleFeed", erc4626OracleFeedAddr));
        deployments.push(Deployment("CompositeOracle", compositeOracleAddr));
        deployments.push(Deployment("SplitRiskPoolFactoryImplementation", address(factoryImplementation)));
        deployments.push(Deployment("SplitRiskPoolImplementation", address(poolImplementation)));
        deployments.push(Deployment("SplitRiskPoolFactory", factoryAddr));
    }

    function deployChainlinkProtocol(address timelockAddr, address governorAddr)
        internal
        returns (
            address factoryAddr,
            address compositeOracleAddr,
            address pythOracleAddr,
            address chainlinkOracleFeedAddr,
            address erc4626OracleFeedAddr
        )
    {
        if (!_isRobinhoodChain()) revert ProductionRobinhoodUnsupportedChain(block.chainid);

        uint256 maxPriceAge = vm.envOr(ENV_CHAINLINK_MAX_PRICE_AGE, DEFAULT_CHAINLINK_MAX_PRICE_AGE);
        ChainlinkOracleFeed chainlinkOracleFeed = new ChainlinkOracleFeed(maxPriceAge);
        chainlinkOracleFeedAddr = address(chainlinkOracleFeed);
        console.log("ChainlinkOracleFeed deployed at:", chainlinkOracleFeedAddr);
        console.log("Chainlink max price age:", maxPriceAge, "seconds");

        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(chainlinkOracleFeedAddr);
        erc4626OracleFeedAddr = address(erc4626OracleFeed);
        console.log("ERC4626OracleFeed deployed at:", erc4626OracleFeedAddr);

        _configureRobinhoodSequencerFeeds(chainlinkOracleFeed, erc4626OracleFeed);

        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracleAddr = address(compositeOracle);
        console.log("CompositeOracle deployed at:", compositeOracleAddr);

        USMarketSessionGate marketSessionGate = new USMarketSessionGate(deployer, timelockAddr);
        address marketSessionGateAddr = address(marketSessionGate);
        console.log("USMarketSessionGate deployed at:", marketSessionGateAddr);

        // Testnet demo seeding is intentionally given only the current UTC day. Mainnet and
        // future days remain fail-closed until governance loads a reviewed exchange calendar.
        if (_isRobinhoodTestnet() && _robinhoodTestnetDemoAssetsRequested()) {
            marketSessionGate.setDailySession(
                uint64(block.timestamp / marketSessionGate.SECONDS_PER_DAY()), 0, marketSessionGate.SECONDS_PER_DAY()
            );
        }

        SplitRiskPoolFactory factoryImplementation = new SplitRiskPoolFactory();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPoolFactory.initialize.selector, deployer, timelockAddr, address(poolImplementation)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImplementation), initData);
        factoryAddr = address(proxy);
        console.log("SplitRiskPoolFactory proxy deployed at:", factoryAddr);
        console.log("Factory implementation:", address(factoryImplementation));
        console.log("Pool implementation:", address(poolImplementation));

        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(factoryAddr));
        uint256 actualMinimumCreationBondUsd = factory.minimumCreationBondUsd();
        console.log("Factory minimum creation bond USD:", actualMinimumCreationBondUsd);
        require(
            actualMinimumCreationBondUsd == factory.DEFAULT_MINIMUM_CREATION_BOND_USD(),
            "Factory minimum creation bond not set correctly"
        );
        ProtocolDeployment memory protocolDeployment = ProtocolDeployment({
            factoryAddr: factoryAddr,
            factoryImplementationAddr: address(factoryImplementation),
            poolImplementationAddr: address(poolImplementation),
            compositeOracleAddr: compositeOracleAddr,
            pythOracleAddr: address(0),
            chainlinkOracleFeedAddr: chainlinkOracleFeedAddr,
            marketSessionGateAddr: marketSessionGateAddr,
            erc4626OracleFeedAddr: erc4626OracleFeedAddr,
            timelockAddr: timelockAddr,
            governorAddr: governorAddr
        });
        _seedRobinhoodTestnetDemoAssets(protocolDeployment);
        _finalizeProductionProtocolBootstrap(protocolDeployment, deployer);

        deployments.push(Deployment("ChainlinkOracleFeed", chainlinkOracleFeedAddr));
        deployments.push(Deployment("USMarketSessionGate", marketSessionGateAddr));
        deployments.push(Deployment("ERC4626OracleFeed", erc4626OracleFeedAddr));
        deployments.push(Deployment("CompositeOracle", compositeOracleAddr));
        deployments.push(Deployment("SplitRiskPoolFactoryImplementation", address(factoryImplementation)));
        deployments.push(Deployment("SplitRiskPoolImplementation", address(poolImplementation)));
        deployments.push(Deployment("SplitRiskPoolFactory", factoryAddr));
        pythOracleAddr = address(0);
    }

    function logDeploymentSummary(
        address ysTokenAddr,
        address timelockAddr,
        address governorAddr,
        address bootstrapHolder,
        address factoryAddr,
        address compositeOracleAddr,
        address pythOracleAddr,
        address chainlinkOracleFeedAddr,
        address erc4626OracleFeedAddr
    ) internal view {
        console.log("\n=== Production Deployment Summary ===");
        console.log("YS Token:", ysTokenAddr);
        console.log("Timelock Controller:", timelockAddr);
        console.log("YS Governor:", governorAddr);
        console.log("Bootstrap Holder:", bootstrapHolder);
        console.log("SplitRiskPoolFactory:", factoryAddr);
        console.log("CompositeOracle:", compositeOracleAddr);
        if (chainlinkOracleFeedAddr != address(0)) {
            console.log("ChainlinkOracleFeed:", chainlinkOracleFeedAddr);
        } else {
            console.log("PythOracle:", pythOracleAddr);
        }
        console.log("ERC4626OracleFeed:", erc4626OracleFeedAddr);

        TimelockController timelock = TimelockController(payable(timelockAddr));
        console.log("Timelock Delay:", timelock.getMinDelay() / 3600, "hours");
        if (_robinhoodTestnetDemoAssetsRequested()) {
            console.log("\nRobinhood testnet demo assets, feeds, pools, and seed liquidity were created.");
        } else {
            console.log("\nNo pools or whitelisted assets were created in this production bootstrap.");
        }
        console.log("Bootstrap holder is self-delegated for YS voting power at deployment.");
        console.log("No external timelock admin is retained after deployment.");
        if (!_robinhoodTestnetDemoAssetsRequested()) {
            console.log("Configure launch assets and oracle feeds through governance after review.");
        }
    }

    function _isLocalNetwork() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }

    function _isRobinhoodChain() internal view returns (bool) {
        return block.chainid == ROBINHOOD_MAINNET_CHAIN_ID || block.chainid == ROBINHOOD_TESTNET_CHAIN_ID;
    }

    function _isRobinhoodTestnet() internal view returns (bool) {
        return block.chainid == ROBINHOOD_TESTNET_CHAIN_ID;
    }

    function _usesChainlinkNativeOracle() internal view returns (bool) {
        return _isRobinhoodChain();
    }

    function _requiresStrictProductionGuards() internal view virtual returns (bool) {
        return !_isRobinhoodTestnet() || _envFlag(ENV_ROBINHOOD_TESTNET_STRICT_PRODUCTION_GUARDS);
    }

    function _configureRobinhoodSequencerFeeds(
        ChainlinkOracleFeed chainlinkOracleFeed,
        ERC4626OracleFeed erc4626OracleFeed
    ) internal {
        bool isTestnet = _isRobinhoodTestnet();
        string memory envName = isTestnet ? ENV_ROBINHOOD_TESTNET_SEQUENCER_FEED : ENV_ROBINHOOD_SEQUENCER_FEED;
        string memory sourceEnvName =
            isTestnet ? ENV_ROBINHOOD_TESTNET_SEQUENCER_FEED_SOURCE : ENV_ROBINHOOD_SEQUENCER_FEED_SOURCE;
        address sequencerFeed = _robinhoodSequencerFeed(isTestnet);
        if (sequencerFeed != address(0)) {
            string memory source = _robinhoodSequencerFeedSource(isTestnet);
            if (!isTestnet && !_hasNonWhitespace(source)) {
                revert ProductionRobinhoodSequencerFeedSourceRequired(block.chainid, sourceEnvName);
            }
            if (sequencerFeed.code.length == 0) {
                revert ProductionRobinhoodSequencerFeedInvalid(sequencerFeed);
            }
            chainlinkOracleFeed.setSequencerUptimeFeed(sequencerFeed);
            erc4626OracleFeed.setSequencerUptimeFeed(sequencerFeed);
            _setDeploymentMetadata(METADATA_ROBINHOOD_SEQUENCER_FEED, vm.toString(sequencerFeed));
            _setDeploymentMetadata(
                METADATA_ROBINHOOD_SEQUENCER_FEED_SOURCE,
                _hasNonWhitespace(source) ? source : "operator-supplied-testnet-feed"
            );
            console.log("Sequencer uptime feed set:", sequencerFeed);
            return;
        }

        bool explicitTestnetException = _robinhoodMissingSequencerFeedExceptionRequested();
        bool allowMissingSequencerFeed = isTestnet && (!_requiresStrictProductionGuards() || explicitTestnetException);
        if (!allowMissingSequencerFeed) {
            revert ProductionRobinhoodSequencerFeedRequired(block.chainid, envName);
        }

        chainlinkOracleFeed.setSequencerUptimeFeedRequired(false);
        erc4626OracleFeed.setSequencerUptimeFeedRequired(false);
        _setDeploymentMetadata(METADATA_ROBINHOOD_SEQUENCER_FEED, vm.toString(address(0)));
        _setDeploymentMetadata(
            METADATA_ROBINHOOD_SEQUENCER_FEED_SOURCE,
            explicitTestnetException ? "robinhood-testnet-explicit-exception" : "robinhood-testnet-relaxed-guards"
        );
        console.log("Sequencer uptime requirement explicitly disabled for Robinhood deployment");
    }

    function _robinhoodSequencerFeed(bool isTestnet) internal view virtual returns (address) {
        return vm.envOr(isTestnet ? ENV_ROBINHOOD_TESTNET_SEQUENCER_FEED : ENV_ROBINHOOD_SEQUENCER_FEED, address(0));
    }

    function _robinhoodSequencerFeedSource(bool isTestnet) internal view virtual returns (string memory) {
        return vm.envOr(
            isTestnet ? ENV_ROBINHOOD_TESTNET_SEQUENCER_FEED_SOURCE : ENV_ROBINHOOD_SEQUENCER_FEED_SOURCE, string("")
        );
    }

    function _robinhoodMissingSequencerFeedExceptionRequested() internal view virtual returns (bool) {
        return _envFlag(ENV_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED);
    }

    function _hasNonWhitespace(string memory value) internal pure returns (bool) {
        bytes memory raw = bytes(value);
        for (uint256 i = 0; i < raw.length; i++) {
            if (uint8(raw[i]) > 0x20) {
                return true;
            }
        }
        return false;
    }

    function _robinhoodTestnetDemoAssetsRequested() internal view returns (bool) {
        return _envFlagOrDefault(ENV_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS, _isRobinhoodTestnet());
    }

    function _envFlag(string memory envName) internal view returns (bool) {
        return _envFlagOrDefault(envName, false);
    }

    function _envFlagOrDefault(string memory envName, bool defaultValue) internal view returns (bool) {
        string memory rawValue = vm.envOr(envName, defaultValue ? string("true") : string("false"));
        bytes32 valueHash = keccak256(bytes(rawValue));
        return valueHash == keccak256(bytes("true")) || valueHash == keccak256(bytes("TRUE"))
            || valueHash == keccak256(bytes("True")) || valueHash == keccak256(bytes("1"))
            || valueHash == keccak256(bytes("yes")) || valueHash == keccak256(bytes("YES"))
            || valueHash == keccak256(bytes("Yes"));
    }

    function _requireRobinhoodTestnetDemoAssetsAllowed() internal view {
        if (_robinhoodTestnetDemoAssetsRequested() && block.chainid != ROBINHOOD_TESTNET_CHAIN_ID) {
            revert ProductionRobinhoodTestnetDemoAssetsUnsupported(block.chainid);
        }
    }

    function _seedRobinhoodTestnetDemoAssets(ProtocolDeployment memory d) internal {
        if (!_robinhoodTestnetDemoAssetsRequested()) {
            return;
        }
        _requireRobinhoodTestnetDemoAssetsAllowed();

        console.log("\n=== Seeding Robinhood Testnet Demo Assets ===");
        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(d.factoryAddr));
        ChainlinkOracleFeed chainlinkOracleFeed = ChainlinkOracleFeed(d.chainlinkOracleFeedAddr);
        CompositeOracle compositeOracle = CompositeOracle(d.compositeOracleAddr);
        ERC4626OracleFeed erc4626OracleFeed = ERC4626OracleFeed(d.erc4626OracleFeedAddr);

        if (compositeOracle.owner() != d.factoryAddr) {
            compositeOracle.transferOwnership(d.factoryAddr);
        }
        if (erc4626OracleFeed.owner() != d.factoryAddr) {
            erc4626OracleFeed.transferOwnership(d.factoryAddr);
        }
        factory.setCompositeOracle(d.compositeOracleAddr);
        factory.setDefaultProtocolFeeRecipient(d.timelockAddr);
        factory.setManagedERC4626OracleFeed(d.erc4626OracleFeedAddr);
        factory.setCompositeOracleAuthorizedCaller(d.factoryAddr, true);

        RobinhoodDemoAssets memory assets = _deployRobinhoodDemoAssets();
        RobinhoodDemoFeeds memory feeds = _deployRobinhoodDemoFeeds();
        _configureRobinhoodDemoFeeds(chainlinkOracleFeed, assets, feeds);
        address stockOracleFeed = _deployRobinhoodStockOracleFeed(d.chainlinkOracleFeedAddr, d.marketSessionGateAddr);
        _addRobinhoodDemoTokens(factory, assets, d.chainlinkOracleFeedAddr, stockOracleFeed);
        _mintRobinhoodDemoBalances(assets);
        _deployRobinhoodDemoAssetFaucet(assets);
        RobinhoodDemoPools memory pools = _createRobinhoodDemoPools(factory, assets);
        _seedRobinhoodDemoLiquidity(assets, pools);

        console.log("Robinhood testnet demo assets seeded");
    }

    function _deployRobinhoodDemoAssets() internal returns (RobinhoodDemoAssets memory assets) {
        assets.usdg = address(new MockERC20Decimals("Robinhood Test USDG", "USDG", 6));
        assets.weth = address(new MockERC20Decimals("Robinhood Test WETH", "WETH", 18));
        assets.sgov = address(new MockRobinhoodStockToken("Robinhood Test SGOV", "SGOV"));
        assets.spy = address(new MockRobinhoodStockToken("Robinhood Test SPY", "SPY"));
        assets.qqq = address(new MockRobinhoodStockToken("Robinhood Test QQQ", "QQQ"));
        (assets.tsla, assets.tslaExternal) =
            _robinhoodDemoStockToken(ENV_ROBINHOOD_TESTNET_TSLA_TOKEN, ROBINHOOD_TESTNET_TSLA_TOKEN, "Tesla", "TSLA");
        (assets.amzn, assets.amznExternal) =
            _robinhoodDemoStockToken(ENV_ROBINHOOD_TESTNET_AMZN_TOKEN, ROBINHOOD_TESTNET_AMZN_TOKEN, "Amazon", "AMZN");
        (assets.pltr, assets.pltrExternal) = _robinhoodDemoStockToken(
            ENV_ROBINHOOD_TESTNET_PLTR_TOKEN, ROBINHOOD_TESTNET_PLTR_TOKEN, "Palantir", "PLTR"
        );
        (assets.nflx, assets.nflxExternal) =
            _robinhoodDemoStockToken(ENV_ROBINHOOD_TESTNET_NFLX_TOKEN, ROBINHOOD_TESTNET_NFLX_TOKEN, "Netflix", "NFLX");
        (assets.amd, assets.amdExternal) =
            _robinhoodDemoStockToken(ENV_ROBINHOOD_TESTNET_AMD_TOKEN, ROBINHOOD_TESTNET_AMD_TOKEN, "AMD", "AMD");

        deployments.push(Deployment("RobinhoodTestUSDG", assets.usdg));
        deployments.push(Deployment("RobinhoodTestWETH", assets.weth));
        deployments.push(Deployment("RobinhoodTestSGOV", assets.sgov));
        deployments.push(Deployment("RobinhoodTestSPY", assets.spy));
        deployments.push(Deployment("RobinhoodTestQQQ", assets.qqq));
        deployments.push(Deployment("RobinhoodTestTSLA", assets.tsla));
        deployments.push(Deployment("RobinhoodTestAMZN", assets.amzn));
        deployments.push(Deployment("RobinhoodTestPLTR", assets.pltr));
        deployments.push(Deployment("RobinhoodTestNFLX", assets.nflx));
        deployments.push(Deployment("RobinhoodTestAMD", assets.amd));

        console.log("USDG:", assets.usdg);
        console.log("WETH:", assets.weth);
        console.log("SGOV:", assets.sgov);
        console.log("SPY:", assets.spy);
        console.log("QQQ:", assets.qqq);
        console.log("TSLA:", assets.tsla);
        console.log("AMZN:", assets.amzn);
        console.log("PLTR:", assets.pltr);
        console.log("NFLX:", assets.nflx);
        console.log("AMD:", assets.amd);
    }

    function _robinhoodDemoStockToken(
        string memory envName,
        address defaultRobinhoodTestnetToken,
        string memory name,
        string memory symbol
    ) internal returns (address token, bool externalToken) {
        token = vm.envOr(envName, address(0));
        if (token == address(0) && _isRobinhoodTestnet() && defaultRobinhoodTestnetToken.code.length != 0) {
            token = defaultRobinhoodTestnetToken;
        }
        if (token != address(0)) {
            _requireProductionContract(NAME_ROBINHOOD_STOCK_TOKEN, token);
            (bool probeSuccess, bytes memory probeData) = token.staticcall(abi.encodeWithSignature("oraclePaused()"));
            if (probeSuccess && probeData.length >= 32) {
                return (token, true);
            }
            console.log("Robinhood testnet token missing oraclePaused(); using local demo token:", token);
        }
        return (address(new MockRobinhoodStockToken(name, symbol)), false);
    }

    function _deployRobinhoodDemoFeeds() internal returns (RobinhoodDemoFeeds memory feeds) {
        feeds.usdg = address(new MockChainlinkAggregator("USDG / USD", 8, 1e8));
        feeds.weth = address(new MockChainlinkAggregator("WETH / USD", 8, 1735e8));
        feeds.sgov = address(new MockChainlinkAggregator("SGOV / USD", 8, 10_043_500_000));
        feeds.spy = address(new MockChainlinkAggregator("SPY / USD", 8, 74_477_000_000));
        feeds.qqq = address(new MockChainlinkAggregator("QQQ / USD", 8, 71_466_135_000));
        feeds.tsla = address(new MockChainlinkAggregator("TSLA / USD", 8, 33_200_000_000));
        feeds.amzn = address(new MockChainlinkAggregator("AMZN / USD", 8, 22_500_000_000));
        feeds.pltr = address(new MockChainlinkAggregator("PLTR / USD", 8, 15_000_000_000));
        feeds.nflx = address(new MockChainlinkAggregator("NFLX / USD", 8, 126_000_000_000));
        feeds.amd = address(new MockChainlinkAggregator("AMD / USD", 8, 17_500_000_000));

        deployments.push(Deployment("RobinhoodUSDGMockChainlinkFeed", feeds.usdg));
        deployments.push(Deployment("RobinhoodWETHMockChainlinkFeed", feeds.weth));
        deployments.push(Deployment("RobinhoodSGOVMockChainlinkFeed", feeds.sgov));
        deployments.push(Deployment("RobinhoodSPYMockChainlinkFeed", feeds.spy));
        deployments.push(Deployment("RobinhoodQQQMockChainlinkFeed", feeds.qqq));
        deployments.push(Deployment("RobinhoodTSLAMockChainlinkFeed", feeds.tsla));
        deployments.push(Deployment("RobinhoodAMZNMockChainlinkFeed", feeds.amzn));
        deployments.push(Deployment("RobinhoodPLTRMockChainlinkFeed", feeds.pltr));
        deployments.push(Deployment("RobinhoodNFLXMockChainlinkFeed", feeds.nflx));
        deployments.push(Deployment("RobinhoodAMDMockChainlinkFeed", feeds.amd));
    }

    function _configureRobinhoodDemoFeeds(
        ChainlinkOracleFeed chainlinkOracleFeed,
        RobinhoodDemoAssets memory assets,
        RobinhoodDemoFeeds memory feeds
    ) internal {
        chainlinkOracleFeed.setTokenFeed(assets.usdg, feeds.usdg);
        chainlinkOracleFeed.setTokenFeed(assets.weth, feeds.weth);
        chainlinkOracleFeed.setTokenFeed(assets.sgov, feeds.sgov);
        chainlinkOracleFeed.setTokenFeed(assets.spy, feeds.spy);
        chainlinkOracleFeed.setTokenFeed(assets.qqq, feeds.qqq);
        chainlinkOracleFeed.setTokenFeed(assets.tsla, feeds.tsla);
        chainlinkOracleFeed.setTokenFeed(assets.amzn, feeds.amzn);
        chainlinkOracleFeed.setTokenFeed(assets.pltr, feeds.pltr);
        chainlinkOracleFeed.setTokenFeed(assets.nflx, feeds.nflx);
        chainlinkOracleFeed.setTokenFeed(assets.amd, feeds.amd);
    }

    function _deployRobinhoodStockOracleFeed(address chainlinkOracleFeed, address marketSessionGate)
        internal
        returns (address stockOracleFeed)
    {
        stockOracleFeed = address(new RobinhoodStockOracleFeed(chainlinkOracleFeed, marketSessionGate));
        deployments.push(Deployment("RobinhoodStockOracleFeed", stockOracleFeed));
        console.log("RobinhoodStockOracleFeed:", stockOracleFeed);
    }

    function _addRobinhoodDemoTokens(
        SplitRiskPoolFactory factory,
        RobinhoodDemoAssets memory assets,
        address chainlinkOracleFeed,
        address stockOracleFeed
    ) internal {
        _addRobinhoodDemoToken(factory, assets.usdg, "Robinhood Test USDG", "USDG", chainlinkOracleFeed, 10_000);
        _addRobinhoodDemoToken(factory, assets.weth, "Robinhood Test WETH", "WETH", chainlinkOracleFeed, 20_000);
        _addRobinhoodDemoStockToken(factory, assets.sgov, "Robinhood Test SGOV", "SGOV", stockOracleFeed, 12_500);
        _addRobinhoodDemoStockToken(factory, assets.spy, "Robinhood Test SPY", "SPY", stockOracleFeed, 20_000);
        _addRobinhoodDemoStockToken(factory, assets.qqq, "Robinhood Test QQQ", "QQQ", stockOracleFeed, 22_500);
        _addRobinhoodDemoStockToken(factory, assets.tsla, "Robinhood Test TSLA", "TSLA", stockOracleFeed, 25_000);
        _addRobinhoodDemoStockToken(factory, assets.amzn, "Robinhood Test AMZN", "AMZN", stockOracleFeed, 25_000);
        _addRobinhoodDemoStockToken(factory, assets.pltr, "Robinhood Test PLTR", "PLTR", stockOracleFeed, 30_000);
        _addRobinhoodDemoStockToken(factory, assets.nflx, "Robinhood Test NFLX", "NFLX", stockOracleFeed, 25_000);
        _addRobinhoodDemoStockToken(factory, assets.amd, "Robinhood Test AMD", "AMD", stockOracleFeed, 30_000);
    }

    /// @dev Registers a stock/ETF demo token in the CompositeOracle through the
    ///      RobinhoodStockOracleFeed wrapper so corporate-action and market-session policy
    ///      gates are never bypassed. External testnet tokens without `oraclePaused()` are
    ///      replaced with local demo tokens before this function is reached.
    function _addRobinhoodDemoStockToken(
        SplitRiskPoolFactory factory,
        address token,
        string memory name,
        string memory symbol,
        address stockOracleFeed,
        uint256 minCollateralRatioBp
    ) internal {
        (bool probeSuccess, bytes memory probeData) = token.staticcall(abi.encodeWithSignature("oraclePaused()"));
        if (!probeSuccess || probeData.length < 32) {
            revert InvalidProductionProtocolContract(NAME_ROBINHOOD_STOCK_TOKEN, token);
        }
        _addRobinhoodDemoToken(factory, token, name, symbol, stockOracleFeed, minCollateralRatioBp);
    }

    function _addRobinhoodDemoToken(
        SplitRiskPoolFactory factory,
        address token,
        string memory name,
        string memory symbol,
        address chainlinkOracleFeed,
        uint256 minCollateralRatioBp
    ) internal {
        factory.addTokenInitial(token, name, symbol, chainlinkOracleFeed, address(0), minCollateralRatioBp, true);
    }

    function _mintRobinhoodDemoBalances(RobinhoodDemoAssets memory assets) internal {
        address testWallet = vm.envOr(ENV_ROBINHOOD_TESTNET_TEST_WALLET, address(0));
        _mintRobinhoodDemoAsset(assets.usdg, deployer, 2_000_000e6);
        _mintRobinhoodDemoAsset(assets.weth, deployer, 2_000e18);
        _mintRobinhoodDemoAsset(assets.sgov, deployer, 10_000e18);
        _mintRobinhoodDemoAsset(assets.spy, deployer, 10_000e18);
        _mintRobinhoodDemoAsset(assets.qqq, deployer, 10_000e18);
        _mintRobinhoodDemoStockAsset(assets.tsla, assets.tslaExternal, deployer, 100e18);
        _mintRobinhoodDemoStockAsset(assets.amzn, assets.amznExternal, deployer, 100e18);
        _mintRobinhoodDemoStockAsset(assets.pltr, assets.pltrExternal, deployer, 100e18);
        _mintRobinhoodDemoStockAsset(assets.nflx, assets.nflxExternal, deployer, 100e18);
        _mintRobinhoodDemoStockAsset(assets.amd, assets.amdExternal, deployer, 100e18);

        if (testWallet != address(0)) {
            _mintRobinhoodDemoAsset(assets.usdg, testWallet, 100_000e6);
            _mintRobinhoodDemoAsset(assets.weth, testWallet, 100e18);
            _mintRobinhoodDemoAsset(assets.sgov, testWallet, 1_000e18);
            _mintRobinhoodDemoAsset(assets.spy, testWallet, 1_000e18);
            _mintRobinhoodDemoAsset(assets.qqq, testWallet, 1_000e18);
            _mintRobinhoodDemoStockAsset(assets.tsla, assets.tslaExternal, testWallet, 5e18);
            _mintRobinhoodDemoStockAsset(assets.amzn, assets.amznExternal, testWallet, 5e18);
            _mintRobinhoodDemoStockAsset(assets.pltr, assets.pltrExternal, testWallet, 5e18);
            _mintRobinhoodDemoStockAsset(assets.nflx, assets.nflxExternal, testWallet, 5e18);
            _mintRobinhoodDemoStockAsset(assets.amd, assets.amdExternal, testWallet, 5e18);
            console.log("Robinhood test wallet funded:", testWallet);
        }
    }

    function _mintRobinhoodDemoAsset(address token, address to, uint256 amount) internal {
        IProductionMintableERC20(token).mint(to, amount);
    }

    function _mintRobinhoodDemoStockAsset(address token, bool externalToken, address to, uint256 amount) internal {
        if (externalToken) {
            console.log("Robinhood stock token is externally managed, skipping mint:", token);
            return;
        }
        _mintRobinhoodDemoAsset(token, to, amount);
    }

    function _deployRobinhoodDemoAssetFaucet(RobinhoodDemoAssets memory assets) internal returns (address faucetAddr) {
        ConfigurableTokenFaucet faucet = new ConfigurableTokenFaucet(deployer);
        faucetAddr = address(faucet);

        address[] memory faucetTokens = new address[](5);
        uint256[] memory dripAmounts = new uint256[](5);
        faucetTokens[0] = assets.usdg;
        faucetTokens[1] = assets.weth;
        faucetTokens[2] = assets.sgov;
        faucetTokens[3] = assets.spy;
        faucetTokens[4] = assets.qqq;
        dripAmounts[0] = ROBINHOOD_DEMO_FAUCET_USDG_DRIP;
        dripAmounts[1] = ROBINHOOD_DEMO_FAUCET_WETH_DRIP;
        dripAmounts[2] = ROBINHOOD_DEMO_FAUCET_EQUITY_DRIP;
        dripAmounts[3] = ROBINHOOD_DEMO_FAUCET_EQUITY_DRIP;
        dripAmounts[4] = ROBINHOOD_DEMO_FAUCET_EQUITY_DRIP;
        faucet.setTokens(faucetTokens, dripAmounts);

        _mintRobinhoodDemoAsset(
            assets.usdg, faucetAddr, ROBINHOOD_DEMO_FAUCET_USDG_DRIP * ROBINHOOD_DEMO_FAUCET_REFILL_MULTIPLIER
        );
        _mintRobinhoodDemoAsset(
            assets.weth, faucetAddr, ROBINHOOD_DEMO_FAUCET_WETH_DRIP * ROBINHOOD_DEMO_FAUCET_REFILL_MULTIPLIER
        );
        _mintRobinhoodDemoAsset(
            assets.sgov, faucetAddr, ROBINHOOD_DEMO_FAUCET_EQUITY_DRIP * ROBINHOOD_DEMO_FAUCET_REFILL_MULTIPLIER
        );
        _mintRobinhoodDemoAsset(
            assets.spy, faucetAddr, ROBINHOOD_DEMO_FAUCET_EQUITY_DRIP * ROBINHOOD_DEMO_FAUCET_REFILL_MULTIPLIER
        );
        _mintRobinhoodDemoAsset(
            assets.qqq, faucetAddr, ROBINHOOD_DEMO_FAUCET_EQUITY_DRIP * ROBINHOOD_DEMO_FAUCET_REFILL_MULTIPLIER
        );

        deployments.push(Deployment("RobinhoodDemoAssetFaucet", faucetAddr));
        console.log("RobinhoodDemoAssetFaucet:", faucetAddr);
    }

    function _createRobinhoodDemoPools(SplitRiskPoolFactory factory, RobinhoodDemoAssets memory assets)
        internal
        returns (RobinhoodDemoPools memory pools)
    {
        pools.sgovUsdg = _createRobinhoodDemoPool(factory, assets.sgov, "SGOV", assets.usdg, "USDG", 12_500, 600e6);
        pools.spyUsdg = _createRobinhoodDemoPool(factory, assets.spy, "SPY", assets.usdg, "USDG", 20_000, 600e6);
        pools.qqqUsdg = _createRobinhoodDemoPool(factory, assets.qqq, "QQQ", assets.usdg, "USDG", 22_500, 600e6);
        pools.usdgWeth = _createRobinhoodDemoPool(factory, assets.usdg, "USDG", assets.weth, "WETH", 20_000, 1e18);
        pools.tslaUsdg = _createRobinhoodDemoPool(factory, assets.tsla, "TSLA", assets.usdg, "USDG", 25_000, 600e6);
        pools.amznUsdg = _createRobinhoodDemoPool(factory, assets.amzn, "AMZN", assets.usdg, "USDG", 25_000, 600e6);
        pools.pltrUsdg = _createRobinhoodDemoPool(factory, assets.pltr, "PLTR", assets.usdg, "USDG", 30_000, 600e6);
        pools.nflxUsdg = _createRobinhoodDemoPool(factory, assets.nflx, "NFLX", assets.usdg, "USDG", 25_000, 600e6);
        pools.amdUsdg = _createRobinhoodDemoPool(factory, assets.amd, "AMD", assets.usdg, "USDG", 30_000, 600e6);

        deployments.push(Deployment("RobinhoodSGOVUSDGPool", pools.sgovUsdg));
        deployments.push(Deployment("RobinhoodSPYUSDGPool", pools.spyUsdg));
        deployments.push(Deployment("RobinhoodQQQUSDGPool", pools.qqqUsdg));
        deployments.push(Deployment("RobinhoodUSDGWETHPool", pools.usdgWeth));
        deployments.push(Deployment("RobinhoodTSLAUSDGPool", pools.tslaUsdg));
        deployments.push(Deployment("RobinhoodAMZNUSDGPool", pools.amznUsdg));
        deployments.push(Deployment("RobinhoodPLTRUSDGPool", pools.pltrUsdg));
        deployments.push(Deployment("RobinhoodNFLXUSDGPool", pools.nflxUsdg));
        deployments.push(Deployment("RobinhoodAMDUSDGPool", pools.amdUsdg));
    }

    function _createRobinhoodDemoPool(
        SplitRiskPoolFactory factory,
        address shieldedToken,
        string memory shieldedSymbol,
        address backingToken,
        string memory backingSymbol,
        uint256 collateralRatioBp,
        uint256 creationBondAmount
    ) internal returns (address pool) {
        IERC20(backingToken).approve(address(factory), creationBondAmount);
        pool = factory.createPool(
            shieldedToken, shieldedSymbol, backingToken, backingSymbol, 500, 200, collateralRatioBp, creationBondAmount
        );
    }

    function _seedRobinhoodDemoLiquidity(RobinhoodDemoAssets memory assets, RobinhoodDemoPools memory pools) internal {
        _seedRobinhoodDemoPosition(pools.sgovUsdg, assets.usdg, 50_000e6, assets.sgov, 10e18);
        _seedRobinhoodDemoPosition(pools.spyUsdg, assets.usdg, 100_000e6, assets.spy, 10e18);
        _seedRobinhoodDemoPosition(pools.qqqUsdg, assets.usdg, 100_000e6, assets.qqq, 10e18);
        _seedRobinhoodDemoPosition(pools.usdgWeth, assets.weth, 100e18, assets.usdg, 10_000e6);
        _seedRobinhoodDemoPositionIfShieldedAvailable(pools.tslaUsdg, assets.usdg, 75_000e6, assets.tsla, 1e18);
        _seedRobinhoodDemoPositionIfShieldedAvailable(pools.amznUsdg, assets.usdg, 75_000e6, assets.amzn, 1e18);
        _seedRobinhoodDemoPositionIfShieldedAvailable(pools.pltrUsdg, assets.usdg, 75_000e6, assets.pltr, 1e18);
        _seedRobinhoodDemoPositionIfShieldedAvailable(pools.nflxUsdg, assets.usdg, 75_000e6, assets.nflx, 1e18);
        _seedRobinhoodDemoPositionIfShieldedAvailable(pools.amdUsdg, assets.usdg, 75_000e6, assets.amd, 1e18);
    }

    function _seedRobinhoodDemoPosition(
        address pool,
        address backingToken,
        uint256 backingAmount,
        address shieldedToken,
        uint256 shieldedAmount
    ) internal {
        IERC20(backingToken).approve(pool, backingAmount);
        SplitRiskPool(payable(pool)).depositBackingAsset(backingToken, backingAmount, 0);
        IERC20(shieldedToken).approve(pool, shieldedAmount);
        SplitRiskPool(payable(pool)).depositShieldedAsset(shieldedToken, shieldedAmount, 0);
    }

    function _seedRobinhoodDemoPositionIfShieldedAvailable(
        address pool,
        address backingToken,
        uint256 backingAmount,
        address shieldedToken,
        uint256 shieldedAmount
    ) internal {
        IERC20(backingToken).approve(pool, backingAmount);
        SplitRiskPool(payable(pool)).depositBackingAsset(backingToken, backingAmount, 0);

        if (IERC20(shieldedToken).balanceOf(deployer) < shieldedAmount) {
            console.log("Skipping shielded seed; deployer lacks Robinhood faucet token:", shieldedToken);
            return;
        }

        IERC20(shieldedToken).approve(pool, shieldedAmount);
        SplitRiskPool(payable(pool)).depositShieldedAsset(shieldedToken, shieldedAmount, 0);
    }

    function _finalizeProductionProtocolBootstrap(ProtocolDeployment memory d, address bootstrapAdmin) internal {
        _requireProductionContract(NAME_FACTORY, d.factoryAddr);
        _requireProductionImplementation(NAME_FACTORY_IMPLEMENTATION, d.factoryImplementationAddr);
        _requireMandatoryProductionCodehash(
            NAME_FACTORY_IMPLEMENTATION, d.factoryImplementationAddr, ENV_FACTORY_IMPLEMENTATION_CODEHASH
        );
        _requireProductionImplementation(NAME_POOL_IMPLEMENTATION, d.poolImplementationAddr);
        _requireMandatoryProductionCodehash(
            NAME_POOL_IMPLEMENTATION, d.poolImplementationAddr, ENV_POOL_IMPLEMENTATION_CODEHASH
        );
        _requireProductionContractCodehash(
            NAME_COMPOSITE_ORACLE, d.compositeOracleAddr, type(CompositeOracle).runtimeCode
        );
        if (_isChainlinkProtocolDeployment(d)) {
            _requireMandatoryProductionCodehash(
                NAME_CHAINLINK_ORACLE_FEED, d.chainlinkOracleFeedAddr, ENV_CHAINLINK_ORACLE_CODEHASH
            );
            _requireProductionContractCodehash(
                NAME_US_MARKET_SESSION_GATE, d.marketSessionGateAddr, type(USMarketSessionGate).runtimeCode
            );
        } else {
            _requireMandatoryProductionCodehash(NAME_PYTH_ORACLE, d.pythOracleAddr, ENV_PYTH_ORACLE_CODEHASH);
        }
        _requireProductionContractCodehash(
            NAME_ERC4626_ORACLE_FEED, d.erc4626OracleFeedAddr, type(ERC4626OracleFeed).runtimeCode
        );
        _requireProductionContract(NAME_TIMELOCK, d.timelockAddr);
        _requireProductionContract(NAME_GOVERNOR, d.governorAddr);
        _requireProductionCodehash(NAME_TIMELOCK, d.timelockAddr, type(YSTimelockController).runtimeCode);

        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(d.factoryAddr));
        _requireProductionAddress(
            FIELD_FACTORY_IMPLEMENTATION, _proxyImplementation(d.factoryAddr), d.factoryImplementationAddr
        );
        _requireProductionAddress(
            FIELD_POOL_IMPLEMENTATION, factory.splitRiskPoolImplementation(), d.poolImplementationAddr
        );
        _validateProductionGovernanceController(d.timelockAddr, d.governorAddr);
        _requireProductionAddress(FIELD_FACTORY_GOVERNANCE_TIMELOCK, factory.governanceTimelock(), d.timelockAddr);

        address configuredCompositeOracle = factory.compositeOracle();
        if (configuredCompositeOracle != address(0)) {
            _requireProductionAddress(FIELD_COMPOSITE_ORACLE, configuredCompositeOracle, d.compositeOracleAddr);
        }
        address configuredProtocolFeeRecipient = factory.defaultProtocolFeeRecipient();
        if (configuredProtocolFeeRecipient != address(0)) {
            _requireProductionAddress(FIELD_PROTOCOL_FEE_RECIPIENT, configuredProtocolFeeRecipient, d.timelockAddr);
        }
        address configuredPythOracle = factory.pythOracle();
        if (configuredPythOracle != address(0)) {
            _requireProductionAddress(FIELD_PYTH_ORACLE, configuredPythOracle, d.pythOracleAddr);
        }
        address configuredERC4626OracleFeed = factory.erc4626OracleFeed();
        if (configuredERC4626OracleFeed != address(0)) {
            _requireProductionAddress(FIELD_ERC4626_ORACLE_FEED, configuredERC4626OracleFeed, d.erc4626OracleFeedAddr);
        }

        _transferOwnershipToFactoryIfNeeded(NAME_COMPOSITE_ORACLE, d.compositeOracleAddr, d.factoryAddr, bootstrapAdmin);
        if (_isChainlinkProtocolDeployment(d)) {
            _transferOwnershipIfNeeded(
                NAME_CHAINLINK_ORACLE_FEED, d.chainlinkOracleFeedAddr, d.timelockAddr, bootstrapAdmin
            );
            _transferOwnershipIfNeeded(
                NAME_US_MARKET_SESSION_GATE, d.marketSessionGateAddr, d.timelockAddr, bootstrapAdmin
            );
        } else {
            _transferOwnershipToFactoryIfNeeded(NAME_PYTH_ORACLE, d.pythOracleAddr, d.factoryAddr, bootstrapAdmin);
        }
        _transferOwnershipToFactoryIfNeeded(
            NAME_ERC4626_ORACLE_FEED, d.erc4626OracleFeedAddr, d.factoryAddr, bootstrapAdmin
        );

        if (factory.compositeOracle() == address(0)) {
            factory.setCompositeOracle(d.compositeOracleAddr);
        }
        _requireProductionAddress(FIELD_COMPOSITE_ORACLE, factory.compositeOracle(), d.compositeOracleAddr);

        if (factory.defaultProtocolFeeRecipient() == address(0)) {
            factory.setDefaultProtocolFeeRecipient(d.timelockAddr);
        }
        _requireProductionAddress(FIELD_PROTOCOL_FEE_RECIPIENT, factory.defaultProtocolFeeRecipient(), d.timelockAddr);

        if (!_isChainlinkProtocolDeployment(d) && factory.pythOracle() == address(0)) {
            factory.setManagedPythOracle(d.pythOracleAddr);
        }
        _requireProductionAddress(
            FIELD_PYTH_ORACLE, factory.pythOracle(), _isChainlinkProtocolDeployment(d) ? address(0) : d.pythOracleAddr
        );

        if (factory.erc4626OracleFeed() == address(0)) {
            factory.setManagedERC4626OracleFeed(d.erc4626OracleFeedAddr);
        }
        _requireProductionAddress(FIELD_ERC4626_ORACLE_FEED, factory.erc4626OracleFeed(), d.erc4626OracleFeedAddr);

        if (factory.bootstrapModeEnabled()) {
            if (factory.owner() != bootstrapAdmin) {
                revert ProductionProtocolBootstrapModeOpen(d.factoryAddr);
            }
            factory.finalizeBootstrap();
        }

        if (factory.owner() == bootstrapAdmin) {
            factory.transferOwnership(d.timelockAddr);
        }

        _validateProductionProtocolFinalized(d);
    }

    function _validateProductionProtocolFinalized(ProtocolDeployment memory d) internal view {
        _requireProductionContract(NAME_FACTORY, d.factoryAddr);
        _requireProductionImplementation(NAME_FACTORY_IMPLEMENTATION, d.factoryImplementationAddr);
        _requireMandatoryProductionCodehash(
            NAME_FACTORY_IMPLEMENTATION, d.factoryImplementationAddr, ENV_FACTORY_IMPLEMENTATION_CODEHASH
        );
        _requireProductionImplementation(NAME_POOL_IMPLEMENTATION, d.poolImplementationAddr);
        _requireMandatoryProductionCodehash(
            NAME_POOL_IMPLEMENTATION, d.poolImplementationAddr, ENV_POOL_IMPLEMENTATION_CODEHASH
        );
        _requireProductionContractCodehash(
            NAME_COMPOSITE_ORACLE, d.compositeOracleAddr, type(CompositeOracle).runtimeCode
        );
        if (_isChainlinkProtocolDeployment(d)) {
            _requireMandatoryProductionCodehash(
                NAME_CHAINLINK_ORACLE_FEED, d.chainlinkOracleFeedAddr, ENV_CHAINLINK_ORACLE_CODEHASH
            );
            _requireProductionContractCodehash(
                NAME_US_MARKET_SESSION_GATE, d.marketSessionGateAddr, type(USMarketSessionGate).runtimeCode
            );
        } else {
            _requireMandatoryProductionCodehash(NAME_PYTH_ORACLE, d.pythOracleAddr, ENV_PYTH_ORACLE_CODEHASH);
        }
        _requireProductionContractCodehash(
            NAME_ERC4626_ORACLE_FEED, d.erc4626OracleFeedAddr, type(ERC4626OracleFeed).runtimeCode
        );
        _requireProductionContract(NAME_TIMELOCK, d.timelockAddr);
        _requireProductionContract(NAME_GOVERNOR, d.governorAddr);
        _requireProductionCodehash(NAME_TIMELOCK, d.timelockAddr, type(YSTimelockController).runtimeCode);

        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(d.factoryAddr));
        _requireProductionAddress(
            FIELD_FACTORY_IMPLEMENTATION, _proxyImplementation(d.factoryAddr), d.factoryImplementationAddr
        );
        _requireProductionAddress(
            FIELD_POOL_IMPLEMENTATION, factory.splitRiskPoolImplementation(), d.poolImplementationAddr
        );
        _validateProductionGovernanceController(d.timelockAddr, d.governorAddr);
        _requireProductionOwner(NAME_FACTORY, factory.owner(), d.timelockAddr);
        _requireProductionAddress(FIELD_FACTORY_GOVERNANCE_TIMELOCK, factory.governanceTimelock(), d.timelockAddr);
        if (factory.bootstrapModeEnabled()) {
            revert ProductionProtocolBootstrapModeOpen(d.factoryAddr);
        }
        bool demoAssetsRequested = block.chainid == ROBINHOOD_TESTNET_CHAIN_ID && _robinhoodTestnetDemoAssetsRequested();
        if (demoAssetsRequested) {
            if (factory.poolCount() == 0 || factory.getWhitelistedTokens().length == 0) {
                revert ProductionRobinhoodTestnetDemoAssetsMissing(d.factoryAddr);
            }
        } else if (factory.poolCount() != 0 || factory.getWhitelistedTokens().length != 0) {
            revert ProductionProtocolLaunchAssetsPresent(d.factoryAddr);
        }

        _requireProductionOwner(NAME_COMPOSITE_ORACLE, IProductionOwnable(d.compositeOracleAddr).owner(), d.factoryAddr);
        uint256 compositeOracleAuthorizedCallerCount =
            IProductionCompositeOracle(d.compositeOracleAddr).authorizedCallerCount();
        if (compositeOracleAuthorizedCallerCount != 0) {
            revert ProductionProtocolAuthorizedCallersPresent(
                d.compositeOracleAddr, compositeOracleAuthorizedCallerCount
            );
        }
        if (_isChainlinkProtocolDeployment(d)) {
            _requireProductionOwner(
                NAME_CHAINLINK_ORACLE_FEED, IProductionOwnable(d.chainlinkOracleFeedAddr).owner(), d.timelockAddr
            );
            _requireProductionOwner(
                NAME_US_MARKET_SESSION_GATE, IProductionOwnable(d.marketSessionGateAddr).owner(), d.timelockAddr
            );
            _requireProductionAddress(FIELD_PYTH_ORACLE, factory.pythOracle(), address(0));
            _requireProductionAddress(
                FIELD_ERC4626_UNDERLYING_PRICE_ORACLE,
                IProductionERC4626OracleFeed(d.erc4626OracleFeedAddr).underlyingPriceOracle(),
                d.chainlinkOracleFeedAddr
            );
        } else {
            _requireProductionOwner(NAME_PYTH_ORACLE, IProductionOwnable(d.pythOracleAddr).owner(), d.factoryAddr);
            _requireProductionAddress(FIELD_PYTH_ORACLE, factory.pythOracle(), d.pythOracleAddr);
        }
        _requireProductionOwner(
            NAME_ERC4626_ORACLE_FEED, IProductionOwnable(d.erc4626OracleFeedAddr).owner(), d.factoryAddr
        );
        _requireProductionAddress(FIELD_COMPOSITE_ORACLE, factory.compositeOracle(), d.compositeOracleAddr);
        _requireProductionAddress(FIELD_PROTOCOL_FEE_RECIPIENT, factory.defaultProtocolFeeRecipient(), d.timelockAddr);
        _requireProductionAddress(FIELD_ERC4626_ORACLE_FEED, factory.erc4626OracleFeed(), d.erc4626OracleFeedAddr);
    }

    function _transferOwnershipToFactoryIfNeeded(
        bytes32 name,
        address contractAddress,
        address factoryAddr,
        address bootstrapAdmin
    ) internal {
        _transferOwnershipIfNeeded(name, contractAddress, factoryAddr, bootstrapAdmin);
    }

    function _transferOwnershipIfNeeded(
        bytes32 name,
        address contractAddress,
        address expectedOwner,
        address bootstrapAdmin
    ) internal {
        address currentOwner = IProductionOwnable(contractAddress).owner();
        if (currentOwner == expectedOwner) {
            return;
        }
        if (currentOwner != bootstrapAdmin) {
            revert ProductionProtocolOwnerMismatch(name, currentOwner, expectedOwner);
        }
        IProductionOwnable(contractAddress).transferOwnership(expectedOwner);
    }

    function _isChainlinkProtocolDeployment(ProtocolDeployment memory d) internal pure returns (bool) {
        return d.chainlinkOracleFeedAddr != address(0);
    }

    function _requireProductionContract(bytes32 name, address contractAddress) internal view {
        if (contractAddress == address(0) || contractAddress.code.length == 0) {
            revert InvalidProductionProtocolContract(name, contractAddress);
        }
    }

    function _requireProductionImplementation(bytes32 name, address implementation) internal view {
        _requireProductionContract(name, implementation);
        try IERC1822Proxiable(implementation).proxiableUUID() returns (bytes32 slot) {
            if (slot != ERC1967_IMPLEMENTATION_SLOT) {
                revert ProductionProtocolUUPSImplementationInvalid(name, implementation, slot);
            }
        } catch {
            revert ProductionProtocolUUPSImplementationInvalid(name, implementation, bytes32(0));
        }
    }

    function _requireMandatoryProductionCodehash(bytes32 name, address contractAddress, string memory envName)
        internal
        view
    {
        _requireProductionContract(name, contractAddress);
        if (!_requiresStrictProductionGuards()) {
            return;
        }
        _requireProductionCodehash(name, contractAddress, _readRequiredProductionCodehash(name, envName));
    }

    function _readRequiredProductionCodehash(bytes32 name, string memory envName)
        internal
        view
        virtual
        returns (bytes32 codehash)
    {
        codehash = vm.envOr(envName, bytes32(0));
        if (codehash == bytes32(0)) {
            revert ProductionProtocolCodehashRequired(name, envName);
        }
    }

    function _requireProductionContractCodehash(bytes32 name, address contractAddress, bytes memory expectedRuntimeCode)
        internal
        view
    {
        _requireProductionContract(name, contractAddress);
        _requireProductionCodehash(name, contractAddress, expectedRuntimeCode);
    }

    function _requireProductionCodehash(bytes32 name, address contractAddress, bytes32 expectedCodehash) internal view {
        if (contractAddress.codehash != expectedCodehash) {
            revert ProductionProtocolCodehashMismatch(name, contractAddress, contractAddress.codehash, expectedCodehash);
        }
    }

    function _requireProductionCodehash(bytes32 name, address contractAddress, bytes memory expectedRuntimeCode)
        internal
        view
    {
        bytes32 expectedCodehash = keccak256(expectedRuntimeCode);
        _requireProductionCodehash(name, contractAddress, expectedCodehash);
    }

    function _proxyImplementation(address proxy) internal view returns (address implementation) {
        implementation = address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _validateProductionGovernanceController(address timelockAddr, address governorAddr) internal view {
        address governorTimelock = YSGovernor(payable(governorAddr)).timelock();
        if (governorTimelock != timelockAddr) {
            revert ProductionProtocolGovernorTimelockMismatch(governorAddr, governorTimelock, timelockAddr);
        }

        YSTimelockController timelock = YSTimelockController(payable(timelockAddr));
        _requireSoleTimelockRoleMember(timelock, timelock.DEFAULT_ADMIN_ROLE(), timelockAddr);
        _requireSoleTimelockRoleMember(timelock, timelock.PROPOSER_ROLE(), governorAddr);
        _requireSoleTimelockRoleMember(timelock, timelock.EXECUTOR_ROLE(), governorAddr);
        _requireSoleTimelockRoleMember(timelock, timelock.CANCELLER_ROLE(), governorAddr);
    }

    function _requireSoleTimelockRoleMember(YSTimelockController timelock, bytes32 role, address expectedMember)
        internal
        view
    {
        uint256 memberCount = timelock.getRoleMemberCount(role);
        if (memberCount != 1) {
            revert ProductionProtocolTimelockRoleCountMismatch(role, memberCount, 1);
        }
        address member = timelock.getRoleMember(role, 0);
        if (member != expectedMember) {
            revert ProductionProtocolTimelockRoleMismatch(role, member, expectedMember);
        }
    }

    function _requireProductionOwner(bytes32 name, address actualOwner, address expectedOwner) internal pure {
        if (actualOwner != expectedOwner) {
            revert ProductionProtocolOwnerMismatch(name, actualOwner, expectedOwner);
        }
    }

    function _requireProductionAddress(bytes32 field, address actualAddress, address expectedAddress) internal pure {
        if (actualAddress != expectedAddress) {
            revert ProductionProtocolAddressMismatch(field, actualAddress, expectedAddress);
        }
    }

    /// @dev Enforces Safe shape and pins the bootstrap holder to an
    ///      operator-reviewed Safe proxy runtime codehash plus singleton/master
    ///      copy. Gnosis Safe bytecode differs across chains and versions, so
    ///      expected values are supplied per deployment via
    ///      YS_PRODUCTION_BOOTSTRAP_HOLDER_CODEHASH and
    ///      YS_PRODUCTION_BOOTSTRAP_HOLDER_SINGLETON. Owners and threshold are
    ///      pinned through YS_PRODUCTION_BOOTSTRAP_HOLDER_OWNERS_HASH and
    ///      YS_PRODUCTION_BOOTSTRAP_HOLDER_THRESHOLD. Modules must be empty,
    ///      while guard, fallback handler, and module guard default to zero and
    ///      may be explicitly pinned through their YS_PRODUCTION_* env values.
    function _validateProductionBootstrapHolder(
        address holder,
        bytes32 expectedCodehash,
        address expectedSingleton,
        uint256 expectedThreshold,
        bytes32 expectedOwnersHash,
        address expectedGuard,
        address expectedFallbackHandler,
        address expectedModuleGuard
    ) internal view {
        if (holder == address(0) || holder.code.length == 0) {
            revert InvalidProductionBootstrapHolder(holder);
        }
        if (expectedCodehash == bytes32(0) || holder.codehash != expectedCodehash) {
            revert InvalidProductionBootstrapHolderCodehash(holder, holder.codehash, expectedCodehash);
        }
        if (expectedSingleton == address(0)) {
            revert InvalidProductionBootstrapHolderSingleton(holder, address(0), expectedSingleton);
        }

        (bool success, bytes memory data) = holder.staticcall(abi.encodeWithSelector(MASTER_COPY_SELECTOR));
        if (!success || data.length < 32) {
            revert InvalidProductionBootstrapHolderSingleton(holder, address(0), expectedSingleton);
        }
        address actualSingleton = abi.decode(data, (address));
        if (actualSingleton != expectedSingleton) {
            revert InvalidProductionBootstrapHolderSingleton(holder, actualSingleton, expectedSingleton);
        }

        (success, data) = holder.staticcall(abi.encodeWithSelector(VERSION_SELECTOR));
        if (!success || data.length < 96 || bytes(abi.decode(data, (string))).length == 0) {
            revert InvalidProductionBootstrapHolder(holder);
        }

        (success, data) = holder.staticcall(abi.encodeWithSelector(NONCE_SELECTOR));
        if (!success || data.length < 32) {
            revert InvalidProductionBootstrapHolder(holder);
        }

        (success, data) = holder.staticcall(abi.encodeWithSelector(DOMAIN_SEPARATOR_SELECTOR));
        if (!success || data.length < 32 || abi.decode(data, (bytes32)) == bytes32(0)) {
            revert InvalidProductionBootstrapHolder(holder);
        }

        (success, data) = holder.staticcall(abi.encodeWithSelector(GET_THRESHOLD_SELECTOR));
        if (!success || data.length < 32) {
            revert InvalidProductionBootstrapHolder(holder);
        }
        uint256 threshold = abi.decode(data, (uint256));

        (success, data) = holder.staticcall(abi.encodeWithSelector(GET_OWNERS_SELECTOR));
        if (!success || data.length < 64) {
            revert InvalidProductionBootstrapHolder(holder);
        }
        address[] memory owners = abi.decode(data, (address[]));

        if (
            threshold < MIN_PRODUCTION_BOOTSTRAP_THRESHOLD || owners.length < MIN_PRODUCTION_BOOTSTRAP_OWNERS
                || threshold > owners.length
        ) {
            revert InvalidProductionBootstrapHolder(holder);
        }
        if (threshold * 2 <= owners.length) {
            revert InvalidProductionBootstrapHolderThresholdRatio(holder, threshold, owners.length);
        }
        if (expectedThreshold == 0 || threshold != expectedThreshold) {
            revert InvalidProductionBootstrapHolderThreshold(holder, threshold, expectedThreshold);
        }

        bytes32 actualOwnersHash = keccak256(abi.encode(owners));
        if (expectedOwnersHash == bytes32(0) || actualOwnersHash != expectedOwnersHash) {
            revert InvalidProductionBootstrapHolderOwnersHash(holder, actualOwnersHash, expectedOwnersHash);
        }

        _validateProductionBootstrapHolderSafeExtensions(
            holder, expectedGuard, expectedFallbackHandler, expectedModuleGuard
        );

        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == address(0)) {
                revert InvalidProductionBootstrapHolder(holder);
            }
            for (uint256 j = i + 1; j < owners.length; j++) {
                if (owners[i] == owners[j]) {
                    revert InvalidProductionBootstrapHolder(holder);
                }
            }
        }
    }

    function _validateProductionBootstrapHolderSafeExtensions(
        address holder,
        address expectedGuard,
        address expectedFallbackHandler,
        address expectedModuleGuard
    ) internal view {
        _validateProductionBootstrapHolderNoModules(holder);

        address actualGuard = _readSafeStorageAddress(holder, SAFE_GUARD_STORAGE_SLOT);
        if (actualGuard != expectedGuard) {
            revert InvalidProductionBootstrapHolderGuard(holder, actualGuard, expectedGuard);
        }

        address actualFallbackHandler = _readSafeStorageAddress(holder, SAFE_FALLBACK_HANDLER_STORAGE_SLOT);
        if (actualFallbackHandler != expectedFallbackHandler) {
            revert InvalidProductionBootstrapHolderFallbackHandler(
                holder, actualFallbackHandler, expectedFallbackHandler
            );
        }

        address actualModuleGuard = _readSafeStorageAddress(holder, SAFE_MODULE_GUARD_STORAGE_SLOT);
        if (actualModuleGuard != expectedModuleGuard) {
            revert InvalidProductionBootstrapHolderModuleGuard(holder, actualModuleGuard, expectedModuleGuard);
        }
    }

    function _validateProductionBootstrapHolderNoModules(address holder) internal view {
        address sentinel = address(0x1);
        (bool success, bytes memory data) =
            holder.staticcall(abi.encodeWithSelector(GET_MODULES_PAGINATED_SELECTOR, sentinel, 1));
        if (!success || data.length < 64) {
            revert InvalidProductionBootstrapHolder(holder);
        }

        (address[] memory modules, address next) = abi.decode(data, (address[], address));
        if (modules.length != 0) {
            revert InvalidProductionBootstrapHolderModule(holder, modules[0]);
        }
        if (next != sentinel) {
            revert InvalidProductionBootstrapHolderModule(holder, next);
        }
    }

    function _readSafeStorageAddress(address holder, bytes32 slot) internal view returns (address value) {
        (bool success, bytes memory data) =
            holder.staticcall(abi.encodeWithSelector(GET_STORAGE_AT_SELECTOR, uint256(slot), 1));
        if (!success || data.length < 64) {
            revert InvalidProductionBootstrapHolder(holder);
        }

        bytes memory rawStorage = abi.decode(data, (bytes));
        if (rawStorage.length < 32) {
            revert InvalidProductionBootstrapHolder(holder);
        }

        bytes32 slotValue;
        assembly ("memory-safe") {
            slotValue := mload(add(rawStorage, 0x20))
        }
        value = address(uint160(uint256(slotValue)));
    }

    function _validateProductionPythConfig(address pythAddress, uint256 maxPriceAge, bool updaterConfirmed)
        internal
        view
    {
        if (pythAddress.code.length == 0) {
            revert InvalidProductionPythContract(pythAddress);
        }
        (bool success, bytes memory data) =
            pythAddress.staticcall(abi.encodeWithSelector(PYTH_VALID_TIME_PERIOD_SELECTOR));
        if (!success || data.length < 32 || abi.decode(data, (uint256)) == 0) {
            revert InvalidProductionPythContract(pythAddress);
        }
        if (block.chainid == PythConfig.ARBITRUM_MAINNET_CHAIN_ID && !updaterConfirmed) {
            revert ProductionPythUpdaterNotConfirmed(block.chainid, maxPriceAge);
        }
    }
}
