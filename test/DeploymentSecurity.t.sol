// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { YSToken } from "../contracts/YSToken.sol";
import { YSGovernor } from "../contracts/YSGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { YSTimelockController } from "../contracts/governance/YSTimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { PythConfig } from "../contracts/oracles/PythConfig.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { DeployYieldShieldProduction } from "../script/DeployYieldShieldProduction.s.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";
import { MockPyth } from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

contract ProductionDeployHarness is DeployYieldShieldProduction {
    function validateProductionBootstrapHolder(address holder) external view {
        _validateProductionBootstrapHolder(
            holder, holder.codehash, _readMasterCopy(holder), _readThreshold(holder), _readOwnersHash(holder)
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
            holder, expectedCodehash, expectedSingleton, expectedThreshold, expectedOwnersHash
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
        _finalizeProductionProtocolBootstrap(
            factoryAddr,
            factoryImplementationAddr,
            poolImplementationAddr,
            compositeOracleAddr,
            pythOracleAddr,
            erc4626OracleFeedAddr,
            timelockAddr,
            governorAddr,
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
    address[] internal owners;
    uint256 internal threshold;
    uint256 internal safeNonce;
    bytes32 internal safeDomainSeparator;

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
}

contract DeploymentSecurityTest is Test, FactoryProxyTestBase {
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant TIMELOCK_DELAY = 2 days;

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
        YSGovernor newGovernor = new YSGovernor(IVotes(address(ysToken)), timelock);

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
        YSGovernor wrongGovernor = new YSGovernor(IVotes(address(ysToken)), otherTimelock);

        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                YSTimelockController.GovernanceControllerRotationInvalid.selector, address(0), address(wrongGovernor)
            )
        );
        ysTimelock.rotateGovernanceController(address(wrongGovernor));

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
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

    function test_ProductionBootstrap_BurnCannotReduceBelowQuorumVotingPower() public {
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

        // M-15: proposalThreshold is now equal to MIN_GOVERNANCE_SUPPLY (both 10k).
        // After M-15, the burn floor and propose threshold coincide — assertLe
        // captures the invariant that you can still propose at the floor.
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
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));
        address directOracleCaller = address(0xCA11);

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

    function test_ProductionProtocol_ValidationRejectsMismatchedFactoryGovernanceTimelock() public {
        (, TimelockController expectedTimelock, YSGovernor expectedGovernor) = _deployGovernance();
        (, TimelockController wrongTimelock,) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory =
            _deployFactory(address(harness), address(wrongTimelock), address(poolImplementation));

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
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));
        SplitRiskPoolFactory wrongFactoryImplementation = new SplitRiskPoolFactory();

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
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPool wrongPoolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));

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
        address attacker = address(0xBEEF);
        address[] memory controllers = new address[](1);
        controllers[0] = attacker;
        TimelockController timelock = TimelockController(
            payable(address(new YSTimelockController(TIMELOCK_DELAY, controllers, controllers, deployer)))
        );
        YSToken ysToken = new YSToken(bootstrapHolder);
        YSGovernor governor = new YSGovernor(IVotes(address(ysToken)), timelock);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployYieldShieldProduction.ProductionProtocolTimelockRoleMismatch.selector,
                timelock.PROPOSER_ROLE(),
                attacker,
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
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));

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
        FakeProductionOwnableOracle fakeERC4626OracleFeed = new FakeProductionOwnableOracle();
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));

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

    function test_ProductionProtocol_FinalizerRejectsUnexpectedOracleOwner() public {
        (, TimelockController timelock, YSGovernor governor) = _deployGovernance();
        ProductionDeployHarness harness = new ProductionDeployHarness();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(address(harness), address(timelock), address(poolImplementation));

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
        governor = new YSGovernor(IVotes(address(ysToken)), timelock);

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
}
