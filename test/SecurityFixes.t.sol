// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { YSToken } from "../contracts/YSToken.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockERC20Decimals } from "../contracts/mocks/MockERC20Decimals.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { IShieldReceiptNFT } from "../contracts/interfaces/IShieldReceiptNFT.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

contract NonReceiverDepositor {
    function depositBacking(SplitRiskPool pool, MockERC4626 token, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.depositBackingAsset(address(token), amount, 0);
    }
}

contract StrictBackingOwner {
    address internal immutable strictToken;

    constructor(address token) {
        strictToken = token;
    }

    function tokenRequiresStrictProtectedPrice(address token) external view returns (bool) {
        return token == strictToken;
    }
}

contract SecurityFeedWithoutCircuitBreaker {
    mapping(address => uint256) internal prices;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view returns (uint256) {
        uint256 price = prices[token];
        return price == 0 ? 1e8 : price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "Security Feed Without Circuit Breaker";
    }
}

contract SecurityFixesTest is Test, TestTimelockHelper {
    SplitRiskPool internal pool;
    MockERC4626 internal shieldedToken;
    MockERC4626 internal backingToken;
    MockOracle internal primaryOracle;
    MockOracle internal backupOracle;
    CompositeOracle internal compositeOracle;

    address internal protector = address(0xA11CE);
    address internal shielded = address(0xB0B);
    address internal governance = address(this);

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

        MockERC20 shieldedBase = new MockERC20("Shielded Base", "SB");
        MockERC20 backingBase = new MockERC20("Backing Base", "BB");
        shieldedToken = new MockERC4626(shieldedBase, "Shielded Vault", "svTOKEN");
        backingToken = new MockERC4626(backingBase, "Backing Vault", "bvTOKEN");

        primaryOracle = new MockOracle();
        backupOracle = new MockOracle();
        primaryOracle.setPrice(address(shieldedToken), 1e8);
        backupOracle.setPrice(address(shieldedToken), 1e8);
        primaryOracle.setPrice(address(backingToken), 1e8);
        backupOracle.setPrice(address(backingToken), 1e8);

        compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeedDual(address(shieldedToken), address(primaryOracle), address(backupOracle));
        compositeOracle.setTokenOracleFeedDual(address(backingToken), address(primaryOracle), address(backupOracle));

        pool = _deployPool(address(shieldedToken), address(backingToken), address(compositeOracle));

        shieldedToken.mintShares(shielded, 1_000_000e18);
        backingToken.mintShares(protector, 1_000_000e18);

        vm.prank(shielded);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.prank(protector);
        backingToken.approve(address(pool), type(uint256).max);
    }

    function test_BackingOracleChallengeBlocksPriceSensitivePoolActions() public {
        vm.prank(protector);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 1_000e18, 0);

        vm.prank(protector);
        pool.startUnlockProcess(protectorTokenId);
        vm.warp(block.timestamp + 29 days);

        backupOracle.setPrice(address(backingToken), 2e8);
        compositeOracle.challengeForToken(address(backingToken));

        assertEq(pool.getAvailableForWithdrawal(protectorTokenId), 0);

        vm.prank(protector);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(backingToken)));
        pool.protectorWithdraw(protectorTokenId, 1e18, address(backingToken), 0);

        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(backingToken)));
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);

        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(backingToken)));
        pool.depositShieldedAsset(address(shieldedToken), 1e18, 0);

        vm.prank(protector);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(backingToken)));
        pool.depositBackingAsset(address(backingToken), 1e18, 0);
    }

    function test_ProtectorOnlyWithdrawalIgnoresBackingOracleChallengeWithoutShieldedLiabilities() public {
        vm.prank(protector);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        vm.prank(protector);
        pool.startUnlockProcess(protectorTokenId);
        vm.warp(block.timestamp + 29 days);

        backupOracle.setPrice(address(backingToken), 2e8);
        compositeOracle.challengeForToken(address(backingToken));

        assertEq(pool.totalShieldedTokens(), 0);
        assertEq(pool.totalValueAtDeposit(), 0);
        assertEq(pool.totalShieldCollateralAmount(), 0);
        assertEq(pool.getAvailableForWithdrawal(protectorTokenId), 2_000e18);

        uint256 protectorBalanceBefore = backingToken.balanceOf(protector);
        vm.prank(protector);
        pool.protectorWithdraw(protectorTokenId, 2_000e18, address(backingToken), 0);

        assertEq(backingToken.balanceOf(protector), protectorBalanceBefore + 2_000e18);
        assertEq(pool.totalProtectorTokens(), 0);
    }

    function test_PreChallengeShieldedDeviationBlocksValueLock() public {
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        primaryOracle.setPrice(address(shieldedToken), 2e8);

        uint256 userBalanceBefore = shieldedToken.balanceOf(shielded);
        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        pool.depositShieldedAsset(address(shieldedToken), 1_000e18, 0);

        assertEq(shieldedToken.balanceOf(shielded), userBalanceBefore, "deposit should fail before transfer");
        assertEq(pool.totalShieldedTokens(), 0, "no receipt value should be locked");
    }

    function test_PreChallengeBackingDeviationBlocksCollateralLock() public {
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        primaryOracle.setPrice(address(backingToken), 5e7);

        uint256 userBalanceBefore = shieldedToken.balanceOf(shielded);
        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(backingToken)));
        pool.depositShieldedAsset(address(shieldedToken), 1_000e18, 0);

        assertEq(shieldedToken.balanceOf(shielded), userBalanceBefore, "deposit should fail before transfer");
        assertEq(pool.totalShieldedTokens(), 0, "no collateral value should be locked");
    }

    function test_ShieldedOracleChallenge_BlocksAllExitsAndFeeAccrualPaths() public {
        // M-13: previously full same-asset exit was allowed during a pending
        // challenge as a liveness escape hatch — but that let users
        // self-trigger a challenge to skip yield fees on exit. Now every
        // priced exit path reverts during a pending challenge; users must
        // wait for the challenge to resolve.
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 1_000e18, 0);

        backupOracle.setPrice(address(shieldedToken), 2e8);
        compositeOracle.challengeForToken(address(shieldedToken));

        vm.startPrank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        pool.partialWithdrawShielded(shieldTokenId, 100e18, address(shieldedToken), 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        pool.claimRewards(shieldTokenId);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        pool.shieldedWithdraw(shieldTokenId, address(shieldedToken), 0);
        vm.stopPrank();

        vm.prank(protector);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        pool.depositBackingAsset(address(backingToken), 1e18, 0);
    }

    function test_ShieldedOracleChallengeablePrice_BlocksSameAssetExit() public {
        // M-13: challengeable-price (deviation has crossed threshold but no
        // one has formally challenged yet) is treated the same as a pending
        // challenge — exits revert. Otherwise an attacker can deliberately
        // step into the deviation window to exit without paying fees on the
        // disputed yield.
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 1_000e18, 0);

        backupOracle.setPrice(address(shieldedToken), 2e8);

        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        pool.shieldedWithdraw(shieldTokenId, address(shieldedToken), 0);
    }

    function test_PoolGovernanceMigrationSyncsProtocolFeeRecipientWhenAligned() public {
        address replacementGovernance = address(_deployTestTimelock(address(this)));

        (
            uint256 shieldedMinDepositAmount,
            uint256 shieldedMaxDepositAmount,
            uint256 backingMinDepositAmount,
            uint256 backingMaxDepositAmount,
            uint256 maxTotalValueLockedUsd,
            uint256 minimumPoolTime,
            uint256 unlockDuration,,
            uint96 protocolFee,
            address priceOracle
        ) = pool.poolConfig();

        vm.prank(governance);
        pool.updatePoolConfig(
            shieldedMinDepositAmount,
            shieldedMaxDepositAmount,
            backingMinDepositAmount,
            backingMaxDepositAmount,
            maxTotalValueLockedUsd,
            minimumPoolTime,
            unlockDuration,
            protocolFee,
            governance,
            priceOracle
        );

        vm.prank(governance);
        pool.setGovernanceTimelock(replacementGovernance);

        vm.prank(replacementGovernance);
        pool.acceptGovernanceTimelock();

        (,,,,,,, address protocolFeeRecipient,,) = pool.poolConfig();

        assertEq(pool.governanceTimelock(), replacementGovernance, "pool governance should migrate");
        assertEq(
            protocolFeeRecipient,
            replacementGovernance,
            "aligned protocol fee recipient should follow pool governance migration"
        );
    }

    function test_ShieldedOracleChallengeBlocksCrossAssetActivationFeesBypass() public {
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 1_000e18, 0);

        primaryOracle.setPrice(address(shieldedToken), 2e8);
        compositeOracle.challengeForToken(address(shieldedToken));

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);
    }

    function test_PartialWithdrawProratesRemainingPositionAfterFeeAccrual() public {
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 1_000e18, 0);

        primaryOracle.setPrice(address(shieldedToken), 2e8);
        backupOracle.setPrice(address(shieldedToken), 2e8);
        uint256 withdrawAmount = 420e18;
        uint256 amountAfterFees = 920e18;
        uint256 remaining = 500e18;

        vm.prank(shielded);
        uint256 newTokenId = pool.partialWithdrawShielded(shieldTokenId, withdrawAmount, address(shieldedToken), 0);

        IShieldReceiptNFT.ShieldPosition memory newPosition =
            IShieldReceiptNFT(pool.shieldReceiptNFT()).getPosition(newTokenId);

        assertEq(newPosition.amount, remaining);
        // L-13: partial-withdraw recomputes now round UP so the remaining
        // position is not penalised by repeated partials. Mirror that in the
        // expected values (floor + 1 when there's a truncated remainder).
        uint256 expectedValue = (1_000e8 * remaining) / amountAfterFees;
        if ((1_000e8 * remaining) % amountAfterFees != 0) expectedValue += 1;
        uint256 expectedCollateral = (1_500e18 * remaining) / amountAfterFees;
        if ((1_500e18 * remaining) % amountAfterFees != 0) expectedCollateral += 1;
        assertEq(newPosition.valueAtDeposit, expectedValue);
        assertEq(newPosition.collateralAmount, expectedCollateral);
    }

    function test_LastProtectorExitRedirectsRoundingCommissions() public {
        vm.prank(protector);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), 3e18, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 1e18, 0);

        vm.warp(block.timestamp + 1 days);

        vm.prank(shielded);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);

        assertEq(pool.accumulatedCommissions(), 1e18);

        uint256 remainingBacking = pool.getProtectorPositionAmount(protectorTokenId);
        vm.prank(protector);
        pool.startUnlockProcess(protectorTokenId);

        vm.warp(block.timestamp + 28 days);

        vm.prank(protector);
        pool.protectorWithdraw(protectorTokenId, remainingBacking, address(backingToken), 0);

        assertEq(pool.totalProtectorTokens(), 0);
        assertEq(pool.totalProtectorShares(), 0);
        assertEq(pool.accumulatedCommissions(), 0);
        assertEq(pool.accumulatedProtocolFee(), 1);
    }

    function test_ReceiptMintsRevertForContractsThatCannotReceiveERC721s() public {
        NonReceiverDepositor depositor = new NonReceiverDepositor();
        backingToken.mintShares(address(depositor), 1_000e18);

        vm.expectRevert();
        depositor.depositBacking(pool, backingToken, 1_000e18);
    }

    function test_InitialGovernanceHolderIsSelfDelegated() public {
        address holder = address(0xCAFE);
        YSToken ysToken = new YSToken(holder);

        assertEq(ysToken.delegates(holder), holder);
        assertEq(ysToken.getVotes(holder), ysToken.INITIAL_SUPPLY());
    }

    function test_PoolRejectsLowDecimalAssets() public {
        MockERC20Decimals lowDecimalToken = new MockERC20Decimals("Low Decimal", "LOW", 5);

        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "SHIELD",
            symbol: "SHIELD",
            token: address(shieldedToken),
            primaryOracleFeed: address(compositeOracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });
        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "LOW",
            symbol: "LOW",
            token: address(lowDecimalToken),
            primaryOracleFeed: address(compositeOracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });
        SplitRiskPool implementation = new SplitRiskPool();
        ShieldReceiptNFT shieldNFT = new ShieldReceiptNFT("sSHIELD", "sSHIELD");
        ProtectorReceiptNFT protectorNFT = new ProtectorReceiptNFT("pLOW", "pLOW");
        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000,
            500,
            address(this),
            15000,
            governance,
            address(compositeOracle),
            address(0xFEE),
            address(shieldNFT),
            address(protectorNFT),
            address(this)
        );

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidTokenDecimals.selector, address(lowDecimalToken), 5));
        new ERC1967Proxy(address(implementation), initData);
    }

    function test_UpdatePoolConfigRejectsMaxDepositsAboveAccumulatorCap() public {
        (
            uint256 shieldedMinDepositAmount,,
            uint256 backingMinDepositAmount,
            uint256 backingMaxDepositAmount,
            uint256 maxTotalValueLockedUsd,
            uint256 minimumPoolTime,
            uint256 unlockDuration,
            address protocolFeeRecipient,
            uint256 protocolFee,
            address priceOracle
        ) = pool.poolConfig();

        vm.prank(governance);
        vm.expectRevert(ErrorsLib.DepositAmountTooLarge.selector);
        pool.updatePoolConfig(
            shieldedMinDepositAmount,
            uint256(type(uint128).max) + 1,
            backingMinDepositAmount,
            backingMaxDepositAmount,
            maxTotalValueLockedUsd,
            minimumPoolTime,
            unlockDuration,
            protocolFee,
            protocolFeeRecipient,
            priceOracle
        );
    }

    function test_CompositeOracleRejectsInactiveBackupLackingProtectedPrice() public {
        CompositeOracle unsafeOracle = new CompositeOracle();
        SecurityFeedWithoutCircuitBreaker fallbackOnlyBackup = new SecurityFeedWithoutCircuitBreaker();
        fallbackOnlyBackup.setPrice(address(backingToken), 1e8);

        unsafeOracle.setTokenOracleFeed(address(shieldedToken), address(primaryOracle));
        vm.expectRevert(
            abi.encodeWithSelector(
                CompositeOracle.CircuitBreakerNotSupported.selector, address(backingToken), address(fallbackOnlyBackup)
            )
        );
        unsafeOracle.setTokenOracleFeedDual(address(backingToken), address(primaryOracle), address(fallbackOnlyBackup));
    }

    function _deployPool(address shieldedAsset, address backingAsset, address oracleAddr)
        internal
        returns (SplitRiskPool deployedPool)
    {
        deployedPool = _deployPoolWithOwner(shieldedAsset, backingAsset, oracleAddr, address(this));
    }

    function _deployPoolWithOwner(address shieldedAsset, address backingAsset, address oracleAddr, address initialOwner)
        internal
        returns (SplitRiskPool deployedPool)
    {
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "SHIELD",
            symbol: "SHIELD",
            token: shieldedAsset,
            primaryOracleFeed: oracleAddr,
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });
        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "BACK",
            symbol: "BACK",
            token: backingAsset,
            primaryOracleFeed: oracleAddr,
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        ShieldReceiptNFT shieldNFT = new ShieldReceiptNFT("sSHIELD", "sSHIELD");
        ProtectorReceiptNFT protectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000,
            500,
            address(this),
            15000,
            governance,
            oracleAddr,
            address(0xFEE),
            address(shieldNFT),
            address(protectorNFT),
            initialOwner
        );

        deployedPool = SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));
        shieldNFT.setPool(address(deployedPool));
        protectorNFT.setPool(address(deployedPool));
        shieldNFT.transferOwnership(address(deployedPool));
        protectorNFT.transferOwnership(address(deployedPool));
    }
}
