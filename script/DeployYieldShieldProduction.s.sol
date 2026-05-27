// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { console } from "forge-std/console.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { PythConfig } from "../contracts/oracles/PythConfig.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { YSToken } from "../contracts/YSToken.sol";
import { YSGovernor } from "../contracts/YSGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { YSTimelockController } from "../contracts/governance/YSTimelockController.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC1822Proxiable } from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";

interface IProductionOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IProductionCompositeOracle is IProductionOwnable {
    function authorizedCallerCount() external view returns (uint256);
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
    uint256 internal constant MIN_PRODUCTION_TIMELOCK_DELAY = 2 days;
    uint256 internal constant DEFAULT_PRODUCTION_TIMELOCK_DELAY = 2 days;
    uint256 internal constant MIN_PRODUCTION_BOOTSTRAP_OWNERS = 2;
    uint256 internal constant MIN_PRODUCTION_BOOTSTRAP_THRESHOLD = 2;
    bytes4 private constant GET_THRESHOLD_SELECTOR = bytes4(keccak256("getThreshold()"));
    bytes4 private constant GET_OWNERS_SELECTOR = bytes4(keccak256("getOwners()"));
    bytes4 private constant VERSION_SELECTOR = bytes4(keccak256("VERSION()"));
    bytes4 private constant NONCE_SELECTOR = bytes4(keccak256("nonce()"));
    bytes4 private constant DOMAIN_SEPARATOR_SELECTOR = bytes4(keccak256("domainSeparator()"));
    bytes4 private constant MASTER_COPY_SELECTOR = bytes4(keccak256("masterCopy()"));
    bytes4 private constant PYTH_VALID_TIME_PERIOD_SELECTOR = bytes4(keccak256("getValidTimePeriod()"));
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant NAME_FACTORY = "SplitRiskPoolFactory";
    bytes32 private constant NAME_FACTORY_IMPLEMENTATION = "FactoryImplementation";
    bytes32 private constant NAME_POOL_IMPLEMENTATION = "PoolImplementation";
    bytes32 private constant NAME_COMPOSITE_ORACLE = "CompositeOracle";
    bytes32 private constant NAME_PYTH_ORACLE = "PythOracle";
    bytes32 private constant NAME_ERC4626_ORACLE_FEED = "ERC4626OracleFeed";
    bytes32 private constant NAME_TIMELOCK = "TimelockController";
    bytes32 private constant NAME_GOVERNOR = "YSGovernor";
    string private constant ENV_FACTORY_IMPLEMENTATION_CODEHASH = "YS_PRODUCTION_FACTORY_IMPLEMENTATION_CODEHASH";
    string private constant ENV_POOL_IMPLEMENTATION_CODEHASH = "YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH";
    string private constant ENV_PYTH_ORACLE_CODEHASH = "YS_PRODUCTION_PYTH_ORACLE_CODEHASH";
    bytes32 private constant FIELD_COMPOSITE_ORACLE = "factory.compositeOracle";
    bytes32 private constant FIELD_PYTH_ORACLE = "factory.pythOracle";
    bytes32 private constant FIELD_ERC4626_ORACLE_FEED = "factory.erc4626OracleFeed";
    bytes32 private constant FIELD_PROTOCOL_FEE_RECIPIENT = "factory.feeRecipient";
    bytes32 private constant FIELD_FACTORY_GOVERNANCE_TIMELOCK = "factory.governanceTimelock";
    bytes32 private constant FIELD_FACTORY_IMPLEMENTATION = "factory.proxyImplementation";
    bytes32 private constant FIELD_POOL_IMPLEMENTATION = "factory.poolImplementation";

    error LocalChainRequiresLocalDeployment(uint256 chainId);
    error ProductionTimelockTooShort(uint256 providedDelay, uint256 minimumDelay);
    error InvalidProductionBootstrapHolder(address holder);
    error InvalidProductionBootstrapHolderCodehash(address holder, bytes32 actualCodehash, bytes32 expectedCodehash);
    error InvalidProductionBootstrapHolderSingleton(address holder, address actualSingleton, address expectedSingleton);
    error InvalidProductionBootstrapHolderThreshold(address holder, uint256 actualThreshold, uint256 expectedThreshold);
    error InvalidProductionBootstrapHolderOwnersHash(
        address holder, bytes32 actualOwnersHash, bytes32 expectedOwnersHash
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

    function run() external ScaffoldEthDeployerRunner {
        if (_isLocalNetwork()) revert LocalChainRequiresLocalDeployment(block.chainid);
        _readRequiredProductionCodehash(NAME_PYTH_ORACLE, ENV_PYTH_ORACLE_CODEHASH);

        (address ysTokenAddr, address timelockAddr, address governorAddr, address bootstrapHolder) = deployGovernance();
        (address factoryAddr, address compositeOracleAddr, address pythOracleAddr, address erc4626OracleFeedAddr) =
            deployProtocol(timelockAddr, governorAddr);

        logDeploymentSummary(
            ysTokenAddr,
            timelockAddr,
            governorAddr,
            bootstrapHolder,
            factoryAddr,
            compositeOracleAddr,
            pythOracleAddr,
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
        _readRequiredProductionCodehash(NAME_PYTH_ORACLE, ENV_PYTH_ORACLE_CODEHASH);
        _finalizeProductionProtocolBootstrap(
            factoryAddr,
            factoryImplementationAddr,
            poolImplementationAddr,
            compositeOracleAddr,
            pythOracleAddr,
            erc4626OracleFeedAddr,
            timelockAddr,
            governorAddr,
            deployer
        );

        deployments.push(Deployment("PythOracle", pythOracleAddr));
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
            factoryAddr,
            factoryImplementationAddr,
            poolImplementationAddr,
            compositeOracleAddr,
            pythOracleAddr,
            erc4626OracleFeedAddr,
            timelockAddr,
            governorAddr
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
        bootstrapHolder = vm.envAddress("YS_PRODUCTION_BOOTSTRAP_HOLDER");
        bytes32 expectedBootstrapHolderCodehash = vm.envBytes32("YS_PRODUCTION_BOOTSTRAP_HOLDER_CODEHASH");
        address expectedBootstrapHolderSingleton = vm.envAddress("YS_PRODUCTION_BOOTSTRAP_HOLDER_SINGLETON");
        uint256 expectedBootstrapHolderThreshold = vm.envUint("YS_PRODUCTION_BOOTSTRAP_HOLDER_THRESHOLD");
        bytes32 expectedBootstrapHolderOwnersHash = vm.envBytes32("YS_PRODUCTION_BOOTSTRAP_HOLDER_OWNERS_HASH");
        _validateProductionBootstrapHolder(
            bootstrapHolder,
            expectedBootstrapHolderCodehash,
            expectedBootstrapHolderSingleton,
            expectedBootstrapHolderThreshold,
            expectedBootstrapHolderOwnersHash
        );

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

        YSGovernor governor = new YSGovernor(ysToken, timelock);
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
            address erc4626OracleFeedAddr
        )
    {
        console.log("\n=== Deploying Production Protocol ===");

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
            factoryAddr,
            address(factoryImplementation),
            address(poolImplementation),
            compositeOracleAddr,
            pythOracleAddr,
            erc4626OracleFeedAddr,
            timelockAddr,
            governorAddr,
            deployer
        );

        deployments.push(Deployment("PythOracle", pythOracleAddr));
        deployments.push(Deployment("ERC4626OracleFeed", erc4626OracleFeedAddr));
        deployments.push(Deployment("CompositeOracle", compositeOracleAddr));
        deployments.push(Deployment("SplitRiskPoolFactoryImplementation", address(factoryImplementation)));
        deployments.push(Deployment("SplitRiskPoolImplementation", address(poolImplementation)));
        deployments.push(Deployment("SplitRiskPoolFactory", factoryAddr));
    }

    function logDeploymentSummary(
        address ysTokenAddr,
        address timelockAddr,
        address governorAddr,
        address bootstrapHolder,
        address factoryAddr,
        address compositeOracleAddr,
        address pythOracleAddr,
        address erc4626OracleFeedAddr
    ) internal view {
        console.log("\n=== Production Deployment Summary ===");
        console.log("YS Token:", ysTokenAddr);
        console.log("Timelock Controller:", timelockAddr);
        console.log("YS Governor:", governorAddr);
        console.log("Bootstrap Holder:", bootstrapHolder);
        console.log("SplitRiskPoolFactory:", factoryAddr);
        console.log("CompositeOracle:", compositeOracleAddr);
        console.log("PythOracle:", pythOracleAddr);
        console.log("ERC4626OracleFeed:", erc4626OracleFeedAddr);

        TimelockController timelock = TimelockController(payable(timelockAddr));
        console.log("Timelock Delay:", timelock.getMinDelay() / 3600, "hours");
        console.log("\nNo pools or whitelisted assets were created in this production bootstrap.");
        console.log("Bootstrap holder must self-delegate YS before the first governance proposal.");
        console.log("No external timelock admin is retained after deployment.");
        console.log("Configure launch assets and oracle feeds through governance after review.");
    }

    function _isLocalNetwork() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }

    function _finalizeProductionProtocolBootstrap(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address pythOracleAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr,
        address bootstrapAdmin
    ) internal {
        _requireProductionContract(NAME_FACTORY, factoryAddr);
        _requireProductionImplementation(NAME_FACTORY_IMPLEMENTATION, factoryImplementationAddr);
        _requireOptionalProductionCodehash(
            NAME_FACTORY_IMPLEMENTATION, factoryImplementationAddr, ENV_FACTORY_IMPLEMENTATION_CODEHASH
        );
        _requireProductionImplementation(NAME_POOL_IMPLEMENTATION, poolImplementationAddr);
        _requireOptionalProductionCodehash(
            NAME_POOL_IMPLEMENTATION, poolImplementationAddr, ENV_POOL_IMPLEMENTATION_CODEHASH
        );
        _requireProductionContractCodehash(
            NAME_COMPOSITE_ORACLE, compositeOracleAddr, type(CompositeOracle).runtimeCode
        );
        _requireMandatoryProductionCodehash(NAME_PYTH_ORACLE, pythOracleAddr, ENV_PYTH_ORACLE_CODEHASH);
        _requireProductionContractCodehash(
            NAME_ERC4626_ORACLE_FEED, erc4626OracleFeedAddr, type(ERC4626OracleFeed).runtimeCode
        );
        _requireProductionContract(NAME_TIMELOCK, timelockAddr);
        _requireProductionContract(NAME_GOVERNOR, governorAddr);
        _requireProductionCodehash(NAME_TIMELOCK, timelockAddr, type(YSTimelockController).runtimeCode);

        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(factoryAddr));
        _requireProductionAddress(
            FIELD_FACTORY_IMPLEMENTATION, _proxyImplementation(factoryAddr), factoryImplementationAddr
        );
        _requireProductionAddress(
            FIELD_POOL_IMPLEMENTATION, factory.splitRiskPoolImplementation(), poolImplementationAddr
        );
        _validateProductionGovernanceController(timelockAddr, governorAddr);
        _requireProductionAddress(FIELD_FACTORY_GOVERNANCE_TIMELOCK, factory.governanceTimelock(), timelockAddr);

        address configuredCompositeOracle = factory.compositeOracle();
        if (configuredCompositeOracle != address(0)) {
            _requireProductionAddress(FIELD_COMPOSITE_ORACLE, configuredCompositeOracle, compositeOracleAddr);
        }
        address configuredProtocolFeeRecipient = factory.defaultProtocolFeeRecipient();
        if (configuredProtocolFeeRecipient != address(0)) {
            _requireProductionAddress(FIELD_PROTOCOL_FEE_RECIPIENT, configuredProtocolFeeRecipient, timelockAddr);
        }
        address configuredPythOracle = factory.pythOracle();
        if (configuredPythOracle != address(0)) {
            _requireProductionAddress(FIELD_PYTH_ORACLE, configuredPythOracle, pythOracleAddr);
        }
        address configuredERC4626OracleFeed = factory.erc4626OracleFeed();
        if (configuredERC4626OracleFeed != address(0)) {
            _requireProductionAddress(FIELD_ERC4626_ORACLE_FEED, configuredERC4626OracleFeed, erc4626OracleFeedAddr);
        }

        _transferOwnershipToFactoryIfNeeded(NAME_COMPOSITE_ORACLE, compositeOracleAddr, factoryAddr, bootstrapAdmin);
        _transferOwnershipToFactoryIfNeeded(NAME_PYTH_ORACLE, pythOracleAddr, factoryAddr, bootstrapAdmin);
        _transferOwnershipToFactoryIfNeeded(
            NAME_ERC4626_ORACLE_FEED, erc4626OracleFeedAddr, factoryAddr, bootstrapAdmin
        );

        if (factory.compositeOracle() == address(0)) {
            factory.setCompositeOracle(compositeOracleAddr);
        }
        _requireProductionAddress(FIELD_COMPOSITE_ORACLE, factory.compositeOracle(), compositeOracleAddr);

        if (factory.defaultProtocolFeeRecipient() == address(0)) {
            factory.setDefaultProtocolFeeRecipient(timelockAddr);
        }
        _requireProductionAddress(FIELD_PROTOCOL_FEE_RECIPIENT, factory.defaultProtocolFeeRecipient(), timelockAddr);

        if (factory.pythOracle() == address(0)) {
            factory.setManagedPythOracle(pythOracleAddr);
        }
        _requireProductionAddress(FIELD_PYTH_ORACLE, factory.pythOracle(), pythOracleAddr);

        if (factory.erc4626OracleFeed() == address(0)) {
            factory.setManagedERC4626OracleFeed(erc4626OracleFeedAddr);
        }
        _requireProductionAddress(FIELD_ERC4626_ORACLE_FEED, factory.erc4626OracleFeed(), erc4626OracleFeedAddr);

        if (factory.bootstrapModeEnabled()) {
            if (factory.owner() != bootstrapAdmin) {
                revert ProductionProtocolBootstrapModeOpen(factoryAddr);
            }
            factory.finalizeBootstrap();
        }

        if (factory.owner() == bootstrapAdmin) {
            factory.transferOwnership(timelockAddr);
        }

        _validateProductionProtocolFinalized(
            factoryAddr,
            factoryImplementationAddr,
            poolImplementationAddr,
            compositeOracleAddr,
            pythOracleAddr,
            erc4626OracleFeedAddr,
            timelockAddr,
            governorAddr
        );
    }

    function _validateProductionProtocolFinalized(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address pythOracleAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr
    ) internal view {
        _requireProductionContract(NAME_FACTORY, factoryAddr);
        _requireProductionImplementation(NAME_FACTORY_IMPLEMENTATION, factoryImplementationAddr);
        _requireOptionalProductionCodehash(
            NAME_FACTORY_IMPLEMENTATION, factoryImplementationAddr, ENV_FACTORY_IMPLEMENTATION_CODEHASH
        );
        _requireProductionImplementation(NAME_POOL_IMPLEMENTATION, poolImplementationAddr);
        _requireOptionalProductionCodehash(
            NAME_POOL_IMPLEMENTATION, poolImplementationAddr, ENV_POOL_IMPLEMENTATION_CODEHASH
        );
        _requireProductionContractCodehash(
            NAME_COMPOSITE_ORACLE, compositeOracleAddr, type(CompositeOracle).runtimeCode
        );
        _requireMandatoryProductionCodehash(NAME_PYTH_ORACLE, pythOracleAddr, ENV_PYTH_ORACLE_CODEHASH);
        _requireProductionContractCodehash(
            NAME_ERC4626_ORACLE_FEED, erc4626OracleFeedAddr, type(ERC4626OracleFeed).runtimeCode
        );
        _requireProductionContract(NAME_TIMELOCK, timelockAddr);
        _requireProductionContract(NAME_GOVERNOR, governorAddr);
        _requireProductionCodehash(NAME_TIMELOCK, timelockAddr, type(YSTimelockController).runtimeCode);

        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(factoryAddr));
        _requireProductionAddress(
            FIELD_FACTORY_IMPLEMENTATION, _proxyImplementation(factoryAddr), factoryImplementationAddr
        );
        _requireProductionAddress(
            FIELD_POOL_IMPLEMENTATION, factory.splitRiskPoolImplementation(), poolImplementationAddr
        );
        _validateProductionGovernanceController(timelockAddr, governorAddr);
        _requireProductionOwner(NAME_FACTORY, factory.owner(), timelockAddr);
        _requireProductionAddress(FIELD_FACTORY_GOVERNANCE_TIMELOCK, factory.governanceTimelock(), timelockAddr);
        if (factory.bootstrapModeEnabled()) {
            revert ProductionProtocolBootstrapModeOpen(factoryAddr);
        }
        if (factory.poolCount() != 0 || factory.getWhitelistedTokens().length != 0) {
            revert ProductionProtocolLaunchAssetsPresent(factoryAddr);
        }

        _requireProductionOwner(NAME_COMPOSITE_ORACLE, IProductionOwnable(compositeOracleAddr).owner(), factoryAddr);
        uint256 compositeOracleAuthorizedCallerCount =
            IProductionCompositeOracle(compositeOracleAddr).authorizedCallerCount();
        if (compositeOracleAuthorizedCallerCount != 0) {
            revert ProductionProtocolAuthorizedCallersPresent(compositeOracleAddr, compositeOracleAuthorizedCallerCount);
        }
        _requireProductionOwner(NAME_PYTH_ORACLE, IProductionOwnable(pythOracleAddr).owner(), factoryAddr);
        _requireProductionOwner(
            NAME_ERC4626_ORACLE_FEED, IProductionOwnable(erc4626OracleFeedAddr).owner(), factoryAddr
        );
        _requireProductionAddress(FIELD_COMPOSITE_ORACLE, factory.compositeOracle(), compositeOracleAddr);
        _requireProductionAddress(FIELD_PROTOCOL_FEE_RECIPIENT, factory.defaultProtocolFeeRecipient(), timelockAddr);
        _requireProductionAddress(FIELD_PYTH_ORACLE, factory.pythOracle(), pythOracleAddr);
        _requireProductionAddress(FIELD_ERC4626_ORACLE_FEED, factory.erc4626OracleFeed(), erc4626OracleFeedAddr);
    }

    function _transferOwnershipToFactoryIfNeeded(
        bytes32 name,
        address contractAddress,
        address factoryAddr,
        address bootstrapAdmin
    ) internal {
        address currentOwner = IProductionOwnable(contractAddress).owner();
        if (currentOwner == factoryAddr) {
            return;
        }
        if (currentOwner != bootstrapAdmin) {
            revert ProductionProtocolOwnerMismatch(name, currentOwner, factoryAddr);
        }
        IProductionOwnable(contractAddress).transferOwnership(factoryAddr);
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

    function _requireOptionalProductionCodehash(bytes32 name, address contractAddress, string memory envName)
        internal
        view
    {
        bytes32 expectedCodehash = vm.envOr(envName, bytes32(0));
        if (expectedCodehash != bytes32(0)) {
            _requireProductionCodehash(name, contractAddress, expectedCodehash);
        }
    }

    function _requireMandatoryProductionCodehash(bytes32 name, address contractAddress, string memory envName)
        internal
        view
    {
        _requireProductionContract(name, contractAddress);
        _requireProductionCodehash(name, contractAddress, _readRequiredProductionCodehash(name, envName));
    }

    function _readRequiredProductionCodehash(bytes32 name, string memory envName) internal view returns (bytes32 codehash) {
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
    ///      YS_PRODUCTION_BOOTSTRAP_HOLDER_THRESHOLD.
    function _validateProductionBootstrapHolder(
        address holder,
        bytes32 expectedCodehash,
        address expectedSingleton,
        uint256 expectedThreshold,
        bytes32 expectedOwnersHash
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
        if (expectedThreshold == 0 || threshold != expectedThreshold) {
            revert InvalidProductionBootstrapHolderThreshold(holder, threshold, expectedThreshold);
        }

        bytes32 actualOwnersHash = keccak256(abi.encode(owners));
        if (expectedOwnersHash == bytes32(0) || actualOwnersHash != expectedOwnersHash) {
            revert InvalidProductionBootstrapHolderOwnersHash(holder, actualOwnersHash, expectedOwnersHash);
        }

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
