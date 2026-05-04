// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { AccessControlExample } from "../contracts/examples/AccessControlExample.sol";
import { IPoolAccessControl } from "../contracts/interfaces/IPoolAccessControl.sol";

contract AccessControlExampleTest is Test {
    AccessControlExample public accessControl;
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);

    event OwnerUpdated(address indexed previousOwner, address indexed newOwner);
    event WhitelistUpdated(address indexed account, bool isWhitelisted);

    function setUp() public {
        accessControl = new AccessControlExample(owner);
    }

    /* Constructor Tests */

    function test_Constructor_SetsOwner() public view {
        assertEq(accessControl.owner(), owner);
    }

    function test_Constructor_RevertsIfZeroAddress() public {
        vm.expectRevert(AccessControlExample.Unauthorized.selector);
        new AccessControlExample(address(0));
    }

    /* Owner Functions Tests */

    function test_SetOwner_OnlyOwner() public {
        address newOwner = address(0x5);
        vm.expectEmit(true, true, false, false);
        emit OwnerUpdated(owner, newOwner);
        vm.prank(owner);
        accessControl.setOwner(newOwner);
        assertEq(accessControl.owner(), newOwner);
    }

    function test_SetOwner_RevertsIfNotOwner() public {
        vm.expectRevert(AccessControlExample.Unauthorized.selector);
        vm.prank(user1);
        accessControl.setOwner(user1);
    }

    function test_SetOwner_RevertsIfZeroAddress() public {
        vm.expectRevert(AccessControlExample.Unauthorized.selector);
        vm.prank(owner);
        accessControl.setOwner(address(0));
    }

    /* Whitelist Functions Tests */

    function test_SetWhitelisted_OnlyOwner() public {
        vm.expectEmit(true, false, false, false);
        emit WhitelistUpdated(user1, true);
        vm.prank(owner);
        accessControl.setWhitelisted(user1, true);
        assertTrue(accessControl.whitelisted(user1));
    }

    function test_SetWhitelisted_RevertsIfNotOwner() public {
        vm.expectRevert(AccessControlExample.Unauthorized.selector);
        vm.prank(user1);
        accessControl.setWhitelisted(user1, true);
    }

    function test_SetWhitelisted_CanUnwhitelist() public {
        vm.startPrank(owner);
        accessControl.setWhitelisted(user1, true);
        assertTrue(accessControl.whitelisted(user1));

        vm.expectEmit(true, false, false, false);
        emit WhitelistUpdated(user1, false);
        accessControl.setWhitelisted(user1, false);
        assertFalse(accessControl.whitelisted(user1));
        vm.stopPrank();
    }

    function test_BatchSetWhitelisted_OnlyOwner() public {
        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;

        vm.expectEmit(true, false, false, false);
        emit WhitelistUpdated(user1, true);
        vm.expectEmit(true, false, false, false);
        emit WhitelistUpdated(user2, true);
        vm.expectEmit(true, false, false, false);
        emit WhitelistUpdated(user3, true);

        vm.prank(owner);
        accessControl.batchSetWhitelisted(accounts, true);

        assertTrue(accessControl.whitelisted(user1));
        assertTrue(accessControl.whitelisted(user2));
        assertTrue(accessControl.whitelisted(user3));
    }

    function test_BatchSetWhitelisted_RevertsIfNotOwner() public {
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        vm.expectRevert(AccessControlExample.Unauthorized.selector);
        vm.prank(user1);
        accessControl.batchSetWhitelisted(accounts, true);
    }

    /* Permission Check Tests */

    function test_CanDepositShielded_ReturnsTrueIfWhitelisted() public {
        vm.prank(owner);
        accessControl.setWhitelisted(user1, true);
        assertTrue(accessControl.canDepositShielded(user1));
    }

    function test_CanDepositShielded_ReturnsFalseIfNotWhitelisted() public view {
        assertFalse(accessControl.canDepositShielded(user1));
    }

    function test_CanWithdrawShielded_ReturnsTrueIfWhitelisted() public {
        vm.prank(owner);
        accessControl.setWhitelisted(user1, true);
        assertTrue(accessControl.canWithdrawShielded(user1));
    }

    function test_CanWithdrawShielded_ReturnsFalseIfNotWhitelisted() public view {
        assertFalse(accessControl.canWithdrawShielded(user1));
    }

    function test_CanDepositProtector_ReturnsTrueIfWhitelisted() public {
        vm.prank(owner);
        accessControl.setWhitelisted(user1, true);
        assertTrue(accessControl.canDepositProtector(user1));
    }

    function test_CanDepositProtector_ReturnsFalseIfNotWhitelisted() public view {
        assertFalse(accessControl.canDepositProtector(user1));
    }

    function test_CanWithdrawProtector_ReturnsTrueIfWhitelisted() public {
        vm.prank(owner);
        accessControl.setWhitelisted(user1, true);
        assertTrue(accessControl.canWithdrawProtector(user1));
    }

    function test_CanWithdrawProtector_ReturnsFalseIfNotWhitelisted() public view {
        assertFalse(accessControl.canWithdrawProtector(user1));
    }

    function test_AllPermissions_ConsistentForWhitelistedUser() public {
        vm.prank(owner);
        accessControl.setWhitelisted(user1, true);

        assertTrue(accessControl.canDepositShielded(user1));
        assertTrue(accessControl.canWithdrawShielded(user1));
        assertTrue(accessControl.canDepositProtector(user1));
        assertTrue(accessControl.canWithdrawProtector(user1));
    }

    function test_AllPermissions_ConsistentForNonWhitelistedUser() public view {
        assertFalse(accessControl.canDepositShielded(user1));
        assertFalse(accessControl.canWithdrawShielded(user1));
        assertFalse(accessControl.canDepositProtector(user1));
        assertFalse(accessControl.canWithdrawProtector(user1));
    }
}
