// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { EventsLib } from "../contracts/libraries/EventsLib.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { SlippageLib } from "../contracts/libraries/SlippageLib.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IShieldReceiptNFT } from "../contracts/interfaces/IShieldReceiptNFT.sol";
import { IProtectorReceiptNFT } from "../contracts/interfaces/IProtectorReceiptNFT.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

contract SplitRiskPoolFeeOnTransferWithdrawalsTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    ShieldReceiptNFT public shieldNFT;
    ProtectorReceiptNFT public protectorNFT;
    MockERC20 public shieldedToken;
    MockERC20 public backingToken;
    MockOracle public oracle;

    address public protector = address(0x1);
    address public shieldedUser = address(0x2);

    function setUp() public {
        shieldedToken = new MockERC20("Shielded Token", "SHT");
        backingToken = new MockERC20("Backing Token", "BACK");

        oracle = new MockOracle();
        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "Shielded Token",
            symbol: "SHT",
            token: address(shieldedToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "Backing Token",
            symbol: "BACK",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        shieldNFT = new ShieldReceiptNFT("sSHT", "sSHT");
        protectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");
        address governanceTimelock = address(_deployTestTimelock(address(this)));

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000,
            500,
            address(this),
            15000,
            governanceTimelock,
            address(oracle),
            address(0xdead),
            address(shieldNFT),
            address(protectorNFT),
            address(this)
        );
        pool = SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));

        shieldNFT.setPool(address(pool));
        protectorNFT.setPool(address(pool));
        shieldNFT.transferOwnership(address(pool));
        protectorNFT.transferOwnership(address(pool));

        shieldedToken.mint(shieldedUser, 1_000e18);
        backingToken.mint(protector, 1_000e18);

        vm.startPrank(protector);
        backingToken.approve(address(pool), 500e18);
        pool.depositBackingAsset(address(backingToken), 500e18, 0);
        vm.stopPrank();
    }

    function _depositShielded(uint256 amount) internal returns (uint256 tokenId) {
        vm.startPrank(shieldedUser);
        shieldedToken.approve(address(pool), amount);
        tokenId = pool.depositShieldedAsset(address(shieldedToken), amount, 0);
        vm.stopPrank();
    }

    function _matureProtectorUnlock(uint256 tokenId) internal {
        vm.startPrank(protector);
        pool.startUnlockProcess(tokenId);
        vm.stopPrank();
        vm.warp(block.timestamp + 28 days + 1);
    }

    function _accrueShieldedYieldFees() internal {
        uint256 tokenId = _depositShielded(100e18);
        oracle.setPrice(address(shieldedToken), 2e8);

        vm.prank(shieldedUser);
        pool.claimRewards(tokenId);
    }

    function test_shieldedWithdraw_UsesActualReceivedForSlippageWithTransferFee() public {
        uint256 tokenId = _depositShielded(100e18);

        shieldedToken.setTransferFee(500);
        uint256 expectedReceived = 95e18;

        vm.startPrank(shieldedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                SlippageLib.SlippageProtectionFailed.selector, expectedReceived + 1e18, expectedReceived
            )
        );
        pool.shieldedWithdraw(tokenId, address(shieldedToken), expectedReceived + 1e18);
        vm.stopPrank();

        assertEq(
            shieldNFT.ownerOf(tokenId), shieldedUser, "withdraw should fully revert when actual received is too low"
        );
        assertEq(pool.totalShieldedTokens(), 100e18, "position accounting should roll back on slippage revert");

        uint256 beforeBalance = shieldedToken.balanceOf(shieldedUser);
        vm.prank(shieldedUser);
        pool.shieldedWithdraw(tokenId, address(shieldedToken), expectedReceived);
        assertEq(
            shieldedToken.balanceOf(shieldedUser) - beforeBalance,
            expectedReceived,
            "minAmountOut should use actual wallet receipt"
        );
    }

    function test_partialWithdrawShielded_UsesActualReceivedForSlippageWithTransferFee() public {
        uint256 tokenId = _depositShielded(100e18);

        shieldedToken.setTransferFee(500);
        uint256 withdrawAmount = 40e18;
        uint256 expectedReceived = 38e18;

        vm.startPrank(shieldedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                SlippageLib.SlippageProtectionFailed.selector, expectedReceived + 1e18, expectedReceived
            )
        );
        pool.partialWithdrawShielded(tokenId, withdrawAmount, address(shieldedToken), expectedReceived + 1e18);
        vm.stopPrank();

        assertEq(
            shieldNFT.ownerOf(tokenId),
            shieldedUser,
            "partial withdrawal should roll back when actual received is too low"
        );
        assertEq(
            pool.totalShieldedTokens(), 100e18, "pool totals should roll back on partial withdrawal slippage revert"
        );

        uint256 beforeBalance = shieldedToken.balanceOf(shieldedUser);
        vm.prank(shieldedUser);
        uint256 newTokenId =
            pool.partialWithdrawShielded(tokenId, withdrawAmount, address(shieldedToken), expectedReceived);

        assertEq(
            shieldedToken.balanceOf(shieldedUser) - beforeBalance,
            expectedReceived,
            "partial withdrawal should enforce wallet-received minAmountOut"
        );
        IShieldReceiptNFT.ShieldPosition memory newPosition = shieldNFT.getPosition(newTokenId);
        assertEq(newPosition.amount, 60e18, "remaining position should still use nominal pool accounting");
    }

    function test_protectorWithdraw_UsesActualReceivedForSlippageWithTransferFee() public {
        uint256 tokenId = 0;
        uint256 withdrawAmount = 40e18;
        uint256 expectedReceived = 38e18;

        _matureProtectorUnlock(tokenId);
        backingToken.setTransferFee(500);

        vm.startPrank(protector);
        vm.expectRevert(
            abi.encodeWithSelector(
                SlippageLib.SlippageProtectionFailed.selector, expectedReceived + 1e18, expectedReceived
            )
        );
        pool.protectorWithdraw(tokenId, withdrawAmount, address(backingToken), expectedReceived + 1e18);
        vm.stopPrank();

        IProtectorReceiptNFT.ProtectorPosition memory positionBefore = protectorNFT.getPosition(tokenId);
        assertEq(positionBefore.amount, 500e18, "protector position should roll back on slippage revert");

        uint256 beforeBalance = backingToken.balanceOf(protector);
        vm.prank(protector);
        pool.protectorWithdraw(tokenId, withdrawAmount, address(backingToken), expectedReceived);

        assertEq(
            backingToken.balanceOf(protector) - beforeBalance,
            expectedReceived,
            "protector withdrawal should enforce actual wallet receipt"
        );
    }

    function test_payPoolFee_EmitsAndPaysActualReceivedWithTransferFee() public {
        address poolFeeRecipient = address(0xFEE);
        pool.setPoolFeeRecipient(poolFeeRecipient);
        _accrueShieldedYieldFees();

        uint256 nominalFee = pool.accumulatedPoolFee();
        uint256 expectedReceived = (nominalFee * 9500) / 10000;
        shieldedToken.setTransferFee(500);

        uint256 beforeBalance = shieldedToken.balanceOf(poolFeeRecipient);
        vm.expectEmit(true, false, false, true);
        emit EventsLib.PoolFeePaid(poolFeeRecipient, expectedReceived);
        pool.payPoolFee();

        assertEq(shieldedToken.balanceOf(poolFeeRecipient) - beforeBalance, expectedReceived);
        assertEq(pool.accumulatedPoolFee(), 0);
    }

    function test_payProtocolFee_EmitsAndPaysActualReceivedWithTransferFee() public {
        address protocolRecipient = address(0xdead);
        _accrueShieldedYieldFees();

        uint256 nominalFee = pool.accumulatedProtocolFee();
        uint256 expectedReceived = (nominalFee * 9500) / 10000;
        shieldedToken.setTransferFee(500);

        uint256 beforeBalance = shieldedToken.balanceOf(protocolRecipient);
        vm.prank(protocolRecipient);
        vm.expectEmit(true, false, false, true);
        emit EventsLib.ProtocolFeePaid(protocolRecipient, expectedReceived);
        pool.payProtocolFee();

        assertEq(shieldedToken.balanceOf(protocolRecipient) - beforeBalance, expectedReceived);
        assertEq(pool.accumulatedProtocolFee(), 0);
    }

    function test_claimCommission_RevertsRatherThanUnderpayingWithTransferFee() public {
        _accrueShieldedYieldFees();

        shieldedToken.setTransferFee(500);

        vm.prank(protector);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.IncompatibleShieldedTokenForCrossAssetWithdrawal.selector, address(shieldedToken)
            )
        );
        pool.claimCommission(0);

        assertGt(pool.accumulatedCommissions(), 0, "commission remains reserved when exact payout is impossible");
    }

    function test_crossAssetWithdraw_RevertsAfterShieldedTransferFeeObserved() public {
        shieldedToken.setTransferFee(500);
        uint256 tokenId = _depositShielded(100e18);

        assertTrue(pool.shieldedTokenTransferIntegrityBroken(), "taxed deposit should flag shielded token");

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(shieldedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.IncompatibleShieldedTokenForCrossAssetWithdrawal.selector, address(shieldedToken)
            )
        );
        pool.shieldedWithdraw(tokenId, address(backingToken), 0);
    }

    function test_crossAssetWithdraw_RevertsIfShieldedTokenBecomesTaxedAfterDeposit() public {
        uint256 tokenId = _depositShielded(100e18);
        shieldedToken.setTransferFee(500);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(shieldedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.IncompatibleShieldedTokenForCrossAssetWithdrawal.selector, address(shieldedToken)
            )
        );
        pool.shieldedWithdraw(tokenId, address(backingToken), 0);
    }
}
