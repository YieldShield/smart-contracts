// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { SplitRiskPoolRewardPrecisionTest } from "./SplitRiskPoolRewardPrecision.t.sol";
import { ConstantsLib } from "../contracts/libraries/ConstantsLib.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract AuditRewardRoundingTest is SplitRiskPoolRewardPrecisionTest {
    function test_RepeatedAccrualCannotAllocateMoreThanCurrentReserve() public {
        vm.prank(protector);
        uint256 protectorId = pool.depositBackingAsset(address(backingToken), 3 * 10 ** 32, 0);
        vm.prank(shielded);
        uint256 shieldId = pool.depositShieldedAsset(address(shieldedToken), 1e6, 0);

        uint256 start = block.timestamp;
        for (uint256 i = 2; i <= 20; i++) {
            oracle.setPrice(address(shieldedToken), i * 1e8);
            vm.warp(start + i * 1 days);
            vm.prank(shielded);
            pool.claimRewards(shieldId);
        }

        uint256 earned = Math.mulDiv(
            pool.rewardPerShareAccumulated(), pool.protectorShares(protectorId), ConstantsLib.REWARD_PRECISION
        ) - pool.rewardDebt(protectorId);
        assertLe(earned, pool.currentEpochCommissionReserve(), "reward index overallocates commission reserve");
    }

    function test_CurrentProtectorCannotSpendHistoricalCommissionReserve() public {
        vm.prank(protector);
        uint256 expiredProtectorId = pool.depositBackingAsset(address(backingToken), 3 * 10 ** 32, 0);
        vm.prank(shielded);
        uint256 expiredShieldId = pool.depositShieldedAsset(address(shieldedToken), 2e6, 0);
        oracle.setPrice(address(backingToken), 5e7);
        vm.warp(block.timestamp + 1 days);
        vm.prank(shielded);
        pool.shieldedWithdraw(expiredShieldId, address(backingToken), 0);
        assertEq(pool.protectorShareEpoch(), 1);
        uint256 historicalClaim = pool.getClaimableCommission(expiredProtectorId);

        oracle.setPrice(address(backingToken), 1e8);
        vm.prank(protector);
        uint256 currentProtectorId = pool.depositBackingAsset(address(backingToken), 3 * 10 ** 32, 0);
        vm.prank(shielded);
        uint256 currentShieldId = pool.depositShieldedAsset(address(shieldedToken), 1e6, 0);

        uint256 start = block.timestamp;
        for (uint256 i = 2; i <= 20; i++) {
            oracle.setPrice(address(shieldedToken), i * 1e8);
            vm.warp(start + i * 1 days);
            vm.prank(shielded);
            pool.claimRewards(currentShieldId);
        }

        uint256 reserve = pool.currentEpochCommissionReserve();
        uint256 beforeBalance = shieldedToken.balanceOf(protector);
        vm.prank(protector);
        pool.claimCommission(currentProtectorId);
        uint256 received = shieldedToken.balanceOf(protector) - beforeBalance;
        assertLe(received, reserve, "current protector spent historical commission reserve");
        assertEq(pool.getClaimableCommission(expiredProtectorId), historicalClaim, "historical entitlement decreased");
    }
}
