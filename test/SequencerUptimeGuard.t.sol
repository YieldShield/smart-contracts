// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SequencerUptimeGuard } from "../contracts/oracles/SequencerUptimeGuard.sol";
import { MockSequencerUptimeFeed } from "../contracts/mocks/MockSequencerUptimeFeed.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { PythEMAOracleFeed } from "../contracts/oracles/PythEMAOracleFeed.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { UniswapV3TWAPFeed } from "../contracts/oracles/UniswapV3TWAPFeed.sol";

/// @dev Minimal concrete harness exposing the abstract guard's internals.
contract GuardHarness is SequencerUptimeGuard {
    constructor() SequencerUptimeGuard() { }

    function check() external view {
        _checkSequencerUptime();
    }

    function isKnownL2(uint256 chainId) external pure returns (bool) {
        return _isKnownL2RequiringSequencer(chainId);
    }
}

/// @title SequencerUptimeGuardTest
/// @notice Exercises the shared L2 sequencer gate (SEC-01) added to the Pyth/TWAP/ERC4626 feeds.
contract SequencerUptimeGuardTest is Test {
    uint256 constant ARBITRUM_ONE = 42161;
    uint256 constant ARBITRUM_SEPOLIA = 421614;
    address constant DUMMY_PYTH = address(0xBEEF);
    address constant TOKEN = address(0xA11CE);

    // -------------------------------------------------------------------------
    // Default requirement per chain
    // -------------------------------------------------------------------------

    function test_DefaultRequiredOnKnownL2s() public {
        uint256[6] memory l2s = [uint256(10), 11155420, 8453, 84532, 42161, 421614];
        for (uint256 i = 0; i < l2s.length; i++) {
            vm.chainId(l2s[i]);
            GuardHarness h = new GuardHarness();
            assertTrue(h.sequencerUptimeFeedRequired(), "should be required on known L2");
        }
    }

    function test_DefaultNotRequiredOffKnownL2s() public {
        uint256[3] memory others = [uint256(31337), 1, 534_352];
        for (uint256 i = 0; i < others.length; i++) {
            vm.chainId(others[i]);
            GuardHarness h = new GuardHarness();
            assertFalse(h.sequencerUptimeFeedRequired(), "should not be required off known L2");
        }
    }

    // -------------------------------------------------------------------------
    // Gate behavior
    // -------------------------------------------------------------------------

    function test_CheckRevertsWhenRequiredAndNoFeed() public {
        vm.chainId(ARBITRUM_ONE);
        GuardHarness h = new GuardHarness();
        vm.expectRevert(abi.encodeWithSelector(SequencerUptimeGuard.SequencerUptimeFeedRequired.selector, ARBITRUM_ONE));
        h.check();
    }

    function test_SetRequiredFalseUnbricks() public {
        vm.chainId(ARBITRUM_ONE);
        GuardHarness h = new GuardHarness();
        h.setSequencerUptimeFeedRequired(false);
        h.check(); // no revert
        assertFalse(h.sequencerUptimeFeedRequired());
    }

    function test_NoCheckWhenNotRequiredAndNoFeed() public {
        vm.chainId(31337);
        GuardHarness h = new GuardHarness();
        h.check(); // no feed, not required → no-op
    }

    function test_SequencerDownReverts() public {
        vm.chainId(ARBITRUM_ONE);
        GuardHarness h = new GuardHarness();
        MockSequencerUptimeFeed feed = new MockSequencerUptimeFeed();
        // Move startedAt far enough back that grace would otherwise pass.
        vm.warp(block.timestamp + h.GRACE_PERIOD_TIME() + 100);
        h.setSequencerUptimeFeed(address(feed));
        feed.setSequencerUp(false);
        vm.expectRevert(SequencerUptimeGuard.SequencerDown.selector);
        h.check();
    }

    function test_GracePeriodNotOverThenPasses() public {
        vm.chainId(ARBITRUM_ONE);
        GuardHarness h = new GuardHarness();
        MockSequencerUptimeFeed feed = new MockSequencerUptimeFeed();
        h.setSequencerUptimeFeed(address(feed));
        feed.setStartedAt(block.timestamp); // just came up

        vm.expectRevert(
            abi.encodeWithSelector(SequencerUptimeGuard.GracePeriodNotOver.selector, 0, h.GRACE_PERIOD_TIME())
        );
        h.check();

        // After the grace period elapses, the read is allowed.
        vm.warp(block.timestamp + h.GRACE_PERIOD_TIME() + 1);
        h.check();
    }

    function test_SetFeedZeroWhenRequiredReverts() public {
        vm.chainId(ARBITRUM_ONE);
        GuardHarness h = new GuardHarness();
        vm.expectRevert(abi.encodeWithSelector(SequencerUptimeGuard.SequencerUptimeFeedRequired.selector, ARBITRUM_ONE));
        h.setSequencerUptimeFeed(address(0));
    }

    function test_SetFeedRejectsInvalidAddress() public {
        vm.chainId(ARBITRUM_ONE);
        GuardHarness h = new GuardHarness();
        // address(0xdead) has no code → latestRoundData() reverts → rejected.
        vm.expectRevert(
            abi.encodeWithSelector(SequencerUptimeGuard.InvalidSequencerFeedAddress.selector, address(0xdead))
        );
        h.setSequencerUptimeFeed(address(0xdead));
    }

    function test_OnlyOwnerSetters() public {
        vm.chainId(ARBITRUM_ONE);
        GuardHarness h = new GuardHarness();
        address attacker = address(0xBAD);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        h.setSequencerUptimeFeedRequired(false);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        h.setSequencerUptimeFeed(address(0));
    }

    function test_GetSequencerStatus() public {
        vm.chainId(ARBITRUM_ONE);
        GuardHarness h = new GuardHarness();
        MockSequencerUptimeFeed feed = new MockSequencerUptimeFeed();
        h.setSequencerUptimeFeed(address(feed));
        feed.setStartedAt(block.timestamp - h.GRACE_PERIOD_TIME() - 10);
        (bool isUp, bool gracePassed,) = h.getSequencerStatus();
        assertTrue(isUp);
        assertTrue(gracePassed);
    }

    // -------------------------------------------------------------------------
    // Wiring: each production feed actually calls the gate on its read path
    // -------------------------------------------------------------------------

    function test_PythOracleGatedOnL2() public {
        vm.chainId(ARBITRUM_ONE);
        PythOracle oracle = new PythOracle(DUMMY_PYTH, 3600);
        assertTrue(oracle.sequencerUptimeFeedRequired());
        // getPriceUnsafe → _getPythPrice → _checkSequencerUptime is the first
        // statement, so it reverts before the token-support lookup.
        vm.expectRevert(abi.encodeWithSelector(SequencerUptimeGuard.SequencerUptimeFeedRequired.selector, ARBITRUM_ONE));
        oracle.getPriceUnsafe(TOKEN);
    }

    function test_PythOracleIsPriceStaleFailsClosedOnL2() public {
        vm.chainId(ARBITRUM_ONE);
        PythOracle oracle = new PythOracle(DUMMY_PYTH, 3600);

        (bool isStale, uint64 publishTime) = oracle.isPriceStale(TOKEN);

        assertTrue(isStale);
        assertEq(publishTime, 0);
    }

    function test_ERC4626GatedOnL2() public {
        vm.chainId(ARBITRUM_ONE);
        PythOracle underlying = new PythOracle(DUMMY_PYTH, 3600);
        ERC4626OracleFeed feed = new ERC4626OracleFeed(address(underlying));
        assertTrue(feed.sequencerUptimeFeedRequired());
        // getPrice → _getValidatedPrice → _checkSequencerUptime first → reverts
        // before the vault-registration lookup.
        vm.expectRevert(abi.encodeWithSelector(SequencerUptimeGuard.SequencerUptimeFeedRequired.selector, ARBITRUM_ONE));
        feed.getPrice(TOKEN);
    }

    function test_ERC4626GetPriceWithStalenessGatedOnL2() public {
        vm.chainId(ARBITRUM_ONE);
        PythOracle underlying = new PythOracle(DUMMY_PYTH, 3600);
        ERC4626OracleFeed feed = new ERC4626OracleFeed(address(underlying));
        // Codex P2: getPriceWithStaleness also returns a USD price and must hit
        // the gate first, before the vault-config lookup.
        vm.expectRevert(abi.encodeWithSelector(SequencerUptimeGuard.SequencerUptimeFeedRequired.selector, ARBITRUM_ONE));
        feed.getPriceWithStaleness(TOKEN);
    }

    function test_PythEMAGatedOnL2() public {
        vm.chainId(ARBITRUM_ONE);
        PythEMAOracleFeed feed = new PythEMAOracleFeed(DUMMY_PYTH, 3600);
        assertTrue(feed.sequencerUptimeFeedRequired());
        // EMA checks token support first, so register a token, then the read
        // must hit the sequencer gate.
        feed.setTokenPriceFeed(TOKEN, bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(SequencerUptimeGuard.SequencerUptimeFeedRequired.selector, ARBITRUM_ONE));
        feed.getPrice(TOKEN);
    }

    function test_UniswapV3TWAPDefaultsRequiredOnL2() public {
        vm.chainId(ARBITRUM_ONE);
        MockERC20 quote = new MockERC20("Quote", "QUOTE");
        UniswapV3TWAPFeed feed = new UniswapV3TWAPFeed(1800, address(quote), DUMMY_PYTH);
        assertTrue(feed.sequencerUptimeFeedRequired(), "TWAP feed must inherit the gate default");
    }
}
