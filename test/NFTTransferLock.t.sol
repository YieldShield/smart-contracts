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
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IProtectorReceiptNFT } from "../contracts/interfaces/IProtectorReceiptNFT.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

/// @title INFO-6 FIX: NFT Transfer Lock Boundary Tests
/// @notice Tests for NFT transfer lock boundaries - exact timing at lock period boundaries
contract NFTTransferLockTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    ShieldReceiptNFT public shieldNFT;
    ProtectorReceiptNFT public protectorNFT;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;

    address public protector = address(0x1);
    address public shielded = address(0x2);
    address public recipient = address(0x3);
    address public governance = address(this);

    uint256 constant INITIAL_BALANCE = 1000000e18;
    uint256 constant SHIELD_LOCK_PERIOD = 1 days;
    uint256 constant PROTECTOR_LOCK_PERIOD = 28 days;

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
        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

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

        // Deploy pool and NFTs
        SplitRiskPool implementation = new SplitRiskPool();
        shieldNFT = new ShieldReceiptNFT("sSHIELD", "sSHIELD");
        protectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000, // 10% commission
            500, // 5% pool fee
            address(this), // pool creator
            15000, // 150% collateral
            governance,
            address(oracle),
            address(0xfa9605A2c38a0B4f16f689FDD07B63F295b86d1C), // protocol fee recipient
            address(shieldNFT),
            address(protectorNFT),
            address(this)
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

        // Deposit into vaults
        vm.startPrank(shielded);
        shieldedBaseToken.approve(address(shieldedToken), INITIAL_BALANCE);
        shieldedToken.deposit(INITIAL_BALANCE, shielded);
        vm.stopPrank();

        vm.startPrank(protector);
        backingBaseToken.approve(address(backingToken), INITIAL_BALANCE);
        backingToken.deposit(INITIAL_BALANCE, protector);
        vm.stopPrank();
    }

    // ============ Shield NFT Transfer Lock Tests ============

    function test_ShieldNFT_TransferBlockedDuringLock() public {
        // Deposit and get NFT
        uint256 tokenId = _depositShielded(1000e18);

        // Try to transfer immediately - should fail
        vm.startPrank(shielded);
        vm.expectRevert();
        shieldNFT.transferFrom(shielded, recipient, tokenId);
        vm.stopPrank();
    }

    function test_ShieldNFT_TransferBlockedOneSecondBeforeLockExpiry() public {
        uint256 tokenId = _depositShielded(1000e18);

        // Warp to 1 second before lock expiry
        vm.warp(block.timestamp + SHIELD_LOCK_PERIOD - 1);

        // Transfer should still fail
        vm.startPrank(shielded);
        vm.expectRevert();
        shieldNFT.transferFrom(shielded, recipient, tokenId);
        vm.stopPrank();
    }

    function test_ShieldNFT_TransferSucceedsAtExactLockExpiry() public {
        uint256 depositTime = block.timestamp;
        uint256 tokenId = _depositShielded(1000e18);

        // Warp to exact lock expiry
        vm.warp(depositTime + SHIELD_LOCK_PERIOD);

        // Transfer should succeed
        vm.startPrank(shielded);
        shieldNFT.transferFrom(shielded, recipient, tokenId);
        vm.stopPrank();

        assertEq(shieldNFT.ownerOf(tokenId), recipient);
    }

    function test_ShieldNFT_TransferSucceedsAfterLockExpiry() public {
        uint256 tokenId = _depositShielded(1000e18);

        // Warp past lock expiry
        vm.warp(block.timestamp + SHIELD_LOCK_PERIOD + 1 hours);

        // Transfer should succeed
        vm.startPrank(shielded);
        shieldNFT.transferFrom(shielded, recipient, tokenId);
        vm.stopPrank();

        assertEq(shieldNFT.ownerOf(tokenId), recipient);
    }

    function test_ShieldNFT_ApprovalDuringLockPeriod_Reverts() public {
        uint256 tokenId = _depositShielded(1000e18);

        // H-7: approvals during lock are rejected so pre-approval of a
        // wrapper contract cannot sweep the position the instant the lock
        // expires.
        vm.startPrank(shielded);
        vm.expectRevert();
        shieldNFT.approve(recipient, tokenId);
        vm.stopPrank();
    }

    function test_ShieldNFT_ApprovalAllowedAfterLockExpiry() public {
        uint256 tokenId = _depositShielded(1000e18);
        vm.warp(block.timestamp + SHIELD_LOCK_PERIOD);
        vm.startPrank(shielded);
        shieldNFT.approve(recipient, tokenId);
        vm.stopPrank();
        assertEq(shieldNFT.getApproved(tokenId), recipient);
    }

    function test_ShieldNFT_OperatorApprovalBeforeDepositCannotSweepAfterUnlock() public {
        vm.prank(shielded);
        shieldNFT.setApprovalForAll(recipient, true);

        uint256 tokenId = _depositShielded(1000e18);
        vm.warp(block.timestamp + SHIELD_LOCK_PERIOD);

        vm.prank(recipient);
        vm.expectRevert();
        shieldNFT.transferFrom(shielded, recipient, tokenId);

        vm.prank(shielded);
        shieldNFT.setApprovalForAll(recipient, true);

        vm.prank(recipient);
        shieldNFT.transferFrom(shielded, recipient, tokenId);
        assertEq(shieldNFT.ownerOf(tokenId), recipient);
    }

    function test_ShieldNFT_OperatorApprovalDuringLockCannotSweepAfterUnlock() public {
        uint256 tokenId = _depositShielded(1000e18);

        vm.prank(shielded);
        shieldNFT.setApprovalForAll(recipient, true);

        vm.warp(block.timestamp + SHIELD_LOCK_PERIOD);

        vm.prank(recipient);
        vm.expectRevert();
        shieldNFT.transferFrom(shielded, recipient, tokenId);

        vm.prank(shielded);
        shieldNFT.setApprovalForAll(recipient, true);

        vm.prank(recipient);
        shieldNFT.transferFrom(shielded, recipient, tokenId);
        assertEq(shieldNFT.ownerOf(tokenId), recipient);
    }

    // ============ Protector NFT Transfer Lock Tests ============

    function test_ProtectorNFT_TransferBlockedDuringLock() public {
        uint256 tokenId = _depositProtector(1000e18);

        // Try to transfer immediately - should fail
        vm.startPrank(protector);
        vm.expectRevert();
        protectorNFT.transferFrom(protector, recipient, tokenId);
        vm.stopPrank();
    }

    function test_ProtectorNFT_TransferBlockedOneSecondBeforeLockExpiry() public {
        uint256 tokenId = _depositProtector(1000e18);

        // Warp to 1 second before lock expiry
        vm.warp(block.timestamp + PROTECTOR_LOCK_PERIOD - 1);

        // Transfer should still fail
        vm.startPrank(protector);
        vm.expectRevert();
        protectorNFT.transferFrom(protector, recipient, tokenId);
        vm.stopPrank();
    }

    function test_ProtectorNFT_TransferSucceedsAtExactLockExpiry() public {
        uint256 depositTime = block.timestamp;
        uint256 tokenId = _depositProtector(1000e18);

        // Warp to exact lock expiry
        vm.warp(depositTime + PROTECTOR_LOCK_PERIOD);

        // Transfer should succeed
        vm.startPrank(protector);
        protectorNFT.transferFrom(protector, recipient, tokenId);
        vm.stopPrank();

        assertEq(protectorNFT.ownerOf(tokenId), recipient);
    }

    function test_ProtectorNFT_TransferSucceedsAfterLockExpiry() public {
        uint256 tokenId = _depositProtector(1000e18);

        // Warp past lock expiry
        vm.warp(block.timestamp + PROTECTOR_LOCK_PERIOD + 1 days);

        // Transfer should succeed
        vm.startPrank(protector);
        protectorNFT.transferFrom(protector, recipient, tokenId);
        vm.stopPrank();

        assertEq(protectorNFT.ownerOf(tokenId), recipient);
    }

    function test_ProtectorNFT_ApprovalDuringLockPeriod_Reverts() public {
        uint256 tokenId = _depositProtector(1000e18);

        // H-7: approvals during lock are rejected.
        vm.startPrank(protector);
        vm.expectRevert();
        protectorNFT.approve(recipient, tokenId);
        vm.stopPrank();
    }

    function test_ProtectorNFT_ApprovalAllowedAfterLockExpiry() public {
        uint256 tokenId = _depositProtector(1000e18);
        vm.warp(block.timestamp + PROTECTOR_LOCK_PERIOD);
        vm.startPrank(protector);
        protectorNFT.approve(recipient, tokenId);
        vm.stopPrank();
        assertEq(protectorNFT.getApproved(tokenId), recipient);
    }

    function test_ProtectorNFT_OperatorApprovalBeforeDepositCannotSweepAfterUnlock() public {
        vm.prank(protector);
        protectorNFT.setApprovalForAll(recipient, true);

        uint256 tokenId = _depositProtector(1000e18);
        vm.warp(block.timestamp + PROTECTOR_LOCK_PERIOD);

        vm.prank(recipient);
        vm.expectRevert();
        protectorNFT.transferFrom(protector, recipient, tokenId);

        vm.prank(protector);
        protectorNFT.setApprovalForAll(recipient, true);

        vm.prank(recipient);
        protectorNFT.transferFrom(protector, recipient, tokenId);
        assertEq(protectorNFT.ownerOf(tokenId), recipient);
    }

    function test_ProtectorNFT_OperatorApprovalDuringLockCannotSweepAfterUnlock() public {
        uint256 tokenId = _depositProtector(1000e18);

        vm.prank(protector);
        protectorNFT.setApprovalForAll(recipient, true);

        vm.warp(block.timestamp + PROTECTOR_LOCK_PERIOD);

        vm.prank(recipient);
        vm.expectRevert();
        protectorNFT.transferFrom(protector, recipient, tokenId);

        vm.prank(protector);
        protectorNFT.setApprovalForAll(recipient, true);

        vm.prank(recipient);
        protectorNFT.transferFrom(protector, recipient, tokenId);
        assertEq(protectorNFT.ownerOf(tokenId), recipient);
    }

    // ============ Edge Case: Multiple NFTs - Basic Independence Test ============

    function test_MultipleNFTs_EachHasOwnDepositTime() public {
        // First deposit
        uint256 tokenId1 = _depositProtector(500e18);
        IProtectorReceiptNFT.ProtectorPosition memory pos1 = protectorNFT.getPosition(tokenId1);

        // Wait and do second deposit
        vm.warp(block.timestamp + 7 days);
        uint256 tokenId2 = _depositProtector(500e18);
        IProtectorReceiptNFT.ProtectorPosition memory pos2 = protectorNFT.getPosition(tokenId2);

        // Verify each NFT has its own depositTime
        assertTrue(pos2.depositTime > pos1.depositTime, "Second NFT should have later deposit time");
        assertEq(pos2.depositTime - pos1.depositTime, 7 days, "Deposit times should differ by 7 days");

        // Both NFTs owned by protector
        assertEq(protectorNFT.ownerOf(tokenId1), protector);
        assertEq(protectorNFT.ownerOf(tokenId2), protector);

        // First NFT becomes transferable after its lock period
        vm.warp(pos1.depositTime + protectorNFT.transferLockPeriod());
        vm.prank(protector);
        protectorNFT.transferFrom(protector, recipient, tokenId1);
        assertEq(protectorNFT.ownerOf(tokenId1), recipient);

        // Second NFT becomes transferable after its own lock period
        vm.warp(pos2.depositTime + protectorNFT.transferLockPeriod());
        vm.prank(protector);
        protectorNFT.transferFrom(protector, recipient, tokenId2);
        assertEq(protectorNFT.ownerOf(tokenId2), recipient);
    }

    function test_ProtectorNFT_InterfaceExposesFreshnessFlag() public {
        uint256 tokenId = _depositProtector(500e18);

        (IProtectorReceiptNFT.ProtectorPosition memory position, bool isFresh) =
            IProtectorReceiptNFT(address(protectorNFT)).getPositionWithFreshness(tokenId);

        assertTrue(isFresh, "newly minted protector position should be fresh");
        assertEq(position.amount, 500e18, "interface should return position details");
    }

    // ============ Helper Functions ============

    function _depositProtector(uint256 amount) internal returns (uint256 tokenId) {
        vm.startPrank(protector);
        backingToken.approve(address(pool), amount);
        tokenId = pool.depositBackingAsset(address(backingToken), amount, 0);
        vm.stopPrank();
    }

    function _depositShielded(uint256 amount) internal returns (uint256 tokenId) {
        // First need protector deposit for capacity
        _depositProtector(amount * 2);

        vm.startPrank(shielded);
        shieldedToken.approve(address(pool), amount);
        tokenId = pool.depositShieldedAsset(address(shieldedToken), amount, 0);
        vm.stopPrank();
    }
}
