// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { YSToken } from "../contracts/YSToken.sol";
import { YSGovernor } from "../contracts/YSGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { YSTimelockController } from "../contracts/governance/YSTimelockController.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { DeployYieldShieldProduction } from "../script/DeployYieldShieldProduction.s.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";

contract ProductionDeployHarness is DeployYieldShieldProduction {
    function validateProductionBootstrapHolder(address holder) external view {
        _validateProductionBootstrapHolder(holder);
    }
}

contract ContractBootstrapHolder { }

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
}

contract DeploymentSecurityTest is Test, FactoryProxyTestBase {
    uint256 internal constant TIMELOCK_DELAY = 2 days;

    address internal deployer = address(this);
    address internal bootstrapHolder = address(0xB0057);
    address internal dummyPyth = address(0x1234);

    function test_ProductionBootstrap_AssignsSupplyAndClearsExternalAdmins() public {
        (YSToken ysToken, TimelockController timelock, YSGovernor governor) = _deployGovernance();

        assertEq(ysToken.balanceOf(bootstrapHolder), ysToken.INITIAL_SUPPLY());
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), bootstrapHolder));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
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
                DeployYieldShieldProduction.InvalidProductionBootstrapHolder.selector, address(contractHolder)
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
                DeployYieldShieldProduction.InvalidProductionBootstrapHolder.selector, address(contractHolder)
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

    function test_ProductionProtocol_RoutesOracleOwnershipThroughFactoryGovernance() public {
        (, TimelockController timelock,) = _deployGovernance();

        PythOracle pythOracle = new PythOracle(dummyPyth, 60);
        ERC4626OracleFeed erc4626OracleFeed = new ERC4626OracleFeed(address(pythOracle));
        CompositeOracle compositeOracle = new CompositeOracle();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        SplitRiskPoolFactory factory = _deployFactory(deployer, address(timelock), address(poolImplementation));

        factory.setCompositeOracle(address(compositeOracle));
        factory.setDefaultProtocolFeeRecipient(address(timelock));
        compositeOracle.setAuthorizedCaller(address(factory), true);

        compositeOracle.transferOwnership(address(factory));
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
}
