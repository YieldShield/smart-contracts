// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { ISplitRiskPoolFactory } from "../contracts/interfaces/ISplitRiskPoolFactory.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

contract FactoryLinearScanHarness is SplitRiskPoolFactory {
    function seedCompositeOracle(address oracle) external {
        compositeOracle = oracle;
    }

    function seedERC4626OracleFeed(address oracle) external {
        erc4626OracleFeed = oracle;
    }

    function seedWhitelistedToken(address token, address primaryFeed) external {
        whitelistedTokens.push(token);
        isWhitelisted[token] = true;
        _seedTokenInfo(token, primaryFeed);
    }

    function seedTokenInfo(address token, address primaryFeed) external {
        _seedTokenInfo(token, primaryFeed);
    }

    function seedActivePool(address pool, address shieldedToken, address backingToken) external {
        activePools.push(pool);
        isPoolActive[pool] = true;
        _poolInfo[pool] = ISplitRiskPoolFactory.PoolInfo({
            shieldedToken: shieldedToken,
            backingToken: backingToken,
            shieldedTokenSymbol: "SHIELD",
            backingTokenSymbol: "BACK",
            commissionRate: 0,
            poolFee: 0,
            colleteralRatio: 10_000,
            createdAt: block.timestamp,
            creator: address(this)
        });
    }

    function benchmarkValidateCompositeOracleFeedsUsing(address oracleFeed) external view {
        _validateCompositeOracleFeedsUsing(oracleFeed);
    }

    function benchmarkRequireTokenUnusedByActivePools(address token) external view {
        _requireTokenUnusedByActivePools(token);
    }

    function benchmarkTokenUsedAsActiveBackingToken(address token) external view returns (bool) {
        return _tokenUsedAsActiveBackingToken(token);
    }

    function benchmarkRequireNoActivePoolUsesCompositeOracle(address oracle) external view {
        _requireNoActivePoolUsesCompositeOracle(oracle);
    }

    function benchmarkValidateActiveERC4626VaultFeedsUsing(address oracleFeed) external view {
        _validateActiveERC4626VaultFeedsUsing(oracleFeed);
    }

    function benchmarkValidateActiveERC4626VaultsDependingOnUnderlying(address underlying, address oracleFeed)
        external
        view
    {
        _validateActiveERC4626VaultsDependingOnUnderlying(underlying, oracleFeed);
    }

    function benchmarkActivePoolUsesPriceOracle(address oracle) external view returns (bool) {
        return _activePoolUsesPriceOracle(oracle);
    }

    function benchmarkWhitelistedRouteReferencesOracle(address oracle) external view returns (bool) {
        return _whitelistedRouteReferencesOracle(oracle);
    }

    function benchmarkRemoveLastWhitelistedToken(address token) external {
        TokenWhitelistLib.removeToken(whitelistedTokens, isWhitelisted, token);
    }

    function _seedTokenInfo(address token, address primaryFeed) private {
        tokenInfo[token] = TokenWhitelistLib.TokenInfo({
            name: "Benchmark Token",
            symbol: "BENCH",
            token: token,
            primaryOracleFeed: primaryFeed,
            backupOracleFeed: address(0),
            minCollateralRatioBp: 10_000
        });
    }
}

contract FactoryLinearScanOracle is Ownable {
    address private immutable _underlyingPriceOracle;
    address private immutable _vaultUnderlying;

    constructor(address underlyingPriceOracle_, address vaultUnderlying_) Ownable(msg.sender) {
        _underlyingPriceOracle = underlyingPriceOracle_;
        _vaultUnderlying = vaultUnderlying_;
    }

    function setTokenOracleFeed(address, address) external view onlyOwner { }

    function setTokenOracleFeedDual(address, address, address) external view onlyOwner { }

    function setStrictCircuitBreakerRequired(address, bool) external view onlyOwner { }

    function setAuthorizedCaller(address, bool) external view onlyOwner { }

    function clearAuthorizedCallers() external view onlyOwner { }

    function authorizedCallerCount() external pure returns (uint256) {
        return 0;
    }

    function getPrice(address) external pure returns (uint256) {
        return 1e8;
    }

    function getPriceUnsafe(address) external pure returns (uint256) {
        return 1e8;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function getTokenDualFeedStatus(address) external pure returns (bool, address, address, bool, bool, uint256) {
        return (false, address(0), address(0), false, false, 0);
    }

    function underlyingPriceOracle() external view returns (address) {
        return _underlyingPriceOracle;
    }

    function vaultToUnderlying(address) external view returns (address) {
        return _vaultUnderlying;
    }
}

contract FactoryLinearScanPool {
    function poolConfig()
        external
        pure
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, address, uint96, address)
    {
        return (0, 0, 0, 0, 0, 0, 0, address(0), 0, address(0xFACADE));
    }
}

/// @dev Executable gas guard for every non-paginated governance scan bounded by
///      MAX_POOLS or TokenWhitelistLib.MAX_WHITELISTED_TOKENS. Each test gets a
///      fresh setup so storage/account warming from another scan cannot understate gas.
contract FactoryLinearScanGasTest is Test, TestTimelockHelper {
    uint256 private constant HARD_CAP = 100;
    uint256 private constant GOVERNANCE_GAS_CEILING = 15_000_000;
    address private constant SEARCH_MISS = address(0xDEAD);
    address private constant SCAN_FEED = address(0xFEED);
    address private constant VAULT_UNDERLYING = address(0xA11CE);

    FactoryLinearScanHarness private factory;
    FactoryLinearScanOracle private currentCompositeOracle;
    FactoryLinearScanOracle private replacementCompositeOracle;
    FactoryLinearScanOracle private erc4626OracleFeed;
    address private lastWhitelistedToken;
    address private governanceTimelock;

    function setUp() public {
        SplitRiskPool poolImplementation = new SplitRiskPool();
        FactoryLinearScanHarness factoryImplementation = new FactoryLinearScanHarness();
        governanceTimelock = address(_deployTestTimelock(address(this)));
        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPoolFactory.initialize.selector, address(this), governanceTimelock, address(poolImplementation)
        );
        factory = FactoryLinearScanHarness(payable(address(new ERC1967Proxy(address(factoryImplementation), initData))));

        currentCompositeOracle = new FactoryLinearScanOracle(SCAN_FEED, address(0));
        replacementCompositeOracle = new FactoryLinearScanOracle(SCAN_FEED, address(0));
        erc4626OracleFeed = new FactoryLinearScanOracle(SCAN_FEED, VAULT_UNDERLYING);
        factory.seedCompositeOracle(address(currentCompositeOracle));
        factory.seedERC4626OracleFeed(address(erc4626OracleFeed));

        FactoryLinearScanPool poolTemplate = new FactoryLinearScanPool();
        bytes memory poolRuntime = address(poolTemplate).code;
        for (uint256 i = 0; i < HARD_CAP;) {
            address shieldedToken = address(uint160(0x1000 + i));
            address backingToken = address(uint160(0x2000 + i));
            address pool = address(uint160(0x3000 + i));

            factory.seedWhitelistedToken(shieldedToken, address(erc4626OracleFeed));
            factory.seedTokenInfo(backingToken, address(erc4626OracleFeed));
            vm.etch(pool, poolRuntime);
            factory.seedActivePool(pool, shieldedToken, backingToken);
            lastWhitelistedToken = shieldedToken;

            unchecked {
                ++i;
            }
        }

        currentCompositeOracle.transferOwnership(address(factory));
        replacementCompositeOracle.transferOwnership(address(factory));
    }

    function testGas_setCompositeOracleMigrationAtHardCap() public {
        vm.prank(governanceTimelock);
        _measureAndAssert(
            "setCompositeOracle migration",
            abi.encodeCall(SplitRiskPoolFactory.setCompositeOracle, (address(replacementCompositeOracle)))
        );
    }

    function testGas_validateCompositeOracleFeedsUsingAtHardCap() public {
        _measureAndAssert(
            "validate composite feeds",
            abi.encodeCall(
                FactoryLinearScanHarness.benchmarkValidateCompositeOracleFeedsUsing, (address(erc4626OracleFeed))
            )
        );
    }

    function testGas_requireTokenUnusedByActivePoolsAtHardCap() public {
        _measureAndAssert(
            "require token unused",
            abi.encodeCall(FactoryLinearScanHarness.benchmarkRequireTokenUnusedByActivePools, (SEARCH_MISS))
        );
    }

    function testGas_tokenUsedAsActiveBackingTokenAtHardCap() public {
        _measureAndAssert(
            "active backing lookup",
            abi.encodeCall(FactoryLinearScanHarness.benchmarkTokenUsedAsActiveBackingToken, (SEARCH_MISS))
        );
    }

    function testGas_requireNoActivePoolUsesCompositeOracleAtHardCap() public {
        _measureAndAssert(
            "require oracle unused",
            abi.encodeCall(FactoryLinearScanHarness.benchmarkRequireNoActivePoolUsesCompositeOracle, (SEARCH_MISS))
        );
    }

    function testGas_validateActiveERC4626VaultFeedsUsingAtHardCap() public {
        _measureAndAssert(
            "validate active ERC4626 feeds",
            abi.encodeCall(FactoryLinearScanHarness.benchmarkValidateActiveERC4626VaultFeedsUsing, (SCAN_FEED))
        );
    }

    function testGas_validateActiveERC4626VaultsDependingOnUnderlyingAtHardCap() public {
        _measureAndAssert(
            "validate active ERC4626 dependencies",
            abi.encodeCall(
                FactoryLinearScanHarness.benchmarkValidateActiveERC4626VaultsDependingOnUnderlying,
                (VAULT_UNDERLYING, SCAN_FEED)
            )
        );
    }

    function testGas_activePoolUsesPriceOracleAtHardCap() public {
        _measureAndAssert(
            "active pool oracle lookup",
            abi.encodeCall(FactoryLinearScanHarness.benchmarkActivePoolUsesPriceOracle, (SEARCH_MISS))
        );
    }

    function testGas_whitelistedRouteReferencesOracleAtHardCap() public {
        _measureAndAssert(
            "whitelist oracle lookup",
            abi.encodeCall(FactoryLinearScanHarness.benchmarkWhitelistedRouteReferencesOracle, (SEARCH_MISS))
        );
    }

    function testGas_removeLastWhitelistedTokenAtHardCap() public {
        _measureAndAssert(
            "remove last whitelist token",
            abi.encodeCall(FactoryLinearScanHarness.benchmarkRemoveLastWhitelistedToken, (lastWhitelistedToken))
        );
    }

    function _measureAndAssert(string memory label, bytes memory callData) private {
        uint256 gasBefore = gasleft();
        (bool success, bytes memory revertData) = address(factory).call(callData);
        uint256 gasUsed = gasBefore - gasleft();
        if (!success) {
            assembly ("memory-safe") {
                revert(add(revertData, 0x20), mload(revertData))
            }
        }

        emit log_named_uint(label, gasUsed);
        assertLt(gasUsed, GOVERNANCE_GAS_CEILING, "hard-cap governance scan exceeds gas ceiling");
    }
}
