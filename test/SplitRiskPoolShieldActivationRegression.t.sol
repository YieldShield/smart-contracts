// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { IPriceOracle } from "../contracts/interfaces/IPriceOracle.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IProtectorReceiptNFT } from "../contracts/interfaces/IProtectorReceiptNFT.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";

contract ShieldActivationLossOracle is IPriceOracle {
    using Math for uint256;

    mapping(address => uint256) internal prices;
    mapping(address => bool) internal priceIsSet;

    address public shieldedToken;
    bool public shieldedCircuitBreakerReverts;

    error ShieldedCircuitBreakerUnavailable(address token);

    function setShieldedToken(address token) external {
        shieldedToken = token;
    }

    function setShieldedCircuitBreakerReverts(bool shouldRevert) external {
        shieldedCircuitBreakerReverts = shouldRevert;
    }

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
        priceIsSet[token] = true;
    }

    function getPrice(address token) external view returns (uint256) {
        return _price(token);
    }

    function getValue(address token, uint256 amount) external view returns (uint256) {
        return amount.mulDiv(_price(token), 1e18);
    }

    function getEquivalentAmount(address tokenA, uint256 amountA, address tokenB) external view returns (uint256) {
        return amountA.mulDiv(_price(tokenA), _price(tokenB));
    }

    function getPriceWithCircuitBreaker(address token) external view returns (uint256) {
        if (token == shieldedToken && shieldedCircuitBreakerReverts) {
            revert ShieldedCircuitBreakerUnavailable(token);
        }
        return _price(token);
    }

    function getEquivalentAmountWithCircuitBreaker(address tokenA, uint256 amountA, address tokenB)
        external
        view
        returns (uint256)
    {
        return amountA.mulDiv(this.getPriceWithCircuitBreaker(tokenA), this.getPriceWithCircuitBreaker(tokenB));
    }

    function _price(address token) internal view returns (uint256) {
        return priceIsSet[token] ? prices[token] : 1e8;
    }
}

contract SplitRiskPoolShieldActivationRegressionTest is Test {
    using stdStorage for StdStorage;

    SplitRiskPool internal pool;
    ShieldReceiptNFT internal shieldNFT;
    ProtectorReceiptNFT internal protectorNFT;
    MockERC4626 internal shieldedToken;
    MockERC4626 internal backingToken;
    MockERC20 internal shieldedBaseToken;
    MockERC20 internal backingBaseToken;
    ShieldActivationLossOracle internal oracle;

    address internal protector1 = address(0x1001);
    address internal protector2 = address(0x1002);
    address internal shieldedUser = address(0x2001);

    function setUp() public {
        shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        backingBaseToken = new MockERC20("Backing Base Token", "BBASE");

        backingToken = new MockERC4626(backingBaseToken, "Backing Token", "BACK");
        shieldedToken = new MockERC4626(shieldedBaseToken, "Shielded Token", "SHIELD");

        oracle = new ShieldActivationLossOracle();
        oracle.setShieldedToken(address(shieldedToken));
        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

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

        SplitRiskPool implementation = new SplitRiskPool();
        shieldNFT = new ShieldReceiptNFT("sSHIELD", "sSHIELD");
        protectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000,
            500,
            address(this),
            10000,
            address(this),
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

        backingBaseToken.mint(protector1, 1_000_000e18);
        backingBaseToken.mint(protector2, 1_000_000e18);
        shieldedBaseToken.mint(shieldedUser, 1_000_000e18);

        vm.startPrank(protector1);
        backingBaseToken.approve(address(backingToken), type(uint256).max);
        backingToken.deposit(1_000_000e18, protector1);
        backingToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(protector2);
        backingBaseToken.approve(address(backingToken), type(uint256).max);
        backingToken.deposit(1_000_000e18, protector2);
        backingToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(shieldedUser);
        shieldedBaseToken.approve(address(shieldedToken), type(uint256).max);
        shieldedToken.deposit(1_000_000e18, shieldedUser);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function test_crossAssetShieldActivationSocializesProtectorLossesAndCommissions() public {
        vm.prank(protector1);
        uint256 protectorTokenId1 = pool.depositBackingAsset(address(backingToken), 100e18, 0);

        vm.prank(protector2);
        uint256 protectorTokenId2 = pool.depositBackingAsset(address(backingToken), 100e18, 0);

        vm.startPrank(shieldedUser);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.warp(block.timestamp + 7 days + 1);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);
        vm.stopPrank();

        assertEq(pool.totalProtectorTokens(), 100e18, "pool tracks only remaining backing");

        (uint256 amount1,,,, uint256 available1,) = pool.getProtectorDepositInfo(protectorTokenId1);
        (uint256 amount2,,,, uint256 available2,) = pool.getProtectorDepositInfo(protectorTokenId2);

        assertEq(amount1, 50e18, "protector 1 claim should be socialized");
        assertEq(amount2, 50e18, "protector 2 claim should be socialized");
        assertEq(available1, 50e18, "protector 1 should only see their fair remaining claim");
        assertEq(available2, 50e18, "protector 2 should only see their fair remaining claim");
        assertEq(available1 + available2, pool.totalProtectorTokens(), "reported availability should match pool assets");

        vm.startPrank(shieldedUser);
        uint256 commissionTokenId = pool.depositShieldedAsset(address(shieldedToken), 50e18, 0);
        vm.stopPrank();
        oracle.setPrice(address(shieldedToken), 2e8);
        vm.prank(shieldedUser);
        pool.claimRewards(commissionTokenId);

        uint256 balanceBefore1 = shieldedToken.balanceOf(protector1);
        uint256 balanceBefore2 = shieldedToken.balanceOf(protector2);
        uint256 availableAfterCommissions1 = pool.getAvailableForWithdrawal(protectorTokenId1);
        uint256 availableAfterCommissions2 = pool.getAvailableForWithdrawal(protectorTokenId2);

        vm.prank(protector1);
        pool.claimCommission(protectorTokenId1);
        vm.prank(protector2);
        pool.claimCommission(protectorTokenId2);

        uint256 claimed1 = shieldedToken.balanceOf(protector1) - balanceBefore1;
        uint256 claimed2 = shieldedToken.balanceOf(protector2) - balanceBefore2;

        assertEq(availableAfterCommissions1, 50e18, "withdrawal availability should stay fair after commission accrual");
        assertEq(availableAfterCommissions2, 50e18, "withdrawal availability should stay fair after commission accrual");
        assertApproxEqAbs(
            claimed1, claimed2, 1, "post-loss commissions should follow share ownership, not stale NFT amount"
        );
    }

    function test_protectorReceiptPositionAmountReflectsSocializedLoss() public {
        vm.prank(protector1);
        uint256 protectorTokenId1 = pool.depositBackingAsset(address(backingToken), 100e18, 0);

        vm.prank(protector2);
        uint256 protectorTokenId2 = pool.depositBackingAsset(address(backingToken), 100e18, 0);

        vm.startPrank(shieldedUser);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.warp(block.timestamp + 7 days + 1);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);
        vm.stopPrank();

        IProtectorReceiptNFT.ProtectorPosition memory directPosition1 = protectorNFT.getPosition(protectorTokenId1);
        IProtectorReceiptNFT.ProtectorPosition memory directPosition2 = protectorNFT.getPosition(protectorTokenId2);

        assertEq(directPosition1.amount, 50e18, "NFT view should report current socialized claim");
        assertEq(directPosition2.amount, 50e18, "NFT view should report current socialized claim");
        assertEq(
            directPosition1.depositTime, directPosition2.depositTime, "metadata should still come from NFT storage"
        );
    }

    function test_crossAssetShieldActivationWipesStaleSharesBeforeFutureDeposits() public {
        vm.prank(protector1);
        uint256 wipedProtectorTokenId = pool.depositBackingAsset(address(backingToken), 100e18, 0);

        vm.startPrank(shieldedUser);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.warp(block.timestamp + 7 days + 1);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);
        vm.stopPrank();

        assertEq(pool.totalProtectorTokens(), 0, "activation should wipe protector backing");
        assertEq(pool.totalProtectorShares(), 0, "wiped shares should leave the active share supply");
        assertEq(pool.getProtectorPositionAmount(wipedProtectorTokenId), 0, "wiped NFT should have no backing claim");

        vm.prank(protector2);
        uint256 newProtectorTokenId = pool.depositBackingAsset(address(backingToken), 100e18, 0);

        assertEq(pool.getProtectorPositionAmount(wipedProtectorTokenId), 0, "old shares must not revive");
        assertEq(pool.getProtectorPositionAmount(newProtectorTokenId), 100e18, "new depositor should own new backing");
    }

    function test_crossAssetShieldActivationPreservesHistoricalCommissionClaims() public {
        vm.prank(protector1);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), 100e18, 0);

        vm.prank(shieldedUser);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);

        oracle.setPrice(address(shieldedToken), 2e8);
        vm.prank(shieldedUser);
        pool.claimRewards(shieldTokenId);

        uint256 claimableBeforeWipe = pool.getClaimableCommission(protectorTokenId);
        assertGt(claimableBeforeWipe, 0, "protector should have earned pre-wipe commissions");

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(shieldedUser);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);

        assertEq(pool.getProtectorPositionAmount(protectorTokenId), 0, "wiped NFT should have no backing claim");
        uint256 claimableAfterWipe = pool.getClaimableCommission(protectorTokenId);
        assertGt(claimableAfterWipe, claimableBeforeWipe, "forfeited shielded assets should be claimable too");

        uint256 balanceBefore = shieldedToken.balanceOf(protector1);
        vm.prank(protector1);
        pool.claimCommission(protectorTokenId);
        assertEq(shieldedToken.balanceOf(protector1) - balanceBefore, claimableAfterWipe);
    }

    function test_crossAssetShieldActivationForfeitsShieldedAssetsToProtectors() public {
        vm.prank(protector1);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), 100e18, 0);

        vm.startPrank(shieldedUser);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.warp(block.timestamp + 7 days + 1);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);
        vm.stopPrank();

        assertEq(pool.totalShieldedTokens(), 0, "shielded position should be closed");
        assertEq(pool.getReservedFees(), 100e18, "forfeited shielded assets should be reserved");
        assertEq(pool.getClaimableCommission(protectorTokenId), 100e18, "protector should receive forfeiture");

        uint256 balanceBefore = shieldedToken.balanceOf(protector1);
        vm.prank(protector1);
        pool.claimCommission(protectorTokenId);

        assertEq(shieldedToken.balanceOf(protector1) - balanceBefore, 100e18);
        assertEq(pool.getReservedFees(), 0, "all reserved forfeiture should be claimed");

        (uint256 shieldedPoolBalance,) = pool.getPoolBalances();
        assertEq(shieldedPoolBalance, 0, "claimed forfeiture should clear shielded pool balance");
    }

    function test_crossAssetShieldActivationDoesNotRequireCurrentShieldedPrice() public {
        vm.prank(protector1);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), 100e18, 0);

        vm.prank(shieldedUser);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);

        oracle.setShieldedCircuitBreakerReverts(true);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(shieldedUser);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);

        assertEq(pool.totalShieldedTokens(), 0, "shielded position should still close");
        assertEq(pool.totalProtectorTokens(), 0, "stored deposit value should drive backing payout");
        assertEq(pool.getClaimableCommission(protectorTokenId), 100e18, "forfeiture remains reserved for protector");
    }

    function test_crossAssetShieldActivationRevertsIfForfeitureCannotBeReserved() public {
        vm.prank(protector1);
        pool.depositBackingAsset(address(backingToken), 100e18, 0);

        vm.prank(shieldedUser);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);

        stdstore.target(address(pool)).sig("accumulatedCommissions()").checked_write(type(uint128).max);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(shieldedUser);
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.RewardAccumulationIncomplete.selector, 100e18, uint256(0), uint256(0))
        );
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);

        assertEq(pool.totalShieldedTokens(), 100e18, "failed reservation should leave position accounting intact");
        assertEq(pool.totalProtectorTokens(), 100e18, "failed reservation should leave backing accounting intact");
    }
}
