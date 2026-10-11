// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;
import { ProtectorRewardConservationTest } from "./ProtectorRewardConservation.t.sol";

contract ProtectorRewardDebtTest is ProtectorRewardConservationTest {
    function _seedMultipleLateReceipts() internal returns (uint256 fourthId, uint256 fifthId) {
        oracle.setPrice(address(shielded), 1e8 + 21);
        _accrueFees(0, 1);
        assertEq(pool.accumulatedCommissions(), 3, "one three-unit commission");
        fourthId = _join(address(0xA4), 500e6);
        fifthId = _join(address(0xA5), 500e6);
        assertEq(pool.getClaimableCommission(fourthId), 0);
        assertEq(pool.getClaimableCommission(fifthId), 0);

        oracle.setPrice(address(shielded), 1e8);
        shielded.mint(shielder, 1e8);
        uint256[1] memory extraShieldIds;
        vm.startPrank(shielder);
        for (uint256 i; i < 1; ++i) {
            extraShieldIds[i] = pool.depositShieldedAsset(address(shielded), 1e8, 1e8);
        }
        vm.stopPrank();
        oracle.setPrice(address(shielded), 1e8 + 1);
        _accrueFees(1, 4);
        vm.startPrank(shielder);
        for (uint256 i; i < 1; ++i) {
            pool.claimRewards(extraShieldIds[i]);
        }
        vm.stopPrank();
    }

    function test_MultipleLateReceiptsDoNotAcquireUnfundedRewardFractions() public {
        (uint256 fourthId, uint256 fifthId) = _seedMultipleLateReceipts();
        uint256 sumClaimable =
            _totalClaimable() + pool.getClaimableCommission(fourthId) + pool.getClaimableCommission(fifthId);
        assertEq(pool.accumulatedCommissions(), 7, "seven actual commission units");
        assertLe(sumClaimable, pool.accumulatedCommissions(), "late receipt debt does not create unfunded fractions");
    }

    function testFuzz_LateReceiptClaimsAreFundedInEveryClaimOrder(uint8 first) public {
        (uint256 fourthId, uint256 fifthId) = _seedMultipleLateReceipts();
        address[5] memory claimants = [protectors[0], protectors[1], protectors[2], address(0xA4), address(0xA5)];
        uint256[5] memory ids = [protectorIds[0], protectorIds[1], protectorIds[2], fourthId, fifthId];
        first = uint8(bound(first, 0, 4));
        uint256 funded = pool.accumulatedCommissions();
        uint256 paid;
        for (uint256 j; j < 5; ++j) {
            uint256 i = (uint256(first) + j) % 5;
            uint256 beforeBalance = shielded.balanceOf(claimants[i]);
            vm.prank(claimants[i]);
            pool.claimCommission(ids[i]);
            uint256 received = shielded.balanceOf(claimants[i]) - beforeBalance;
            assertEq(received, i < 3 ? 2 : 0, "old receipts retain earned rewards; new fractions stay reserved");
            paid += received;
        }
        assertEq(paid, 6);
        assertEq(paid + pool.accumulatedCommissions(), funded);
        assertEq(pool.accumulatedCommissions(), 1, "two half-unit claims remain funded as residual reserve");
    }

    function test_PartialProtectorExitsCannotReviveSettledRewardFractions() public {
        oracle.setPrice(address(shielded), 1e8 + 21);
        _accrueFees(0, 1);
        for (uint256 i; i < 2; ++i) {
            vm.prank(protectors[i]);
            pool.startUnlockProcess(protectorIds[i]);
        }
        vm.warp(block.timestamp + 28 days);
        for (uint256 i; i < 2; ++i) {
            vm.prank(protectors[i]);
            pool.protectorWithdraw(protectorIds[i], 500e6, address(backing), 500e6);
            assertEq(shielded.balanceOf(protectors[i]), 1, "earned whole rewards were paid before share reset");
            assertEq(pool.getClaimableCommission(protectorIds[i]), 0, "settled fraction cannot be reclaimed");
            assertEq(pool.getProtectorPositionAmount(protectorIds[i]), 500e6);
        }
        assertEq(pool.accumulatedCommissions(), 1);
        oracle.setPrice(address(shielded), 1e8 + 1);
        _accrueFees(1, 3);
        assertEq(pool.accumulatedCommissions(), 3);
        assertLe(_totalClaimable(), pool.accumulatedCommissions(), "post-exit claims remain funded");
        assertEq(pool.getClaimableCommission(protectorIds[0]), 0);
        assertEq(pool.getClaimableCommission(protectorIds[1]), 0);
        assertEq(
            pool.getClaimableCommission(protectorIds[2]), 2, "untouched receipt keeps prior and subsequent rewards"
        );
        for (uint256 i; i < 3; ++i) {
            vm.prank(protectors[i]);
            pool.claimCommission(protectorIds[i]);
        }
        assertEq(pool.accumulatedCommissions(), 1);
        assertEq(
            shielded.balanceOf(protectors[0]) + shielded.balanceOf(protectors[1]) + shielded.balanceOf(protectors[2])
                + pool.accumulatedCommissions(),
            5,
            "claims conserve all contributed fees"
        );
    }
}
