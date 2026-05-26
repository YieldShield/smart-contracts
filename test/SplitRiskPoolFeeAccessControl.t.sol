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
import { AccessControlExample } from "../contracts/examples/AccessControlExample.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

/// @title Tests for fee payment access control (NEW-1 FIX)
/// @notice Tests that payPoolFee() and payProtocolFee() are restricted to authorized callers
contract SplitRiskPoolFeeAccessControlTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;

    address public poolCreator = address(0x1);
    address public protocolFeeRecipient = address(0x2);
    address public governance = address(0x3);
    address public unauthorized = address(0x4);
    address public shielded = address(0x5);
    address public protector = address(0x6);

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
            governance // owner (same as governance for tests)
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

    function _seedClaimableCommission() internal returns (uint256 protectorTokenId) {
        vm.prank(protector);
        protectorTokenId = pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);

        oracle.setPrice(address(shieldedToken), 1.1e8);
        _claimRewardsAsOwner(shieldTokenId);

        assertGt(pool.getClaimableCommission(protectorTokenId), 0, "test requires claimable commission");
    }

    function testPayPoolFee_OnlyCreatorCanCall() public {
        // Deposit protector tokens first (required for shielded deposits)
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        // Create some accumulated pool fee by depositing and generating fees
        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);

        // Simulate yield by increasing price
        oracle.setPrice(address(shieldedToken), 1.1e8); // 10% yield

        // Claim rewards to accumulate fees
        _claimRewardsAsOwner(tokenId);

        uint256 poolFeeBefore = pool.accumulatedPoolFee();
        assertGt(poolFeeBefore, 0, "Should have accumulated pool fee");

        // Pool creator can call
        vm.prank(poolCreator);
        pool.payPoolFee();

        assertEq(pool.accumulatedPoolFee(), 0, "Pool fee should be reset");
        assertGt(IERC20(shieldedToken).balanceOf(poolCreator), 0, "Creator should receive fee");
    }

    function testPayPoolFee_GovernanceCanCall() public {
        // Deposit protector tokens first
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        // Create some accumulated pool fee
        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        oracle.setPrice(address(shieldedToken), 1.1e8);
        _claimRewardsAsOwner(tokenId);

        uint256 creatorBalanceBefore = IERC20(shieldedToken).balanceOf(poolCreator);

        // Governance can call
        vm.prank(governance);
        pool.payPoolFee();

        assertEq(pool.accumulatedPoolFee(), 0, "Pool fee should be reset");
        assertGt(
            IERC20(shieldedToken).balanceOf(poolCreator),
            creatorBalanceBefore,
            "Creator should receive fee (even when called by governance)"
        );
    }

    function testPayPoolFee_RevertsForUnauthorized() public {
        // Deposit protector tokens first
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        // Create some accumulated pool fee
        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        oracle.setPrice(address(shieldedToken), 1.1e8);
        _claimRewardsAsOwner(tokenId);

        // Unauthorized caller should revert
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AccessControlDenied.selector, unauthorized, "payPoolFee"));
        pool.payPoolFee();
    }

    function testPayProtocolFee_OnlyRecipientCanCall() public {
        // Deposit protector tokens first
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        // Create some accumulated protocol fee
        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        oracle.setPrice(address(shieldedToken), 1.1e8);
        _claimRewardsAsOwner(tokenId);

        uint256 protocolFeeBefore = pool.accumulatedProtocolFee();
        assertGt(protocolFeeBefore, 0, "Should have accumulated protocol fee");

        // Protocol fee recipient can call
        vm.prank(protocolFeeRecipient);
        pool.payProtocolFee();

        assertEq(pool.accumulatedProtocolFee(), 0, "Protocol fee should be reset");
        assertGt(IERC20(shieldedToken).balanceOf(protocolFeeRecipient), 0, "Recipient should receive fee");
    }

    function testPayProtocolFee_GovernanceCanCall() public {
        // Deposit protector tokens first
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        // Create some accumulated protocol fee
        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        oracle.setPrice(address(shieldedToken), 1.1e8);
        _claimRewardsAsOwner(tokenId);

        uint256 recipientBalanceBefore = IERC20(shieldedToken).balanceOf(protocolFeeRecipient);

        // Governance can call
        vm.prank(governance);
        pool.payProtocolFee();

        assertEq(pool.accumulatedProtocolFee(), 0, "Protocol fee should be reset");
        assertGt(
            IERC20(shieldedToken).balanceOf(protocolFeeRecipient),
            recipientBalanceBefore,
            "Recipient should receive fee (even when called by governance)"
        );
    }

    function testSetAccessControl_CreatorCanConfigureBeforeLaunch() public {
        AccessControlExample accessControl = new AccessControlExample(governance);

        vm.prank(poolCreator);
        pool.setAccessControl(address(accessControl));

        assertEq(pool.accessControl(), address(accessControl), "creator should configure ACL before launch");
        assertFalse(pool.accessControlCanGateWithdrawals(), "creator-installed ACL should not gate withdrawals");
    }

    function testSetAccessControl_CreatorCannotChangeAfterLaunch() public {
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        AccessControlExample accessControl = new AccessControlExample(governance);

        vm.prank(poolCreator);
        vm.expectRevert(ErrorsLib.InvalidPoolCreator.selector);
        pool.setAccessControl(address(accessControl));
    }

    function testSetAccessControl_GovernanceCanChangeAfterLaunch() public {
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        AccessControlExample accessControl = new AccessControlExample(governance);

        vm.prank(governance);
        pool.setAccessControl(address(accessControl));

        assertEq(pool.accessControl(), address(accessControl), "governance should retain live ACL authority");
        assertTrue(pool.accessControlCanGateWithdrawals(), "governance-installed ACL may gate withdrawals");
    }

    function testSetAccessControl_GovernanceAclWithoutTimelockAuthorityCannotGateWithdrawals() public {
        AccessControlExample accessControl = new AccessControlExample(unauthorized);

        vm.startPrank(unauthorized);
        accessControl.setWhitelisted(protector, true);
        accessControl.setWhitelisted(shielded, true);
        vm.stopPrank();

        vm.prank(governance);
        pool.setAccessControl(address(accessControl));

        assertEq(pool.accessControl(), address(accessControl), "governance should install ACL");
        assertFalse(pool.accessControlCanGateWithdrawals(), "externally administered ACL should be deposit-only");
        assertTrue(pool.governanceAccessControlInstalled(), "governance ACL install should remain sticky");

        vm.prank(poolCreator);
        vm.expectRevert(ErrorsLib.InvalidPoolCreator.selector);
        pool.setAccessControl(address(0));

        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);

        vm.prank(unauthorized);
        accessControl.setWhitelisted(shielded, false);

        vm.prank(shielded);
        uint256 newTokenId = pool.partialWithdrawShielded(tokenId, 100e18, address(shieldedToken), 0);
        assertGt(newTokenId, tokenId, "externally administered ACL should not trap shielded withdrawals");
    }

    function testGovernanceInstalledAcl_StopsGatingWithdrawalsWhenAuthorityTransfersAway() public {
        AccessControlExample accessControl = new AccessControlExample(governance);

        vm.startPrank(governance);
        accessControl.setWhitelisted(protector, true);
        accessControl.setWhitelisted(shielded, true);
        pool.setAccessControl(address(accessControl));
        vm.stopPrank();

        assertTrue(pool.accessControlCanGateWithdrawals(), "timelock-administered ACL should gate withdrawals");

        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);

        vm.prank(governance);
        accessControl.setOwner(unauthorized);

        vm.prank(unauthorized);
        accessControl.setWhitelisted(shielded, false);

        vm.prank(shielded);
        uint256 newTokenId = pool.partialWithdrawShielded(tokenId, 100e18, address(shieldedToken), 0);
        assertGt(newTokenId, tokenId, "ACL should stop gating withdrawals after timelock loses authority");
    }

    function testSetAccessControl_CreatorCannotOverrideGovernanceAclBeforeLaunch() public {
        AccessControlExample governanceAccessControl = new AccessControlExample(governance);
        AccessControlExample creatorAccessControl = new AccessControlExample(governance);

        vm.prank(governance);
        pool.setAccessControl(address(governanceAccessControl));

        assertTrue(pool.accessControlCanGateWithdrawals(), "governance ACL should gate withdrawals");
        assertTrue(pool.governanceAccessControlInstalled(), "governance ACL install should be sticky");

        vm.prank(poolCreator);
        vm.expectRevert(ErrorsLib.InvalidPoolCreator.selector);
        pool.setAccessControl(address(creatorAccessControl));

        assertEq(pool.accessControl(), address(governanceAccessControl), "creator must not replace governance ACL");
        assertTrue(pool.accessControlCanGateWithdrawals(), "withdrawal gate should remain active");
    }

    function testSetAccessControl_CreatorCannotClearGovernanceAclBeforeLaunch() public {
        AccessControlExample governanceAccessControl = new AccessControlExample(governance);

        vm.prank(governance);
        pool.setAccessControl(address(governanceAccessControl));

        vm.prank(poolCreator);
        vm.expectRevert(ErrorsLib.InvalidPoolCreator.selector);
        pool.setAccessControl(address(0));

        assertEq(pool.accessControl(), address(governanceAccessControl), "creator must not clear governance ACL");
        assertTrue(pool.accessControlCanGateWithdrawals(), "withdrawal gate should remain active");
    }

    function testSetAccessControl_CreatorCannotOverrideAfterGovernanceDisablesAclBeforeLaunch() public {
        AccessControlExample governanceAccessControl = new AccessControlExample(governance);
        AccessControlExample creatorAccessControl = new AccessControlExample(governance);

        vm.startPrank(governance);
        pool.setAccessControl(address(governanceAccessControl));
        pool.setAccessControl(address(0));
        vm.stopPrank();

        assertEq(pool.accessControl(), address(0), "governance should be able to disable ACL");
        assertFalse(pool.accessControlCanGateWithdrawals(), "disabled ACL should not gate withdrawals");
        assertTrue(pool.governanceAccessControlInstalled(), "sticky governance install flag should remain");

        vm.prank(poolCreator);
        vm.expectRevert(ErrorsLib.InvalidPoolCreator.selector);
        pool.setAccessControl(address(creatorAccessControl));

        assertEq(pool.accessControl(), address(0), "creator must not regain ACL control");
    }

    function testCreatorInstalledAcl_GatesDepositsButCannotBlockShieldedWithdrawals() public {
        AccessControlExample accessControl = new AccessControlExample(governance);

        vm.startPrank(governance);
        accessControl.setWhitelisted(protector, true);
        vm.stopPrank();

        vm.prank(poolCreator);
        pool.setAccessControl(address(accessControl));

        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AccessControlDenied.selector, shielded, "depositShielded"));
        pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);

        vm.prank(governance);
        accessControl.setWhitelisted(shielded, true);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);

        vm.prank(governance);
        accessControl.setWhitelisted(shielded, false);

        vm.prank(shielded);
        uint256 newTokenId = pool.partialWithdrawShielded(tokenId, 100e18, address(shieldedToken), 0);
        assertGt(newTokenId, tokenId, "creator ACL should not trap shielded withdrawals");
    }

    function testGovernanceInstalledAcl_CanBlockShieldedWithdrawals() public {
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);

        AccessControlExample accessControl = new AccessControlExample(governance);

        vm.prank(governance);
        pool.setAccessControl(address(accessControl));

        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AccessControlDenied.selector, shielded, "withdrawShielded"));
        pool.partialWithdrawShielded(tokenId, 100e18, address(shieldedToken), 0);
    }

    function testGovernanceInstalledAcl_CanBlockProtectorCommissionClaim() public {
        uint256 tokenId = _seedClaimableCommission();

        AccessControlExample accessControl = new AccessControlExample(governance);
        vm.prank(governance);
        pool.setAccessControl(address(accessControl));

        vm.prank(protector);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AccessControlDenied.selector, protector, "claimCommission"));
        pool.claimCommission(tokenId);
    }

    function testCreatorInstalledAcl_CannotBlockProtectorCommissionClaim() public {
        AccessControlExample accessControl = new AccessControlExample(governance);
        vm.startPrank(governance);
        accessControl.setWhitelisted(protector, true);
        accessControl.setWhitelisted(shielded, true);
        vm.stopPrank();

        vm.prank(poolCreator);
        pool.setAccessControl(address(accessControl));

        uint256 tokenId = _seedClaimableCommission();

        vm.prank(governance);
        accessControl.setWhitelisted(protector, false);

        uint256 balanceBefore = shieldedToken.balanceOf(protector);
        vm.prank(protector);
        pool.claimCommission(tokenId);

        assertGt(shieldedToken.balanceOf(protector), balanceBefore, "creator ACL must not trap commissions");
    }

    function testCreatorInstalledAcl_CannotBlockProtectorWithdrawals() public {
        AccessControlExample accessControl = new AccessControlExample(governance);

        vm.prank(governance);
        accessControl.setWhitelisted(protector, true);

        vm.prank(poolCreator);
        pool.setAccessControl(address(accessControl));

        vm.startPrank(protector);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), 10000e18, 0);
        pool.startUnlockProcess(tokenId);
        vm.stopPrank();

        vm.prank(governance);
        accessControl.setWhitelisted(protector, false);

        (,,,,,, uint256 unlockDuration,,,) = pool.poolConfig();
        vm.warp(block.timestamp + unlockDuration + 1);

        uint256 balanceBefore = backingToken.balanceOf(protector);
        vm.prank(protector);
        pool.protectorWithdraw(tokenId, 10000e18, address(backingToken), 0);

        assertEq(backingToken.balanceOf(protector) - balanceBefore, 10000e18);
    }

    function testSetAccessControl_CreatorCannotChangeAfterPoolHasEverLaunchedAndEmptied() public {
        vm.startPrank(protector);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), 10000e18, 0);
        pool.startUnlockProcess(tokenId);
        vm.stopPrank();

        (,,,,,, uint256 unlockDuration,,,) = pool.poolConfig();
        vm.warp(block.timestamp + unlockDuration + 1);

        vm.prank(protector);
        pool.protectorWithdraw(tokenId, 10000e18, address(backingToken), 0);

        assertEq(pool.totalProtectorTokens(), 0, "pool should be empty after full exit");
        assertTrue(pool.hasEverLaunched(), "launch flag should stay sticky after the pool empties");

        AccessControlExample accessControl = new AccessControlExample(governance);

        vm.prank(poolCreator);
        vm.expectRevert(ErrorsLib.InvalidPoolCreator.selector);
        pool.setAccessControl(address(accessControl));
    }

    function testPayProtocolFee_RevertsForUnauthorized() public {
        // Deposit protector tokens first
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 10000e18, 0);

        // Create some accumulated protocol fee
        vm.prank(shielded);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 1000e18, 0);
        oracle.setPrice(address(shieldedToken), 1.1e8);
        _claimRewardsAsOwner(tokenId);

        // Unauthorized caller should revert
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.AccessControlDenied.selector, unauthorized, "payProtocolFee"));
        pool.payProtocolFee();
    }

    function testPayPoolFee_ReturnsEarlyWhenZero() public {
        // No accumulated fee
        assertEq(pool.accumulatedPoolFee(), 0, "Should have no accumulated fee");

        // Should not revert, just return early
        vm.prank(poolCreator);
        pool.payPoolFee();

        // No state change expected
        assertEq(pool.accumulatedPoolFee(), 0, "Should still be zero");
    }

    function testPayProtocolFee_ReturnsEarlyWhenZero() public {
        // No accumulated fee
        assertEq(pool.accumulatedProtocolFee(), 0, "Should have no accumulated fee");

        // Should not revert, just return early
        vm.prank(protocolFeeRecipient);
        pool.payProtocolFee();

        // No state change expected
        assertEq(pool.accumulatedProtocolFee(), 0, "Should still be zero");
    }
}
