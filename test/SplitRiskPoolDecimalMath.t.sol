// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IShieldReceiptNFT } from "../contracts/interfaces/IShieldReceiptNFT.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

contract SplitRiskPoolDecimalMathTest is Test, TestTimelockHelper {
    address internal constant PROTECTOR = address(0xA11CE);
    address internal constant SHIELDED_USER = address(0xB0B);
    address internal lastGovernanceTimelock;

    function test_DepositShieldedAsset_StoresBackingCollateralInNativeUnits() public {
        MockERC20 shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        MockERC4626 shieldedToken = new MockERC4626(IERC20(address(shieldedBaseToken)), "Shielded Token", "SHIELD");
        MockUSDC backingToken = new MockUSDC();

        (SplitRiskPool pool, ShieldReceiptNFT shieldNFT, MockOracle oracle) =
            _deployPool(address(shieldedToken), "SHIELD", address(backingToken), "USDC");

        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        backingToken.mint(PROTECTOR, 200e6);
        shieldedBaseToken.mint(SHIELDED_USER, 100e18);

        vm.startPrank(PROTECTOR);
        backingToken.approve(address(pool), type(uint256).max);
        pool.depositBackingAsset(address(backingToken), 200e6, 0);
        vm.stopPrank();

        vm.startPrank(SHIELDED_USER);
        shieldedBaseToken.approve(address(shieldedToken), type(uint256).max);
        shieldedToken.deposit(100e18, SHIELDED_USER);
        shieldedToken.approve(address(pool), type(uint256).max);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        IShieldReceiptNFT.ShieldPosition memory position = shieldNFT.getPosition(tokenId);
        assertEq(position.valueAtDeposit, 100e8, "deposit value should stay in USD precision");
        assertEq(position.collateralAmount, 150e6, "collateral cap should use native backing token units");
    }

    function test_ShieldedWithdraw_CrossAssetUsesBackingTokenScale() public {
        MockERC20 shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        MockERC4626 shieldedToken = new MockERC4626(IERC20(address(shieldedBaseToken)), "Shielded Token", "SHIELD");
        MockUSDC backingToken = new MockUSDC();

        (SplitRiskPool pool,, MockOracle oracle) =
            _deployPool(address(shieldedToken), "SHIELD", address(backingToken), "USDC");

        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        backingToken.mint(PROTECTOR, 200e6);
        shieldedBaseToken.mint(SHIELDED_USER, 100e18);

        vm.startPrank(PROTECTOR);
        backingToken.approve(address(pool), type(uint256).max);
        pool.depositBackingAsset(address(backingToken), 200e6, 0);
        vm.stopPrank();

        vm.startPrank(SHIELDED_USER);
        shieldedBaseToken.approve(address(shieldedToken), type(uint256).max);
        shieldedToken.deposit(100e18, SHIELDED_USER);
        shieldedToken.approve(address(pool), type(uint256).max);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 balanceBefore = backingToken.balanceOf(SHIELDED_USER);
        pool.shieldedWithdraw(tokenId, address(backingToken), 0);
        vm.stopPrank();

        assertEq(backingToken.balanceOf(SHIELDED_USER) - balanceBefore, 100e6, "backing payout should use 6-dec scale");
        assertEq(pool.totalProtectorTokens(), 100e6, "protector liquidity should decrease by backing payout");
    }

    function test_DepositShieldedAsset_RevertsWhenBackingCollateralRoundsToZero() public {
        MockERC20 shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        MockERC4626 shieldedToken = new MockERC4626(IERC20(address(shieldedBaseToken)), "Shielded Token", "SHIELD");
        MockUSDC backingToken = new MockUSDC();

        (SplitRiskPool pool,, MockOracle oracle) =
            _deployPool(address(shieldedToken), "SHIELD", address(backingToken), "USDC");

        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);
        _setShieldedMinDepositAmount(pool, 1);

        backingToken.mint(PROTECTOR, 1e6);
        shieldedBaseToken.mint(SHIELDED_USER, 1e18);

        vm.startPrank(PROTECTOR);
        backingToken.approve(address(pool), type(uint256).max);
        pool.depositBackingAsset(address(backingToken), 1e6, 0);
        vm.stopPrank();

        vm.startPrank(SHIELDED_USER);
        shieldedBaseToken.approve(address(shieldedToken), type(uint256).max);
        shieldedToken.deposit(1e10, SHIELDED_USER);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.expectRevert(ErrorsLib.InvalidOraclePrice.selector);
        pool.depositShieldedAsset(address(shieldedToken), 1e10, 0);
        vm.stopPrank();
    }

    function test_ShieldedWithdraw_CrossAssetFloorsBackingPayoutDust() public {
        MockERC20 shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        MockERC4626 shieldedToken = new MockERC4626(IERC20(address(shieldedBaseToken)), "Shielded Token", "SHIELD");
        MockUSDC backingToken = new MockUSDC();

        (SplitRiskPool pool,, MockOracle oracle) =
            _deployPool(address(shieldedToken), "SHIELD", address(backingToken), "USDC");

        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);
        _setShieldedMinDepositAmount(pool, 1);

        backingToken.mint(PROTECTOR, 1e6);
        shieldedBaseToken.mint(SHIELDED_USER, 1e18);

        vm.startPrank(PROTECTOR);
        backingToken.approve(address(pool), type(uint256).max);
        pool.depositBackingAsset(address(backingToken), 1e6, 0);
        vm.stopPrank();

        vm.startPrank(SHIELDED_USER);
        shieldedBaseToken.approve(address(shieldedToken), type(uint256).max);
        shieldedToken.deposit(101e10, SHIELDED_USER);
        shieldedToken.approve(address(pool), type(uint256).max);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 101e10, 0);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 balanceBefore = backingToken.balanceOf(SHIELDED_USER);
        pool.shieldedWithdraw(tokenId, address(backingToken), 0);
        vm.stopPrank();

        assertEq(backingToken.balanceOf(SHIELDED_USER) - balanceBefore, 1, "payout should not round up to 2 units");
    }

    function test_ClaimRewards_UsesShieldedTokenScaleForSixDecimalVault() public {
        MockUSDC shieldedBaseToken = new MockUSDC();
        MockERC4626 shieldedToken = new MockERC4626(IERC20(address(shieldedBaseToken)), "USDC Vault", "vUSDC");
        MockERC20 backingToken = new MockERC20("Backing Token", "BACK");

        (SplitRiskPool pool, ShieldReceiptNFT shieldNFT, MockOracle oracle) =
            _deployPool(address(shieldedToken), "vUSDC", address(backingToken), "BACK");

        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        shieldedBaseToken.mint(SHIELDED_USER, 100e6);
        backingToken.mint(PROTECTOR, 500e18);

        vm.startPrank(PROTECTOR);
        backingToken.approve(address(pool), type(uint256).max);
        pool.depositBackingAsset(address(backingToken), 500e18, 0);
        vm.stopPrank();

        vm.startPrank(SHIELDED_USER);
        shieldedBaseToken.approve(address(shieldedToken), type(uint256).max);
        shieldedToken.deposit(100e6, SHIELDED_USER);
        shieldedToken.approve(address(pool), type(uint256).max);
        uint256 tokenId = pool.depositShieldedAsset(address(shieldedToken), 100e6, 0);
        vm.stopPrank();

        oracle.setPrice(address(shieldedToken), 2e8);
        vm.prank(SHIELDED_USER);
        pool.claimRewards(tokenId);

        IShieldReceiptNFT.ShieldPosition memory position = shieldNFT.getPosition(tokenId);
        assertEq(position.amount, 92e6, "fee accrual should keep native 6-dec shielded units");
        assertEq(pool.totalShieldedTokens(), 92e6, "tracked shielded total should reflect deducted fees");
        assertEq(pool.accumulatedCommissions(), 5e6, "commission should be denominated in 6-dec shielded units");
        assertEq(pool.accumulatedPoolFee(), 2_500_000, "pool fee should be denominated in 6-dec shielded units");
        assertEq(pool.accumulatedProtocolFee(), 500_000, "protocol fee should be denominated in 6-dec shielded units");
    }

    function test_GetAvailableForWithdrawal_FailsClosedWhenSixDecimalBackingPriceUnavailable() public {
        MockERC20 shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        MockERC4626 shieldedToken = new MockERC4626(IERC20(address(shieldedBaseToken)), "Shielded Token", "SHIELD");
        MockUSDC backingToken = new MockUSDC();

        (SplitRiskPool pool,, MockOracle oracle) =
            _deployPool(address(shieldedToken), "SHIELD", address(backingToken), "USDC");

        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        backingToken.mint(PROTECTOR, 200e6);
        shieldedBaseToken.mint(SHIELDED_USER, 100e18);

        vm.startPrank(PROTECTOR);
        backingToken.approve(address(pool), type(uint256).max);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), 200e6, 0);
        vm.stopPrank();

        vm.startPrank(SHIELDED_USER);
        shieldedBaseToken.approve(address(shieldedToken), type(uint256).max);
        shieldedToken.deposit(100e18, SHIELDED_USER);
        shieldedToken.approve(address(pool), type(uint256).max);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        assertEq(pool.getAvailableForWithdrawal(tokenId), 50e6, "available should use 6-dec backing units");

        vm.mockCallRevert(
            address(oracle),
            abi.encodeWithSelector(MockOracle.getPrice.selector, address(backingToken)),
            abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(backingToken))
        );
        assertEq(pool.getAvailableForWithdrawal(tokenId), 0, "price outage should fail closed for 18->6 pools");
    }

    function test_DepositShieldedAsset_RevertsWhenShieldedCircuitBreakerTrips() public {
        MockERC20 shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        MockERC4626 shieldedToken = new MockERC4626(IERC20(address(shieldedBaseToken)), "Shielded Token", "SHIELD");
        MockUSDC backingToken = new MockUSDC();

        (SplitRiskPool pool,, MockOracle oracle) =
            _deployPool(address(shieldedToken), "SHIELD", address(backingToken), "USDC");

        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        backingToken.mint(PROTECTOR, 200e6);
        shieldedBaseToken.mint(SHIELDED_USER, 100e18);

        vm.startPrank(PROTECTOR);
        backingToken.approve(address(pool), type(uint256).max);
        pool.depositBackingAsset(address(backingToken), 200e6, 0);
        vm.stopPrank();

        vm.mockCallRevert(
            address(oracle),
            abi.encodeWithSelector(MockOracle.getPrice.selector, address(shieldedToken)),
            abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(shieldedToken))
        );

        vm.startPrank(SHIELDED_USER);
        shieldedBaseToken.approve(address(shieldedToken), type(uint256).max);
        shieldedToken.deposit(100e18, SHIELDED_USER);
        shieldedToken.approve(address(pool), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(shieldedToken)));
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();
    }

    function test_DepositBackingAsset_RevertsWhenShieldedCircuitBreakerTripsDuringTvlCheck() public {
        MockERC20 shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        MockERC4626 shieldedToken = new MockERC4626(IERC20(address(shieldedBaseToken)), "Shielded Token", "SHIELD");
        MockUSDC backingToken = new MockUSDC();

        (SplitRiskPool pool,, MockOracle oracle) =
            _deployPool(address(shieldedToken), "SHIELD", address(backingToken), "USDC");

        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        backingToken.mint(PROTECTOR, 400e6);
        shieldedBaseToken.mint(SHIELDED_USER, 100e18);

        vm.startPrank(PROTECTOR);
        backingToken.approve(address(pool), type(uint256).max);
        pool.depositBackingAsset(address(backingToken), 200e6, 0);
        vm.stopPrank();

        vm.startPrank(SHIELDED_USER);
        shieldedBaseToken.approve(address(shieldedToken), type(uint256).max);
        shieldedToken.deposit(100e18, SHIELDED_USER);
        shieldedToken.approve(address(pool), type(uint256).max);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        vm.mockCallRevert(
            address(oracle),
            abi.encodeWithSelector(MockOracle.getPrice.selector, address(shieldedToken)),
            abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(shieldedToken))
        );

        vm.startPrank(PROTECTOR);
        vm.expectRevert(abi.encodeWithSelector(MockOracle.MockCircuitBreakerTriggered.selector, address(shieldedToken)));
        pool.depositBackingAsset(address(backingToken), 50e6, 0);
        vm.stopPrank();
    }

    function test_DepositShieldedAsset_UsesProtectedShieldedPriceForTvlLimit() public {
        MockERC20 shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        MockERC4626 shieldedToken = new MockERC4626(IERC20(address(shieldedBaseToken)), "Shielded Token", "SHIELD");
        MockUSDC backingToken = new MockUSDC();

        (SplitRiskPool pool,, MockOracle oracle) =
            _deployPool(address(shieldedToken), "SHIELD", address(backingToken), "USDC");

        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        backingToken.mint(PROTECTOR, 200e6);
        shieldedBaseToken.mint(SHIELDED_USER, 200e18);

        vm.startPrank(PROTECTOR);
        backingToken.approve(address(pool), type(uint256).max);
        pool.depositBackingAsset(address(backingToken), 200e6, 0);
        vm.stopPrank();

        vm.startPrank(SHIELDED_USER);
        shieldedBaseToken.approve(address(shieldedToken), type(uint256).max);
        shieldedToken.deposit(100e18, SHIELDED_USER);
        shieldedToken.approve(address(pool), type(uint256).max);
        pool.depositShieldedAsset(address(shieldedToken), 100e18, 0);
        vm.stopPrank();

        (
            uint256 shieldedMinDepositAmount,
            uint256 shieldedMaxDepositAmount,
            uint256 backingMinDepositAmount,
            uint256 backingMaxDepositAmount,,
            uint256 minimumPoolTime,
            uint256 unlockDuration,
            address protocolFeeRecipient,
            uint96 protocolFee,
            address priceOracle
        ) = pool.poolConfig();

        vm.prank(lastGovernanceTimelock);
        pool.updatePoolConfig(
            shieldedMinDepositAmount,
            shieldedMaxDepositAmount,
            backingMinDepositAmount,
            backingMaxDepositAmount,
            350e8,
            minimumPoolTime,
            unlockDuration,
            protocolFee,
            protocolFeeRecipient,
            priceOracle
        );

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(MockOracle.getPrice.selector, address(shieldedToken)),
            abi.encode(2e8)
        );

        vm.startPrank(SHIELDED_USER);
        shieldedToken.deposit(1e18, SHIELDED_USER);
        vm.expectRevert(ErrorsLib.TVLLimitExceeded.selector);
        pool.depositShieldedAsset(address(shieldedToken), 1e18, 0);
        vm.stopPrank();
    }

    function test_GetAvailableForWithdrawal_FailsClosedWhenEighteenDecimalBackingPriceUnavailable() public {
        MockUSDC shieldedBaseToken = new MockUSDC();
        MockERC4626 shieldedToken = new MockERC4626(IERC20(address(shieldedBaseToken)), "USDC Vault", "vUSDC");
        MockERC20 backingToken = new MockERC20("Backing Token", "BACK");

        (SplitRiskPool pool,, MockOracle oracle) =
            _deployPool(address(shieldedToken), "vUSDC", address(backingToken), "BACK");

        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        shieldedBaseToken.mint(SHIELDED_USER, 100e6);
        backingToken.mint(PROTECTOR, 500e18);

        vm.startPrank(PROTECTOR);
        backingToken.approve(address(pool), type(uint256).max);
        uint256 tokenId = pool.depositBackingAsset(address(backingToken), 500e18, 0);
        vm.stopPrank();

        vm.startPrank(SHIELDED_USER);
        shieldedBaseToken.approve(address(shieldedToken), type(uint256).max);
        shieldedToken.deposit(100e6, SHIELDED_USER);
        shieldedToken.approve(address(pool), type(uint256).max);
        pool.depositShieldedAsset(address(shieldedToken), 100e6, 0);
        vm.stopPrank();

        assertEq(pool.getAvailableForWithdrawal(tokenId), 350e18, "available should use 18-dec backing units");

        oracle.setShouldRevertOnCircuitBreaker(true);
        assertEq(pool.getAvailableForWithdrawal(tokenId), 0, "price outage should fail closed for 6->18 pools");
    }

    function _deployPool(
        address shieldedToken,
        string memory shieldedSymbol,
        address backingToken,
        string memory backingSymbol
    ) internal returns (SplitRiskPool pool, ShieldReceiptNFT shieldNFT, MockOracle oracle) {
        oracle = new MockOracle();

        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: shieldedSymbol,
            symbol: shieldedSymbol,
            token: shieldedToken,
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: backingSymbol,
            symbol: backingSymbol,
            token: backingToken,
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        shieldNFT = new ShieldReceiptNFT(string.concat("s", shieldedSymbol), string.concat("s", shieldedSymbol));
        ProtectorReceiptNFT protectorNFT =
            new ProtectorReceiptNFT(string.concat("p", backingSymbol), string.concat("p", backingSymbol));
        lastGovernanceTimelock = address(_deployTestTimelock(address(this)));

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000,
            500,
            address(this),
            15000,
            lastGovernanceTimelock,
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
    }

    function _setShieldedMinDepositAmount(SplitRiskPool pool, uint256 newMin) internal {
        (
            ,
            uint256 shieldedMaxDepositAmount,
            uint256 backingMinDepositAmount,
            uint256 backingMaxDepositAmount,
            uint256 maxTotalValueLockedUsd,
            uint256 minimumPoolTime,
            uint256 unlockDuration,
            address protocolFeeRecipient,
            uint96 protocolFee,
            address priceOracle
        ) = pool.poolConfig();

        vm.prank(lastGovernanceTimelock);
        pool.updatePoolConfig(
            newMin,
            shieldedMaxDepositAmount,
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
}
