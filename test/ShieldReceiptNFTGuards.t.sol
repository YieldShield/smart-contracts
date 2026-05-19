// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { IShieldReceiptNFT } from "../contracts/interfaces/IShieldReceiptNFT.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";

contract ShieldReceiptNFTGuardsTest is Test {
    ShieldReceiptNFT internal nft;
    address internal pool = address(0xBEEF);

    function setUp() public {
        nft = new ShieldReceiptNFT("Shield", "SHLD");
        nft.setPool(pool);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function test_updatePosition_RevertsForFutureFeeClaimTime() public {
        vm.prank(pool);
        uint256 tokenId = nft.mint(address(this), 100, 100, 100);

        uint64 future = uint64(block.timestamp + 1);
        vm.prank(pool);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FutureTimestamp.selector, uint256(future), block.timestamp));
        nft.updatePosition(tokenId, 100, 100, 100, future);
    }

    function test_updatePosition_AcceptsCurrentTimestamp() public {
        vm.prank(pool);
        uint256 tokenId = nft.mint(address(this), 100, 100, 100);

        vm.prank(pool);
        nft.updatePosition(tokenId, 90, 90, 90, uint64(block.timestamp));
        IShieldReceiptNFT.ShieldPosition memory pos = nft.getPosition(tokenId);
        assertEq(pos.amount, 90);
        assertEq(pos.lastFeeClaimTime, uint64(block.timestamp));
    }

    function test_setTransferLockPeriod_RevertsForZero() public {
        vm.expectRevert(ErrorsLib.InvalidUnlockDuration.selector);
        nft.setTransferLockPeriod(0);
    }

    function test_setTransferLockPeriod_RevertsBelowMinimum() public {
        uint256 belowMin = nft.MIN_TRANSFER_LOCK() - 1;
        vm.expectRevert(ErrorsLib.InvalidUnlockDuration.selector);
        nft.setTransferLockPeriod(belowMin);
    }

    function test_setTransferLockPeriod_AcceptsMinimum() public {
        uint256 minLock = nft.MIN_TRANSFER_LOCK();
        nft.setTransferLockPeriod(minLock);
        assertEq(nft.transferLockPeriod(), minLock);
    }

    // C10 (2026-05-19): mintWithDepositTime must reject future-dated
    // originalDepositTime. Mirrors test_updatePosition_RevertsForFutureFeeClaimTime
    // (the L-12 fix). Today the pool only ever passes `pos.depositTime` from an
    // existing position so the branch is unreachable, but a future caller passing
    // a user-influenced value must not be able to brick the NFT.
    function test_mintWithDepositTime_RevertsForFutureDepositTime() public {
        uint64 future = uint64(block.timestamp + 1);
        vm.prank(pool);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.FutureTimestamp.selector, uint256(future), block.timestamp));
        nft.mintWithDepositTime(address(this), 100, 100, 100, future);
    }

    function test_mintWithDepositTime_AcceptsCurrentTimestamp() public {
        uint64 now64 = uint64(block.timestamp);
        vm.prank(pool);
        uint256 tokenId = nft.mintWithDepositTime(address(this), 100, 100, 100, now64);
        IShieldReceiptNFT.ShieldPosition memory pos = nft.getPosition(tokenId);
        assertEq(pos.depositTime, now64);
    }
}
