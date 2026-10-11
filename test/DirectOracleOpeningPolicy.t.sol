// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { StockMarketSessionProtectionTest } from "./StockMarketSessionProtection.t.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { RobinhoodStockOracleFeed } from "../contracts/oracles/RobinhoodStockOracleFeed.sol";

contract DirectOracleOpeningPolicyTest is StockMarketSessionProtectionTest {
    function _migrateToDirectStockFeed() internal {
        // Pauseable stablecoins are valid direct-wrapper backing tokens. Model
        // their canonical paused() hook using the existing backing fixture.
        vm.mockCall(address(backing), abi.encodeWithSignature("paused()"), abi.encode(false));
        stockFeed.setPauseProbeMode(address(backing), RobinhoodStockOracleFeed.PauseProbeMode.TokenPaused);
        (
            uint256 shieldedMin,
            uint256 shieldedMax,
            uint256 backingMin,
            uint256 backingMax,
            uint256 maxTvl,
            uint256 minimumTime,
            uint256 unlockDuration,
            address feeRecipient,
            uint96 protocolFee,
        ) = pool.poolConfig();
        vm.prank(governance);
        pool.updatePoolConfig(
            shieldedMin,
            shieldedMax,
            backingMin,
            backingMax,
            maxTvl,
            minimumTime,
            unlockDuration,
            protocolFee,
            feeRecipient,
            address(stockFeed)
        );
    }

    function test_directStockFeedRejectsClosedMarketBeforeTransfer() public {
        _migrateToDirectStockFeed();
        marketGate.clearDailySession(uint64(block.timestamp / 1 days));
        assertTrue(stockFeed.supportsProtectionOpeningEligibility(address(stock)));
        assertFalse(stockFeed.isProtectionOpeningAllowed(address(stock)));
        uint256 balanceBefore = stock.balanceOf(address(this));
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ProtectionOpeningClosed.selector, address(stock)));
        pool.depositShieldedAsset(address(stock), 10e18, 0);
        assertEq(stock.balanceOf(address(this)), balanceBefore);
        assertEq(pool.totalShieldedTokens(), 0);
    }

    function test_directStockFeedAllowsOpenMarket() public {
        _migrateToDirectStockFeed();
        pool.depositShieldedAsset(address(stock), 10e18, 0);
        assertEq(pool.totalShieldedTokens(), 10e18);
    }

    function test_directStockFeedRejectsEmergencyPause() public {
        _migrateToDirectStockFeed();
        marketGate.emergencyPause();
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ProtectionOpeningClosed.selector, address(stock)));
        pool.depositShieldedAsset(address(stock), 10e18, 0);
    }

    function test_directStockFeedRejectsExpiredOpeningFreshness() public {
        _migrateToDirectStockFeed();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ProtectionOpeningClosed.selector, address(stock)));
        pool.depositShieldedAsset(address(stock), 10e18, 0);
    }

    function test_directStockFeedRejectsUnavailableAdvertisedStatus() public {
        _migrateToDirectStockFeed();
        vm.mockCallRevert(
            address(stockFeed), abi.encodeCall(stockFeed.isProtectionOpeningAllowed, (address(stock))), bytes("")
        );
        _expectUnavailablePolicy();
        pool.depositShieldedAsset(address(stock), 10e18, 0);
    }

    function test_directStockFeedRejectsMalformedAdvertisedStatus() public {
        _migrateToDirectStockFeed();
        vm.mockCall(
            address(stockFeed), abi.encodeCall(stockFeed.isProtectionOpeningAllowed, (address(stock))), abi.encode(2)
        );
        _expectUnavailablePolicy();
        pool.depositShieldedAsset(address(stock), 10e18, 0);
    }

    function test_directStockFeedRejectsMalformedCapability() public {
        _migrateToDirectStockFeed();
        vm.mockCall(
            address(stockFeed),
            abi.encodeCall(stockFeed.supportsProtectionOpeningEligibility, (address(stock))),
            abi.encode(2)
        );
        _expectUnavailablePolicy();
        pool.depositShieldedAsset(address(stock), 10e18, 0);
    }

    function _expectUnavailablePolicy() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ProtectionOpeningEligibilityUnavailable.selector, address(stock), address(stockFeed)
            )
        );
    }
}
