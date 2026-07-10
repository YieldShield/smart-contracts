// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { USMarketSessionGate } from "../contracts/oracles/USMarketSessionGate.sol";

contract USMarketSessionGateTest is Test {
    USMarketSessionGate internal gate;
    address internal guardian = address(0xBEEF);
    address internal stranger = address(0xCAFE);

    function setUp() public {
        gate = new USMarketSessionGate(address(this), guardian);
    }

    function test_missingCalendarDayFailsClosed() public view {
        assertFalse(gate.isMarketOpen());
    }

    function test_sessionUsesInclusiveOpenAndExclusiveClose() public {
        uint64 day = 20_000;
        uint256 dayStart = uint256(day) * 1 days;
        gate.setDailySession(day, 14 hours + 30 minutes, 21 hours);

        vm.warp(dayStart + 14 hours + 29 minutes + 59 seconds);
        assertFalse(gate.isMarketOpen());
        vm.warp(dayStart + 14 hours + 30 minutes);
        assertTrue(gate.isMarketOpen());
        vm.warp(dayStart + 20 hours + 59 minutes + 59 seconds);
        assertTrue(gate.isMarketOpen());
        vm.warp(dayStart + 21 hours);
        assertFalse(gate.isMarketOpen());
    }

    function test_explicitHolidayAndEarlyCloseRemainClosedOutsideSchedule() public {
        uint64 holiday = 20_001;
        uint64 earlyClose = 20_002;
        gate.setDailySession(earlyClose, 0, 18 hours);

        vm.warp(uint256(holiday) * 1 days + 12 hours);
        assertFalse(gate.isMarketOpen(), "unconfigured holiday must remain closed");

        vm.warp(uint256(earlyClose) * 1 days + 17 hours + 59 minutes);
        assertTrue(gate.isMarketOpen());
        vm.warp(uint256(earlyClose) * 1 days + 18 hours);
        assertFalse(gate.isMarketOpen(), "early close must be exclusive");
    }

    function test_emergencyGuardianCanOnlyPause() public {
        uint64 day = uint64(block.timestamp / 1 days);
        gate.setDailySession(day, 0, uint32(1 days));
        assertTrue(gate.isMarketOpen());

        vm.prank(guardian);
        gate.emergencyPause();
        assertFalse(gate.isMarketOpen());

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        gate.clearEmergencyPause();

        gate.clearEmergencyPause();
        assertTrue(gate.isMarketOpen());
    }

    function test_unauthorizedAccountCannotPauseOrConfigure() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(USMarketSessionGate.UnauthorizedEmergencyPause.selector, stranger));
        gate.emergencyPause();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        gate.setDailySession(1, 0, uint32(1 days));
    }

    function test_batchConfigurationAndClearing() public {
        uint64[] memory epochDays = new uint64[](2);
        uint32[] memory opens = new uint32[](2);
        uint32[] memory closes = new uint32[](2);
        epochDays[0] = 20_003;
        epochDays[1] = 20_004;
        opens[0] = 0;
        opens[1] = 1 hours;
        closes[0] = uint32(1 days);
        closes[1] = 20 hours;

        gate.setDailySessions(epochDays, opens, closes);
        (uint32 firstOpen, uint32 firstClose) = gate.getDailySession(epochDays[0]);
        assertEq(firstOpen, 0);
        assertEq(firstClose, 1 days);

        gate.clearDailySession(epochDays[0]);
        (firstOpen, firstClose) = gate.getDailySession(epochDays[0]);
        assertEq(firstOpen, 0);
        assertEq(firstClose, 0);
    }

    function test_invalidSessionBoundsRevert() public {
        vm.expectRevert(abi.encodeWithSelector(USMarketSessionGate.InvalidSession.selector, 1, 10, 10));
        gate.setDailySession(1, 10, 10);

        vm.expectRevert(abi.encodeWithSelector(USMarketSessionGate.InvalidSession.selector, 1, 0, uint32(1 days + 1)));
        gate.setDailySession(1, 0, uint32(1 days + 1));
    }
}
