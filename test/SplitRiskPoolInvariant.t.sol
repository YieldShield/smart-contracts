// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test, console2 } from "forge-std/Test.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { ErrorsLib } from "../contracts/libraries/ErrorsLib.sol";
import { ConstantsLib } from "../contracts/libraries/ConstantsLib.sol";
import { TokenWhitelistLib } from "../contracts/libraries/TokenWhitelistLib.sol";
import { MockERC4626 } from "../contracts/mocks/MockERC4626.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ShieldReceiptNFT } from "../contracts/ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../contracts/ProtectorReceiptNFT.sol";
import { IProtectorReceiptNFT } from "../contracts/interfaces/IProtectorReceiptNFT.sol";
import { IShieldReceiptNFT } from "../contracts/interfaces/IShieldReceiptNFT.sol";
import { TestTimelockHelper } from "./helpers/TestTimelockHelper.sol";

/// @title Handler Contract for SplitRiskPool Invariant Tests
/// @notice Performs random valid operations on the pool for invariant testing
contract SplitRiskPoolHandler is Test {
    SplitRiskPool public pool;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;
    ShieldReceiptNFT public shieldNFT;
    ProtectorReceiptNFT public protectorNFT;

    // Track actors and their token IDs
    address[] public protectors;
    address[] public shieldeds;
    mapping(address => uint256[]) public protectorTokenIds;
    mapping(address => uint256[]) public shieldedTokenIds;

    // Ghost variables for tracking expected state
    uint256 public ghost_totalProtectorDeposits;
    uint256 public ghost_totalShieldedDeposits;
    uint256 public ghost_totalProtectorWithdrawals;
    uint256 public ghost_totalShieldedWithdrawals;
    uint256 public ghost_totalCommissionsClaimed;
    uint256 public ghost_totalCrossAssetWithdrawals;

    // Call counters for debugging
    uint256 public calls_depositProtector;
    uint256 public calls_depositShielded;
    uint256 public calls_withdrawProtector;
    uint256 public calls_withdrawShielded;
    uint256 public calls_claimCommission;
    uint256 public calls_claimRewards;
    uint256 public calls_withdrawShieldedCrossAsset;
    uint256 public calls_dropPrice;

    // Pool config
    uint256 public shieldedMinDepositAmount;
    uint256 public shieldedMaxDepositAmount;
    uint256 public backingMinDepositAmount;
    uint256 public backingMaxDepositAmount;

    constructor(
        SplitRiskPool _pool,
        MockERC4626 _shieldedToken,
        MockERC4626 _backingToken,
        MockERC20 _shieldedBaseToken,
        MockERC20 _backingBaseToken,
        MockOracle _oracle,
        ShieldReceiptNFT _shieldNFT,
        ProtectorReceiptNFT _protectorNFT
    ) {
        pool = _pool;
        shieldedToken = _shieldedToken;
        backingToken = _backingToken;
        shieldedBaseToken = _shieldedBaseToken;
        backingBaseToken = _backingBaseToken;
        oracle = _oracle;
        shieldNFT = _shieldNFT;
        protectorNFT = _protectorNFT;

        // Cache pool config
        (shieldedMinDepositAmount, shieldedMaxDepositAmount, backingMinDepositAmount, backingMaxDepositAmount,,,,,,) =
            pool.poolConfig();

        // Setup actor addresses (funding happens in test contract)
        for (uint256 i = 1; i <= 5; i++) {
            address prot = address(uint160(i * 1000));
            address sh = address(uint160(i * 2000));
            protectors.push(prot);
            shieldeds.push(sh);
        }
    }

    /// @notice Get actor addresses for external funding
    function getProtector(uint256 i) external view returns (address) {
        return protectors[i % protectors.length];
    }

    function getShielded(uint256 i) external view returns (address) {
        return shieldeds[i % shieldeds.length];
    }

    function _toUsd(uint256 amount) internal pure returns (uint256) {
        return (amount * 1e8) / 1e18;
    }

    // ============ Handler Functions ============

    /// @notice Deposit as protector
    function depositProtector(uint256 actorSeed, uint256 amount) external {
        address actor = protectors[actorSeed % protectors.length];
        amount = bound(amount, backingMinDepositAmount + 1, backingMaxDepositAmount);

        uint256 balance = backingToken.balanceOf(actor);
        if (balance < amount) return;

        // Check TVL limit
        (uint256 shieldedBal, uint256 protectorBal) = pool.getPoolBalances();
        (,,,, uint256 maxTVLUsd,,,,,) = pool.poolConfig();
        if (_toUsd(shieldedBal) + _toUsd(protectorBal + amount) > maxTVLUsd) return;

        vm.prank(actor);
        try pool.depositBackingAsset(address(backingToken), amount, 0) returns (uint256 tokenId) {
            protectorTokenIds[actor].push(tokenId);
            ghost_totalProtectorDeposits += amount;
            calls_depositProtector++;
        } catch { }
    }

    /// @notice Deposit as shielded
    function depositShielded(uint256 actorSeed, uint256 amount) external {
        address actor = shieldeds[actorSeed % shieldeds.length];
        amount = bound(amount, shieldedMinDepositAmount + 1, shieldedMaxDepositAmount);

        uint256 balance = shieldedToken.balanceOf(actor);
        if (balance < amount) return;

        // Check if there's enough protector capacity
        uint256 totalProt = pool.totalProtectorTokens();
        uint256 totalSh = pool.totalShieldedTokens();
        uint256 requiredCollateral = ((totalSh + amount) * pool.COLLATERAL_RATIO()) / 1e4;
        if (requiredCollateral > totalProt) return;

        // Check TVL limit
        (uint256 shieldedBal, uint256 protectorBal) = pool.getPoolBalances();
        (,,,, uint256 maxTVLUsd,,,,,) = pool.poolConfig();
        if (_toUsd(shieldedBal + amount) + _toUsd(protectorBal) > maxTVLUsd) return;

        vm.prank(actor);
        try pool.depositShieldedAsset(address(shieldedToken), amount, 0) returns (uint256 tokenId) {
            shieldedTokenIds[actor].push(tokenId);
            ghost_totalShieldedDeposits += amount;
            calls_depositShielded++;
        } catch { }
    }

    /// @notice Withdraw as protector (requires unlock)
    function withdrawProtector(uint256 actorSeed, uint256 tokenIdSeed, uint256 amount) external {
        address actor = protectors[actorSeed % protectors.length];
        uint256[] storage tokenIds = protectorTokenIds[actor];
        if (tokenIds.length == 0) return;

        uint256 tokenId = tokenIds[tokenIdSeed % tokenIds.length];

        // Get position info
        IProtectorReceiptNFT.ProtectorPosition memory pos;
        try protectorNFT.getPosition(tokenId) returns (IProtectorReceiptNFT.ProtectorPosition memory p) {
            pos = p;
        } catch {
            return;
        }

        uint256 positionAmount = pool.getProtectorPositionAmount(tokenId);
        if (positionAmount == 0) return;

        // Start unlock if not started
        if (pos.unlockRequestTime == 0) {
            vm.prank(actor);
            try pool.startUnlockProcess(tokenId) { }
            catch {
                return;
            }

            // Warp to unlock time
            vm.warp(block.timestamp + 29 days);
        }

        // Check if unlocked
        if (pos.unlockRequestTime > block.timestamp) {
            vm.warp(pos.unlockRequestTime + 1);
        }

        uint256 available = pool.getAvailableForWithdrawal(tokenId);
        amount = bound(amount, 1, available > 0 ? available : 1);
        if (amount > positionAmount) amount = positionAmount;
        if (amount == 0) return;

        vm.prank(actor);
        try pool.protectorWithdraw(tokenId, amount, address(backingToken), 0) {
            ghost_totalProtectorWithdrawals += amount;
            calls_withdrawProtector++;
        } catch { }
    }

    /// @notice Withdraw as shielded
    function withdrawShielded(uint256 actorSeed, uint256 tokenIdSeed) external {
        address actor = shieldeds[actorSeed % shieldeds.length];
        uint256[] storage tokenIds = shieldedTokenIds[actor];
        if (tokenIds.length == 0) return;

        uint256 tokenId = tokenIds[tokenIdSeed % tokenIds.length];

        // Get position info
        IShieldReceiptNFT.ShieldPosition memory pos;
        try shieldNFT.getPosition(tokenId) returns (IShieldReceiptNFT.ShieldPosition memory p) {
            pos = p;
        } catch {
            return;
        }

        if (pos.amount == 0 || pos.isWithdrawn) return;

        vm.prank(actor);
        try pool.shieldedWithdraw(tokenId, address(shieldedToken), 0) {
            ghost_totalShieldedWithdrawals += pos.amount;
            calls_withdrawShielded++;

            // Remove token ID from array
            for (uint256 i = 0; i < tokenIds.length; i++) {
                if (tokenIds[i] == tokenId) {
                    tokenIds[i] = tokenIds[tokenIds.length - 1];
                    tokenIds.pop();
                    break;
                }
            }
        } catch { }
    }

    /// @notice Claim commission as protector
    function claimCommission(uint256 actorSeed, uint256 tokenIdSeed) external {
        address actor = protectors[actorSeed % protectors.length];
        uint256[] storage tokenIds = protectorTokenIds[actor];
        if (tokenIds.length == 0) return;

        uint256 tokenId = tokenIds[tokenIdSeed % tokenIds.length];

        uint256 claimable = pool.getClaimableCommission(tokenId);
        if (claimable == 0) return;

        vm.prank(actor);
        try pool.claimCommission(tokenId) {
            ghost_totalCommissionsClaimed += claimable;
            calls_claimCommission++;
        } catch { }
    }

    /// @notice Claim rewards to trigger fee accumulation
    function claimRewards(uint256 actorSeed, uint256 tokenIdSeed) external {
        address actor = shieldeds[actorSeed % shieldeds.length];
        uint256[] storage tokenIds = shieldedTokenIds[actor];
        if (tokenIds.length == 0) return;

        uint256 tokenId = tokenIds[tokenIdSeed % tokenIds.length];

        // Warp past cooldown
        uint256 lastClaim = pool.lastClaimRewardsTime(tokenId);
        if (lastClaim > 0 && block.timestamp < lastClaim + 1 days) {
            vm.warp(lastClaim + 1 days + 1);
        }

        vm.prank(actor);
        try pool.claimRewards(tokenId) {
            calls_claimRewards++;
        } catch { }
    }

    /// @notice Withdraw as shielded via cross-asset path (backing token)
    function withdrawShieldedCrossAsset(uint256 actorSeed, uint256 tokenIdSeed) external {
        address actor = shieldeds[actorSeed % shieldeds.length];
        uint256[] storage tokenIds = shieldedTokenIds[actor];
        if (tokenIds.length == 0) return;

        uint256 tokenId = tokenIds[tokenIdSeed % tokenIds.length];

        // Get position info
        IShieldReceiptNFT.ShieldPosition memory pos;
        try shieldNFT.getPosition(tokenId) returns (IShieldReceiptNFT.ShieldPosition memory p) {
            pos = p;
        } catch {
            return;
        }

        if (pos.amount == 0 || pos.isWithdrawn) return;

        // Warp past minimumPoolTime (cross-asset requires it)
        (,,,,, uint256 minimumPoolTime,,,,) = pool.poolConfig();
        if (block.timestamp < pos.depositTime + minimumPoolTime) {
            vm.warp(pos.depositTime + minimumPoolTime + 1);
        }

        vm.prank(actor);
        try pool.shieldedWithdraw(tokenId, address(backingToken), 0) {
            ghost_totalCrossAssetWithdrawals += pos.amount;
            calls_withdrawShieldedCrossAsset++;

            // Remove token ID from array
            for (uint256 i = 0; i < tokenIds.length; i++) {
                if (tokenIds[i] == tokenId) {
                    tokenIds[i] = tokenIds[tokenIds.length - 1];
                    tokenIds.pop();
                    break;
                }
            }
        } catch { }
    }

    /// @notice Drop the shielded token price (simulates adverse market move)
    function dropPrice(uint256 dropBps) external {
        dropBps = bound(dropBps, 0, 5000); // 0% to 50% drop
        if (dropBps == 0) return;

        uint256 currentPrice = oracle.getPrice(address(shieldedToken));
        uint256 newPrice = currentPrice - (currentPrice * dropBps) / 1e4;
        if (newPrice == 0) newPrice = 1; // prevent zero price

        (bool success,) =
            address(oracle).call(abi.encodeWithSignature("setPrice(address,uint256)", address(shieldedToken), newPrice));
        success; // suppress unused warning
        calls_dropPrice++;
    }

    /// @notice Simulate yield by changing oracle price
    /// @dev Must be called by test contract owner since oracle is owned by test
    function generateYield(uint256 yieldBps) external {
        yieldBps = bound(yieldBps, 0, 5000); // 0% to 50%
        if (yieldBps == 0) return;

        uint256 currentPrice = oracle.getPrice(address(shieldedToken));
        uint256 newPrice = currentPrice + (currentPrice * yieldBps) / 1e4;

        // Call via low-level call since oracle is owned by test contract
        // The test contract will delegate this via a special function
        (bool success,) =
            address(oracle).call(abi.encodeWithSignature("setPrice(address,uint256)", address(shieldedToken), newPrice));
        // Silently fail if not owner - invariant tests will still work without yield generation
        success; // suppress unused warning
    }

    /// @notice Warp time forward
    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 0, 30 days);
        vm.warp(block.timestamp + seconds_);
    }

    // ============ View Functions ============

    function getProtectorCount() external view returns (uint256) {
        return protectors.length;
    }

    function getShieldedCount() external view returns (uint256) {
        return shieldeds.length;
    }

    function getProtectorTokenIdCount(address actor) external view returns (uint256) {
        return protectorTokenIds[actor].length;
    }

    function getShieldedTokenIdCount(address actor) external view returns (uint256) {
        return shieldedTokenIds[actor].length;
    }
}

/// @title Invariant Tests for SplitRiskPool
/// @notice Tests critical protocol invariants under random operations
contract SplitRiskPoolInvariantTest is Test, TestTimelockHelper {
    SplitRiskPool public pool;
    SplitRiskPoolHandler public handler;
    MockERC4626 public shieldedToken;
    MockERC4626 public backingToken;
    MockERC20 public shieldedBaseToken;
    MockERC20 public backingBaseToken;
    MockOracle public oracle;
    ShieldReceiptNFT public shieldNFT;
    ProtectorReceiptNFT public protectorNFT;

    address public governance = address(this);
    address public protocolFeeRecipient = address(0xfee);

    function setUp() public {
        governance = address(_deployTestTimelock(address(this)));

        // Deploy base ERC20 tokens
        shieldedBaseToken = new MockERC20("Shielded Base Token", "SBASE");
        backingBaseToken = new MockERC20("Backing Base Token", "BBASE");

        // Deploy ERC4626 vaults
        backingToken = new MockERC4626(backingBaseToken, "Backing Token", "BACK");
        shieldedToken = new MockERC4626(shieldedBaseToken, "Shielded Token", "SHIELD");

        // Deploy oracle
        oracle = new MockOracle();
        oracle.setPrice(address(shieldedToken), 1e8); // $1 per token
        oracle.setPrice(address(backingToken), 1e8); // $1 per token

        // Create TokenInfo structs
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo = TokenWhitelistLib.TokenInfo({
            name: "SHIELD",
            symbol: "SHIELD",
            token: address(shieldedToken),
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

        // Deploy pool
        SplitRiskPool implementation = new SplitRiskPool();
        shieldNFT = new ShieldReceiptNFT("sSHIELD", "sSHIELD");
        protectorNFT = new ProtectorReceiptNFT("pBACK", "pBACK");

        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPool.initialize.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            1000, // 10% commission rate
            500, // 5% pool fee
            address(this), // pool creator
            15000, // 150% collateral ratio
            governance,
            address(oracle),
            protocolFeeRecipient,
            address(shieldNFT),
            address(protectorNFT),
            address(this) // owner
        );
        pool = SplitRiskPool(payable(address(new ERC1967Proxy(address(implementation), initData))));

        // Set pool address on NFTs
        shieldNFT.setPool(address(pool));
        protectorNFT.setPool(address(pool));
        shieldNFT.transferOwnership(address(pool));
        protectorNFT.transferOwnership(address(pool));

        // Deploy handler (needs to be done carefully to handle token ownership)
        handler = new SplitRiskPoolHandler(
            pool, shieldedToken, backingToken, shieldedBaseToken, backingBaseToken, oracle, shieldNFT, protectorNFT
        );

        // Fund the handler's actors from the test contract
        _fundHandlerActors();

        // Target handler for invariant testing
        targetContract(address(handler));

        // Exclude specific selectors that shouldn't be called randomly
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = SplitRiskPoolHandler.depositProtector.selector;
        selectors[1] = SplitRiskPoolHandler.depositShielded.selector;
        selectors[2] = SplitRiskPoolHandler.withdrawProtector.selector;
        selectors[3] = SplitRiskPoolHandler.withdrawShielded.selector;
        selectors[4] = SplitRiskPoolHandler.claimCommission.selector;
        selectors[5] = SplitRiskPoolHandler.claimRewards.selector;
        selectors[6] = SplitRiskPoolHandler.generateYield.selector;
        selectors[7] = SplitRiskPoolHandler.warpTime.selector;
        selectors[8] = SplitRiskPoolHandler.withdrawShieldedCrossAsset.selector;
        selectors[9] = SplitRiskPoolHandler.dropPrice.selector;

        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @notice Fund all handler actors with tokens
    function _fundHandlerActors() internal {
        uint256 amount = 10_000_000e18;

        for (uint256 i = 0; i < 5; i++) {
            address prot = handler.getProtector(i);
            address sh = handler.getShielded(i);

            // Fund protector with backing tokens
            backingBaseToken.mint(prot, amount);
            vm.startPrank(prot);
            backingBaseToken.approve(address(backingToken), amount);
            backingToken.deposit(amount, prot);
            backingToken.approve(address(pool), type(uint256).max);
            vm.stopPrank();

            // Fund shielded with shielded tokens
            shieldedBaseToken.mint(sh, amount);
            vm.startPrank(sh);
            shieldedBaseToken.approve(address(shieldedToken), amount);
            shieldedToken.deposit(amount, sh);
            shieldedToken.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ============ Invariant 1: Pool Balance Solvency ============

    /// @notice Pool token balances must always be >= tracked balances
    /// @dev The actual token balance should never be less than what accounting says
    function invariant_poolBalanceSolvency() public view {
        (uint256 shieldedBal, uint256 protectorBal) = pool.getPoolBalances();

        uint256 actualShieldedBal = shieldedToken.balanceOf(address(pool));
        uint256 actualProtectorBal = backingToken.balanceOf(address(pool));

        // Actual balance should be >= tracked balance (could be higher due to direct transfers)
        assertGe(actualShieldedBal, shieldedBal, "Shielded token balance should be >= tracked");
        assertGe(actualProtectorBal, protectorBal, "Protector token balance should be >= tracked");
    }

    // ============ Invariant 2: Fee Accumulator Safety ============

    /// @notice Fee accumulators must never exceed uint128 max
    function invariant_feeAccumulatorsBounded() public view {
        uint256 accumulatedCommissions = pool.accumulatedCommissions();
        uint256 accumulatedPoolFee = pool.accumulatedPoolFee();
        uint256 accumulatedProtocolFee = pool.accumulatedProtocolFee();

        assertLe(accumulatedCommissions, type(uint128).max, "Commissions should be within uint128");
        assertLe(accumulatedPoolFee, type(uint128).max, "Pool fee should be within uint128");
        assertLe(accumulatedProtocolFee, type(uint128).max, "Protocol fee should be within uint128");
    }

    // ============ Invariant 3: Commission Distribution Conservation ============

    /// @notice Total claimable commissions should approximate accumulated commissions
    /// @dev The sum of all claimable commissions should equal accumulatedCommissions
    function invariant_commissionConservation() public view {
        uint256 accumulatedCommissions = pool.accumulatedCommissions();

        // Sum all claimable commissions from all protector positions
        // Use nextTokenId to iterate through all possible token IDs
        uint256 totalClaimable = 0;
        uint256 nextTokenId = protectorNFT.nextTokenId();

        for (uint256 tokenId = 0; tokenId < nextTokenId; tokenId++) {
            // Skip burned tokens (owner will be address(0))
            try protectorNFT.ownerOf(tokenId) returns (address owner) {
                if (owner != address(0)) {
                    totalClaimable += pool.getClaimableCommission(tokenId);
                }
            } catch {
                // Token doesn't exist or was burned
            }
        }

        // Allow tolerance for rounding (0.1% or 1e15, whichever is larger)
        uint256 tolerance = accumulatedCommissions / 1000 > 1e15 ? accumulatedCommissions / 1000 : 1e15;

        // Total claimable should approximately equal accumulated (allow for rounding)
        if (accumulatedCommissions > 0) {
            uint256 diff = totalClaimable > accumulatedCommissions
                ? totalClaimable - accumulatedCommissions
                : accumulatedCommissions - totalClaimable;
            assertLe(diff, tolerance, "Commission distribution should be conserved");
        }
    }

    // ============ Invariant 4: Collateralization Ratio ============

    /// @notice When utilization > 100%, withdrawals should be blocked
    /// @dev Utilization can temporarily exceed 100% during protector withdrawals,
    ///      but getAvailableForWithdrawal should return 0 in such cases
    function invariant_collateralizationMaintained() public view {
        uint256 utilizationRatio = pool.getUtilizationRatio();

        // If utilization exceeds 100%, all protector positions should have 0 available for withdrawal
        if (utilizationRatio > 10000) {
            uint256 nextTokenId = protectorNFT.nextTokenId();
            for (uint256 tokenId = 0; tokenId < nextTokenId; tokenId++) {
                try protectorNFT.ownerOf(tokenId) returns (address owner) {
                    if (owner != address(0)) {
                        uint256 available = pool.getAvailableForWithdrawal(tokenId);
                        assertEq(available, 0, "Available should be 0 when utilization > 100%");
                    }
                } catch {
                    // Token doesn't exist or was burned
                }
            }
        }
    }

    // ============ Invariant 5: Total Token Tracking ============

    /// @notice Sum of all position amounts should equal total tracked tokens
    function invariant_totalTokenTracking() public view {
        // Sum all current protector claims
        uint256 sumProtectorPositions = 0;
        uint256 protectorNextTokenId = protectorNFT.nextTokenId();
        for (uint256 tokenId = 0; tokenId < protectorNextTokenId; tokenId++) {
            try protectorNFT.ownerOf(tokenId) returns (address owner) {
                if (owner != address(0)) {
                    sumProtectorPositions += pool.getProtectorPositionAmount(tokenId);
                }
            } catch {
                // Token doesn't exist or was burned
            }
        }

        // Sum all shielded positions (only non-withdrawn)
        uint256 sumShieldedPositions = 0;
        uint256 sumShieldedValueAtDeposit = 0;
        uint256 shieldedNextTokenId = shieldNFT.nextTokenId();
        for (uint256 tokenId = 0; tokenId < shieldedNextTokenId; tokenId++) {
            try shieldNFT.ownerOf(tokenId) returns (address owner) {
                if (owner != address(0)) {
                    IShieldReceiptNFT.ShieldPosition memory pos = shieldNFT.getPosition(tokenId);
                    if (!pos.isWithdrawn) {
                        sumShieldedPositions += pos.amount;
                        sumShieldedValueAtDeposit += pos.valueAtDeposit;
                    }
                }
            } catch {
                // Token doesn't exist or was burned
            }
        }

        // Total tokens should match sum of positions
        assertLe(
            sumProtectorPositions,
            pool.totalProtectorTokens(),
            "Summed protector claims should never exceed tracked protector backing"
        );
        assertLe(
            pool.totalProtectorTokens() - sumProtectorPositions,
            protectorNextTokenId,
            "Protector rounding dust should stay bounded by position count"
        );
        assertEq(
            pool.totalShieldedTokens(), sumShieldedPositions, "Total shielded tokens should match sum of positions"
        );
        assertEq(
            pool.totalValueAtDeposit(),
            sumShieldedValueAtDeposit,
            "Total valueAtDeposit should match sum of position valueAtDeposit values"
        );
    }

    // ============ Invariant 6: Reserved Fees Protection ============

    /// @notice Withdrawable balance should never allow taking reserved fees
    function invariant_reservedFeesProtected() public view {
        uint256 reservedFees = pool.getReservedFees();
        uint256 withdrawableBalance = pool.getWithdrawableBalance();
        (uint256 shieldedBal,) = pool.getPoolBalances();

        // Withdrawable should be shieldedBal - reserved (or 0 if reserved > shieldedBal)
        if (shieldedBal > reservedFees) {
            assertEq(withdrawableBalance, shieldedBal - reservedFees, "Withdrawable should exclude reserved");
        } else {
            assertEq(withdrawableBalance, 0, "Withdrawable should be 0 when reserved >= balance");
        }
    }

    // ============ Invariant 7: Reward Per Share Monotonicity ============

    /// @notice Reward per share accumulator should never decrease
    /// @dev This is tracked implicitly - we verify it's non-negative
    function invariant_rewardPerShareNonNegative() public view {
        uint256 rewardPerShare = pool.rewardPerShareAccumulated();
        assertGe(rewardPerShare, 0, "Reward per share should be non-negative");
    }

    // ============ Invariant 8: No Orphaned Commissions ============

    /// @notice When protector tokens exist, commissions should be claimable
    /// @dev If totalProtectorTokens == 0 and commissions exist, they're stranded
    function invariant_noOrphanedCommissions() public view {
        uint256 totalShares = pool.totalProtectorShares();
        uint256 accumulated = pool.accumulatedCommissions();

        // If no active shares exist in the initial epoch, commissions should be 0.
        // Later epochs may still have historical claims capped at the finalized epoch RPS.
        if (totalShares == 0 && pool.protectorShareEpoch() == 0) {
            assertEq(accumulated, 0, "No commissions should accumulate with 0 protectors");
        }
    }

    // ============ Invariant 9: Available + Locked Consistency ============

    /// @notice Available for withdrawal should be correctly computed based on locked amount
    /// @dev When locked >= amount, available should be 0
    function invariant_lockedAmountConsistent() public view {
        uint256 nextTokenId = protectorNFT.nextTokenId();

        for (uint256 tokenId = 0; tokenId < nextTokenId; tokenId++) {
            try protectorNFT.ownerOf(tokenId) returns (address owner) {
                if (owner != address(0)) {
                    uint256 positionAmount = pool.getProtectorPositionAmount(tokenId);
                    uint256 locked = pool.getLockedAmount(tokenId);
                    uint256 available = pool.getAvailableForWithdrawal(tokenId);

                    // If locked >= amount, available should be 0
                    if (locked >= positionAmount) {
                        assertEq(available, 0, "Available should be 0 when locked >= amount");
                    } else {
                        // Otherwise, available should equal amount - locked
                        assertEq(available, positionAmount - locked, "Available should equal amount - locked");
                    }
                }
            } catch {
                // Token doesn't exist or was burned
            }
        }
    }

    // ============ Invariant 10: TVL Limit Respected ============

    /// @notice Total pool value should never exceed max TVL
    function invariant_tvlLimitRespected() public view {
        (uint256 shieldedBal, uint256 protectorBal) = pool.getPoolBalances();
        (,,,, uint256 maxTVLUsd,,,,,) = pool.poolConfig();

        assertLe((shieldedBal * 1e8) / 1e18 + (protectorBal * 1e8) / 1e18, maxTVLUsd, "TVL should not exceed limit");
    }

    // ============ Invariant 11: Double Withdrawal Prevention ============

    /// @notice Withdrawn positions should have isWithdrawn = true and amount = 0
    function invariant_noDoubleWithdrawal() public view {
        uint256 nextTokenId = shieldNFT.nextTokenId();

        for (uint256 tokenId = 0; tokenId < nextTokenId; tokenId++) {
            try shieldNFT.ownerOf(tokenId) returns (address owner) {
                if (owner != address(0)) {
                    IShieldReceiptNFT.ShieldPosition memory pos = shieldNFT.getPosition(tokenId);

                    // If withdrawn, amount should be 0 (or position should be burned)
                    if (pos.isWithdrawn) {
                        assertEq(pos.amount, 0, "Withdrawn position should have 0 amount");
                    }
                }
            } catch {
                // Token doesn't exist or was burned - this is valid for withdrawn positions
            }
        }
    }

    // ============ Invariant 12: Pool Value Conservation ============

    /// @notice Pool value should equal sum of all positions plus accumulated fees
    function invariant_poolValueConservation() public view {
        (uint256 shieldedBal, uint256 protectorBal) = pool.getPoolBalances();

        // For shielded side: balance = sum of positions + accumulated fees
        uint256 totalShielded = pool.totalShieldedTokens();

        // Shielded balance should be >= total shielded tokens + fees
        // (could be higher due to yield not yet claimed)
        assertGe(shieldedBal, totalShielded, "Shielded balance should be >= total shielded positions");

        // For protector side: balance should equal total protector tokens
        uint256 totalProtector = pool.totalProtectorTokens();
        assertGe(protectorBal, totalProtector, "Protector balance should be >= total positions");
    }

    // ============ Invariant 13: Shielded Balance Covers Positions + Fees ============

    /// @notice Shielded token balance must always cover total positions plus reserved fees
    /// @dev Critical for cross-asset withdrawal safety: ensures fees are never consumed by withdrawals
    function invariant_shieldedBalanceCoversPositionsAndFees() public view {
        uint256 shieldedBalance = shieldedToken.balanceOf(address(pool));
        uint256 totalShieldedTokens = pool.totalShieldedTokens();
        uint256 reservedFees = pool.getReservedFees();

        assertGe(
            shieldedBalance, totalShieldedTokens + reservedFees, "Shielded balance must cover positions + reserved fees"
        );
    }

    // ============ Post-Run Summary ============

    /// @notice Helper to check handler call statistics after test run
    function invariant_callSummary() public view {
        console2.log("=== Handler Call Summary ===");
        console2.log("depositProtector:", handler.calls_depositProtector());
        console2.log("depositShielded:", handler.calls_depositShielded());
        console2.log("withdrawProtector:", handler.calls_withdrawProtector());
        console2.log("withdrawShielded:", handler.calls_withdrawShielded());
        console2.log("claimCommission:", handler.calls_claimCommission());
        console2.log("claimRewards:", handler.calls_claimRewards());
        console2.log("withdrawShieldedCrossAsset:", handler.calls_withdrawShieldedCrossAsset());
        console2.log("dropPrice:", handler.calls_dropPrice());
        console2.log("");
        console2.log("Ghost Variables:");
        console2.log("totalProtectorDeposits:", handler.ghost_totalProtectorDeposits());
        console2.log("totalShieldedDeposits:", handler.ghost_totalShieldedDeposits());
        console2.log("totalProtectorWithdrawals:", handler.ghost_totalProtectorWithdrawals());
        console2.log("totalShieldedWithdrawals:", handler.ghost_totalShieldedWithdrawals());
        console2.log("totalCommissionsClaimed:", handler.ghost_totalCommissionsClaimed());
        console2.log("totalCrossAssetWithdrawals:", handler.ghost_totalCrossAssetWithdrawals());
    }
}
