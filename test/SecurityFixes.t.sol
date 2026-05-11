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

contract NonReceiverDepositor {
    function depositBacking(SplitRiskPool pool, MockERC4626 token, uint256 amount) external {
        token.approve(address(pool), amount);
        pool.depositBackingAsset(address(token), amount, 0);
    }
}

contract SecurityFixesTest is Test {
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
    }

    function test_ShieldedOracleChallengeBlocksFeeAccrualPaths() public {
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 1_000e18, 0);

        backupOracle.setPrice(address(shieldedToken), 2e8);
        compositeOracle.challengeForToken(address(shieldedToken));

        vm.startPrank(shielded);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        pool.shieldedWithdraw(shieldTokenId, address(shieldedToken), 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        pool.partialWithdrawShielded(shieldTokenId, 100e18, address(shieldedToken), 0);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.OraclePendingChallenge.selector, address(shieldedToken)));
        pool.claimRewards(shieldTokenId);
        vm.stopPrank();
    }

    function test_ShieldedOracleChallengeSkipsCrossAssetActivationFees() public {
        vm.prank(protector);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 1_000e18, 0);

        primaryOracle.setPrice(address(shieldedToken), 2e8);
        compositeOracle.challengeForToken(address(shieldedToken));

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(shielded);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);

        assertEq(pool.accumulatedPoolFee(), 0, "pool fee should not accrue from challenged active price");
        assertEq(pool.accumulatedProtocolFee(), 0, "protocol fee should not accrue from challenged active price");
        assertEq(
            pool.getClaimableCommission(protectorTokenId),
            1_000e18,
            "full forfeiture should remain reserved for protectors"
        );
        assertEq(pool.getReservedFees(), 1_000e18, "full forfeiture should remain reserved");
    }

    function test_PartialWithdrawProratesRemainingPositionAfterFeeAccrual() public {
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 2_000e18, 0);

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 1_000e18, 0);

        primaryOracle.setPrice(address(shieldedToken), 2e8);
        uint256 withdrawAmount = 420e18;
        uint256 amountAfterFees = 920e18;
        uint256 remaining = 500e18;

        vm.prank(shielded);
        uint256 newTokenId = pool.partialWithdrawShielded(shieldTokenId, withdrawAmount, address(shieldedToken), 0);

        IShieldReceiptNFT.ShieldPosition memory newPosition =
            IShieldReceiptNFT(pool.shieldReceiptNFT()).getPosition(newTokenId);

        assertEq(newPosition.amount, remaining);
        assertEq(newPosition.valueAtDeposit, (1_000e8 * remaining) / amountAfterFees);
        assertEq(newPosition.collateralAmount, (1_500e18 * remaining) / amountAfterFees);
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

    function _deployPool(address shieldedAsset, address backingAsset, address oracleAddr)
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
            address(this)
        );

        deployedPool = SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));
        shieldNFT.setPool(address(deployedPool));
        protectorNFT.setPool(address(deployedPool));
        shieldNFT.transferOwnership(address(deployedPool));
        protectorNFT.transferOwnership(address(deployedPool));
    }
}
