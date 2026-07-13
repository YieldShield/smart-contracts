// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IPyth } from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythErrors } from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";
import { PythConfig } from "../contracts/oracles/PythConfig.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { ISequencerUptimeFeed, SequencerUptimeGuard } from "../contracts/oracles/SequencerUptimeGuard.sol";
import { ForkTestHelper } from "./helpers/ForkTestHelper.sol";

interface IPythValidTimePeriod {
    function getValidTimePeriod() external view returns (uint256);
}

/// @notice Required pull-request smoke tests for the checked-in Arbitrum oracle addresses.
/// @dev Each test forks an official public RPC and treats both a sane live Pyth price and
///      Pyth's exact no-price/stale errors as valid. Missing sequencer configuration and
///      unknown Pyth feeds must always fail closed with their exact selectors.
contract ArbitrumOracleForkTest is ForkTestHelper {
    address internal constant TEST_TOKEN = address(0xA11CE);
    bytes32 internal constant UNKNOWN_FEED_ID = bytes32(type(uint256).max);

    modifier onlyArbitrumOne() {
        string memory forkUrl = _forkUrlOrSkip("ARBITRUM_RPC_URL", "Arbitrum One");
        if (bytes(forkUrl).length == 0) return;
        vm.createSelectFork(forkUrl);
        _;
    }

    modifier onlyArbitrumSepolia() {
        string memory forkUrl = _forkUrlOrSkip("ARBITRUM_SEPOLIA_RPC_URL", "Arbitrum Sepolia");
        if (bytes(forkUrl).length == 0) return;
        vm.createSelectFork(forkUrl);
        _;
    }

    function testArbitrumOnePythAndSequencerIntegration() public onlyArbitrumOne {
        assertEq(block.chainid, PythConfig.ARBITRUM_MAINNET_CHAIN_ID, "unexpected Arbitrum One chain ID");

        address pythAddress = PythConfig.PYTH_ARBITRUM_MAINNET;
        _assertPythInterfaceAndFailClosedBehavior(pythAddress);

        PythOracle oracle = _deployOracle(pythAddress);
        _assertMissingSequencerFailsClosed(oracle, PythConfig.ARBITRUM_MAINNET_CHAIN_ID);

        address sequencerAddress = PythConfig.ARBITRUM_MAINNET_SEQUENCER_UPTIME_FEED;
        assertGt(sequencerAddress.code.length, 0, "canonical Arbitrum sequencer feed has no code");

        ISequencerUptimeFeed sequencer = ISequencerUptimeFeed(sequencerAddress);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            sequencer.latestRoundData();
        assertGt(roundId, 0, "sequencer feed has no round");
        assertTrue(answer == 0 || answer == 1, "sequencer feed returned an invalid status");
        assertGt(startedAt, 0, "sequencer status round never started");
        assertLe(startedAt, block.timestamp, "sequencer status is future-dated");
        assertGe(updatedAt, startedAt, "sequencer update predates its status change");
        assertLe(updatedAt, block.timestamp, "sequencer update is future-dated");
        assertGe(answeredInRound, roundId, "sequencer round is incomplete");

        oracle.setSequencerUptimeFeed(sequencerAddress);
        assertEq(address(oracle.sequencerUptimeFeed()), sequencerAddress, "canonical sequencer feed was not wired");

        if (answer != 0) {
            vm.expectRevert(SequencerUptimeGuard.SequencerDown.selector);
            oracle.getPrice(TEST_TOKEN);
        } else {
            uint256 timeSinceUp = block.timestamp - startedAt;
            if (timeSinceUp <= oracle.GRACE_PERIOD_TIME()) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        SequencerUptimeGuard.GracePeriodNotOver.selector, timeSinceUp, oracle.GRACE_PERIOD_TIME()
                    )
                );
                oracle.getPrice(TEST_TOKEN);
            } else {
                _assertProtocolPriceOrExpectedPythFailure(oracle);
            }
        }
    }

    function testArbitrumSepoliaPythIntegrationWithExplicitSequencerException() public onlyArbitrumSepolia {
        assertEq(block.chainid, PythConfig.ARBITRUM_SEPOLIA_CHAIN_ID, "unexpected Arbitrum Sepolia chain ID");

        address pythAddress = PythConfig.PYTH_ARBITRUM_SEPOLIA;
        _assertPythInterfaceAndFailClosedBehavior(pythAddress);

        PythOracle oracle = _deployOracle(pythAddress);
        assertEq(address(oracle.sequencerUptimeFeed()), address(0), "unexpected Arbitrum Sepolia sequencer feed");
        _assertMissingSequencerFailsClosed(oracle, PythConfig.ARBITRUM_SEPOLIA_CHAIN_ID);

        // Chainlink does not publish a canonical Arbitrum Sepolia sequencer feed.
        // The production policy therefore requires this exception to be explicit.
        oracle.setSequencerUptimeFeedRequired(false);
        assertFalse(oracle.sequencerUptimeFeedRequired(), "sequencer exception was not applied");
        assertEq(address(oracle.sequencerUptimeFeed()), address(0), "sequencer exception installed an unknown feed");
        _assertProtocolPriceOrExpectedPythFailure(oracle);
    }

    function _deployOracle(address pythAddress) internal returns (PythOracle oracle) {
        oracle = new PythOracle(pythAddress, 60);
        oracle.setTokenPriceFeed(TEST_TOKEN, PythConfig.USDC_USD_FEED_ID);
        assertTrue(oracle.sequencerUptimeFeedRequired(), "Arbitrum must default to sequencer protection");
    }

    function _assertMissingSequencerFailsClosed(PythOracle oracle, uint256 chainId) internal {
        vm.expectRevert(abi.encodeWithSelector(SequencerUptimeGuard.SequencerUptimeFeedRequired.selector, chainId));
        oracle.getPrice(TEST_TOKEN);
    }

    function _assertPythInterfaceAndFailClosedBehavior(address pythAddress) internal view {
        assertGt(pythAddress.code.length, 0, "canonical Pyth contract has no code");

        uint256 validTimePeriod = IPythValidTimePeriod(pythAddress).getValidTimePeriod();
        assertGt(validTimePeriod, 0, "Pyth valid time period is zero");

        bytes[] memory noUpdates = new bytes[](0);
        assertEq(IPyth(pythAddress).getUpdateFee(noUpdates), 0, "empty Pyth update batch has a fee");

        (bool success, bytes memory reason) = pythAddress.staticcall(
            abi.encodeWithSelector(IPyth.getPriceNoOlderThan.selector, UNKNOWN_FEED_ID, validTimePeriod)
        );
        assertFalse(success, "unknown Pyth feed unexpectedly returned a price");
        assertEq(_errorSelector(reason), PythErrors.PriceFeedNotFound.selector, "unknown Pyth feed did not fail closed");
    }

    function _assertProtocolPriceOrExpectedPythFailure(PythOracle oracle) internal view {
        try oracle.getPrice(TEST_TOKEN) returns (uint256 price) {
            assertGt(price, 50_000_000, "USDC/USD price is implausibly low");
            assertLt(price, 150_000_000, "USDC/USD price is implausibly high");
        } catch (bytes memory reason) {
            bytes4 selector = _errorSelector(reason);
            assertTrue(
                selector == PythErrors.PriceFeedNotFound.selector || selector == PythOracle.StalePrice.selector
                    || selector == PythErrors.StalePrice.selector,
                "unexpected Pyth integration failure"
            );
        }
    }

    function _errorSelector(bytes memory reason) internal pure returns (bytes4 selector) {
        assertGe(reason.length, 4, "oracle reverted without a selector");
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }
}
