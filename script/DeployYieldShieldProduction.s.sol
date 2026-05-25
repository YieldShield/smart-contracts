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

    error LocalChainRequiresLocalDeployment(uint256 chainId);
    error ProductionTimelockTooShort(uint256 providedDelay, uint256 minimumDelay);
    error InvalidProductionBootstrapHolder(address holder);
    error InvalidProductionBootstrapHolderCodehash(address holder, bytes32 actualCodehash, bytes32 expectedCodehash);
    error InvalidProductionBootstrapHolderSingleton(address holder, address actualSingleton, address expectedSingleton);
    error InvalidProductionBootstrapHolderThreshold(address holder, uint256 actualThreshold, uint256 expectedThreshold);
    error InvalidProductionBootstrapHolderOwnersHash(address holder, bytes32 actualOwnersHash, bytes32 expectedOwnersHash);
    error InvalidProductionPythContract(address pythAddress);
    error ProductionPythUpdaterNotConfirmed(uint256 chainId, uint256 maxPriceAge);

    function run() external ScaffoldEthDeployerRunner {
        if (_isLocalNetwork()) revert LocalChainRequiresLocalDeployment(block.chainid);

        (address ysTokenAddr, address timelockAddr, address governorAddr, address bootstrapHolder) = deployGovernance();
        (address factoryAddr, address compositeOracleAddr, address pythOracleAddr, address erc4626OracleFeedAddr) =
            deployProtocol(timelockAddr);

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

    function deployProtocol(address timelockAddr)
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
        compositeOracle.transferOwnership(factoryAddr);
        factory.setCompositeOracle(compositeOracleAddr);
        factory.setDefaultProtocolFeeRecipient(timelockAddr);

        pythOracle.transferOwnership(factoryAddr);
        erc4626OracleFeed.transferOwnership(factoryAddr);
        factory.setManagedPythOracle(pythOracleAddr);
        factory.setManagedERC4626OracleFeed(erc4626OracleFeedAddr);
        factory.finalizeBootstrap();
        factory.transferOwnership(timelockAddr);

        require(factory.owner() == timelockAddr, "Factory owner not transferred");
        require(!factory.bootstrapModeEnabled(), "Factory bootstrap mode not finalized");
        require(compositeOracle.owner() == factoryAddr, "Composite oracle owner not transferred");
        require(pythOracle.owner() == factoryAddr, "Pyth oracle owner not transferred");
        require(erc4626OracleFeed.owner() == factoryAddr, "ERC4626 oracle owner not transferred");
        require(factory.pythOracle() == pythOracleAddr, "Factory Pyth oracle not registered");
        require(factory.erc4626OracleFeed() == erc4626OracleFeedAddr, "Factory ERC4626 oracle not registered");

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
