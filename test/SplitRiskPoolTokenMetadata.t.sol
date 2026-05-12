// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockERC20Decimals } from "../contracts/mocks/MockERC20Decimals.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

contract SplitRiskPoolTokenMetadataTest is Test, TestTimelockHelper {
    function test_Initialize_Caches18DecimalTokenMetadata() public {
        MockERC20 shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        MockERC20 backingBaseToken = new MockERC20("Backing Base Token", "BBASE");

        MockERC4626 shieldedToken = new MockERC4626(shieldedBaseToken, "Shielded Token", "SHIELD");
        MockERC4626 backingToken = new MockERC4626(backingBaseToken, "Backing Token", "BACK");

        SplitRiskPool pool = _deployPool(address(shieldedToken), "SHIELD", address(backingToken), "BACK");

        assertEq(pool.shieldedTokenDecimals(), 18);
        assertEq(pool.backingTokenDecimals(), 18);
        assertEq(pool.shieldedTokenScale(), 1e18);
        assertEq(pool.backingTokenScale(), 1e18);
    }

    function test_Initialize_CachesMixedDecimalTokenMetadata() public {
        MockUSDC usdc = new MockUSDC();
        MockERC20 backingToken = new MockERC20("Backing Token", "BACK");
        MockERC4626 shieldedToken = new MockERC4626(IERC20(address(usdc)), "USDC Vault", "vUSDC");

        SplitRiskPool pool = _deployPool(address(shieldedToken), "vUSDC", address(backingToken), "BACK");

        assertEq(pool.shieldedTokenDecimals(), 6);
        assertEq(pool.backingTokenDecimals(), 18);
        assertEq(pool.shieldedTokenScale(), 1e6);
        assertEq(pool.backingTokenScale(), 1e18);
    }

    function test_Initialize_RevertsForUnsafeHighDecimalTokenMetadata() public {
        MockERC20Decimals highDecimalToken = new MockERC20Decimals("High Decimal Token", "HIGH", 33);
        MockERC20 backingToken = new MockERC20("Backing Token", "BACK");
        MockOracle oracle = new MockOracle();
        oracle.setPrice(address(highDecimalToken), 1e8);
        oracle.setPrice(address(backingToken), 1e8);

        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "HIGH",
            symbol: "HIGH",
            token: address(highDecimalToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });
        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "BACK",
            symbol: "BACK",
            token: address(backingToken),
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        ShieldReceiptNFT shieldNFT = new ShieldReceiptNFT("sHIGH", "sHIGH");
        ProtectorReceiptNFT protectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");
        address governanceTimelock = address(_deployTestTimelock(address(this)));
        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000,
            500,
            address(this),
            15000,
            governanceTimelock,
            address(oracle),
            address(0xdead),
            address(shieldNFT),
            address(protectorNFT),
            address(this)
        );

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidTokenDecimals.selector, address(highDecimalToken), 33));
        new ERC1967Proxy(address(implementation), initData);
    }

    function _deployPool(
        address shieldedToken,
        string memory shieldedSymbol,
        address backingToken,
        string memory backingSymbol
    ) internal returns (SplitRiskPool pool) {
        MockOracle oracle = new MockOracle();
        oracle.setPrice(shieldedToken, 1e8);
        oracle.setPrice(backingToken, 1e8);

        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: shieldedSymbol,
            symbol: shieldedSymbol,
            token: shieldedToken,
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        TokenWhitelistLib.TokenInfo memory backingTokenInfo = TokenWhitelistLib.TokenInfo({
            name: backingSymbol,
            symbol: backingSymbol,
            token: backingToken,
            primaryOracleFeed: address(oracle),
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10000
        });

        SplitRiskPool implementation = new SplitRiskPool();
        ShieldReceiptNFT shieldNFT =
            new ShieldReceiptNFT(string.concat("s", shieldedSymbol), string.concat("s", shieldedSymbol));
        ProtectorReceiptNFT protectorNFT =
            new ProtectorReceiptNFT(string.concat("p", backingSymbol), string.concat("p", backingSymbol));
        address governanceTimelock = address(_deployTestTimelock(address(this)));

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000,
            500,
            address(this),
            15000,
            governanceTimelock,
            address(oracle),
            address(0xdead),
            address(shieldNFT),
            address(protectorNFT),
            address(this)
        );

        pool = SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));

        shieldNFT.setPool(address(pool));
        protectorNFT.setPool(address(pool));
        shieldNFT.transferOwnership(address(pool));
        protectorNFT.transferOwnership(address(pool));
    }
}
