// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { ChainlinkOracleFeed } from "../contracts/oracles/ChainlinkOracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { RobinhoodStockOracleFeed } from "../contracts/oracles/RobinhoodStockOracleFeed.sol";
import { USMarketSessionGate } from "../contracts/oracles/USMarketSessionGate.sol";
import { MockChainlinkAggregator } from "../contracts/mocks/MockChainlinkAggregator.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockRobinhoodStockToken } from "../contracts/mocks/MockRobinhoodStockToken.sol";
import { FactoryProxyTestBase } from "./helpers/FactoryProxyTestBase.sol";

contract StockMarketSessionProtectionTest is Test, FactoryProxyTestBase, IERC721Receiver {
    SplitRiskPool internal pool;
    SplitRiskPoolFactory internal factory;
    CompositeOracle internal composite;
    ChainlinkOracleFeed internal chainlink;
    RobinhoodStockOracleFeed internal stockFeed;
    USMarketSessionGate internal marketGate;
    MockRobinhoodStockToken internal stock;
    MockERC20 internal backing;
    MockChainlinkAggregator internal stockAggregator;
    MockChainlinkAggregator internal backingAggregator;

    address internal governance;

    function setUp() public {
        vm.warp(20_000 days + 12 hours);
        governance = address(_deployTestTimelock(address(this)));

        stock = new MockRobinhoodStockToken("Test Stock", "STOCK");
        backing = new MockERC20("Backing", "BACK");
        stockAggregator = new MockChainlinkAggregator("STOCK / USD", 8, 100e8);
        backingAggregator = new MockChainlinkAggregator("BACK / USD", 8, 1e8);

        chainlink = new ChainlinkOracleFeed(1 days);
        chainlink.setTokenFeed(address(stock), address(stockAggregator));
        chainlink.setTokenFeed(address(backing), address(backingAggregator));
        marketGate = new USMarketSessionGate(address(this), address(0xBEEF));
        marketGate.setDailySession(uint64(block.timestamp / 1 days), 0, uint32(1 days));
        stockFeed = new RobinhoodStockOracleFeed(address(chainlink), address(marketGate));
        composite = new CompositeOracle();

        SplitRiskPool implementation = new SplitRiskPool();
        factory = _deployFactory(address(this), governance, address(implementation));
        composite.transferOwnership(address(factory));
        factory.setCompositeOracle(address(composite));
        factory.setCompositeOracleAuthorizedCaller(address(this), true);
        factory.setDefaultProtocolFeeRecipient(address(0xFEE));
        vm.prank(governance);
        factory.setMinimumCreationBondUsd(0);

        factory.addTokenInitial(address(stock), "Test Stock", "STOCK", address(stockFeed), address(0), 10_000, true);
        factory.addTokenInitial(address(backing), "Backing", "BACK", address(chainlink), address(0), 10_000, true);

        address poolAddress = factory.createPool(address(stock), "STOCK", address(backing), "BACK", 500, 200, 15_000, 0);
        pool = SplitRiskPool(payable(poolAddress));

        stock.mint(address(this), 100e18);
        backing.mint(address(this), 20_000e18);
        stock.approve(address(pool), type(uint256).max);
        backing.approve(address(pool), type(uint256).max);
        pool.depositBackingAsset(address(backing), 20_000e18, 0);
    }

    function test_freshButClosedStockPriceRejectsNewProtectionBeforeTransfer() public {
        uint64 day = uint64(block.timestamp / 1 days);
        marketGate.clearDailySession(day);
        uint256 balanceBefore = stock.balanceOf(address(this));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ProtectionOpeningClosed.selector, address(stock)));
        pool.depositShieldedAsset(address(stock), 10e18, 0);

        assertEq(stock.balanceOf(address(this)), balanceBefore);
        assertEq(stock.balanceOf(address(pool)), 0);
        assertEq(chainlink.getPrice(address(stock)), 100e8, "price remains fresh and readable while market is closed");
    }

    function test_closedSessionDoesNotBlockSameAssetWithdrawal() public {
        uint256 tokenId = pool.depositShieldedAsset(address(stock), 10e18, 0);
        marketGate.clearDailySession(uint64(block.timestamp / 1 days));

        pool.shieldedWithdraw(tokenId, address(stock), 0);
        assertEq(pool.totalShieldedTokens(), 0);
    }

    function test_emergencyPauseRejectsOpeningsWithoutDisablingValuation() public {
        vm.prank(address(0xBEEF));
        marketGate.emergencyPause();

        assertFalse(composite.isProtectionOpeningAllowed(address(stock)));
        assertEq(composite.getPrice(address(stock)), 100e8);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.ProtectionOpeningClosed.selector, address(stock)));
        pool.depositShieldedAsset(address(stock), 10e18, 0);
    }

    function test_requiredEligibilityCallFailureFailsClosed() public {
        vm.mockCallRevert(
            address(composite), abi.encodeCall(composite.isProtectionOpeningAllowed, (address(stock))), bytes("")
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ErrorsLib.ProtectionOpeningEligibilityUnavailable.selector, address(stock), address(composite)
            )
        );
        pool.depositShieldedAsset(address(stock), 10e18, 0);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
