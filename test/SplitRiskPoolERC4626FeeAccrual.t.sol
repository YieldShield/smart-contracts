// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

contract SplitRiskPoolERC4626FeeAccrualTest is Test, TestTimelockHelper {
    SplitRiskPool internal pool;
    ShieldReceiptNFT internal shieldNFT;
    ProtectorReceiptNFT internal protectorNFT;
    MockERC20 internal shieldedBase;
    MockERC20 internal backingToken;
    MockERC4626 internal shieldedVault;
    MockOracle internal underlyingOracle;
    CompositeOracle internal compositeOracle;
    ERC4626OracleFeed internal erc4626Feed;

    address internal shielded = address(0xB0B);
    address internal protector = address(0xA11CE);
    address internal governance;

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

        shieldedBase = new MockERC20("Shielded Base", "SB");
        backingToken = new MockERC20("Backing", "BACK");
        shieldedVault = new MockERC4626(IERC20(address(shieldedBase)), "Shielded Vault", "svTOKEN");

        underlyingOracle = new MockOracle();
        underlyingOracle.setPrice(address(shieldedBase), 1e8);
        underlyingOracle.setPrice(address(backingToken), 1e8);

        erc4626Feed = new ERC4626OracleFeed(address(underlyingOracle));
        uint256 minSupply = erc4626Feed.MIN_VAULT_SHARE_COUNT() * 1e18;
        shieldedBase.mint(address(this), minSupply);
        shieldedBase.approve(address(shieldedVault), minSupply);
        shieldedVault.deposit(minSupply, address(this));
        erc4626Feed.registerVault(address(shieldedVault), address(shieldedBase));

        compositeOracle = new CompositeOracle();
        compositeOracle.setTokenOracleFeedWithType(address(shieldedVault), address(erc4626Feed), "erc4626");
        compositeOracle.setTokenOracleFeed(address(backingToken), address(underlyingOracle));

        TokenWhitelistLib.TokenInfo memory shieldedInfo = TokenWhitelistLib.TokenInfo({
            name: "svTOKEN",
            symbol: "svTOKEN",
            token: address(shieldedVault),
            primaryOracleFeed: address(erc4626Feed),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });
        TokenWhitelistLib.TokenInfo memory backingInfo = TokenWhitelistLib.TokenInfo({
            name: "BACK",
            symbol: "BACK",
            token: address(backingToken),
            primaryOracleFeed: address(underlyingOracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        shieldNFT = new ShieldReceiptNFT("sSV", "sSV");
        protectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedInfo,
            backingInfo,
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

        pool = SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));
        shieldNFT.setPool(address(pool));
        protectorNFT.setPool(address(pool));
        shieldNFT.transferOwnership(address(pool));
        protectorNFT.transferOwnership(address(pool));

        backingToken.mint(protector, 1_000_000e18);
        shieldedBase.mint(shielded, 1_000_000e18);

        vm.startPrank(protector);
        backingToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(shielded);
        shieldedBase.approve(address(shieldedVault), type(uint256).max);
        shieldedVault.deposit(1_000_000e18, shielded);
        shieldedVault.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _seedPool() internal returns (uint256 shieldTokenId) {
        vm.prank(protector);
        pool.depositBackingAsset(address(backingToken), 200e18, 0);

        vm.prank(shielded);
        shieldTokenId = pool.depositShieldedAsset(address(shieldedVault), 100e18, 0);
    }

    function _donateUnderlyingBps(uint256 bps) internal {
        uint256 donation = (shieldedVault.totalAssets() * bps) / 10_000;
        shieldedBase.mint(address(shieldedVault), donation);
    }

    function test_SameAssetWithdraw_AccruesFeesOnInBandERC4626NavGrowth() public {
        uint256 shieldTokenId = _seedPool();
        _donateUnderlyingBps(400);

        assertEq(compositeOracle.getPrice(address(shieldedVault)), 1e8, "protected price remains clamped");
        assertGt(compositeOracle.getPriceForFeeAccrual(address(shieldedVault)), 1e8, "fee price sees live NAV");

        uint256 balanceBefore = shieldedVault.balanceOf(shielded);
        vm.prank(shielded);
        pool.shieldedWithdraw(shieldTokenId, address(shieldedVault), 0);

        uint256 received = shieldedVault.balanceOf(shielded) - balanceBefore;
        assertLt(received, 100e18, "same-asset exit should pay fees on live NAV gain");
        assertGt(pool.accumulatedCommissions(), 0, "protector commission accrues");
        assertGt(pool.accumulatedPoolFee(), 0, "pool fee accrues");
        assertGt(pool.accumulatedProtocolFee(), 0, "protocol fee accrues");
    }

    function test_SameAssetWithdraw_RevertsWhenFeeAccrualUnderlyingProtectedPathReverts() public {
        uint256 shieldTokenId = _seedPool();
        _donateUnderlyingBps(400);
        underlyingOracle.setShouldRevertOnCircuitBreaker(true);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ShieldedFeePriceUnavailable.selector, address(shieldedVault)));
        vm.prank(shielded);
        pool.shieldedWithdraw(shieldTokenId, address(shieldedVault), 0);
    }

    function test_SameAssetWithdraw_RevertsWhenLiveShareRateExceedsReviewedBand() public {
        uint256 shieldTokenId = _seedPool();
        _donateUnderlyingBps(600);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ShieldedFeePriceUnavailable.selector, address(shieldedVault)));
        vm.prank(shielded);
        pool.shieldedWithdraw(shieldTokenId, address(shieldedVault), 0);
    }
}
