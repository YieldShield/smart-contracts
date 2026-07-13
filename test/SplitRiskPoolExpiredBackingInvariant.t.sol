// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";

/// @notice Randomizes the owner-only and keeper expired-backing settlement entrypoints on independent pools.
contract SplitRiskPoolExpiredBackingHandler is Test {
    struct CallMetrics {
        uint256 attempts;
        uint256 preconditionSkips;
        uint256 successes;
        uint256 unexpectedReverts;
    }

    SplitRiskPool public ownerClaimPool;
    SplitRiskPool public keeperSettlementPool;
    address[2] public ownerClaimBeneficiaries;
    address[2] public keeperSettlementBeneficiaries;
    uint256[2] public ownerClaimTokenIds;
    uint256[2] public keeperSettlementTokenIds;
    uint256 public ghostOwnerClaimedBacking;
    uint256 public ghostKeeperSettledBacking;
    mapping(bytes4 => CallMetrics) public callMetrics;

    constructor(
        SplitRiskPool ownerClaimPool_,
        SplitRiskPool keeperSettlementPool_,
        address[2] memory ownerClaimBeneficiaries_,
        address[2] memory keeperSettlementBeneficiaries_,
        uint256[2] memory ownerClaimTokenIds_,
        uint256[2] memory keeperSettlementTokenIds_
    ) {
        ownerClaimPool = ownerClaimPool_;
        keeperSettlementPool = keeperSettlementPool_;
        ownerClaimBeneficiaries = ownerClaimBeneficiaries_;
        keeperSettlementBeneficiaries = keeperSettlementBeneficiaries_;
        ownerClaimTokenIds = ownerClaimTokenIds_;
        keeperSettlementTokenIds = keeperSettlementTokenIds_;
    }

    function claimExpiredBacking(uint256 seed) external {
        CallMetrics storage metrics = callMetrics[this.claimExpiredBacking.selector];
        metrics.attempts++;
        uint256 index = seed % 2;
        uint256 tokenId = ownerClaimTokenIds[index];
        if (ownerClaimPool.getExpiredProtectorBackingClaim(tokenId) == 0) {
            metrics.preconditionSkips++;
            return;
        }

        vm.prank(ownerClaimBeneficiaries[index]);
        try ownerClaimPool.claimExpiredProtectorBacking(tokenId, 0) returns (uint256 received) {
            ghostOwnerClaimedBacking += received;
            metrics.successes++;
        } catch {
            metrics.unexpectedReverts++;
        }
    }

    function settleExpiredBacking(uint256 seed) external {
        CallMetrics storage metrics = callMetrics[this.settleExpiredBacking.selector];
        metrics.attempts++;
        uint256 index = seed % 2;
        uint256 tokenId = keeperSettlementTokenIds[index];
        if (keeperSettlementPool.getExpiredProtectorBackingClaim(tokenId) == 0) {
            metrics.preconditionSkips++;
            return;
        }

        vm.prank(address(0xBEEF));
        try keeperSettlementPool.settleExpiredProtectorBacking(tokenId, 0) returns (uint256 received) {
            ghostKeeperSettledBacking += received;
            metrics.successes++;
        } catch {
            metrics.unexpectedReverts++;
        }
    }
}

contract SplitRiskPoolExpiredBackingInvariantTest is Test, FactoryProxyTestBase {
    SplitRiskPoolFactory public factory;
    SplitRiskPool public ownerClaimPool;
    SplitRiskPool public keeperSettlementPool;
    SplitRiskPoolExpiredBackingHandler public handler;
    MockERC20 public ownerClaimShieldedToken;
    MockERC20 public keeperSettlementShieldedToken;
    MockERC20 public backingToken;
    MockOracle public oracle;
    CompositeOracle public compositeOracle;

    address public governance;
    address[2] public ownerClaimBeneficiaries = [address(0xC101), address(0xC102)];
    address[2] public keeperSettlementBeneficiaries = [address(0xD101), address(0xD102)];
    address public ownerClaimShielded = address(0xC200);
    address public keeperSettlementShielded = address(0xD200);
    address public ownerClaimFreshProtector = address(0xC300);
    address public keeperSettlementFreshProtector = address(0xD300);
    uint256 public ownerClaimLiability;
    uint256 public keeperSettlementLiability;
    bool public requireHandlerReachability;

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));
        ownerClaimShieldedToken = new MockERC20("Owner Claim Shielded", "OCS");
        keeperSettlementShieldedToken = new MockERC20("Keeper Settlement Shielded", "KSS");
        backingToken = new MockERC20("Expired Backing", "EBACK");
        oracle = new MockOracle();
        oracle.setPrice(address(ownerClaimShieldedToken), 1e18);
        oracle.setPrice(address(keeperSettlementShieldedToken), 1e18);
        oracle.setPrice(address(backingToken), 1e18);

        compositeOracle = new CompositeOracle();
        SplitRiskPool implementation = new SplitRiskPool();
        factory = _deployFactory(address(this), governance, address(implementation));
        compositeOracle.transferOwnership(address(factory));
        factory.setCompositeOracle(address(compositeOracle));
        factory.setDefaultProtocolFeeRecipient(address(0xFEE));
        factory.setCompositeOracleAuthorizedCaller(address(this), true);
        vm.prank(governance);
        factory.setMinimumCreationBondUsd(0);

        factory.addTokenInitial(
            address(ownerClaimShieldedToken), "Owner Claim Shielded", "OCS", address(oracle), address(0), 10_000, true
        );
        factory.addTokenInitial(
            address(keeperSettlementShieldedToken),
            "Keeper Settlement Shielded",
            "KSS",
            address(oracle),
            address(0),
            10_000,
            true
        );
        factory.addTokenInitial(
            address(backingToken), "Expired Backing", "EBACK", address(oracle), address(0), 10_000, true
        );
        factory.setTokenRequiresStrictProtectedPrice(address(backingToken), true);

        ownerClaimPool = SplitRiskPool(
            payable(factory.createPool(
                    address(ownerClaimShieldedToken), "OCS", address(backingToken), "EBACK", 500, 200, 10_000, 0
                ))
        );
        keeperSettlementPool = SplitRiskPool(
            payable(factory.createPool(
                    address(keeperSettlementShieldedToken), "KSS", address(backingToken), "EBACK", 500, 200, 10_000, 0
                ))
        );

        _setUnlimitedTvl(ownerClaimPool);
        _setUnlimitedTvl(keeperSettlementPool);
        uint256[2] memory ownerClaimTokenIds = _createExpiredBackingReserve(
            ownerClaimPool,
            ownerClaimShieldedToken,
            ownerClaimBeneficiaries,
            ownerClaimShielded,
            ownerClaimFreshProtector
        );
        uint256[2] memory keeperSettlementTokenIds = _createExpiredBackingReserve(
            keeperSettlementPool,
            keeperSettlementShieldedToken,
            keeperSettlementBeneficiaries,
            keeperSettlementShielded,
            keeperSettlementFreshProtector
        );

        ownerClaimLiability = ownerClaimPool.protectorEpochBackingRemainingReserve(0);
        keeperSettlementLiability = keeperSettlementPool.protectorEpochBackingRemainingReserve(0);
        assertEq(ownerClaimLiability, 2, "owner-claim fixture must reserve two backing wei");
        assertEq(keeperSettlementLiability, 2, "keeper fixture must reserve two backing wei");

        handler = new SplitRiskPoolExpiredBackingHandler(
            ownerClaimPool,
            keeperSettlementPool,
            ownerClaimBeneficiaries,
            keeperSettlementBeneficiaries,
            ownerClaimTokenIds,
            keeperSettlementTokenIds
        );
        requireHandlerReachability = vm.envOr("INVARIANT_REQUIRE_HANDLER_REACHABILITY", false);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = SplitRiskPoolExpiredBackingHandler.claimExpiredBacking.selector;
        selectors[1] = SplitRiskPoolExpiredBackingHandler.settleExpiredBacking.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function _setUnlimitedTvl(SplitRiskPool pool) internal {
        (
            uint256 shieldedMinDepositAmount,
            uint256 shieldedMaxDepositAmount,
            uint256 backingMinDepositAmount,
            uint256 backingMaxDepositAmount,,
            uint256 minimumPoolTime,
            uint256 unlockDuration,
            address protocolFeeRecipient,
            uint96 protocolFee,
            address priceOracle
        ) = pool.poolConfig();
        vm.prank(governance);
        pool.updatePoolConfig(
            shieldedMinDepositAmount,
            shieldedMaxDepositAmount,
            backingMinDepositAmount,
            backingMaxDepositAmount,
            type(uint256).max,
            minimumPoolTime,
            unlockDuration,
            protocolFee,
            protocolFeeRecipient,
            priceOracle
        );
    }

    function _createExpiredBackingReserve(
        SplitRiskPool pool,
        MockERC20 shieldedToken,
        address[2] memory beneficiaries,
        address shielded,
        address freshProtector
    ) internal returns (uint256[2] memory tokenIds) {
        backingToken.mint(beneficiaries[0], 150e18);
        vm.startPrank(beneficiaries[0]);
        backingToken.approve(address(pool), type(uint256).max);
        tokenIds[0] = pool.depositBackingAsset(address(backingToken), 150e18, 0);
        vm.stopPrank();

        backingToken.mint(beneficiaries[1], 50e18);
        vm.startPrank(beneficiaries[1]);
        backingToken.approve(address(pool), type(uint256).max);
        tokenIds[1] = pool.depositBackingAsset(address(backingToken), 50e18, 0);
        vm.stopPrank();

        shieldedToken.mint(shielded, 200e18 - 2);
        vm.startPrank(shielded);
        shieldedToken.approve(address(pool), type(uint256).max);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 200e18 - 2, 0);
        (,,,,, uint256 minimumPoolTime,,,,) = pool.poolConfig();
        vm.warp(block.timestamp + minimumPoolTime + 1);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);
        vm.stopPrank();

        backingToken.mint(freshProtector, 100e18);
        vm.startPrank(freshProtector);
        backingToken.approve(address(pool), type(uint256).max);
        pool.depositBackingAsset(address(backingToken), 100e18, 0);
        vm.stopPrank();
    }

    function invariant_ownerClaimConservesExpiredBacking() public view {
        uint256 reserve = ownerClaimPool.protectorEpochBackingRemainingReserve(0);
        assertEq(
            reserve + handler.ghostOwnerClaimedBacking(),
            ownerClaimLiability,
            "owner claims plus expired reserve must conserve backing"
        );
        _assertPoolBackingCovered(ownerClaimPool, reserve);
    }

    function invariant_keeperSettlementConservesExpiredBacking() public view {
        uint256 reserve = keeperSettlementPool.protectorEpochBackingRemainingReserve(0);
        assertEq(
            reserve + handler.ghostKeeperSettledBacking(),
            keeperSettlementLiability,
            "keeper settlements plus expired reserve must conserve backing"
        );
        _assertPoolBackingCovered(keeperSettlementPool, reserve);
    }

    function _assertPoolBackingCovered(SplitRiskPool pool, uint256 expiredReserve) internal view {
        (, uint256 trackedBacking) = pool.getPoolBalances();
        assertEq(
            trackedBacking,
            pool.totalProtectorTokens() + expiredReserve,
            "tracked backing must equal active claims plus expired reserve"
        );
        assertEq(backingToken.balanceOf(address(pool)), trackedBacking, "actual backing must cover tracked backing");
    }

    function afterInvariant() public view {
        _assertNoUnexpectedReverts(SplitRiskPoolExpiredBackingHandler.claimExpiredBacking.selector);
        _assertNoUnexpectedReverts(SplitRiskPoolExpiredBackingHandler.settleExpiredBacking.selector);
        if (requireHandlerReachability) {
            _assertReached(SplitRiskPoolExpiredBackingHandler.claimExpiredBacking.selector);
            _assertReached(SplitRiskPoolExpiredBackingHandler.settleExpiredBacking.selector);
        }
    }

    function _assertNoUnexpectedReverts(bytes4 selector) internal view {
        (,,, uint256 unexpectedReverts) = handler.callMetrics(selector);
        assertEq(unexpectedReverts, 0, "modeled expired-backing action reverted unexpectedly");
    }

    function _assertReached(bytes4 selector) internal view {
        (uint256 attempts,, uint256 successes,) = handler.callMetrics(selector);
        assertGt(attempts, 0, "expired-backing action was never attempted");
        assertGt(successes, 0, "expired-backing action never reached its success path");
    }

    function test_expiredBackingPathsAreReachable() public {
        handler.claimExpiredBacking(0);
        handler.claimExpiredBacking(1);
        handler.settleExpiredBacking(0);
        handler.settleExpiredBacking(1);

        assertEq(handler.ghostOwnerClaimedBacking(), ownerClaimLiability);
        assertEq(handler.ghostKeeperSettledBacking(), keeperSettlementLiability);
        _assertReached(SplitRiskPoolExpiredBackingHandler.claimExpiredBacking.selector);
        _assertReached(SplitRiskPoolExpiredBackingHandler.settleExpiredBacking.selector);
    }
}
