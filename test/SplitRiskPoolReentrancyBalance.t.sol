// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";

contract SplitRiskPoolRoundTripHarness is SplitRiskPool {
    function setShieldedTokenForHarness(address token) external {
        SHIELDED_TOKEN = token;
    }

    function probeRoundTrip(uint256 amount) external nonReentrant {
        _requireUntaxedShieldedRoundTrip(amount);
    }
}

contract ReentrantBalanceToken is ERC20 {
    address private callbackTarget;
    address private callbackRecipient;
    bytes private callbackData;
    bool private callbackArmed;

    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes4 public callbackRevertSelector;

    constructor() ERC20("Reentrant Balance Token", "RBT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function armCallback(address recipient, address target, bytes calldata data) external {
        callbackRecipient = recipient;
        callbackTarget = target;
        callbackData = data;
        callbackArmed = true;
        callbackAttempted = false;
        callbackSucceeded = false;
        callbackRevertSelector = bytes4(0);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        _attemptCallback(to);
        return success;
    }

    function _attemptCallback(address recipient) private {
        if (!callbackArmed || recipient != callbackRecipient) {
            return;
        }

        callbackArmed = false;
        callbackAttempted = true;
        bytes memory data = callbackData;
        (callbackSucceeded, data) = callbackTarget.call(data);
        if (!callbackSucceeded && data.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(data, 0x20))
            }
            callbackRevertSelector = selector;
        }
    }
}

contract SplitRiskPoolReentrancyBalanceTest is Test {
    function test_roundTripRejectsTokenCallbackReentrancyAndPreservesBalances() public {
        SplitRiskPoolRoundTripHarness pool = new SplitRiskPoolRoundTripHarness();
        ReentrantBalanceToken token = new ReentrantBalanceToken();
        pool.setShieldedTokenForHarness(address(token));
        token.mint(address(pool), 10e18);

        token.armCallback({
            recipient: address(pool),
            target: address(pool),
            data: abi.encodeCall(SplitRiskPoolRoundTripHarness.probeRoundTrip, (1e18))
        });

        pool.probeRoundTrip(5e18);

        assertTrue(token.callbackAttempted(), "return transfer did not invoke callback");
        assertFalse(token.callbackSucceeded(), "callback re-entered round-trip path");
        assertEq(
            token.callbackRevertSelector(),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "unexpected callback failure"
        );
        assertEq(token.balanceOf(address(pool)), 10e18, "pool balance changed across probe");
        assertEq(token.balanceOf(address(pool.shieldedTransferIntegrityProbe())), 0, "probe retained tokens");
    }
}
