// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { MockERC20Decimals } from "../contracts/mocks/MockERC20Decimals.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ConstantsLib } from "../contracts/libraries/ConstantsLib.sol";

/// @notice Fresh audit: repeated fee accrual must not promise more rewards than it funds.
contract ProtectorRewardConservationTest is Test, TestTimelockHelper {
    SplitRiskPool internal pool;
    MockERC20Decimals internal shielded;
    MockERC20Decimals internal backing;
    MockOracle internal oracle;
    address internal shielder = address(0xB0B);
    address[3] internal protectors = [address(0xA1), address(0xA2), address(0xA3)];
    uint256[3] internal protectorIds;
    uint256[4] internal shieldIds;

    function setUp() public {
        shielded = new MockERC20Decimals("Test stock", "tSTOCK", 8);
        backing = new MockERC20Decimals("Test USD", "tUSD", 6);
        oracle = new MockOracle();
        oracle.setPrice(address(shielded), 1e8);
        oracle.setPrice(address(backing), 1e8);
        ShieldReceiptNFT shieldNFT = new ShieldReceiptNFT("sSTOCK", "sSTOCK");
        ProtectorReceiptNFT protectorNFT = new ProtectorReceiptNFT("pUSD", "pUSD");
        address governance = address(_deployTestTimelock(address(this)));
        TokenWhitelistLib.TokenInfo memory shieldInfo =
            TokenWhitelistLib.TokenInfo("Test stock", "tSTOCK", address(shielded), address(oracle), address(0), 10000);
        TokenWhitelistLib.TokenInfo memory backingInfo =
            TokenWhitelistLib.TokenInfo("Test USD", "tUSD", address(backing), address(oracle), address(0), 10000);
        address implementation = address(new SplitRiskPool());
        pool = SplitRiskPool(
            payable(address(
                    new ERC1967Proxy(
                        implementation,
                        abi.encodeCall(
                            SplitRiskPool.initialize,
                            (
                                shieldInfo,
                                backingInfo,
                                1000,
                                0,
                                address(this),
                                15000,
                                governance,
                                address(oracle),
                                address(0xFEE),
                                address(shieldNFT),
                                address(protectorNFT),
                                address(this)
                            )
                        )
                    )
                ))
        );
        shieldNFT.setPool(address(pool));
        protectorNFT.setPool(address(pool));
        shieldNFT.transferOwnership(address(pool));
        protectorNFT.transferOwnership(address(pool));
        for (uint256 i; i < 3; ++i) {
            backing.mint(protectors[i], 1000e6);
            vm.startPrank(protectors[i]);
            backing.approve(address(pool), type(uint256).max);
            protectorIds[i] = pool.depositBackingAsset(address(backing), 1000e6, 1000e6);
            vm.stopPrank();
        }
        shielded.mint(shielder, 4e8);
        vm.startPrank(shielder);
        shielded.approve(address(pool), type(uint256).max);
        for (uint256 i; i < 4; ++i) {
            shieldIds[i] = pool.depositShieldedAsset(address(shielded), 1e8, 1e8);
        }
        vm.stopPrank();
    }

    function _accrueFees(uint256 start, uint256 end) internal {
        vm.startPrank(shielder);
        for (uint256 i = start; i < end; ++i) {
            pool.claimRewards(shieldIds[i]);
        }
        vm.stopPrank();
    }

    function _totalClaimable() internal view returns (uint256 sumClaimable) {
        for (uint256 i; i < 3; ++i) {
            sumClaimable += pool.getClaimableCommission(protectorIds[i]);
        }
    }

    function _join(address protector, uint256 amount) internal returns (uint256 tokenId) {
        backing.mint(protector, amount);
        vm.startPrank(protector);
        backing.approve(address(pool), type(uint256).max);
        tokenId = pool.depositBackingAsset(address(backing), amount, amount);
        vm.stopPrank();
    }

    function test_AccruedProtectorEntitlementsNeverExceedCommissionReserve() public {
        oracle.setPrice(address(shielded), 2e8);
        _accrueFees(0, 4);
        assertEq(pool.accumulatedCommissions(), 20_000_000, "four actual fee payments");
        assertLe(_totalClaimable(), pool.accumulatedCommissions(), "reward entitlement exceeds funded reserve");
        assertEq(pool.pendingProtectorRewardDust(), 0, "credited fractions are not native-unit pending dust");
    }

    function testFuzz_ActualClaimsAreFundedInEveryClaimOrder(uint8 first) public {
        first = uint8(bound(first, 0, 2));
        oracle.setPrice(address(shielded), 2e8);
        _accrueFees(0, 4);
        uint256 funded = pool.accumulatedCommissions();
        uint256 paid;
        for (uint256 j; j < 3; ++j) {
            uint256 i = (uint256(first) + j) % 3;
            uint256 beforeBalance = shielded.balanceOf(protectors[i]);
            vm.prank(protectors[i]);
            pool.claimCommission(protectorIds[i]);
            uint256 received = shielded.balanceOf(protectors[i]) - beforeBalance;
            assertEq(received, funded / 3, "each equal protector receives its funded share");
            paid += received;
        }
        assertEq(paid + pool.accumulatedCommissions(), funded, "payouts plus residual reserve conserve commissions");
        assertEq(pool.accumulatedCommissions(), 2, "sub-token fractions remain funded until orphan handling");
    }

    function test_LaterProtectorReceivesOnlySubsequentAccrual() public {
        oracle.setPrice(address(shielded), 2e8);
        _accrueFees(0, 2);
        address laterProtector = address(0xA4);
        uint256 laterId = _join(laterProtector, 1000e6);
        assertEq(pool.getClaimableCommission(laterId), 0, "joining does not acquire prior rewards");
        _accrueFees(2, 4);
        // Excluding the pre-entry fraction conservatively retains one native
        // token unit; that rounding residue stays funded in the reserve.
        assertEq(pool.getClaimableCommission(laterId), 2_499_999, "subsequent share less one rounding unit");
        uint256 sumClaimable = _totalClaimable() + pool.getClaimableCommission(laterId);
        assertLe(sumClaimable, pool.accumulatedCommissions(), "join and subsequent accrual remain funded");
        assertEq(pool.pendingProtectorRewardDust(), 0);
    }
}

/// @dev Exposes existing internal arithmetic only for a local conservation probe.
contract Round2RewardDistributionHarness is SplitRiskPool {
    function seedShares(uint256 shares) external {
        totalProtectorShares = shares;
        totalProtectorTokens = 1;
    }

    function addReward(uint256 amount) external {
        _accumulateProtectorReward(amount, ConstantsLib.MAX_SAFE_ACCUMULATION);
    }

    function distributePending() external {
        _tryDistributePendingProtectorRewardDust();
    }
}

contract ProtectorPendingRewardConservationTest is Test {
    function testFuzz_PendingAndCreditedRewardsNeverExceedFunding(uint128 shareSeed, uint256 rewardSeed) public {
        uint256 precision = ConstantsLib.REWARD_PRECISION;
        uint256 shares = bound(uint256(shareSeed), 1, ConstantsLib.MAX_PROTECTOR_REWARD_SHARES);
        Round2RewardDistributionHarness harness = new Round2RewardDistributionHarness();
        harness.seedShares(shares);
        uint256 funded;
        for (uint256 i; i < 16; ++i) {
            uint256 reward = 1 + uint256(keccak256(abi.encode(rewardSeed, i))) % 1000;
            funded += reward;
            harness.addReward(reward);
            harness.distributePending();
            uint256 represented =
                Math.mulDiv(harness.rewardPerShareAccumulated(), shares, precision, Math.Rounding.Ceil);
            assertLe(represented + harness.pendingProtectorRewardDust(), funded, "pending dust is not already credited");
            assertEq(harness.accumulatedCommissions(), funded, "all contributed tokens remain in commission reserves");
        }
    }

    function test_PendingRewardRedistributionDoesNotRecycleCreditedFractions() public {
        uint256 precision = ConstantsLib.REWARD_PRECISION;
        Round2RewardDistributionHarness harness = new Round2RewardDistributionHarness();
        harness.seedShares(3 * precision / 2);
        harness.addReward(4);
        assertEq(harness.rewardPerShareAccumulated(), 2);
        assertEq(harness.pendingProtectorRewardDust(), 1);
        harness.addReward(1);
        harness.distributePending();
        assertEq(harness.rewardPerShareAccumulated(), 3);
        assertEq(harness.pendingProtectorRewardDust(), 0);
        assertEq(harness.accumulatedCommissions(), 5);
    }
}
