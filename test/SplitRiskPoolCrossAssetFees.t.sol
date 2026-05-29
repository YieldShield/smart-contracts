// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

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

/// @title Tests for cross-asset withdrawal fee accounting (M-6 fix)
contract SplitRiskPoolCrossAssetFeesTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;
    ShieldReceiptNFT public shieldNFT;
    ProtectorReceiptNFT public protectorNFT;

    address public poolCreator = address(0x1);
    address public protocolFeeRecipient = address(0x2);
    address public governance = address(0x3);
    address public shielded = address(0x4);
    address public protector = address(0x5);
    address public protector2 = address(0x6);

    uint256 constant INITIAL_BALANCE = 1_000_000e18;

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
            poolCreator, // pool creator
            15000, // 150% collateral ratio
            governance,
            address(oracle),
            protocolFeeRecipient,
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
        _fundAccount(shielded, shieldedBaseToken, shieldedToken);
        _fundAccount(protector, backingBaseToken, backingToken);
        _fundAccount(protector2, backingBaseToken, backingToken);
    }

    function _fundAccount(address account, MockERC20 baseToken, MockERC4626 vaultToken) internal {
        baseToken.mint(account, INITIAL_BALANCE);
        vm.startPrank(account);
        baseToken.approve(address(vaultToken), INITIAL_BALANCE);
        vaultToken.deposit(INITIAL_BALANCE, account);
        vaultToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _claimRewardsAsOwner(uint256 tokenId) internal {
        address owner = IShieldReceiptNFT(pool.shieldReceiptNFT()).ownerOf(tokenId);
        vm.prank(owner);
        pool.claimRewards(tokenId);
    }

    /// @notice Cross-asset withdrawal should maintain shielded balance covering positions + fees
    function testCrossAssetWithdrawal_MaintainsFeeAccounting() public {
        // 1. Protector deposits 200_000 backing tokens
        vm.prank(protector);
        uint256 protTokenId = pool.depositBackingAsset(address(backingToken), 200_000e18, 0);

        // 2. Shielded user deposits 100_000 shielded tokens
        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 100_000e18, 0);

        // 3. Simulate 20% yield: oracle price increases
        oracle.setPrice(address(shieldedToken), 1.2e8);

        // 4. Claim rewards to accumulate fees
        _claimRewardsAsOwner(shieldTokenId);

        // Record state before cross-asset withdrawal
        uint256 reservedFeesBefore = pool.getReservedFees();
        uint256 totalProtectorBefore = pool.totalProtectorTokens();
        assertGt(reservedFeesBefore, 0, "Should have accumulated fees");

        // 5. Warp past minimumPoolTime for cross-asset withdrawal
        (,,,,, uint256 minimumPoolTime,,,,) = pool.poolConfig();
        vm.warp(block.timestamp + minimumPoolTime + 1);

        // 6. Perform cross-asset withdrawal: withdraw shielded position as backing token
        vm.prank(shielded);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);

        // 7. Assert: shieldedToken balance covers remaining positions + fees
        uint256 shieldedBalance = shieldedToken.balanceOf(address(pool));
        uint256 totalShieldedTokens = pool.totalShieldedTokens();
        uint256 reservedFeesAfter = pool.getReservedFees();

        assertGe(
            shieldedBalance,
            totalShieldedTokens + reservedFeesAfter,
            "Shielded balance must cover positions + fees after cross-asset withdrawal"
        );

        // 8. Assert: totalProtectorTokens decreased (payout came from backing side)
        uint256 totalProtectorAfter = pool.totalProtectorTokens();
        assertLt(totalProtectorAfter, totalProtectorBefore, "Protector tokens should decrease from cross-asset payout");

        // 9. Remaining protectors can still withdraw their available amounts
        // Start unlock process
        vm.prank(protector);
        pool.startUnlockProcess(protTokenId);

        (,,,,,, uint256 unlockDuration,,,) = pool.poolConfig();
        vm.warp(block.timestamp + unlockDuration + 1);

        uint256 available = pool.getAvailableForWithdrawal(protTokenId);
        assertGt(available, 0, "Protector should still have available funds");

        // Withdraw should succeed
        vm.prank(protector);
        pool.protectorWithdraw(protTokenId, available, address(backingToken), 0);
    }

    /// @notice Fee accounting invariant holds even with multiple shielded positions and cross-asset
    function testCrossAssetWithdrawal_MultiplePositions_FeesConsistent() public {
        // Setup: two protectors
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 150_000e18, 0);

        vm.prank(protector2);
        pool.depositBackingAsset(address(backingToken), 150_000e18, 0);

        // Two shielded deposits
        vm.prank(shielded);
        uint256 tokenId1 = pool.depositShieldedAsset(address(shieldedToken), 50_000e18, 0);

        vm.prank(shielded);
        uint256 tokenId2 = pool.depositShieldedAsset(address(shieldedToken), 50_000e18, 0);

        // Generate yield
        oracle.setPrice(address(shieldedToken), 1.15e8); // 15% yield

        // Claim for both
        _claimRewardsAsOwner(tokenId1);
        vm.warp(block.timestamp + 1 days + 1);
        _claimRewardsAsOwner(tokenId2);

        // Warp past minimumPoolTime
        (,,,,, uint256 minimumPoolTime,,,,) = pool.poolConfig();
        vm.warp(block.timestamp + minimumPoolTime + 1);

        // Cross-asset withdraw the first position
        vm.prank(shielded);
        pool.shieldedWithdraw(tokenId1, address(backingToken), 0);

        // Invariant: shielded balance >= totalShieldedTokens + reservedFees
        uint256 shieldedBalance = shieldedToken.balanceOf(address(pool));
        uint256 totalShieldedTokens = pool.totalShieldedTokens();
        uint256 reservedFees = pool.getReservedFees();

        assertGe(
            shieldedBalance,
            totalShieldedTokens + reservedFees,
            "Balance must cover positions + fees after partial cross-asset withdrawal"
        );

        // Second position can still withdraw normally (same-asset)
        vm.prank(shielded);
        pool.shieldedWithdraw(tokenId2, address(shieldedToken), 0);

        // Final check: all positions withdrawn, fees should still be protected
        uint256 finalBalance = shieldedToken.balanceOf(address(pool));
        uint256 finalTotal = pool.totalShieldedTokens();
        uint256 finalFees = pool.getReservedFees();

        assertEq(finalTotal, 0, "All shielded positions should be withdrawn");
        assertGe(finalBalance, finalFees, "Remaining balance should cover reserved fees");
    }
}
