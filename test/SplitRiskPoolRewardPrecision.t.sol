// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { MockERC20Decimals } from "../contracts/mocks/MockERC20Decimals.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

contract SplitRiskPoolRewardPrecisionTest is Test, TestTimelockHelper {
    SplitRiskPool internal pool;
    ShieldReceiptNFT internal shieldNFT;
    ProtectorReceiptNFT internal protectorNFT;
    MockERC20Decimals internal shieldedToken;
    MockERC20Decimals internal backingToken;
    MockOracle internal oracle;

    address internal protector = address(0xA11CE);
    address internal shielded = address(0xB0B);
    address internal governance;

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

        shieldedToken = new MockERC20Decimals("Six Decimal Shielded", "SIX", 6);
        backingToken = new MockERC20Decimals("Thirty Two Decimal Backing", "B32", 32);
        oracle = new MockOracle();
        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        TokenWhitelistLib.TokenInfo memory shieldedInfo = TokenWhitelistLib.TokenInfo({
            name: "SIX",
            symbol: "SIX",
            token: address(shieldedToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });
        TokenWhitelistLib.TokenInfo memory backingInfo = TokenWhitelistLib.TokenInfo({
            name: "B32",
            symbol: "B32",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        shieldNFT = new ShieldReceiptNFT("sSIX", "sSIX");
        protectorNFT = new ProtectorReceiptNFT("pB32", "pB32");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedInfo,
            backingInfo,
            1000,
            0,
            address(this),
            15000,
            governance,
            address(oracle),
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

        shieldedToken.mint(shielded, 1_000_000e6);
        backingToken.mint(protector, 1_000_000 * 10 ** 32);

        vm.prank(shielded);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.prank(protector);
        backingToken.approve(address(pool), type(uint256).max);
    }

    function test_MixedDecimalProtectorRewardsRemainClaimable() public {
        uint256 backingAmount = 1_000_000 * 10 ** 32;
        uint256 shieldedAmount = 500_000e6;

        vm.prank(protector);
        uint256 protectorTokenId = pool.depositBackingAsset(address(backingToken), backingAmount, 0);
        assertEq(pool.totalProtectorShares(), 1_000_000e18, "protector shares normalize to 18 decimals");

        vm.prank(shielded);
        uint256 shieldTokenId = pool.depositShieldedAsset(address(shieldedToken), shieldedAmount, 0);

        vm.warp(block.timestamp + 1 days);
        vm.prank(shielded);
        pool.shieldedWithdraw(shieldTokenId, address(backingToken), 0);

        uint256 claimable = pool.getClaimableCommission(protectorTokenId);
        assertEq(claimable, shieldedAmount, "forfeited shielded amount must be claimable");

        uint256 beforeBalance = shieldedToken.balanceOf(protector);
        vm.prank(protector);
        pool.claimCommission(protectorTokenId);
        assertEq(shieldedToken.balanceOf(protector) - beforeBalance, shieldedAmount, "protector receives reward");
    }
}
