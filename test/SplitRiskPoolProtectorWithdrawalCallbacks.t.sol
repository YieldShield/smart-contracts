// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { ConstantsLib } from "../contracts/libraries/ConstantsLib.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IHookedTokenReceiver {
    function onHookedTokenTransfer(address operator, uint256 amount) external;
}

contract HookedERC20 is ERC20 {
    bool public hooksEnabled;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHooksEnabled(bool enabled) external {
        hooksEnabled = enabled;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        _callHook(to, amount);
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _callHook(to, amount);
        return ok;
    }

    function _callHook(address to, uint256 amount) internal {
        if (!hooksEnabled || to.code.length == 0) {
            return;
        }

        try IHookedTokenReceiver(to).onHookedTokenTransfer(msg.sender, amount) { } catch { }
    }
}

contract ProtectorReceiptCallbackSeller is IERC721Receiver, IHookedTokenReceiver {
    SplitRiskPool public immutable pool;
    MockERC20 public immutable backingToken;
    ProtectorReceiptNFT public immutable protectorReceiptNFT;
    address public immutable buyer;
    uint256 public tokenId;
    bool public callbackAttempted;

    constructor(
        SplitRiskPool pool_,
        MockERC20 backingToken_,
        ProtectorReceiptNFT protectorReceiptNFT_,
        address buyer_
    ) {
        pool = pool_;
        backingToken = backingToken_;
        protectorReceiptNFT = protectorReceiptNFT_;
        buyer = buyer_;
    }

    function depositBacking(uint256 amount) external returns (uint256) {
        backingToken.approve(address(pool), amount);
        tokenId = pool.depositBackingAsset(address(backingToken), amount, 0);
        return tokenId;
    }

    function startUnlock() external {
        pool.startUnlockProcess(tokenId);
    }

    function withdraw(uint256 amount) external {
        pool.protectorWithdraw(tokenId, amount, address(backingToken), 0);
    }

    function onHookedTokenTransfer(address, uint256) external {
        callbackAttempted = true;
        protectorReceiptNFT.transferFrom(address(this), buyer, tokenId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract SplitRiskPoolProtectorWithdrawalCallbacksTest is Test, TestTimelockHelper {
    SplitRiskPool internal pool;
    HookedERC20 internal shieldedToken;
    MockERC20 internal backingToken;
    MockOracle internal oracle;
    ProtectorReceiptNFT internal protectorReceiptNFT;
    ProtectorReceiptCallbackSeller internal seller;

    address internal shielded = address(0xA11CE);
    address internal buyer = address(0xB0B);

    function setUp() public {
        address governance = address(_deployTestTimelock(address(this)));

        shieldedToken = new HookedERC20("Shielded Token", "SHLD");
        backingToken = new MockERC20("Backing Token", "BACK");
        oracle = new MockOracle();
        oracle.setPrice(address(shieldedToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "Shielded Token",
            symbol: "SHLD",
            token: address(shieldedToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10_000
        });
        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "Backing Token",
            symbol: "BACK",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10_000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        ShieldReceiptNFT shieldReceiptNFT = new ShieldReceiptNFT("iSHLD", "iSHLD");
        protectorReceiptNFT = new ProtectorReceiptNFT("uBACK", "uBACK");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000,
            500,
            address(this),
            15_000,
            governance,
            address(oracle),
            address(0xFEE),
            address(shieldReceiptNFT),
            address(protectorReceiptNFT),
            address(this)
        );
        pool = SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));

        shieldReceiptNFT.setPool(address(pool));
        protectorReceiptNFT.setPool(address(pool));
        shieldReceiptNFT.transferOwnership(address(pool));
        protectorReceiptNFT.transferOwnership(address(pool));

        seller = new ProtectorReceiptCallbackSeller(pool, backingToken, protectorReceiptNFT, buyer);
        backingToken.mint(address(seller), 1_000e18);
        shieldedToken.mint(shielded, 1_000e18);

        vm.prank(shielded);
        shieldedToken.approve(address(pool), type(uint256).max);
    }

    function _createPositionWithClaimableCommission() internal returns (uint256 tokenId) {
        tokenId = seller.depositBacking(1_000e18);

        vm.prank(shielded);
        pool.depositShieldedAsset(address(shieldedToken), 500e18, 0);

        oracle.setPrice(address(shieldedToken), 1.1e8);
        vm.prank(shielded);
        pool.claimRewards(0);

        seller.startUnlock();
        vm.warp(block.timestamp + ConstantsLib.DEFAULT_UNLOCK_DURATION);
        shieldedToken.setHooksEnabled(true);
    }

    function testProtectorWithdrawRevertsIfCommissionCallbackTransfersReceipt() public {
        uint256 tokenId = _createPositionWithClaimableCommission();
        uint256 sharesBefore = pool.protectorShares(tokenId);
        uint256 rewardDebtBefore = pool.rewardDebt(tokenId);
        uint256 claimedBefore = pool.commissionsClaimed(tokenId);
        uint256 claimableBefore = pool.getClaimableCommission(tokenId);

        vm.expectRevert(ErrorsLib.InvalidTokenId.selector);
        seller.withdraw(100e18);

        assertEq(protectorReceiptNFT.ownerOf(tokenId), address(seller), "receipt owner should be restored");
        assertEq(pool.getProtectorPositionAmount(tokenId), 1_000e18, "position amount should be unchanged");
        assertEq(pool.protectorShares(tokenId), sharesBefore, "shares should be unchanged");
        assertEq(pool.rewardDebt(tokenId), rewardDebtBefore, "reward debt should be unchanged");
        assertEq(pool.commissionsClaimed(tokenId), claimedBefore, "claimed amount should be unchanged");
        assertEq(pool.getClaimableCommission(tokenId), claimableBefore, "claimable commission should be unchanged");
    }
}
