// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { YSToken } from "../contracts/YSToken.sol";
import { YSGovernor } from "../contracts/YSGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { YSTimelockController } from "../contracts/governance/YSTimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { PythConfig } from "../contracts/oracles/PythConfig.sol";
import { ChainlinkOracleFeed } from "../contracts/oracles/ChainlinkOracleFeed.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ConfigurableTokenFaucet } from "../contracts/mocks/ConfigurableTokenFaucet.sol";
import { MockERC20Decimals } from "../contracts/mocks/MockERC20Decimals.sol";
import { DeployYieldShieldProduction } from "../script/DeployYieldShieldProduction.s.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";
import { MockPyth } from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

contract ProductionDeployHarness is DeployYieldShieldProduction {
    bytes32 internal expectedFactoryImplementationCodehash;
    bytes32 internal expectedPoolImplementationCodehash;
    bytes32 internal expectedPythOracleCodehash;
    bytes32 internal expectedChainlinkOracleCodehash;
    bool internal strictProductionGuardsOverrideSet;
    bool internal strictProductionGuardsOverride;

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function robinhoodTestnetDemoAssetsRequestedHarness() external view returns (bool) {
        return _robinhoodTestnetDemoAssetsRequested();
    }

    function envFlagOrDefaultHarness(string memory envName, bool defaultValue) external view returns (bool) {
        return _envFlagOrDefault(envName, defaultValue);
    }

    function defaultRobinhoodTestnetStockTokensHarness()
        external
        pure
        returns (address tsla, address amzn, address pltr, address nflx, address amd)
    {
        return (
            ROBINHOOD_TESTNET_TSLA_TOKEN,
            ROBINHOOD_TESTNET_AMZN_TOKEN,
            ROBINHOOD_TESTNET_PLTR_TOKEN,
            ROBINHOOD_TESTNET_NFLX_TOKEN,
            ROBINHOOD_TESTNET_AMD_TOKEN
        );
    }

    function currentDeploymentAddressHarness(string memory deploymentName) external view returns (address) {
        bytes32 deploymentNameHash = keccak256(bytes(deploymentName));
        for (uint256 i = deployments.length; i > 0; i--) {
            Deployment memory deployment = deployments[i - 1];
            if (keccak256(bytes(deployment.name)) == deploymentNameHash) {
                return deployment.addr;
            }
        }
        return address(0);
    }

    function validateProductionBootstrapHolder(address holder) external view {
        _validateProductionBootstrapHolder(
            holder,
            holder.codehash,
            _readMasterCopy(holder),
            _readThreshold(holder),
            _readOwnersHash(holder),
            address(0),
            address(0),
            address(0)
        );
    }

    function validateProductionBootstrapHolderPinned(
        address holder,
        bytes32 expectedCodehash,
        address expectedSingleton,
        uint256 expectedThreshold,
        bytes32 expectedOwnersHash
    ) external view {
        _validateProductionBootstrapHolder(
            holder,
            expectedCodehash,
            expectedSingleton,
            expectedThreshold,
            expectedOwnersHash,
            address(0),
            address(0),
            address(0)
        );
    }

    function validateProductionBootstrapHolderPinnedExtensions(
        address holder,
        bytes32 expectedCodehash,
        address expectedSingleton,
        uint256 expectedThreshold,
        bytes32 expectedOwnersHash,
        address expectedGuard,
        address expectedFallbackHandler,
        address expectedModuleGuard
    ) external view {
        _validateProductionBootstrapHolder(
            holder,
            expectedCodehash,
            expectedSingleton,
            expectedThreshold,
            expectedOwnersHash,
            expectedGuard,
            expectedFallbackHandler,
            expectedModuleGuard
        );
    }

    function validateProductionPythConfig(address pythAddress, uint256 maxPriceAge, bool updaterConfirmed)
        external
        view
    {
        _validateProductionPythConfig(pythAddress, maxPriceAge, updaterConfirmed);
    }

    function finalizeProductionProtocolBootstrapHarness(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address pythOracleAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr,
        address bootstrapAdmin
    ) external {
        _pinProductionProtocolCodehashesForHarness(factoryImplementationAddr, poolImplementationAddr, pythOracleAddr);
        _finalizeProductionProtocolBootstrap(
            ProtocolDeployment({
                factoryAddr: factoryAddr,
                factoryImplementationAddr: factoryImplementationAddr,
                poolImplementationAddr: poolImplementationAddr,
                compositeOracleAddr: compositeOracleAddr,
                pythOracleAddr: pythOracleAddr,
                chainlinkOracleFeedAddr: address(0),
                erc4626OracleFeedAddr: erc4626OracleFeedAddr,
                timelockAddr: timelockAddr,
                governorAddr: governorAddr
            }),
            bootstrapAdmin
        );
    }

    function validateProductionProtocolFinalizedHarness(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address pythOracleAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr
    ) external {
        _pinProductionProtocolCodehashesForHarness(factoryImplementationAddr, poolImplementationAddr, pythOracleAddr);
        _validateProductionProtocolFinalized(
            ProtocolDeployment({
                factoryAddr: factoryAddr,
                factoryImplementationAddr: factoryImplementationAddr,
                poolImplementationAddr: poolImplementationAddr,
                compositeOracleAddr: compositeOracleAddr,
                pythOracleAddr: pythOracleAddr,
                chainlinkOracleFeedAddr: address(0),
                erc4626OracleFeedAddr: erc4626OracleFeedAddr,
                timelockAddr: timelockAddr,
                governorAddr: governorAddr
            })
        );
    }

    function validateProductionProtocolFinalizedWithExpectedPythCodehashHarness(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address pythOracleAddr,
        address expectedPythOracleCodehashAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr
    ) external {
        _pinProductionProtocolCodehashesForHarness(
            factoryImplementationAddr, poolImplementationAddr, expectedPythOracleCodehashAddr
        );
        _validateProductionProtocolFinalized(
            ProtocolDeployment({
                factoryAddr: factoryAddr,
                factoryImplementationAddr: factoryImplementationAddr,
                poolImplementationAddr: poolImplementationAddr,
                compositeOracleAddr: compositeOracleAddr,
                pythOracleAddr: pythOracleAddr,
                chainlinkOracleFeedAddr: address(0),
                erc4626OracleFeedAddr: erc4626OracleFeedAddr,
                timelockAddr: timelockAddr,
                governorAddr: governorAddr
            })
        );
    }

    function finalizeProductionChainlinkProtocolBootstrapHarness(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address chainlinkOracleFeedAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr,
        address bootstrapAdmin
    ) external {
        _pinProductionChainlinkProtocolCodehashesForHarness(
            factoryImplementationAddr, poolImplementationAddr, chainlinkOracleFeedAddr
        );
        _finalizeProductionProtocolBootstrap(
            ProtocolDeployment({
                factoryAddr: factoryAddr,
                factoryImplementationAddr: factoryImplementationAddr,
                poolImplementationAddr: poolImplementationAddr,
                compositeOracleAddr: compositeOracleAddr,
                pythOracleAddr: address(0),
                chainlinkOracleFeedAddr: chainlinkOracleFeedAddr,
                erc4626OracleFeedAddr: erc4626OracleFeedAddr,
                timelockAddr: timelockAddr,
                governorAddr: governorAddr
            }),
            bootstrapAdmin
        );
    }

    function seedRobinhoodTestnetDemoAssetsHarness(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address chainlinkOracleFeedAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr
    ) external {
        deployer = address(this);
        _seedRobinhoodTestnetDemoAssets(
            ProtocolDeployment({
                factoryAddr: factoryAddr,
                factoryImplementationAddr: factoryImplementationAddr,
                poolImplementationAddr: poolImplementationAddr,
                compositeOracleAddr: compositeOracleAddr,
                pythOracleAddr: address(0),
                chainlinkOracleFeedAddr: chainlinkOracleFeedAddr,
                erc4626OracleFeedAddr: erc4626OracleFeedAddr,
                timelockAddr: timelockAddr,
                governorAddr: governorAddr
            })
        );
    }

    function validateProductionChainlinkProtocolFinalizedHarness(
        address factoryAddr,
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address compositeOracleAddr,
        address chainlinkOracleFeedAddr,
        address erc4626OracleFeedAddr,
        address timelockAddr,
        address governorAddr
    ) external {
        _pinProductionChainlinkProtocolCodehashesForHarness(
            factoryImplementationAddr, poolImplementationAddr, chainlinkOracleFeedAddr
        );
        _validateProductionProtocolFinalized(
            ProtocolDeployment({
                factoryAddr: factoryAddr,
                factoryImplementationAddr: factoryImplementationAddr,
                poolImplementationAddr: poolImplementationAddr,
                compositeOracleAddr: compositeOracleAddr,
                pythOracleAddr: address(0),
                chainlinkOracleFeedAddr: chainlinkOracleFeedAddr,
                erc4626OracleFeedAddr: erc4626OracleFeedAddr,
                timelockAddr: timelockAddr,
                governorAddr: governorAddr
            })
        );
    }

    function _pinProductionProtocolCodehashesForHarness(
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address pythOracleCodehashAddr
    ) internal {
        expectedFactoryImplementationCodehash = factoryImplementationAddr.codehash;
        expectedPoolImplementationCodehash = poolImplementationAddr.codehash;
        expectedPythOracleCodehash = pythOracleCodehashAddr.codehash;
    }

    function _pinProductionChainlinkProtocolCodehashesForHarness(
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address chainlinkOracleCodehashAddr
    ) internal {
        expectedFactoryImplementationCodehash = factoryImplementationAddr.codehash;
        expectedPoolImplementationCodehash = poolImplementationAddr.codehash;
        expectedChainlinkOracleCodehash = chainlinkOracleCodehashAddr.codehash;
    }

    function _readRequiredProductionCodehash(bytes32 name, string memory envName)
        internal
        view
        override
        returns (bytes32 codehash)
    {
        if (name == bytes32("FactoryImplementation") && expectedFactoryImplementationCodehash != bytes32(0)) {
            return expectedFactoryImplementationCodehash;
        }
        if (name == bytes32("PoolImplementation") && expectedPoolImplementationCodehash != bytes32(0)) {
            return expectedPoolImplementationCodehash;
        }
        if (name == bytes32("PythOracle") && expectedPythOracleCodehash != bytes32(0)) {
            return expectedPythOracleCodehash;
        }
        if (name == bytes32("ChainlinkOracleFeed") && expectedChainlinkOracleCodehash != bytes32(0)) {
            return expectedChainlinkOracleCodehash;
        }

        return super._readRequiredProductionCodehash(name, envName);
    }

    function requireProductionPythOracleCodehashHarness(address pythOracleAddr, string memory envName) external view {
        _requireMandatoryProductionCodehash(bytes32("PythOracle"), pythOracleAddr, envName);
    }

    function requireProductionFactoryImplementationCodehashHarness(
        address factoryImplementationAddr,
        string memory envName
    ) external view {
        _requireMandatoryProductionCodehash(bytes32("FactoryImplementation"), factoryImplementationAddr, envName);
    }

    function requireProductionPoolImplementationCodehashHarness(address poolImplementationAddr, string memory envName)
        external
        view
    {
        _requireMandatoryProductionCodehash(bytes32("PoolImplementation"), poolImplementationAddr, envName);
    }

    function requireProductionChainlinkOracleCodehashHarness(address chainlinkOracleAddr, string memory envName)
        external
        view
    {
        _requireMandatoryProductionCodehash(bytes32("ChainlinkOracleFeed"), chainlinkOracleAddr, envName);
    }

    function deployGovernanceWithRelaxedTestnetGuardsHarness()
        external
        returns (YSToken ysToken, TimelockController timelock, YSGovernor governor, address bootstrapHolder)
    {
        deployer = address(this);
        address ysTokenAddr;
        address timelockAddr;
        address governorAddr;
        (ysTokenAddr, timelockAddr, governorAddr, bootstrapHolder) = deployGovernance();
        ysToken = YSToken(ysTokenAddr);
        timelock = TimelockController(payable(timelockAddr));
        governor = YSGovernor(payable(governorAddr));
    }

    function requiresStrictProductionGuardsHarness() external view returns (bool) {
        return _requiresStrictProductionGuards();
    }

    function setStrictProductionGuardsOverrideHarness(bool value) external {
        strictProductionGuardsOverrideSet = true;
        strictProductionGuardsOverride = value;
    }

    function _requiresStrictProductionGuards() internal view override returns (bool) {
        if (strictProductionGuardsOverrideSet) {
            return strictProductionGuardsOverride;
        }

        return super._requiresStrictProductionGuards();
    }

    function _readMasterCopy(address holder) internal view returns (address singleton) {
        (bool success, bytes memory data) = holder.staticcall(abi.encodeWithSignature("masterCopy()"));
        if (success && data.length >= 32) {
            singleton = abi.decode(data, (address));
        }
    }

    function _readThreshold(address holder) internal view returns (uint256 threshold) {
        (bool success, bytes memory data) = holder.staticcall(abi.encodeWithSignature("getThreshold()"));
        if (success && data.length >= 32) {
            threshold = abi.decode(data, (uint256));
        }
    }

    function _readOwnersHash(address holder) internal view returns (bytes32 ownersHash) {
        (bool success, bytes memory data) = holder.staticcall(abi.encodeWithSignature("getOwners()"));
        if (success && data.length >= 64) {
            ownersHash = keccak256(abi.encode(abi.decode(data, (address[]))));
        }
    }
}

contract ContractBootstrapHolder { }

contract CodeButNotPyth { }

contract FakeProductionOwnableOracle {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function transferOwnership(address newOwner) external {
        owner = newOwner;
    }
}

contract ZeroValidTimePeriodPyth {
    function getValidTimePeriod() external pure returns (uint256) {
        return 0;
    }
}

contract SelectorsOnlyBootstrapHolder {
    address[] internal owners;
    uint256 internal threshold;

    constructor(address[] memory owners_, uint256 threshold_) {
        owners = owners_;
        threshold = threshold_;
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }
}

contract SafeLikeBootstrapHolder {
    address internal constant SAFE_SINGLETON = address(0x5AFE);
    address internal constant SENTINEL_MODULES = address(0x1);
    bytes32 internal constant SAFE_GUARD_STORAGE_SLOT =
        0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 internal constant SAFE_FALLBACK_HANDLER_STORAGE_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;
    bytes32 internal constant SAFE_MODULE_GUARD_STORAGE_SLOT =
        0xb104e0b93118902c651344349b610029d694cfdec91c589c91ebafbcd0289947;
    address[] internal owners;
    address[] internal modules;
    uint256 internal threshold;
    uint256 internal safeNonce;
    bytes32 internal safeDomainSeparator;
    address internal safeGuard;
    address internal safeFallbackHandler;
    address internal safeModuleGuard;

    constructor(address[] memory owners_, uint256 threshold_) {
        owners = owners_;
        threshold = threshold_;
        safeDomainSeparator = keccak256(abi.encodePacked(address(this), owners_.length, threshold_));
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function VERSION() external pure returns (string memory) {
        return "1.4.1";
    }

    function nonce() external view returns (uint256) {
        return safeNonce;
    }

    function domainSeparator() external view returns (bytes32) {
        return safeDomainSeparator;
    }

    function masterCopy() external pure returns (address) {
        return SAFE_SINGLETON;
    }

    function addModule(address module) external {
        modules.push(module);
    }

    function setGuard(address guard) external {
        safeGuard = guard;
    }

    function setFallbackHandler(address fallbackHandler) external {
        safeFallbackHandler = fallbackHandler;
    }

    function setModuleGuard(address moduleGuard) external {
        safeModuleGuard = moduleGuard;
    }

    function getModulesPaginated(address, uint256 pageSize)
        external
        view
        returns (address[] memory page, address next)
    {
        if (modules.length == 0 || pageSize == 0) {
            return (new address[](0), SENTINEL_MODULES);
        }

        uint256 pageLength = modules.length < pageSize ? modules.length : pageSize;
        page = new address[](pageLength);
        for (uint256 i = 0; i < pageLength; i++) {
            page[i] = modules[i];
        }
        next = pageLength == modules.length ? SENTINEL_MODULES : modules[pageLength - 1];
    }

    function getStorageAt(uint256 offset, uint256 length) external view returns (bytes memory data) {
        if (length == 0) {
            return new bytes(0);
        }

        bytes32 slot = bytes32(offset);
        if (slot == SAFE_GUARD_STORAGE_SLOT) {
            return abi.encodePacked(bytes32(uint256(uint160(safeGuard))));
        }
        if (slot == SAFE_FALLBACK_HANDLER_STORAGE_SLOT) {
            return abi.encodePacked(bytes32(uint256(uint160(safeFallbackHandler))));
        }
        if (slot == SAFE_MODULE_GUARD_STORAGE_SLOT) {
            return abi.encodePacked(bytes32(uint256(uint160(safeModuleGuard))));
        }

        return new bytes(32);
    }
}

contract DeploymentSecurityTest is Test, FactoryProxyTestBase {
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    string internal constant ENV_FACTORY_IMPLEMENTATION_CODEHASH = "YS_PRODUCTION_FACTORY_IMPLEMENTATION_CODEHASH";
    string internal constant ENV_POOL_IMPLEMENTATION_CODEHASH = "YS_PRODUCTION_POOL_IMPLEMENTATION_CODEHASH";
    string internal constant ENV_PYTH_ORACLE_CODEHASH = "YS_PRODUCTION_PYTH_ORACLE_CODEHASH";
    string internal constant ENV_CHAINLINK_ORACLE_CODEHASH = "YS_PRODUCTION_CHAINLINK_ORACLE_CODEHASH";
    uint256 internal constant TIMELOCK_DELAY = 2 days;
    uint256 internal constant ROBINHOOD_MAINNET_CHAIN_ID = 4_663;
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46_630;

    address internal deployer = address(this);
    address internal bootstrapHolder = address(0xB0057);
    address internal dummyPyth = address(0x1234);

    function _proxyImplementation(address proxy) internal view returns (address implementation) {
        implementation = address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function test_ProductionBootstrap_AssignsSupplyAndClearsExternalAdmins() public {
        (YSToken ysToken, TimelockController timelock, YSGovernor governor) = _deployGovernance();

        assertEq(ysToken.balanceOf(bootstrapHolder), ysToken.INITIAL_SUPPLY());
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), bootstrapHolder));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        _assertSoleSelfAdmin(timelock);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
    }

    function test_ProductionBootstrap_CanReachProposalThresholdAfterDelegation() public {
        (YSToken ysToken,, YSGovernor governor) = _deployGovernance();

        vm.prank(bootstrapHolder);
        ysToken.delegate(bootstrapHolder);
        vm.warp(block.timestamp + 1);

        assertGe(ysToken.getVotes(bootstrapHolder), governor.proposalThreshold());
    }

    function test_TimelockRejectsExternalDefaultAdminGrant() public {
        (, TimelockController timelock,) = _deployGovernance();
        address attacker = address(0xBEEF);
        bytes32 defaultAdminRole = timelock.DEFAULT_ADMIN_ROLE();

        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(YSTimelockController.DefaultAdminMustBeTimelock.selector, attacker));
        timelock.grantRole(defaultAdminRole, attacker);
    }

    function test_TimelockRejectsSelfDefaultAdminRevocation() public {
        (, TimelockController timelock,) = _deployGovernance();
        bytes32 defaultAdminRole = timelock.DEFAULT_ADMIN_ROLE();

        vm.prank(address(timelock));
        vm.expectRevert(YSTimelockController.TimelockDefaultAdminCannotBeRevoked.selector);
        timelock.revokeRole(defaultAdminRole, address(timelock));

        vm.prank(address(timelock));
        vm.expectRevert(YSTimelockController.TimelockDefaultAdminCannotBeRevoked.selector);
        timelock.renounceRole(defaultAdminRole, address(timelock));
    }

    function test_TimelockRejectsSelfManagingOperationalRoles() public {
        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        address attacker = address(0xBEEF);

        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(YSTimelockController.TimelockOperationalRoleFrozen.selector, proposerRole, attacker)
        );
        timelock.grantRole(proposerRole, attacker);

        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                YSTimelockController.TimelockOperationalRoleFrozen.selector, proposerRole, address(governor)
            )
        );
        timelock.revokeRole(proposerRole, address(governor));

        vm.prank(address(governor));
        vm.expectRevert(
            abi.encodeWithSelector(
                YSTimelockController.TimelockOperationalRoleFrozen.selector, proposerRole, address(governor)
            )
        );
        timelock.renounceRole(proposerRole, address(governor));
    }

    function test_TimelockCanRotateGovernanceControllerAtomically() public {
        (YSToken ysToken, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        YSTimelockController ysTimelock = YSTimelockController(payable(address(timelock)));
        YSGovernor newGovernor = new YSGovernor(IVotes(address(ysToken)), timelock, address(0));

        vm.prank(address(timelock));
        ysTimelock.rotateGovernanceController(address(newGovernor));

        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(governor)));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(newGovernor)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(newGovernor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(newGovernor)));
    }

    function test_TimelockControllerRotationRejectsEOA() public {
        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        YSTimelockController ysTimelock = YSTimelockController(payable(address(timelock)));
        address eoaController = address(0xA11CE);

        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                YSTimelockController.GovernanceControllerRotationInvalid.selector, address(0), eoaController
            )
        );
        ysTimelock.rotateGovernanceController(eoaController);

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
    }

    function test_TimelockControllerRotationRejectsNonGovernorContract() public {
        (YSToken ysToken, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        YSTimelockController ysTimelock = YSTimelockController(payable(address(timelock)));

        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                YSTimelockController.GovernanceControllerRotationInvalid.selector, address(0), address(ysToken)
            )
        );
        ysTimelock.rotateGovernanceController(address(ysToken));

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
    }

    function test_TimelockControllerRotationRejectsGovernorForDifferentTimelock() public {
        (YSToken ysToken, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        (, TimelockController otherTimelock,) = _deployGovernance();
        YSTimelockController ysTimelock = YSTimelockController(payable(address(timelock)));
        YSGovernor wrongGovernor = new YSGovernor(IVotes(address(ysToken)), otherTimelock, address(0));

        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                YSTimelockController.GovernanceControllerRotationInvalid.selector, address(0), address(wrongGovernor)
            )
        );
        ysTimelock.rotateGovernanceController(address(wrongGovernor));

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
    }

    function test_GovernorConstructorRejectsNonYSTimelock() public {
        address[] memory emptyAccounts = new address[](0);
        TimelockController ozTimelock = new TimelockController(TIMELOCK_DELAY, emptyAccounts, emptyAccounts, deployer);
        YSToken ysToken = new YSToken(bootstrapHolder);
        bytes32 expectedCodehash = keccak256(type(YSTimelockController).runtimeCode);

        vm.expectRevert(
            abi.encodeWithSelector(
                YSGovernor.GovernorTimelockImplementationMismatch.selector,
                address(ozTimelock),
                expectedCodehash,
                address(ozTimelock).codehash
            )
        );
        new YSGovernor(IVotes(address(ysToken)), ozTimelock, deployer);
    }

    function test_GovernorConstructorRejectsUnexpectedBootstrapAdmin() public {
        address attacker = address(0xBEEF);
        address[] memory emptyAccounts = new address[](0);
        TimelockController timelock = TimelockController(
            payable(address(new YSTimelockController(TIMELOCK_DELAY, emptyAccounts, emptyAccounts, attacker)))
        );
        YSToken ysToken = new YSToken(bootstrapHolder);

        vm.expectRevert(
            abi.encodeWithSelector(
                YSGovernor.GovernorTimelockInvalidInitialAdmin.selector, address(timelock), deployer, attacker, 2
            )
        );
        new YSGovernor(IVotes(address(ysToken)), timelock, deployer);
    }

    function test_GovernorConstructorRejectsEOAOperationalController() public {
        address attacker = address(0xBEEF);
        address[] memory controllers = new address[](1);
        controllers[0] = attacker;
        TimelockController timelock = TimelockController(
            payable(address(new YSTimelockController(TIMELOCK_DELAY, controllers, controllers, deployer)))
        );
        YSToken ysToken = new YSToken(bootstrapHolder);

        vm.expectRevert(
            abi.encodeWithSelector(
                YSGovernor.GovernorTimelockInvalidInitialController.selector, address(timelock), attacker
            )
        );
        new YSGovernor(IVotes(address(ysToken)), timelock, deployer);
    }

    function test_GovernorConstructorRejectsShortPublicTimelockDelay() public {
        address[] memory emptyAccounts = new address[](0);
        vm.chainId(31337);
        TimelockController timelock = TimelockController(
            payable(address(new YSTimelockController(1 days, emptyAccounts, emptyAccounts, deployer)))
        );
        YSToken ysToken = new YSToken(bootstrapHolder);

        vm.chainId(PythConfig.ARBITRUM_MAINNET_CHAIN_ID);
        vm.expectRevert(
            abi.encodeWithSelector(YSGovernor.GovernorTimelockDelayTooShort.selector, address(timelock), 1 days, 2 days)
        );
        new YSGovernor(IVotes(address(ysToken)), timelock, deployer);
        vm.chainId(31337);
    }

    function test_ProductionBootstrap_RejectsEOABootstrapHolder() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolder.selector, bootstrapHolder
            )
        );
        harness.validateProductionBootstrapHolder(bootstrapHolder);
    }

    function test_ProductionBootstrap_RejectsInertContractBootstrapHolder() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        ContractBootstrapHolder contractHolder = new ContractBootstrapHolder();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolderSingleton.selector,
                address(contractHolder),
                address(0),
                address(0)
            )
        );
        harness.validateProductionBootstrapHolder(address(contractHolder));
    }

    function test_ProductionBootstrap_AllowsSafeLikeBootstrapHolder() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);

        harness.validateProductionBootstrapHolder(address(contractHolder));
    }

    function test_ProductionBootstrap_RejectsWrongBootstrapHolderCodehash() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);
        bytes32 wrongCodehash = keccak256("wrong bootstrap holder codehash");
        address expectedSingleton = contractHolder.masterCopy();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolderCodehash.selector,
                address(contractHolder),
                address(contractHolder).codehash,
                wrongCodehash
            )
        );
        harness.validateProductionBootstrapHolderPinned(
            address(contractHolder), wrongCodehash, expectedSingleton, 2, keccak256(abi.encode(owners))
        );
    }

    function test_ProductionBootstrap_RejectsWrongBootstrapHolderSingleton() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolderSingleton.selector,
                address(contractHolder),
                contractHolder.masterCopy(),
                address(0xBAD)
            )
        );
        harness.validateProductionBootstrapHolderPinned(
            address(contractHolder), address(contractHolder).codehash, address(0xBAD), 2, keccak256(abi.encode(owners))
        );
    }

    function test_ProductionBootstrap_RejectsWrongBootstrapHolderThreshold() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);
        address expectedSingleton = contractHolder.masterCopy();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolderThreshold.selector,
                address(contractHolder),
                2,
                3
            )
        );
        harness.validateProductionBootstrapHolderPinned(
            address(contractHolder),
            address(contractHolder).codehash,
            expectedSingleton,
            3,
            keccak256(abi.encode(owners))
        );
    }

    function test_ProductionBootstrap_RejectsNonMajorityBootstrapHolderThreshold() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](4);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        owners[2] = address(0xCAFE);
        owners[3] = address(0xDAD);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolderThresholdRatio.selector,
                address(contractHolder),
                2,
                owners.length
            )
        );
        harness.validateProductionBootstrapHolder(address(contractHolder));
    }

    function test_ProductionBootstrap_RejectsWrongBootstrapHolderOwnersHash() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);
        address expectedSingleton = contractHolder.masterCopy();
        bytes32 wrongOwnersHash = keccak256("wrong owners hash");

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolderOwnersHash.selector,
                address(contractHolder),
                keccak256(abi.encode(owners)),
                wrongOwnersHash
            )
        );
        harness.validateProductionBootstrapHolderPinned(
            address(contractHolder), address(contractHolder).codehash, expectedSingleton, 2, wrongOwnersHash
        );
    }

    function test_ProductionBootstrap_RejectsSafeLikeHolderWithInvalidThreshold() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](1);
        owners[0] = address(0xA11CE);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolder.selector, address(contractHolder)
            )
        );
        harness.validateProductionBootstrapHolder(address(contractHolder));
    }

    function test_ProductionBootstrap_RejectsSelectorOnlyBootstrapHolder() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        SelectorsOnlyBootstrapHolder contractHolder = new SelectorsOnlyBootstrapHolder(owners, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolderSingleton.selector,
                address(contractHolder),
                address(0),
                address(0)
            )
        );
        harness.validateProductionBootstrapHolder(address(contractHolder));
    }

    function test_ProductionBootstrap_RejectsDuplicateOwnerSafeLikeHolder() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xA11CE);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolder.selector, address(contractHolder)
            )
        );
        harness.validateProductionBootstrapHolder(address(contractHolder));
    }

    function test_ProductionBootstrap_RejectsSafeLikeHolderWithEnabledModule() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);
        address module = address(0xCA11);
        contractHolder.addModule(module);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolderModule.selector,
                address(contractHolder),
                module
            )
        );
        harness.validateProductionBootstrapHolder(address(contractHolder));
    }

    function test_ProductionBootstrap_RejectsSafeLikeHolderWithUnexpectedGuard() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);
        address guard = address(0x6A4D);
        contractHolder.setGuard(guard);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolderGuard.selector,
                address(contractHolder),
                guard,
                address(0)
            )
        );
        harness.validateProductionBootstrapHolder(address(contractHolder));
    }

    function test_ProductionBootstrap_RejectsSafeLikeHolderWithUnexpectedFallbackHandler() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);
        address fallbackHandler = address(0xFA11BA);
        contractHolder.setFallbackHandler(fallbackHandler);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolderFallbackHandler.selector,
                address(contractHolder),
                fallbackHandler,
                address(0)
            )
        );
        harness.validateProductionBootstrapHolder(address(contractHolder));
    }

    function test_ProductionBootstrap_RejectsSafeLikeHolderWithUnexpectedModuleGuard() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);
        address moduleGuard = address(0xD00D);
        contractHolder.setModuleGuard(moduleGuard);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionBootstrapHolderModuleGuard.selector,
                address(contractHolder),
                moduleGuard,
                address(0)
            )
        );
        harness.validateProductionBootstrapHolder(address(contractHolder));
    }

    function test_ProductionBootstrap_AllowsPinnedSafeLikeHolderExtensions() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address[] memory owners = new address[](2);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        SafeLikeBootstrapHolder contractHolder = new SafeLikeBootstrapHolder(owners, 2);
        address guard = address(0x6A4D);
        address fallbackHandler = address(0xFA11BA);
        address moduleGuard = address(0xD00D);
        contractHolder.setGuard(guard);
        contractHolder.setFallbackHandler(fallbackHandler);
        contractHolder.setModuleGuard(moduleGuard);

        harness.validateProductionBootstrapHolderPinnedExtensions(
            address(contractHolder),
            address(contractHolder).codehash,
            contractHolder.masterCopy(),
            2,
            keccak256(abi.encode(owners)),
            guard,
            fallbackHandler,
            moduleGuard
        );
    }

    function test_ProductionBootstrap_BurnCannotBreakProposalReachability() public {
        (YSToken ysToken,, YSGovernor governor) = _deployGovernance();
        uint256 belowQuorumSupply = ysToken.MIN_GOVERNANCE_SUPPLY() - 1;
        uint256 burnAmount = ysToken.INITIAL_SUPPLY() - belowQuorumSupply;

        vm.prank(bootstrapHolder);
        vm.expectRevert(
            abi.encodeWithSelector(
                YSToken.BurnWouldReduceSupplyBelowGovernanceQuorum.selector,
                belowQuorumSupply,
                ysToken.MIN_GOVERNANCE_SUPPLY()
            )
        );
        ysToken.burn(burnAmount);

        assertEq(
            governor.MAX_GOVERNOR_PROPOSAL_THRESHOLD(),
            ysToken.MIN_GOVERNANCE_SUPPLY(),
            "burn floor must match the maximum configurable proposal threshold"
        );
        assertLe(governor.proposalThreshold(), ysToken.MIN_GOVERNANCE_SUPPLY());
    }

    function test_ProductionPythConfig_RejectsNoCodePythContract() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        address missingPyth = address(0x1234);

        vm.expectRevert(
            abi.encodeWithSelector(DeployYieldShieldProduction.InvalidProductionPythContract.selector, missingPyth)
        );
        harness.validateProductionPythConfig(missingPyth, PythConfig.DEFAULT_ARBITRUM_MAINNET_MAX_PRICE_AGE, true);
    }

    function test_ProductionPythConfig_RejectsContractWithoutPythInterface() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        CodeButNotPyth notPyth = new CodeButNotPyth();

        vm.expectRevert(
            abi.encodeWithSelector(DeployYieldShieldProduction.InvalidProductionPythContract.selector, address(notPyth))
        );
        harness.validateProductionPythConfig(address(notPyth), PythConfig.DEFAULT_ARBITRUM_MAINNET_MAX_PRICE_AGE, true);
    }

    function test_ProductionPythConfig_RejectsZeroValidTimePeriod() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        ZeroValidTimePeriodPyth notUsablePyth = new ZeroValidTimePeriodPyth();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.InvalidProductionPythContract.selector, address(notUsablePyth)
            )
        );
        harness.validateProductionPythConfig(
            address(notUsablePyth), PythConfig.DEFAULT_ARBITRUM_MAINNET_MAX_PRICE_AGE, true
        );
    }

    function test_ProductionPythConfig_RequiresMainnetUpdaterConfirmation() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        MockPyth mockPyth = new MockPyth(60, 1);
        vm.chainId(PythConfig.ARBITRUM_MAINNET_CHAIN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionPythUpdaterNotConfirmed.selector,
                PythConfig.ARBITRUM_MAINNET_CHAIN_ID,
                PythConfig.DEFAULT_ARBITRUM_MAINNET_MAX_PRICE_AGE
            )
        );
        harness.validateProductionPythConfig(
            address(mockPyth), PythConfig.DEFAULT_ARBITRUM_MAINNET_MAX_PRICE_AGE, false
        );
    }

    function test_ProductionPythConfig_AllowsConfirmedMainnetUpdater() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        MockPyth mockPyth = new MockPyth(60, 1);
        vm.chainId(PythConfig.ARBITRUM_MAINNET_CHAIN_ID);

        harness.validateProductionPythConfig(address(mockPyth), PythConfig.DEFAULT_ARBITRUM_MAINNET_MAX_PRICE_AGE, true);
    }

    function test_ProductionPythConfig_AllowsSepoliaWithoutUpdaterConfirmation() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        MockPyth mockPyth = new MockPyth(3600, 1);
        vm.chainId(PythConfig.ARBITRUM_SEPOLIA_CHAIN_ID);

        harness.validateProductionPythConfig(
            address(mockPyth), PythConfig.DEFAULT_ARBITRUM_SEPOLIA_MAX_PRICE_AGE, false
        );
    }

    function test_ProductionProtocol_RoutesOracleOwnershipThroughFactoryGovernance() public {
        (, TimelockController timelock,) = _deployGovernance();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        _pinPythOracleCodehash(address(pythOracle));
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImplementation));

        compositeOracle.transferOwnership(address(factory));
        factory.setCompositeOracle(address(compositeOracle));
        factory.setDefaultProtocolFeeRecipient(address(timelock));

        pythOracle.transferOwnership(address(factory));
        erc4626OracleFeed.transferOwnership(address(factory));
        factory.setManagedPythOracle(address(pythOracle));
        factory.setManagedERC4626OracleFeed(address(erc4626OracleFeed));
        factory.finalizeBootstrap();
        factory.transferOwnership(address(timelock));

        assertEq(factory.owner(), address(timelock));
        assertFalse(factory.bootstrapModeEnabled());
        assertEq(compositeOracle.owner(), address(factory));
        assertEq(pythOracle.owner(), address(factory));
        assertEq(erc4626OracleFeed.owner(), address(factory));
        assertEq(factory.pythOracle(), address(pythOracle));
        assertEq(factory.erc4626OracleFeed(), address(erc4626OracleFeed));

        bytes32 feedId = keccak256("feed");
        address token = address(0xCAFE);
        vm.prank(address(timelock));
        factory.setPythTokenPriceFeed(token, feedId);
        assertEq(pythOracle.tokenToPriceFeedId(token), feedId);

        vm.prank(address(timelock));
        factory.setPythMaxPriceAgeForToken(token, 86_400);
        assertEq(pythOracle.maxPriceAgeForToken(token), 86_400);

        vm.prank(address(timelock));
        factory.schedulePythTokenRemoval(token);
        assertEq(pythOracle.scheduledTokenRemovalTime(token), block.timestamp + pythOracle.TOKEN_REMOVAL_DELAY());

        vm.warp(block.timestamp + pythOracle.TOKEN_REMOVAL_DELAY());

        vm.prank(address(timelock));
        factory.removePythToken(token);
        assertFalse(pythOracle.isTokenSupported(token));
        assertEq(pythOracle.tokenToPriceFeedId(token), bytes32(0));
        assertEq(pythOracle.maxPriceAgeForToken(token), 0);
    }

    function test_ProductionProtocol_FinalizerResumesPartialBootstrapAndIsIdempotent() public {
        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        _pinPythOracleCodehash(address(pythOracle));
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));
        address directOracleCaller = address(0xCA11);
        _pinProductionProtocolCodehashes(
            _proxyImplementation(address(factory)), address(poolImplementation), address(pythOracle)
        );

        compositeOracle.setAuthorizedCaller(directOracleCaller, true);
        compositeOracle.transferOwnership(address(harness));
        pythOracle.transferOwnership(address(harness));
        erc4626OracleFeed.transferOwnership(address(harness));

        harness.finalizeProductionProtocolBootstrapHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(pythOracle),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor),
            address(harness)
        );
        harness.validateProductionProtocolFinalizedHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(pythOracle),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor)
        );

        assertEq(factory.owner(), address(timelock));
        assertFalse(factory.bootstrapModeEnabled());
        assertEq(compositeOracle.owner(), address(factory));
        assertEq(pythOracle.owner(), address(factory));
        assertEq(erc4626OracleFeed.owner(), address(factory));
        assertEq(factory.compositeOracle(), address(compositeOracle));
        assertEq(factory.defaultProtocolFeeRecipient(), address(timelock));
        assertEq(factory.pythOracle(), address(pythOracle));
        assertEq(factory.erc4626OracleFeed(), address(erc4626OracleFeed));
        assertFalse(compositeOracle.authorizedCallers(directOracleCaller));
        assertEq(compositeOracle.authorizedCallerCount(), 0);

        harness.finalizeProductionProtocolBootstrapHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(pythOracle),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor),
            address(harness)
        );
        harness.validateProductionProtocolFinalizedHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(pythOracle),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor)
        );
    }

    function test_ProductionProtocol_FinalizerSupportsChainlinkNativeBootstrap() public {
        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        ChainlinkOracleFeed chainlinkOracleFeed = new ChainlinkOracleFeed(86_400);
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(chainlinkOracleFeed));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));

        compositeOracle.transferOwnership(address(harness));
        chainlinkOracleFeed.transferOwnership(address(harness));
        erc4626OracleFeed.transferOwnership(address(harness));

        harness.finalizeProductionChainlinkProtocolBootstrapHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(chainlinkOracleFeed),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor),
            address(harness)
        );
        harness.validateProductionChainlinkProtocolFinalizedHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(chainlinkOracleFeed),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor)
        );

        assertEq(factory.owner(), address(timelock));
        assertFalse(factory.bootstrapModeEnabled());
        assertEq(compositeOracle.owner(), address(factory));
        assertEq(chainlinkOracleFeed.owner(), address(timelock));
        assertEq(erc4626OracleFeed.owner(), address(factory));
        assertEq(factory.compositeOracle(), address(compositeOracle));
        assertEq(factory.defaultProtocolFeeRecipient(), address(timelock));
        assertEq(factory.pythOracle(), address(0));
        assertEq(factory.erc4626OracleFeed(), address(erc4626OracleFeed));
        assertEq(address(erc4626OracleFeed.underlyingPriceOracle()), address(chainlinkOracleFeed));
    }

    function test_ProductionProtocol_RobinhoodTestnetSeedCreatesPoolsAndFinalizes() public {
        vm.chainId(46_630);
        vm.setEnv("YS_ROBINHOOD_TESTNET_SEED_DEMO_ASSETS", "true");

        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        ChainlinkOracleFeed chainlinkOracleFeed = new ChainlinkOracleFeed(86_400);
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(chainlinkOracleFeed));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));

        chainlinkOracleFeed.setSequencerUptimeFeedRequired(false);
        erc4626OracleFeed.setSequencerUptimeFeedRequired(false);
        compositeOracle.transferOwnership(address(harness));
        chainlinkOracleFeed.transferOwnership(address(harness));
        erc4626OracleFeed.transferOwnership(address(harness));

        harness.seedRobinhoodTestnetDemoAssetsHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(chainlinkOracleFeed),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor)
        );

        assertEq(factory.poolCount(), 9);
        assertEq(factory.getWhitelistedTokens().length, 10);
        assertFalse(factory.bootstrapModeEnabled());
        assertEq(compositeOracle.authorizedCallerCount(), 0);

        address faucetAddr = harness.currentDeploymentAddressHarness("RobinhoodDemoAssetFaucet");
        assertTrue(faucetAddr != address(0));
        ConfigurableTokenFaucet faucet = ConfigurableTokenFaucet(faucetAddr);
        assertEq(faucet.owner(), address(harness));
        assertEq(faucet.getAllTokens().length, 5);
        assertEq(faucet.dripAmount(harness.currentDeploymentAddressHarness("RobinhoodTestUSDG")), 10_000e6);
        assertEq(faucet.dripAmount(harness.currentDeploymentAddressHarness("RobinhoodTestWETH")), 10e18);
        assertEq(faucet.dripAmount(harness.currentDeploymentAddressHarness("RobinhoodTestSGOV")), 25e18);
        assertFalse(faucet.enabledTokens(harness.currentDeploymentAddressHarness("RobinhoodTestTSLA")));

        harness.finalizeProductionChainlinkProtocolBootstrapHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(chainlinkOracleFeed),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor),
            address(harness)
        );
        harness.validateProductionChainlinkProtocolFinalizedHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(chainlinkOracleFeed),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor)
        );

        assertEq(factory.owner(), address(timelock));
        assertEq(compositeOracle.owner(), address(factory));
        assertEq(chainlinkOracleFeed.owner(), address(timelock));
        assertEq(erc4626OracleFeed.owner(), address(factory));
        assertEq(factory.poolCount(), 9);
        assertEq(factory.getWhitelistedTokens().length, 10);
    }

    function test_ConfigurableTokenFaucet_UsesPerTokenDripAmountsAndCooldowns() public {
        MockERC20Decimals usdg = new MockERC20Decimals("Robinhood Test USDG", "USDG", 6);
        MockERC20Decimals weth = new MockERC20Decimals("Robinhood Test WETH", "WETH", 18);
        ConfigurableTokenFaucet faucet = new ConfigurableTokenFaucet(address(this));

        address[] memory tokens = new address[](2);
        uint256[] memory dripAmounts = new uint256[](2);
        tokens[0] = address(usdg);
        tokens[1] = address(weth);
        dripAmounts[0] = 10_000e6;
        dripAmounts[1] = 10e18;
        faucet.setTokens(tokens, dripAmounts);

        usdg.mint(address(faucet), 100_000e6);
        weth.mint(address(faucet), 100e18);

        address recipient = address(0xBEEF);
        (bool canDrip, uint256 nextDripTime) = faucet.canDrip(address(usdg), recipient);
        assertTrue(canDrip);
        assertEq(nextDripTime, 0);

        faucet.drip(address(usdg), recipient);
        assertEq(usdg.balanceOf(recipient), 10_000e6);
        (canDrip, nextDripTime) = faucet.canDrip(address(usdg), recipient);
        assertFalse(canDrip);
        assertGt(nextDripTime, block.timestamp);

        vm.expectRevert(bytes("ConfigurableTokenFaucet: drip unavailable"));
        faucet.drip(address(usdg), recipient);

        address batchRecipient = address(0xCAFE);
        faucet.dripAll(batchRecipient);
        assertEq(usdg.balanceOf(batchRecipient), 10_000e6);
        assertEq(weth.balanceOf(batchRecipient), 10e18);
    }

    function test_ProductionProtocol_RobinhoodTestnetSeedDefaultsAndOptOutsArePinned() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();

        assertTrue(harness.envFlagOrDefaultHarness("YS_TEST_UNSET_20260709_ROBINHOOD_SEED_DEFAULT", true));
        assertFalse(harness.envFlagOrDefaultHarness("YS_TEST_UNSET_20260709_ROBINHOOD_SEED_OFF", false));

        vm.setEnv("YS_TEST_SET_20260709_ROBINHOOD_SEED_TRUE", "true");
        assertTrue(harness.envFlagOrDefaultHarness("YS_TEST_SET_20260709_ROBINHOOD_SEED_TRUE", false));

        vm.setEnv("YS_TEST_SET_20260709_ROBINHOOD_SEED_FALSE", "false");
        assertFalse(harness.envFlagOrDefaultHarness("YS_TEST_SET_20260709_ROBINHOOD_SEED_FALSE", true));
    }

    function test_ProductionProtocol_RobinhoodTestnetFaucetTokenDefaultsArePinned() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();

        (address tsla, address amzn, address pltr, address nflx, address amd) =
            harness.defaultRobinhoodTestnetStockTokensHarness();

        assertEq(tsla, 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E);
        assertEq(amzn, 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02);
        assertEq(pltr, 0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0);
        assertEq(nflx, 0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93);
        assertEq(amd, 0x71178BAc73cBeb415514eB542a8995b82669778d);
    }

    function test_ProductionProtocol_ValidationRejectsMismatchedFactoryGovernanceTimelock() public {
        (, TimelockController expectedTimelock, YSGovernor expectedGovernor) = _deployGovernance();
        (, TimelockController wrongTimelock,) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        _pinPythOracleCodehash(address(pythOracle));
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory =
            _deployFactory(address(harness), address(wrongTimelock), address(poolImplementation));
        _pinProductionProtocolCodehashes(
            _proxyImplementation(address(factory)), address(poolImplementation), address(pythOracle)
        );

        compositeOracle.transferOwnership(address(factory));
        pythOracle.transferOwnership(address(factory));
        erc4626OracleFeed.transferOwnership(address(factory));

        vm.startPrank(address(harness));
        factory.setCompositeOracle(address(compositeOracle));
        factory.setDefaultProtocolFeeRecipient(address(expectedTimelock));
        factory.setManagedPythOracle(address(pythOracle));
        factory.setManagedERC4626OracleFeed(address(erc4626OracleFeed));
        factory.finalizeBootstrap();
        factory.transferOwnership(address(expectedTimelock));
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolAddressMismatch.selector,
                bytes32("factory.governanceTimelock"),
                address(wrongTimelock),
                address(expectedTimelock)
            )
        );
        harness.validateProductionProtocolFinalizedHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(pythOracle),
            address(erc4626OracleFeed),
            address(expectedTimelock),
            address(expectedGovernor)
        );
    }

    function test_ProductionProtocol_ValidationRejectsMismatchedFactoryImplementation() public {
        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        _pinPythOracleCodehash(address(pythOracle));
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));
        SplitRiskPoolFactory wrongFactoryImplementation = new SplitRiskPoolFactory();
        _pinProductionProtocolCodehashes(
            address(wrongFactoryImplementation), address(poolImplementation), address(pythOracle)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolAddressMismatch.selector,
                bytes32("factory.proxyImplementation"),
                _proxyImplementation(address(factory)),
                address(wrongFactoryImplementation)
            )
        );
        harness.validateProductionProtocolFinalizedHarness(
            address(factory),
            address(wrongFactoryImplementation),
            address(poolImplementation),
            address(compositeOracle),
            address(pythOracle),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor)
        );
    }

    function test_ProductionProtocol_ValidationRejectsMismatchedPoolImplementation() public {
        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        _pinPythOracleCodehash(address(pythOracle));
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPool wrongPoolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));
        _pinProductionProtocolCodehashes(
            _proxyImplementation(address(factory)), address(wrongPoolImplementation), address(pythOracle)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolAddressMismatch.selector,
                bytes32("factory.poolImplementation"),
                address(poolImplementation),
                address(wrongPoolImplementation)
            )
        );
        harness.validateProductionProtocolFinalizedHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(wrongPoolImplementation),
            address(compositeOracle),
            address(pythOracle),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor)
        );
    }

    function test_ProductionProtocol_ValidationRejectsTimelockControlledByNonGovernor() public {
        (,, YSGovernor wrongController) = _deployGovernance();
        address wrongControllerAddr = address(wrongController);
        address[] memory controllers = new address[](1);
        controllers[0] = wrongControllerAddr;
        TimelockController timelock = TimelockController(
            payable(address(new YSTimelockController(TIMELOCK_DELAY, controllers, controllers, deployer)))
        );
        YSToken ysToken = new YSToken(bootstrapHolder);
        YSGovernor governor = new YSGovernor(IVotes(address(ysToken)), timelock, deployer);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        _pinPythOracleCodehash(address(pythOracle));
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));
        _pinProductionProtocolCodehashes(
            _proxyImplementation(address(factory)), address(poolImplementation), address(pythOracle)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolTimelockRoleMismatch.selector,
                timelock.PROPOSER_ROLE(),
                wrongControllerAddr,
                address(governor)
            )
        );
        harness.validateProductionProtocolFinalizedHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(pythOracle),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor)
        );
    }

    function test_ProductionProtocol_ValidationRejectsCompositeOracleAuthorizedCallers() public {
        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        _pinPythOracleCodehash(address(pythOracle));
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));
        _pinProductionProtocolCodehashes(
            _proxyImplementation(address(factory)), address(poolImplementation), address(pythOracle)
        );

        compositeOracle.transferOwnership(address(factory));
        pythOracle.transferOwnership(address(factory));
        erc4626OracleFeed.transferOwnership(address(factory));

        vm.startPrank(address(harness));
        factory.setCompositeOracle(address(compositeOracle));
        factory.setDefaultProtocolFeeRecipient(address(timelock));
        factory.setManagedPythOracle(address(pythOracle));
        factory.setManagedERC4626OracleFeed(address(erc4626OracleFeed));
        factory.finalizeBootstrap();
        factory.transferOwnership(address(timelock));
        vm.stopPrank();

        address staleCaller = address(0xCA11);
        vm.prank(address(factory));
        compositeOracle.setAuthorizedCaller(staleCaller, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolAuthorizedCallersPresent.selector,
                address(compositeOracle),
                1
            )
        );
        harness.validateProductionProtocolFinalizedHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(pythOracle),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor)
        );
    }

    function test_ProductionProtocol_ValidationRejectsUnexpectedERC4626OracleBytecode() public {
        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        _pinPythOracleCodehash(address(pythOracle));
        FakeProductionOwnableOracle fakeERC4626OracleFeed = new FakeProductionOwnableOracle();
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));
        _pinProductionProtocolCodehashes(
            _proxyImplementation(address(factory)), address(poolImplementation), address(pythOracle)
        );

        compositeOracle.transferOwnership(address(factory));
        pythOracle.transferOwnership(address(factory));
        fakeERC4626OracleFeed.transferOwnership(address(factory));

        vm.startPrank(address(harness));
        factory.setCompositeOracle(address(compositeOracle));
        factory.setDefaultProtocolFeeRecipient(address(timelock));
        factory.setManagedPythOracle(address(pythOracle));
        factory.setManagedERC4626OracleFeed(address(fakeERC4626OracleFeed));
        factory.finalizeBootstrap();
        factory.transferOwnership(address(timelock));
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolCodehashMismatch.selector,
                bytes32("ERC4626OracleFeed"),
                address(fakeERC4626OracleFeed),
                address(fakeERC4626OracleFeed).codehash,
                keccak256(type(ERC4626OracleFeed).runtimeCode)
            )
        );
        harness.validateProductionProtocolFinalizedHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(pythOracle),
            address(fakeERC4626OracleFeed),
            address(timelock),
            address(governor)
        );
    }

    function test_ProductionProtocol_ValidationRequiresPythOracleCodehashEnv() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        string memory missingEnvName = "YS_TEST_REQUIRED_PYTH_ORACLE_CODEHASH";
        vm.setEnv(missingEnvName, vm.toString(bytes32(0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolCodehashRequired.selector,
                bytes32("PythOracle"),
                missingEnvName
            )
        );
        harness.requireProductionPythOracleCodehashHarness(address(pythOracle), missingEnvName);
    }

    function test_ProductionProtocol_ValidationRequiresFactoryImplementationCodehashEnv() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        SplitRiskPoolFactory factoryImplementation = new SplitRiskPoolFactory();
        string memory missingEnvName = "YS_TEST_REQUIRED_FACTORY_IMPLEMENTATION_CODEHASH";
        vm.setEnv(missingEnvName, vm.toString(bytes32(0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolCodehashRequired.selector,
                bytes32("FactoryImplementation"),
                missingEnvName
            )
        );
        harness.requireProductionFactoryImplementationCodehashHarness(address(factoryImplementation), missingEnvName);
    }

    function test_ProductionProtocol_ValidationRequiresPoolImplementationCodehashEnv() public {
        ProductionDeployHarness harness = new ProductionDeployHarness();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        string memory missingEnvName = "YS_TEST_REQUIRED_POOL_IMPLEMENTATION_CODEHASH";
        vm.setEnv(missingEnvName, vm.toString(bytes32(0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolCodehashRequired.selector,
                bytes32("PoolImplementation"),
                missingEnvName
            )
        );
        harness.requireProductionPoolImplementationCodehashHarness(address(poolImplementation), missingEnvName);
    }

    function test_RobinhoodTestnetRelaxedDeploy_DefaultsBootstrapHolderToDeployer() public {
        vm.chainId(ROBINHOOD_TESTNET_CHAIN_ID);
        ProductionDeployHarness harness = new ProductionDeployHarness();
        harness.setStrictProductionGuardsOverrideHarness(false);

        (YSToken ysToken, TimelockController timelock,, address testnetBootstrapHolder) =
            harness.deployGovernanceWithRelaxedTestnetGuardsHarness();

        assertEq(testnetBootstrapHolder, address(harness));
        assertEq(ysToken.balanceOf(testnetBootstrapHolder), ysToken.INITIAL_SUPPLY());
        assertEq(ysToken.delegates(testnetBootstrapHolder), testnetBootstrapHolder);
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), testnetBootstrapHolder));
        _assertSoleSelfAdmin(timelock);
    }

    function test_RobinhoodTestnetRelaxedDeploy_SkipsManualProtocolCodehashPins() public {
        vm.chainId(ROBINHOOD_TESTNET_CHAIN_ID);
        ProductionDeployHarness harness = new ProductionDeployHarness();
        harness.setStrictProductionGuardsOverrideHarness(false);
        ChainlinkOracleFeed chainlinkOracleFeed = new ChainlinkOracleFeed(86_400);
        string memory missingEnvName = "YS_TEST_REQUIRED_CHAINLINK_ORACLE_CODEHASH";
        vm.setEnv(missingEnvName, vm.toString(bytes32(0)));

        assertFalse(harness.requiresStrictProductionGuardsHarness());
        harness.requireProductionChainlinkOracleCodehashHarness(address(chainlinkOracleFeed), missingEnvName);
    }

    function test_RobinhoodMainnetStillRequiresManualProtocolCodehashPins() public {
        vm.chainId(ROBINHOOD_MAINNET_CHAIN_ID);
        ProductionDeployHarness harness = new ProductionDeployHarness();
        ChainlinkOracleFeed chainlinkOracleFeed = new ChainlinkOracleFeed(86_400);
        string memory missingEnvName = "YS_TEST_REQUIRED_CHAINLINK_ORACLE_CODEHASH";
        vm.setEnv(missingEnvName, vm.toString(bytes32(0)));

        assertTrue(harness.requiresStrictProductionGuardsHarness());
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolCodehashRequired.selector,
                bytes32("ChainlinkOracleFeed"),
                missingEnvName
            )
        );
        harness.requireProductionChainlinkOracleCodehashHarness(address(chainlinkOracleFeed), missingEnvName);
    }

    function test_RobinhoodTestnetStrictModeRequiresManualProtocolCodehashPins() public {
        vm.chainId(ROBINHOOD_TESTNET_CHAIN_ID);
        ProductionDeployHarness harness = new ProductionDeployHarness();
        harness.setStrictProductionGuardsOverrideHarness(true);
        ChainlinkOracleFeed chainlinkOracleFeed = new ChainlinkOracleFeed(86_400);
        string memory missingEnvName = "YS_TEST_REQUIRED_CHAINLINK_ORACLE_CODEHASH";
        vm.setEnv(missingEnvName, vm.toString(bytes32(0)));

        assertTrue(harness.requiresStrictProductionGuardsHarness());
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolCodehashRequired.selector,
                bytes32("ChainlinkOracleFeed"),
                missingEnvName
            )
        );
        harness.requireProductionChainlinkOracleCodehashHarness(address(chainlinkOracleFeed), missingEnvName);
    }

    function test_ProductionProtocol_ValidationRejectsUnexpectedPythOracleBytecode() public {
        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle expectedPythOracle = new PythOracle(dummyPyth, 60);
        FakeProductionOwnableOracle fakePythOracle = new FakeProductionOwnableOracle();
        _pinPythOracleCodehash(address(expectedPythOracle));
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(expectedPythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));
        _pinProductionProtocolCodehashes(
            _proxyImplementation(address(factory)), address(poolImplementation), address(expectedPythOracle)
        );

        compositeOracle.transferOwnership(address(factory));
        fakePythOracle.transferOwnership(address(factory));
        erc4626OracleFeed.transferOwnership(address(factory));

        vm.startPrank(address(harness));
        factory.setCompositeOracle(address(compositeOracle));
        factory.setDefaultProtocolFeeRecipient(address(timelock));
        factory.setManagedPythOracle(address(fakePythOracle));
        factory.setManagedERC4626OracleFeed(address(erc4626OracleFeed));
        factory.finalizeBootstrap();
        factory.transferOwnership(address(timelock));
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolCodehashMismatch.selector,
                bytes32("PythOracle"),
                address(fakePythOracle),
                address(fakePythOracle).codehash,
                address(expectedPythOracle).codehash
            )
        );
        harness.validateProductionProtocolFinalizedWithExpectedPythCodehashHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(fakePythOracle),
            address(expectedPythOracle),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor)
        );
    }

    function test_ProductionProtocol_FinalizerRejectsUnexpectedOracleOwner() public {
        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        _pinPythOracleCodehash(address(pythOracle));
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));
        _pinProductionProtocolCodehashes(
            _proxyImplementation(address(factory)), address(poolImplementation), address(pythOracle)
        );

        address unexpectedOwner = address(0xA11CE);
        compositeOracle.transferOwnership(unexpectedOwner);
        pythOracle.transferOwnership(address(harness));
        erc4626OracleFeed.transferOwnership(address(harness));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolOwnerMismatch.selector,
                bytes32("CompositeOracle"),
                unexpectedOwner,
                address(factory)
            )
        );
        harness.finalizeProductionProtocolBootstrapHarness(
            address(factory),
            _proxyImplementation(address(factory)),
            address(poolImplementation),
            address(compositeOracle),
            address(pythOracle),
            address(erc4626OracleFeed),
            address(timelock),
            address(governor),
            address(harness)
        );
    }

    function _deployGovernance() internal returns (YSToken ysToken, TimelockController timelock, YSGovernor governor) {
        address[] memory emptyAccounts = new address[](0);
        timelock = TimelockController(
            payable(address(new YSTimelockController(TIMELOCK_DELAY, emptyAccounts, emptyAccounts, deployer)))
        );
        ysToken = new YSToken(bootstrapHolder);
        governor = new YSGovernor(IVotes(address(ysToken)), timelock, deployer);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _assertSoleSelfAdmin(TimelockController timelock) internal view {
        YSTimelockController ysTimelock = YSTimelockController(payable(address(timelock)));
        assertEq(ysTimelock.getRoleMemberCount(ysTimelock.DEFAULT_ADMIN_ROLE()), 1);
        assertEq(ysTimelock.getRoleMember(ysTimelock.DEFAULT_ADMIN_ROLE(), 0), address(timelock));
    }

    function _pinPythOracleCodehash(address pythOracleAddr) internal {
        vm.setEnv(ENV_PYTH_ORACLE_CODEHASH, vm.toString(pythOracleAddr.codehash));
    }

    function _pinProductionProtocolCodehashes(
        address factoryImplementationAddr,
        address poolImplementationAddr,
        address pythOracleAddr
    ) internal {
        vm.setEnv(ENV_FACTORY_IMPLEMENTATION_CODEHASH, vm.toString(factoryImplementationAddr.codehash));
        vm.setEnv(ENV_POOL_IMPLEMENTATION_CODEHASH, vm.toString(poolImplementationAddr.codehash));
        _pinPythOracleCodehash(pythOracleAddr);
    }
}
