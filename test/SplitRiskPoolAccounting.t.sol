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

/// @title Tests for totalShieldedTokens accounting consistency
/// @notice Verifies that totalShieldedTokens always equals sum of active position amounts
contract SplitRiskPoolAccountingTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    ShieldReceiptNFT public shieldNFT;
    ProtectorReceiptNFT public protectorNFT;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;

    address public protector = address(0x1);
    address public shielded1 = address(0x2);
    address public shielded2 = address(0x3);
    address public governance = address(this);

    uint256 constant INITIAL_BALANCE = 1000000e18;

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

        // Deploy base ERC20 tokens
        shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        backingBaseToken = new MockERC20("Backing Base Token", "BBASE");

        // Deploy ERC4626 vaults
        backingToken = new MockERC4626(backingBaseToken, "Backing Token", "BACK");
        shieldedToken = new MockERC4626(shieldedBaseToken, "Shielded Token", "SHIELD");

        // Deploy oracle
        oracle = new MockOracle();
        oracle.setPrice(address(shieldedToken), 1e8); // $1 per token
        oracle.setPrice(address(backingToken), 1e8); // $1 per token

        // Create TokenInfo structs
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "SHIELD",
            symbol: "SHIELD",
            token: address(shieldedToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "BACK",
            symbol: "BACK",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        // Deploy pool
        SplitRiskPool implementation = new SplitRiskPool();
        shieldNFT = new ShieldReceiptNFT("sSHIELD", "sSHIELD");
        protectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000, // 10% commission rate
            500, // 5% pool fee
            address(this), // pool creator
            15000, // 150% collateral ratio
            governance, // governance
            address(oracle), // oracle
            address(0xdead), // protocol fee recipient
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
        shieldedBaseToken.mint(shielded1, INITIAL_BALANCE);
        shieldedBaseToken.mint(shielded2, INITIAL_BALANCE);
        backingBaseToken.mint(protector, INITIAL_BALANCE);

        // Deposit into vaults
        vm.startPrank(protector);
        backingBaseToken.approve(address(backingToken), INITIAL_BALANCE);
        backingToken.deposit(INITIAL_BALANCE, protector);
        vm.stopPrank();

        vm.startPrank(shielded1);
        shieldedBaseToken.approve(address(shieldedToken), INITIAL_BALANCE);
        shieldedToken.deposit(INITIAL_BALANCE, shielded1);
        vm.stopPrank();

        vm.startPrank(shielded2);
        shieldedBaseToken.approve(address(shieldedToken), INITIAL_BALANCE);
        shieldedToken.deposit(INITIAL_BALANCE, shielded2);
        vm.stopPrank();

        // Protector deposits to pool first
        vm.startPrank(protector);
        backingToken.approve(address(pool), 500000e18);
        pool.depositBackingAsset(address(backingToken), 500000e18, 0);
        vm.stopPrank();
    }

    /// @notice Calculate sum of all active shielded position amounts
    function _sumActivePositionAmounts() internal view returns (uint256 total) {
        uint256 nextId = shieldNFT.nextTokenId();
        for (uint256 i = 0; i < nextId; i++) {
            try shieldNFT.ownerOf(i) returns (address owner) {
                if (owner != address(0)) {
                    IShieldReceiptNFT.ShieldPosition memory pos = shieldNFT.getPosition(i);
                    if (!pos.isWithdrawn) {
                        total += pos.amount;
                    }
                }
            } catch {
                // Token doesn't exist (burned), skip
            }
        }
    }

    /// @notice Calculate sum of all active shielded position valueAtDeposit values
    function _sumActivePositionValueAtDeposit() internal view returns (uint256 total) {
        uint256 nextId = shieldNFT.nextTokenId();
        for (uint256 i = 0; i < nextId; i++) {
            try shieldNFT.ownerOf(i) returns (address owner) {
                if (owner != address(0)) {
                    IShieldReceiptNFT.ShieldPosition memory pos = shieldNFT.getPosition(i);
                    if (!pos.isWithdrawn) {
                        total += pos.valueAtDeposit;
                    }
                }
            } catch {
                // Token doesn't exist (burned), skip
            }
        }
    }

    /// @notice Assert that totalShieldedTokens matches sum of position amounts
    function _assertTotalShieldedTokensConsistent() internal view {
        uint256 recorded = pool.totalShieldedTokens();
        uint256 actual = _sumActivePositionAmounts();
        assertEq(recorded, actual, "totalShieldedTokens != sum of position amounts");
    }

    /// @notice Assert that totalValueAtDeposit matches sum of position valueAtDeposit values
    function _assertTotalValueAtDepositConsistent() internal view {
        uint256 recorded = pool.totalValueAtDeposit();
        uint256 actual = _sumActivePositionValueAtDeposit();
        assertEq(recorded, actual, "totalValueAtDeposit != sum of position valueAtDeposit values");
    }

    function _claimRewardsAsOwner(uint256 tokenId) internal {
        vm.prank(shieldNFT.ownerOf(tokenId));
        pool.claimRewards(tokenId);
    }

    // ============ Test: Deposit ============

    function test_deposit_UpdatesTotalShieldedTokensCorrectly() public {
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 1000e18);
        pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        vm.stopPrank();

        _assertTotalShieldedTokensConsistent();
        assertEq(pool.totalShieldedTokens(), 1000e18);
    }

    function test_deposit_UpdatesTotalValueAtDepositCorrectly() public {
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 1000e18);
        pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        vm.stopPrank();

        _assertTotalValueAtDepositConsistent();
        // At $1 per token, valueAtDeposit should be 1000e8 (USD, 8 decimals)
        assertEq(pool.totalValueAtDeposit(), 1000e8);
    }

    // ============ Test: Full Withdrawal ============

    function test_shieldedWithdraw_UpdatesTotalShieldedTokensCorrectly() public {
        // Deposit
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 1000e18);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        vm.stopPrank();

        _assertTotalShieldedTokensConsistent();

        // Withdraw
        vm.prank(shielded1);
        pool.shieldedWithdraw(tokenId, address(shieldedToken), 0);

        _assertTotalShieldedTokensConsistent();
        assertEq(pool.totalShieldedTokens(), 0);
    }

    // ============ Test: Partial Withdrawal ============

    function test_partialWithdraw_UpdatesTotalShieldedTokensCorrectly() public {
        // Deposit
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 1000e18);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        vm.stopPrank();

        uint256 totalBefore = pool.totalShieldedTokens();
        assertEq(totalBefore, 1000e18);

        // Simulate yield by increasing token price (creates fees)
        oracle.setPrice(address(shieldedToken), 1.1e8); // 10% price increase

        // Partial withdraw
        vm.prank(shielded1);
        pool.partialWithdrawShielded(tokenId, 300e18, address(shieldedToken), 0);

        // After partial withdrawal, totalShieldedTokens should equal sum of positions
        _assertTotalShieldedTokensConsistent();

        // The new total should be: original (1000) - withdrawn (300) - fees
        // Fees are taken from the position, so totalShieldedTokens accounts for them
        uint256 totalAfter = pool.totalShieldedTokens();
        assertTrue(
            totalAfter < totalBefore - 300e18,
            "totalShieldedTokens should be reduced by more than withdrawAmount due to fees"
        );
    }

    function test_partialWithdrawShielded_UpdatesTotalValueAtDepositCorrectly() public {
        // Deposit
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 1000e18);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        vm.stopPrank();

        uint256 originalValueAtDeposit = pool.totalValueAtDeposit();
        assertEq(originalValueAtDeposit, 1000e8); // $1000 at $1 per token
        _assertTotalValueAtDepositConsistent();

        // Partial withdraw 30% (300 tokens)
        vm.prank(shielded1);
        uint256 newTokenId = pool.partialWithdrawShielded(tokenId, 300e18, address(shieldedToken), 0);

        _assertTotalValueAtDepositConsistent();

        // Calculate expected new valueAtDeposit proportionally
        // Original: 1000e8, withdraw 300/1000 = 30%, remaining 70%
        // New valueAtDeposit should be: 1000e8 * 700 / 1000 = 700e8
        uint256 expectedNewValueAtDeposit = (originalValueAtDeposit * 700e18) / 1000e18;

        // Get new position's valueAtDeposit
        IShieldReceiptNFT.ShieldPosition memory posAfter = shieldNFT.getPosition(newTokenId);
        assertEq(
            posAfter.valueAtDeposit, expectedNewValueAtDeposit, "New position valueAtDeposit should be proportional"
        );
        assertEq(
            pool.totalValueAtDeposit(), expectedNewValueAtDeposit, "totalValueAtDeposit should match new position value"
        );
    }

    // ============ Test: Claim Rewards ============

    function test_claimRewards_UpdatesTotalShieldedTokensCorrectly() public {
        // Deposit
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 1000e18);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        vm.stopPrank();

        uint256 totalBefore = pool.totalShieldedTokens();
        assertEq(totalBefore, 1000e18);
        _assertTotalShieldedTokensConsistent();

        // Simulate yield by increasing token price
        oracle.setPrice(address(shieldedToken), 1.1e8); // 10% price increase

        // Claim rewards (triggers fee accumulation)
        _claimRewardsAsOwner(tokenId);

        // After claimRewards, totalShieldedTokens should still equal sum of positions
        _assertTotalShieldedTokensConsistent();

        // Total should be reduced by the fees taken
        uint256 totalAfter = pool.totalShieldedTokens();
        assertTrue(totalAfter < totalBefore, "totalShieldedTokens should be reduced by fees");
    }

    function test_claimRewards_DoesNotChangeTotalValueAtDeposit() public {
        // Deposit
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 1000e18);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        vm.stopPrank();

        uint256 valueAtDepositBefore = pool.totalValueAtDeposit();
        assertEq(valueAtDepositBefore, 1000e8); // $1000 at $1 per token
        _assertTotalValueAtDepositConsistent();

        // Simulate yield by increasing token price (creates fees)
        oracle.setPrice(address(shieldedToken), 1.1e8); // 10% price increase

        // Claim rewards (triggers fee accumulation)
        _claimRewardsAsOwner(tokenId);

        // totalValueAtDeposit should NOT change (original deposit value stays the same)
        // Only totalShieldedTokens (current position amount) changes due to fees
        uint256 valueAtDepositAfter = pool.totalValueAtDeposit();
        assertEq(
            valueAtDepositAfter, valueAtDepositBefore, "totalValueAtDeposit should remain unchanged after claimRewards"
        );
        _assertTotalValueAtDepositConsistent();
    }

    // ============ Test: Multiple Claims ============

    function test_multipleClaimRewards_TotalShieldedTokensStaysConsistent() public {
        // Deposit
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 1000e18);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        vm.stopPrank();

        // First claim
        oracle.setPrice(address(shieldedToken), 1.1e8);
        _claimRewardsAsOwner(tokenId);
        _assertTotalShieldedTokensConsistent();

        // Skip cooldown and second claim
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(address(shieldedToken), 1.2e8);
        _claimRewardsAsOwner(tokenId);
        _assertTotalShieldedTokensConsistent();

        // Skip cooldown and third claim
        vm.warp(block.timestamp + 1 days + 2);
        oracle.setPrice(address(shieldedToken), 1.3e8);
        _claimRewardsAsOwner(tokenId);
        _assertTotalShieldedTokensConsistent();
    }

    // ============ Test: Complex Scenario ============

    function test_multipleOperations_TotalShieldedTokensConsistency() public {
        // User1 deposits
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), 5000e18);
        uint256 tokenId1 = pool.depositShieldedAsset(address(shieldedToken), 2000e18, 0);
        vm.stopPrank();
        _assertTotalShieldedTokensConsistent();

        // User2 deposits
        vm.startPrank(shielded2);
        shieldedToken.approve(address(pool), 5000e18);
        uint256 tokenId2 = pool.depositShieldedAsset(address(shieldedToken), 3000e18, 0);
        vm.stopPrank();
        _assertTotalShieldedTokensConsistent();

        // Price goes up, claim rewards on both
        oracle.setPrice(address(shieldedToken), 1.1e8);
        _claimRewardsAsOwner(tokenId1);
        _assertTotalShieldedTokensConsistent();
        _claimRewardsAsOwner(tokenId2);
        _assertTotalShieldedTokensConsistent();

        // User1 partial withdraws
        vm.prank(shielded1);
        pool.partialWithdrawShielded(tokenId1, 500e18, address(shieldedToken), 0);
        _assertTotalShieldedTokensConsistent();

        // User2 full withdraws
        vm.prank(shielded2);
        pool.shieldedWithdraw(tokenId2, address(shieldedToken), 0);
        _assertTotalShieldedTokensConsistent();

        // User1 claims rewards again
        vm.warp(block.timestamp + 1 days + 1);
        oracle.setPrice(address(shieldedToken), 1.2e8);

        // Need to find the new token ID from partial withdrawal
        uint256 newTokenId = shieldNFT.nextTokenId() - 1;
        _claimRewardsAsOwner(newTokenId);
        _assertTotalShieldedTokensConsistent();
    }

    // ============ Test: Fuzz ============

    function testFuzz_partialWithdraw_Consistency(uint256 depositAmount, uint256 withdrawAmount) public {
        // Bound inputs to ensure valid partial withdrawal
        // Need: depositAmount >= minDeposit + withdrawAmount + fees_buffer
        depositAmount = bound(depositAmount, 1000e18, 100000e18);
        // Max withdraw is deposit minus minimum remaining (200e18 to account for fees and min deposit)
        withdrawAmount = bound(withdrawAmount, 100e18, depositAmount - 200e18);

        // Deposit
        vm.startPrank(shielded1);
        shieldedToken.approve(address(pool), depositAmount);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), depositAmount, 0);
        vm.stopPrank();

        _assertTotalShieldedTokensConsistent();

        // Partial withdraw
        vm.prank(shielded1);
        try pool.partialWithdrawShielded(tokenId, withdrawAmount, address(shieldedToken), 0) {
            _assertTotalShieldedTokensConsistent();
        } catch {
            // If it reverts (e.g., below minimum), that's ok, just verify consistency still holds
            _assertTotalShieldedTokensConsistent();
        }
    }
}
