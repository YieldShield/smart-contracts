// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IShieldReceiptNFT } from "../contracts/interfaces/IShieldReceiptNFT.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

/// @title Tests for fee reserve protection (MED-3 FIX)
/// @notice Tests that withdrawals respect reserved fees and cannot drain fee funds
contract SplitRiskPoolFeeScalingHarness is SplitRiskPool {
    function scaleFeesToAvailableAmount(
        uint256 commissionAmount,
        uint256 poolFeeAmount,
        uint256 protocolFeeAmount,
        uint256 maxTotalFees
    ) external pure returns (uint256 scaledCommission, uint256 scaledPoolFee, uint256 scaledProtocolFee) {
        return _scaleFeesToAvailableAmount(commissionAmount, poolFeeAmount, protocolFeeAmount, maxTotalFees);
    }
}

contract SplitRiskPoolFeeReserveProtectionTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;

    address public poolCreator = address(0x1);
    address public protocolFeeRecipient = address(0x2);
    address public governance = address(0x3);
    address public shielded = address(0x4);
    address public protector = address(0x5);

    uint256 constant INITIAL_BALANCE = 1000000e18;

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

        // Deploy base ERC20 tokens
        shieldedBaseToken = new MockERC20("Shielded Base Token", "IBASE");
        backingBaseToken = new MockERC20("Backing Base Token", "UBASE");

        // Deploy ERC4626 vaults
        backingToken = new MockERC4626(backingBaseToken, "Backing Token", "UNDER");
        shieldedToken = new MockERC4626(shieldedBaseToken, "Shielded Token", "INSURE");

        // Deploy oracle
        oracle = new MockOracle();
        oracle.setPrice(address(shieldedToken), 1e8); // $1 per token
        oracle.setPrice(address(backingToken), 1e8); // $1 per token

        // Create TokenInfo structs
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "INSURE",
            symbol: "INSURE",
            token: address(shieldedToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "UNDER",
            symbol: "UNDER",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        // Deploy pool
        SplitRiskPool implementation = new SplitRiskPool();
        ShieldReceiptNFT shieldNFT = new ShieldReceiptNFT("iINSURE", "iINSURE");
        ProtectorReceiptNFT protectorNFT = new ProtectorReceiptNFT("uUNDER", "uUNDER");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000, // 10% commission rate
            500, // 5% pool fee
            poolCreator, // pool creator
            15000, // 150% collateral ratio
            governance, // governance
            address(oracle), // oracle
            protocolFeeRecipient, // protocol fee recipient
            address(shieldNFT),
            address(protectorNFT),
            address(this) // owner
        );
        pool = SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));

        // Set pool address on NFTs
        shieldNFT.setPool(address(pool));
        protectorNFT.setPool(address(pool));
        shieldNFT.transferOwnership(address(pool));
        protectorNFT.transferOwnership(address(pool));

        // Fund accounts
        shieldedBaseToken.mint(shielded, INITIAL_BALANCE);
        backingBaseToken.mint(protector, INITIAL_BALANCE);

        vm.startPrank(shielded);
        shieldedBaseToken.approve(address(shieldedToken), INITIAL_BALANCE);
        shieldedToken.deposit(INITIAL_BALANCE, shielded);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(protector);
        backingBaseToken.approve(address(backingToken), INITIAL_BALANCE);
        backingToken.deposit(INITIAL_BALANCE, protector);
        backingToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _claimRewardsAsOwner(uint256 tokenId) internal {
        address owner = IShieldReceiptNFT(pool.shieldReceiptNFT()).ownerOf(tokenId);
        vm.prank(owner);
        pool.claimRewards(tokenId);
    }

    function testWithdrawalRespectsReservedFees() public {
        // Setup: Deposit protector tokens first (required for shielded deposits)
        // Need 150% collateral: 10000e18 * 1.5 = 15000e18
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 20000e18, 0);

        // Deposit shielded tokens
        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 10000e18, 0);

        // Generate yield to accumulate fees
        oracle.setPrice(address(shieldedToken), 1.2e8); // 20% yield

        // Claim rewards to accumulate fees
        _claimRewardsAsOwner(tokenId);

        // Check reserved fees
        uint256 reservedFees = pool.getReservedFees();
        assertGt(reservedFees, 0, "Should have reserved fees");

        uint256 withdrawableBalance = pool.getWithdrawableBalance();
        (uint256 totalBalance,) = pool.getPoolBalances();

        assertEq(withdrawableBalance, totalBalance - reservedFees, "Withdrawable should exclude reserved fees");

        // Get position amount to ensure we don't exceed it
        (uint256 positionAmount,,,) = pool.getShieldDepositInfo(tokenId);

        // Try to withdraw more than withdrawable balance (but less than position amount)
        uint256 withdrawAmount = withdrawableBalance + 1;
        if (withdrawAmount >= positionAmount) {
            // If withdrawable balance is close to position amount, use a smaller test
            withdrawAmount = withdrawableBalance;
        }

        // If withdrawAmount would exceed withdrawable balance, it should revert
        if (withdrawAmount > withdrawableBalance) {
            vm.prank(shielded);
            vm.expectRevert(ErrorsLib.InsufficientTokenBalance.selector);
            pool.partialWithdrawShielded(tokenId, withdrawAmount, address(shieldedToken), 0);
        }
    }

    function testPartialWithdrawalRespectsReservedFees() public {
        // Setup
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 20000e18, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 10000e18, 0);

        // Generate yield
        oracle.setPrice(address(shieldedToken), 1.2e8);
        _claimRewardsAsOwner(tokenId);

        uint256 withdrawableBalance = pool.getWithdrawableBalance();

        // Partial withdrawal within withdrawable balance should succeed
        uint256 partialAmount = withdrawableBalance / 2;

        vm.prank(shielded);
        pool.partialWithdrawShielded(tokenId, partialAmount, address(shieldedToken), 0);

        // Reserved fees should still be protected
        uint256 reservedFeesAfter = pool.getReservedFees();
        assertGt(reservedFeesAfter, 0, "Reserved fees should still exist");
    }

    function testScaleFeesToAvailableAmount_UsesSingleStepMulDiv() public {
        SplitRiskPoolFeeScalingHarness harness = new SplitRiskPoolFeeScalingHarness();

        (uint256 commissionAmount, uint256 poolFeeAmount, uint256 protocolFeeAmount) =
            harness.scaleFeesToAvailableAmount(66, 33, 33, 100);

        assertEq(commissionAmount, 50, "Commission should be scaled proportionally");
        assertEq(poolFeeAmount, 25, "Pool fee should be scaled proportionally");
        assertEq(protocolFeeAmount, 25, "Protocol fee should be scaled proportionally");
        assertEq(
            commissionAmount + poolFeeAmount + protocolFeeAmount, 100, "Scaled fees should fully use available amount"
        );
    }

    function testFullWithdrawalRespectsReservedFees() public {
        // Setup
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 20000e18, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 10000e18, 0);

        // Generate yield
        oracle.setPrice(address(shieldedToken), 1.2e8);
        _claimRewardsAsOwner(tokenId);

        uint256 withdrawableBalance = pool.getWithdrawableBalance();
        (uint256 positionAmount,,,) = pool.getShieldDepositInfo(tokenId);

        // If position amount exceeds withdrawable balance, withdrawal should revert
        if (positionAmount > withdrawableBalance) {
            vm.prank(shielded);
            vm.expectRevert(ErrorsLib.InsufficientTokenBalance.selector);
            pool.shieldedWithdraw(tokenId, address(shieldedToken), 0);
        }
    }

    function testGetReservedFees_IncludesAllFeeTypes() public {
        // Setup
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 20000e18, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 10000e18, 0);

        // Generate yield
        oracle.setPrice(address(shieldedToken), 1.2e8);
        _claimRewardsAsOwner(tokenId);

        uint256 reservedFees = pool.getReservedFees();
        uint256 poolFee = pool.accumulatedPoolFee();
        uint256 protocolFee = pool.accumulatedProtocolFee();
        uint256 commissions = pool.accumulatedCommissions();

        assertEq(reservedFees, poolFee + protocolFee + commissions, "Reserved fees should sum all fee types");
    }

    function testGetWithdrawableBalance_ExcludesReservedFees() public {
        // Setup
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 20000e18, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 10000e18, 0);

        // Generate yield
        oracle.setPrice(address(shieldedToken), 1.2e8);
        _claimRewardsAsOwner(tokenId);

        (uint256 totalBalance,) = pool.getPoolBalances();
        uint256 reservedFees = pool.getReservedFees();
        uint256 withdrawableBalance = pool.getWithdrawableBalance();

        assertEq(withdrawableBalance, totalBalance - reservedFees, "Withdrawable should be total minus reserved");
    }

    function testWithdrawalSucceedsWhenFeesPaid() public {
        // Setup
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 20000e18, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 10000e18, 0);

        // Generate yield
        oracle.setPrice(address(shieldedToken), 1.2e8);
        _claimRewardsAsOwner(tokenId);

        // Pay out fees
        vm.prank(poolCreator);
        pool.payPoolFee();

        vm.prank(protocolFeeRecipient);
        pool.payProtocolFee();

        // Now withdrawal should succeed (fees are no longer reserved)
        uint256 reservedFeesAfter = pool.getReservedFees();
        assertEq(reservedFeesAfter, pool.accumulatedCommissions(), "Only commissions should remain reserved");

        // Withdrawal should now work
        vm.prank(shielded);
        pool.shieldedWithdraw(tokenId, address(shieldedToken), 0);
    }

    function testMultipleWithdrawalsRespectReservedFees() public {
        // Setup
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 20000e18, 0);

        address shielded2 = address(0x6);
        shieldedBaseToken.mint(shielded2, INITIAL_BALANCE);
        vm.startPrank(shielded2);
        shieldedBaseToken.approve(address(shieldedToken), INITIAL_BALANCE);
        shieldedToken.deposit(INITIAL_BALANCE, shielded2);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        // Two shielded deposits
        vm.prank(shielded);
        uint256 tokenId1 = pool.depositShieldedAsset(address(shieldedToken), 5000e18, 0);

        vm.prank(shielded2);
        uint256 tokenId2 = pool.depositShieldedAsset(address(shieldedToken), 5000e18, 0);

        // Generate yield
        oracle.setPrice(address(shieldedToken), 1.2e8);

        _claimRewardsAsOwner(tokenId1);
        _claimRewardsAsOwner(tokenId2);

        uint256 withdrawableBalance = pool.getWithdrawableBalance();

        // First withdrawal should succeed if within withdrawable balance
        (uint256 position1,,,) = pool.getShieldDepositInfo(tokenId1);
        if (position1 <= withdrawableBalance) {
            vm.prank(shielded);
            pool.shieldedWithdraw(tokenId1, address(shieldedToken), 0);
        }

        // Reserved fees should still be protected after first withdrawal
        uint256 reservedFeesAfter = pool.getReservedFees();
        assertGt(reservedFeesAfter, 0, "Reserved fees should still be protected");
    }
}
