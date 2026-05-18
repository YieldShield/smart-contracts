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
        vm.expectRevert(
            abi.encodeWithSelector(ErrorsLib.FutureTimestamp.selector, uint256(future), block.timestamp)
        );
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
}
