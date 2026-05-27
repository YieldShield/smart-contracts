// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { console } from "forge-std/console.sol";
import { SplitRiskPoolFactory } from "../contracts/SplitRiskPoolFactory.sol";
import { SplitRiskPool } from "../contracts/SplitRiskPool.sol";
import { MockERC20 } from "../contracts/mocks/MockERC20.sol";
import { MockUSDC } from "../contracts/mocks/MockUSDC.sol";
import { MockOracle } from "../contracts/mocks/MockOracle.sol";
import { MockGauntletUSDCPrime } from "../contracts/mocks/MockGauntletUSDCPrime.sol";
import { MockUSD0 } from "../contracts/mocks/MockUSD0.sol";
import { MockMEVCapitalUSD0 } from "../contracts/mocks/MockMEVCapitalUSD0.sol";
import { MockSteakhouseUSDC } from "../contracts/mocks/MockSteakhouseUSDC.sol";
import { MockSkyUSDS } from "../contracts/mocks/MockSkyUSDS.sol";
import { PythOracle } from "../contracts/oracles/PythOracle.sol";
import { PythConfig } from "../contracts/oracles/PythConfig.sol";
import { ERC4626OracleFeed } from "../contracts/oracles/ERC4626OracleFeed.sol";
import { CompositeOracle } from "../contracts/oracles/CompositeOracle.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { YSToken } from "../contracts/YSToken.sol";
import { YSGovernor } from "../contracts/YSGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { YSTimelockController } from "../contracts/governance/YSTimelockController.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { AccessControlExample } from "../contracts/examples/AccessControlExample.sol";
import { MockTokenFaucet } from "../contracts/mocks/MockTokenFaucet.sol";

/**
 * @notice Local-only deployment script for YieldShield development environments
 * @dev Deploys:
 *      - YS Token (governance token)
 *      - Timelock Controller
 *      - YS Governor
 *      - SplitRiskPoolFactory (with governance integration)
 *      - Mock tokens for testing
 * @dev Inherits ScaffoldETHDeploy which:
 *      - Includes forge-std/Script.sol for deployment
 *      - Includes ScaffoldEthDeployerRunner modifier
 *      - Provides `deployer` variable
 * Example:
 * yarn deploy --file DeployYieldShield.s.sol  # local anvil chain
 */
contract DeployYieldShield is ScaffoldETHDeploy {
    uint256 internal constant LOCAL_TIMELOCK_DELAY = 2 minutes;
    uint256 internal constant PRODUCTION_TIMELOCK_DELAY = 2 days;
    address internal constant LOCAL_E2E_ACCOUNT = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    error ProductionDeploymentNotAllowed(uint256 chainId);

    /**
     * @dev Deployer setup based on `ETH_KEYSTORE_ACCOUNT` in `.env`:
     *      - "scaffold-eth-default": Uses Anvil's account #9 (0xa0Ee7A142d267C1f36714E4a8F75612F20a79720), no password prompt
     *      - "scaffold-eth-custom": requires password used while creating keystore
     *
     * Note: Must use ScaffoldEthDeployerRunner modifier to:
     *      - Setup correct `deployer` account and fund it
     *      - Export contract addresses & ABIs to `nextjs` packages
     */
    function run() external ScaffoldEthDeployerRunner {
        if (!_isLocalNetwork()) revert ProductionDeploymentNotAllowed(block.chainid);

        // Deploy governance infrastructure
        (address ysTokenAddr, address timelockAddr, address governorAddr) = deployGovernance();

        // Deploy core protocol contracts
        (address factoryAddr, address compositeOracleAddr, address underlyingOracleAddr) = deployProtocol(timelockAddr);

        // Deploy access control example
        deployAccessControl();

        // Deploy mock tokens
        deployMocks(factoryAddr, ysTokenAddr, compositeOracleAddr, underlyingOracleAddr);

        // Log governance summary
        logGovernanceSummary(ysTokenAddr, timelockAddr, governorAddr, factoryAddr);
    }

    function deployGovernance() internal returns (address ysTokenAddr, address timelockAddr, address governorAddr) {
        console.log("\n=== Deploying Governance Infrastructure ===");

        bool isLocalNetwork = _isLocalNetwork();

        // 1. Deploy YS Token
        YSToken ysToken = new YSToken(deployer);
        ysTokenAddr = address(ysToken);
        console.log("YS Token deployed at:", ysTokenAddr);

        // 2. Deploy Timelock Controller
        uint256 minDelay = isLocalNetwork ? LOCAL_TIMELOCK_DELAY : PRODUCTION_TIMELOCK_DELAY;
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](0);

        TimelockController timelock = TimelockController(
            payable(address(
                    new YSTimelockController(
                        minDelay,
                        proposers,
                        executors,
                        deployer // Bootstrap admin until governance roles are assigned
                    )
                ))
        );
        timelockAddr = address(timelock);
        console.log("Timelock Controller deployed at:", timelockAddr);
        console.log("Timelock delay set to:", minDelay, "seconds");

        // 3. Deploy YS Governor
        YSGovernor governor = new YSGovernor(ysToken, timelock, deployer);
        governorAddr = address(governor);
        console.log("YS Governor deployed at:", governorAddr);

        // 4. Configure Timelock Controller
        timelock.grantRole(timelock.PROPOSER_ROLE(), governorAddr);
        timelock.grantRole(timelock.EXECUTOR_ROLE(), governorAddr);
        timelock.grantRole(timelock.CANCELLER_ROLE(), governorAddr);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), deployer), "Deployer timelock admin not cleared");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), governorAddr), "Governor proposer role missing");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), governorAddr), "Governor executor role missing");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), governorAddr), "Governor canceller role missing");
        console.log("Timelock roles configured and bootstrap admin renounced");

        deployments.push(Deployment("YSToken", ysTokenAddr));
        deployments.push(Deployment("TimelockController", timelockAddr));
        deployments.push(Deployment("YSGovernor", governorAddr));
    }

    // Backup oracle address for dual-feed mode (set in deployProtocol, used in deployMocks)
    address internal backupOracleAddr;

    function deployProtocol(address timelockAddr)
        internal
        returns (address factoryAddr, address compositeOracleAddr, address underlyingOracleAddr)
    {
        console.log("\n=== Deploying Protocol Contracts ===");

        // Determine which underlying oracle to deploy based on chain ID
        uint256 chainId = block.chainid;
        bool isLocalNetwork = chainId == 31337 || chainId == 1337;

        if (isLocalNetwork) {
            // Deploy primary MockOracle for local testing (simulates Pyth/Chainlink primary)
            MockOracle primaryOracle = new MockOracle();
            underlyingOracleAddr = address(primaryOracle);
            console.log("Primary MockOracle deployed at:", underlyingOracleAddr);
            deployments.push(Deployment("MockOracle", underlyingOracleAddr));

            // Deploy backup MockOracle for dual-feed testing (simulates backup oracle)
            MockOracle backupOracle = new MockOracle();
            backupOracleAddr = address(backupOracle);
            console.log("Backup MockOracle deployed at:", backupOracleAddr);
            deployments.push(Deployment("BackupMockOracle", backupOracleAddr));
        } else {
            // Deploy PythOracle for testnet/mainnet
            address pythAddress = PythConfig.getPythAddress(chainId);
            uint256 maxPriceAge = chainId == 421614 ? 3600 : 60; // 1h for testnet, 60s for mainnet

            PythOracle oracle = new PythOracle(pythAddress, maxPriceAge);
            underlyingOracleAddr = address(oracle);
            console.log("PythOracle deployed at:", underlyingOracleAddr);
            console.log("Pyth contract address:", pythAddress);
            console.log("Max price age:", maxPriceAge, "seconds");

            deployments.push(Deployment("PythOracle", underlyingOracleAddr));
        }

        // Deploy CompositeOracle - routes pricing to per-token oracle feeds
        console.log("\n=== Deploying CompositeOracle ===");
        CompositeOracle compositeOracle = new CompositeOracle();
        compositeOracleAddr = address(compositeOracle);
        console.log("CompositeOracle deployed at:", compositeOracleAddr);
        deployments.push(Deployment("CompositeOracle", compositeOracleAddr));

        SplitRiskPoolFactory factoryImplementation = new SplitRiskPoolFactory();
        SplitRiskPool poolImplementation = new SplitRiskPool();
        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPoolFactory.initialize.selector, deployer, timelockAddr, address(poolImplementation)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImplementation), initData);
        factoryAddr = address(proxy);
        console.log("SplitRiskPoolFactory proxy deployed at:", factoryAddr);
        console.log("Factory implementation:", address(factoryImplementation));
        console.log("Pool implementation:", address(poolImplementation));

        // Verify owner is set correctly
        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(factoryAddr));
        address actualOwner = factory.owner();
        uint256 actualMinimumCreationBondUsd = factory.minimumCreationBondUsd();
        console.log("Factory owner set to:", actualOwner);
        console.log("Factory minimum creation bond USD:", actualMinimumCreationBondUsd);
        require(actualOwner == deployer, "Factory owner not set correctly!");
        require(
            actualMinimumCreationBondUsd == factory.DEFAULT_MINIMUM_CREATION_BOND_USD(),
            "Factory minimum creation bond not set correctly!"
        );

        // Transfer CompositeOracle custody before registering it with the factory.
        compositeOracle.transferOwnership(factoryAddr);
        console.log("CompositeOracle ownership transferred to factory");

        // Set composite oracle
        factory.setCompositeOracle(compositeOracleAddr);
        console.log("Composite oracle set to:", compositeOracleAddr);

        // Temporarily authorize deployer for direct launch-feed setup below.
        factory.setCompositeOracleAuthorizedCaller(deployer, true);
        console.log("Deployer temporarily authorized to configure CompositeOracle");

        // Set default protocol fee recipient (using timelock for governance control)
        factory.setDefaultProtocolFeeRecipient(timelockAddr);
        console.log("Default protocol fee recipient set to:", timelockAddr);

        // Verify all required configurations are set
        address verifiedOracle = factory.compositeOracle();
        address verifiedRecipient = factory.defaultProtocolFeeRecipient();
        address verifiedImpl = factory.splitRiskPoolImplementation();

        require(verifiedOracle != address(0), "ERROR: Composite oracle not set!");
        require(verifiedRecipient != address(0), "ERROR: Default protocol fee recipient not set!");
        require(verifiedImpl != address(0), "ERROR: Pool implementation not set!");

        console.log("\n=== Factory Configuration Verification ===");
        console.log("Composite Oracle:", verifiedOracle);
        console.log("Protocol Fee Recipient:", verifiedRecipient);
        console.log("Pool Implementation:", verifiedImpl);
        console.log("All configurations verified successfully!");

        // Add factory deployment to exports
        deployments.push(Deployment("SplitRiskPoolFactoryImplementation", address(factoryImplementation)));
        deployments.push(Deployment("SplitRiskPoolImplementation", address(poolImplementation)));
        deployments.push(Deployment("SplitRiskPoolFactory", factoryAddr));
    }

    function deployAccessControl() internal returns (address accessControlAddr) {
        console.log("\n=== Deploying Access Control Example ===");

        // Deploy access control with deployer as owner
        AccessControlExample accessControl = new AccessControlExample(deployer);
        accessControlAddr = address(accessControl);
        console.log("AccessControlExample deployed at:", accessControlAddr);
        console.log("Access control owner:", deployer);

        // Add to deployments for export
        deployments.push(Deployment("AccessControlExample", accessControlAddr));
    }

    function deployMocks(
        address factoryAddr,
        address ysTokenAddr,
        address compositeOracleAddr,
        address underlyingOracleAddr
    ) internal {
        console.log("\n=== Deploying Mock Tokens ===");

        // Get factory and composite oracle instances
        SplitRiskPoolFactory factory = SplitRiskPoolFactory(payable(factoryAddr));
        CompositeOracle compositeOracle = CompositeOracle(compositeOracleAddr);

        // Determine oracle type based on chain ID
        uint256 chainId = block.chainid;
        bool isLocalNetwork = chainId == 31337 || chainId == 1337;

        // Deploy MockERC20 tokens (prices come from oracles)
        MockERC20 susde = new MockERC20("Staked USDe", "SUSDE");
        MockERC20 sdai = new MockERC20("Savings DAI", "SDAI");
        MockERC20 usdy = new MockERC20("Ondo USD Yield", "USDY");
        MockERC20 steth = new MockERC20("Lido Staked Ether", "STETH");
        MockERC20 stone = new MockERC20("Stargate Finance", "STONE");
        MockERC20 jaaa = new MockERC20("Janus Henderson Anemoy AAA CLO Fund", "JAAA");
        MockERC20 ustb = new MockERC20("U.S. Government Securities Fund", "USTB");
        MockERC20 usyc = new MockERC20("Circle Yield Fund", "USYC");
        MockERC20 lbtc = new MockERC20("Lightning Bitcoin", "LBTC");
        MockERC20 rlp = new MockERC20("Resolv Liquidity Provider Token", "RLP");
        MockERC20 susds = new MockERC20("Staked USD Sky Protocol", "SUSDS");

        // Deploy USDC mock with 6 decimals (like real USDC)
        MockUSDC usdc = new MockUSDC();
        console.log("USDC token deployed at:", address(usdc));

        // Deploy Gauntlet USDC Prime vault (ERC4626)
        MockGauntletUSDCPrime gtusdc = new MockGauntletUSDCPrime(
            IERC20(address(usdc)),
            500 // 5% APY
        );
        console.log("Gauntlet USDC Prime vault deployed at:", address(gtusdc));

        // Deploy USD0 mock (underlying for MEV Capital vault)
        MockUSD0 usd0 = new MockUSD0();
        console.log("USD0 token deployed at:", address(usd0));

        // Deploy MEV Capital USD0 vault (ERC4626, 6% APY)
        MockMEVCapitalUSD0 mcusd0 = new MockMEVCapitalUSD0(
            IERC20(address(usd0)),
            600 // 6% APY
        );
        console.log("MEV Capital USD0 vault deployed at:", address(mcusd0));

        // Deploy Steakhouse High Yield USDC vault (ERC4626, 10% APY)
        MockSteakhouseUSDC steakusdc = new MockSteakhouseUSDC(
            IERC20(address(usdc)),
            1000 // 10% APY
        );
        console.log("Steakhouse USDC vault deployed at:", address(steakusdc));

        // Deploy Sky.money USDS Risk Capital vault (ERC4626, 12% APY)
        MockSkyUSDS skyusds = new MockSkyUSDS(
            IERC20(address(susds)),
            1200 // 12% APY
        );
        console.log("Sky.money USDS vault deployed at:", address(skyusds));

        console.log("SUSDe token deployed at:", address(susde));
        console.log("SDAI token deployed at:", address(sdai));
        console.log("USDY token deployed at:", address(usdy));
        console.log("STETH token deployed at:", address(steth));
        console.log("STONE token deployed at:", address(stone));
        console.log("JAAA token deployed at:", address(jaaa));
        console.log("USTB token deployed at:", address(ustb));
        console.log("USYC token deployed at:", address(usyc));
        console.log("LBTC token deployed at:", address(lbtc));
        console.log("RLP token deployed at:", address(rlp));
        console.log("SUSDS token deployed at:", address(susds));

        // Deploy faucet contract
        console.log("\n=== Deploying Token Faucet ===");
        MockTokenFaucet faucet = new MockTokenFaucet();
        address faucetAddr = address(faucet);
        console.log("MockTokenFaucet deployed at:", faucetAddr);

        // Set token addresses in faucet
        address[] memory tokenAddresses = new address[](17);
        tokenAddresses[0] = address(susde);
        tokenAddresses[1] = address(sdai);
        tokenAddresses[2] = address(usdy);
        tokenAddresses[3] = address(steth);
        tokenAddresses[4] = address(stone);
        tokenAddresses[5] = address(jaaa);
        tokenAddresses[6] = address(ustb);
        tokenAddresses[7] = address(usyc);
        tokenAddresses[8] = address(lbtc);
        tokenAddresses[9] = address(rlp);
        tokenAddresses[10] = address(susds);
        tokenAddresses[11] = address(usdc);
        tokenAddresses[12] = address(gtusdc);
        tokenAddresses[13] = address(usd0);
        tokenAddresses[14] = address(mcusd0);
        tokenAddresses[15] = address(steakusdc);
        tokenAddresses[16] = address(skyusds);
        faucet.setTokens(tokenAddresses);
        console.log("Faucet configured with 17 mock tokens (including 4 ERC4626 vaults)");

        // Mint tokens directly to faucet
        uint256 faucetFundAmount = 100000e18; // 100k tokens for faucet
        susde.mint(faucetAddr, faucetFundAmount);
        sdai.mint(faucetAddr, faucetFundAmount);
        usdy.mint(faucetAddr, faucetFundAmount);
        steth.mint(faucetAddr, faucetFundAmount);
        stone.mint(faucetAddr, faucetFundAmount);
        jaaa.mint(faucetAddr, faucetFundAmount);
        ustb.mint(faucetAddr, faucetFundAmount);
        usyc.mint(faucetAddr, faucetFundAmount);
        lbtc.mint(faucetAddr, faucetFundAmount);
        rlp.mint(faucetAddr, faucetFundAmount);
        susds.mint(faucetAddr, faucetFundAmount);
        uint256 usdcFaucetAmount = 100000e6; // 100k USDC
        usdc.mint(faucetAddr, usdcFaucetAmount);
        gtusdc.mintShares(faucetAddr, faucetFundAmount);
        usd0.mint(faucetAddr, faucetFundAmount);
        mcusd0.mintShares(faucetAddr, faucetFundAmount);
        steakusdc.mintShares(faucetAddr, faucetFundAmount);
        skyusds.mintShares(faucetAddr, faucetFundAmount);

        console.log("Funded faucet with tokens");
        deployments.push(Deployment("MockTokenFaucet", faucetAddr));

        // Fund test user with YS tokens
        address testUser = LOCAL_E2E_ACCOUNT;
        YSToken ysToken = YSToken(ysTokenAddr);
        uint256 minRequiredAmount = (ysToken.INITIAL_SUPPLY() * 5) / 100;
        uint256 currentBalance = ysToken.balanceOf(testUser);

        if (currentBalance < minRequiredAmount) {
            uint256 amountToTransfer = minRequiredAmount - currentBalance;
            require(ysToken.balanceOf(deployer) >= amountToTransfer, "Deployer has insufficient tokens");
            require(ysToken.transfer(testUser, amountToTransfer), "YS transfer failed");
            console.log("Transferred YS tokens to test user:", amountToTransfer / 1e18, "YS tokens");
        }

        // Fund the local E2E account with mock assets so create-pool and deposit
        // flows can satisfy the creation-bond and token-balance requirements.
        uint256 testUserFundAmount = 1000e18;
        uint256 testUserUsdcFundAmount = 1000e6;
        susde.mint(testUser, testUserFundAmount);
        sdai.mint(testUser, testUserFundAmount);
        usdy.mint(testUser, testUserFundAmount);
        steth.mint(testUser, testUserFundAmount);
        stone.mint(testUser, testUserFundAmount);
        jaaa.mint(testUser, testUserFundAmount);
        ustb.mint(testUser, testUserFundAmount);
        usyc.mint(testUser, testUserFundAmount);
        lbtc.mint(testUser, testUserFundAmount);
        rlp.mint(testUser, testUserFundAmount);
        susds.mint(testUser, testUserFundAmount);
        usdc.mint(testUser, testUserUsdcFundAmount);
        gtusdc.mintShares(testUser, testUserFundAmount);
        usd0.mint(testUser, testUserFundAmount);
        mcusd0.mintShares(testUser, testUserFundAmount);
        steakusdc.mintShares(testUser, testUserFundAmount);
        skyusds.mintShares(testUser, testUserFundAmount);
        console.log("Funded local E2E account with mock assets for pool creation and deposit flows");

        // Deploy and configure oracle feeds
        console.log("\n=== Configuring Per-Token Oracle Feeds ===");

        // Deploy ERC4626OracleFeed for vault tokens (gtUSDC)
        ERC4626OracleFeed erc4626Feed = new ERC4626OracleFeed(underlyingOracleAddr);
        console.log("ERC4626OracleFeed deployed at:", address(erc4626Feed));
        erc4626Feed.registerVault(address(gtusdc), address(usdc));
        console.log("  Registered gtUSDC vault with USDC underlying");
        erc4626Feed.registerVault(address(mcusd0), address(usd0));
        console.log("  Registered mcUSD0 vault with USD0 underlying");
        erc4626Feed.registerVault(address(steakusdc), address(usdc));
        console.log("  Registered steakUSDC vault with USDC underlying");
        erc4626Feed.registerVault(address(skyusds), address(susds));
        console.log("  Registered skyUSDS vault with SUSDS underlying");
        deployments.push(Deployment("ERC4626OracleFeed", address(erc4626Feed)));

        address backupErc4626FeedAddr = address(0);
        if (isLocalNetwork) {
            ERC4626OracleFeed backupErc4626Feed = new ERC4626OracleFeed(backupOracleAddr);
            backupErc4626Feed.registerVault(address(gtusdc), address(usdc));
            backupErc4626Feed.registerVault(address(mcusd0), address(usd0));
            backupErc4626Feed.registerVault(address(steakusdc), address(usdc));
            backupErc4626Feed.registerVault(address(skyusds), address(susds));
            backupErc4626FeedAddr = address(backupErc4626Feed);
            console.log("Backup ERC4626OracleFeed deployed at:", backupErc4626FeedAddr);
            deployments.push(Deployment("BackupERC4626OracleFeed", backupErc4626FeedAddr));
        }

        if (isLocalNetwork) {
            // For local network, set prices on BOTH primary and backup oracles
            MockOracle primaryOracle = MockOracle(underlyingOracleAddr);
            MockOracle backupOracle = MockOracle(backupOracleAddr);

            // Set realistic prices on primary oracle
            // Yield-bearing tokens are priced above $1 to reflect accrued yield
            // True stablecoins (USDC, USD0) stay at $1.00
            // All prices use 8-decimal precision (1e8 = $1.00)
            uint256 susdePrice = 122e6; // $1.22 — Ethena staked USDe (yield-bearing)
            uint256 sdaiPrice = 115e6; // $1.15 — MakerDAO Savings DAI (accrues DSR)
            uint256 usdyPrice = 108e6; // $1.08 — Ondo USD Yield (US Treasury yield)
            uint256 jaaaPrice = 105e6; // $1.05 — Janus Henderson AAA CLO
            uint256 ustbPrice = 103e6; // $1.03 — US Gov Securities Fund
            uint256 usycPrice = 106e6; // $1.06 — Circle Yield Fund (short-term treasury)
            uint256 rlpPrice = 102e6; // $1.02 — Resolv LP Token
            uint256 susdsPrice = 110e6; // $1.10 — Sky Protocol staked USDS
            uint256 stablePrice = 1e8; // $1.00 — true stablecoins (USDC, USD0)
            uint256 stethPrice = 3300e8; // $3,300 — Lido Staked Ether
            uint256 stonePrice = 3250e8; // $3,250 — StakeStone ETH
            uint256 btcPrice = 100_000e8; // $100,000 — Bitcoin

            primaryOracle.setPrice(address(susde), susdePrice);
            primaryOracle.setPrice(address(sdai), sdaiPrice);
            primaryOracle.setPrice(address(usdy), usdyPrice);
            primaryOracle.setPrice(address(jaaa), jaaaPrice);
            primaryOracle.setPrice(address(ustb), ustbPrice);
            primaryOracle.setPrice(address(usyc), usycPrice);
            primaryOracle.setPrice(address(rlp), rlpPrice);
            primaryOracle.setPrice(address(susds), susdsPrice);
            primaryOracle.setPrice(address(usdc), stablePrice);
            primaryOracle.setPrice(address(usd0), stablePrice);
            primaryOracle.setPrice(address(steth), stethPrice);
            primaryOracle.setPrice(address(stone), stonePrice);
            primaryOracle.setPrice(address(lbtc), btcPrice);
            console.log("Set realistic token prices on primary MockOracle");

            // Set same prices on backup oracle (for dual-feed testing)
            backupOracle.setPrice(address(susde), susdePrice);
            backupOracle.setPrice(address(sdai), sdaiPrice);
            backupOracle.setPrice(address(usdy), usdyPrice);
            backupOracle.setPrice(address(jaaa), jaaaPrice);
            backupOracle.setPrice(address(ustb), ustbPrice);
            backupOracle.setPrice(address(usyc), usycPrice);
            backupOracle.setPrice(address(rlp), rlpPrice);
            backupOracle.setPrice(address(susds), susdsPrice);
            backupOracle.setPrice(address(usdc), stablePrice);
            backupOracle.setPrice(address(usd0), stablePrice);
            backupOracle.setPrice(address(steth), stethPrice);
            backupOracle.setPrice(address(stone), stonePrice);
            backupOracle.setPrice(address(lbtc), btcPrice);
            console.log("Set realistic token prices on backup MockOracle");

            // Register tokens with DUAL-FEED mode in CompositeOracle
            // Based on ORACLE_RESEARCH.md recommendations:
            // - Most tokens: primary oracle (Pyth-like) + backup oracle (Chainlink-like)
            // - ERC4626 vaults: NAV pricing via ERC4626OracleFeed

            console.log("\n=== Configuring Dual-Feed Oracle Mode ===");

            // SUSDE: Pyth primary, Chainlink backup
            compositeOracle.setTokenOracleFeedDual(address(susde), underlyingOracleAddr, backupOracleAddr);
            console.log("  SUSDE: dual-feed configured");

            // SDAI: Primary oracle, backup oracle (in production: ERC4626 NAV primary)
            compositeOracle.setTokenOracleFeedDual(address(sdai), underlyingOracleAddr, backupOracleAddr);
            console.log("  SDAI: dual-feed configured");

            // USDY: Pyth primary, backup oracle
            compositeOracle.setTokenOracleFeedDual(address(usdy), underlyingOracleAddr, backupOracleAddr);
            console.log("  USDY: dual-feed configured");

            // JAAA: Pyth primary, backup oracle
            compositeOracle.setTokenOracleFeedDual(address(jaaa), underlyingOracleAddr, backupOracleAddr);
            console.log("  JAAA: dual-feed configured");

            // USTB: Pyth primary, backup oracle
            compositeOracle.setTokenOracleFeedDual(address(ustb), underlyingOracleAddr, backupOracleAddr);
            console.log("  USTB: dual-feed configured");

            // USYC: Pyth primary, backup oracle
            compositeOracle.setTokenOracleFeedDual(address(usyc), underlyingOracleAddr, backupOracleAddr);
            console.log("  USYC: dual-feed configured");

            // RLP: Pyth primary, backup oracle
            compositeOracle.setTokenOracleFeedDual(address(rlp), underlyingOracleAddr, backupOracleAddr);
            console.log("  RLP: dual-feed configured");

            // SUSDS: Primary oracle, backup oracle (in production: ERC4626 NAV primary)
            compositeOracle.setTokenOracleFeedDual(address(susds), underlyingOracleAddr, backupOracleAddr);
            console.log("  SUSDS: dual-feed configured");

            // USDC: Chainlink primary, Pyth backup
            compositeOracle.setTokenOracleFeedDual(address(usdc), underlyingOracleAddr, backupOracleAddr);
            console.log("  USDC: dual-feed configured");

            // STETH: Chainlink primary, Pyth backup
            compositeOracle.setTokenOracleFeedDual(address(steth), underlyingOracleAddr, backupOracleAddr);
            console.log("  STETH: dual-feed configured");

            // STONE: Chainlink primary, Pyth backup
            compositeOracle.setTokenOracleFeedDual(address(stone), underlyingOracleAddr, backupOracleAddr);
            console.log("  STONE: dual-feed configured");

            // LBTC: Chainlink primary, Pyth backup
            compositeOracle.setTokenOracleFeedDual(address(lbtc), underlyingOracleAddr, backupOracleAddr);
            console.log("  LBTC: dual-feed configured");

            // gtUSDC: ERC4626 NAV primary, backup NAV feed
            compositeOracle.setTokenOracleFeedDual(address(gtusdc), address(erc4626Feed), backupErc4626FeedAddr);
            console.log("  gtUSDC: ERC4626 dual-feed configured");

            // USD0: Pyth primary, backup oracle
            compositeOracle.setTokenOracleFeedDual(address(usd0), underlyingOracleAddr, backupOracleAddr);
            console.log("  USD0: dual-feed configured");

            // mcUSD0: ERC4626 NAV primary, backup NAV feed
            compositeOracle.setTokenOracleFeedDual(address(mcusd0), address(erc4626Feed), backupErc4626FeedAddr);
            console.log("  mcUSD0: ERC4626 dual-feed configured");

            // steakUSDC: ERC4626 NAV primary, backup NAV feed
            compositeOracle.setTokenOracleFeedDual(address(steakusdc), address(erc4626Feed), backupErc4626FeedAddr);
            console.log("  steakUSDC: ERC4626 dual-feed configured");

            // skyUSDS: ERC4626 NAV primary, backup NAV feed
            compositeOracle.setTokenOracleFeedDual(address(skyusds), address(erc4626Feed), backupErc4626FeedAddr);
            console.log("  skyUSDS: ERC4626 dual-feed configured");

            console.log("All 17 tokens configured with local oracle feeds");
        } else {
            // For testnet/mainnet, configure PythOracle and register feeds
            PythOracle pythOracle = PythOracle(underlyingOracleAddr);
            console.log("Configuring PythOracle price feeds");

            // Configure Pyth feed IDs for tokens
            bytes32 susdeFeedId = PythConfig.getFeedIdBySymbol("SUSDE");
            pythOracle.setTokenPriceFeed(address(susde), susdeFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(susde), underlyingOracleAddr, "pyth");

            bytes32 sdaiFeedId = PythConfig.getFeedIdBySymbol("SDAI");
            pythOracle.setTokenPriceFeed(address(sdai), sdaiFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(sdai), underlyingOracleAddr, "pyth");

            bytes32 usdyFeedId = PythConfig.getFeedIdBySymbol("USDY");
            pythOracle.setTokenPriceFeed(address(usdy), usdyFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(usdy), underlyingOracleAddr, "pyth");

            bytes32 stethFeedId = PythConfig.getFeedIdBySymbol("STETH");
            pythOracle.setTokenPriceFeed(address(steth), stethFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(steth), underlyingOracleAddr, "pyth");

            bytes32 stoneFeedId = PythConfig.getFeedIdBySymbol("STONE");
            pythOracle.setTokenPriceFeed(address(stone), stoneFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(stone), underlyingOracleAddr, "pyth");

            bytes32 jaaaFeedId = PythConfig.getFeedIdBySymbol("JAAA");
            pythOracle.setTokenPriceFeed(address(jaaa), jaaaFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(jaaa), underlyingOracleAddr, "pyth");

            bytes32 ustbFeedId = PythConfig.getFeedIdBySymbol("USTB");
            pythOracle.setTokenPriceFeed(address(ustb), ustbFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(ustb), underlyingOracleAddr, "pyth");

            bytes32 usycFeedId = PythConfig.getFeedIdBySymbol("USYC");
            pythOracle.setTokenPriceFeed(address(usyc), usycFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(usyc), underlyingOracleAddr, "pyth");

            bytes32 lbtcFeedId = PythConfig.getFeedIdBySymbol("LBTC");
            pythOracle.setTokenPriceFeed(address(lbtc), lbtcFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(lbtc), underlyingOracleAddr, "pyth");

            bytes32 rlpFeedId = PythConfig.getFeedIdBySymbol("RLP");
            pythOracle.setTokenPriceFeed(address(rlp), rlpFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(rlp), underlyingOracleAddr, "pyth");

            bytes32 susdsFeedId = PythConfig.getFeedIdBySymbol("SUSDS");
            bytes32 usdsUsdFeedId = PythConfig.getQuoteFeedIdBySymbol("SUSDS");
            pythOracle.setTokenCompositePriceFeed(address(susds), susdsFeedId, usdsUsdFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(susds), underlyingOracleAddr, "pyth");

            // USDC also uses Pyth (as underlying for gtUSDC)
            bytes32 usdcFeedId = PythConfig.getFeedIdBySymbol("USDC");
            pythOracle.setTokenPriceFeed(address(usdc), usdcFeedId);
            compositeOracle.setTokenOracleFeedWithType(address(usdc), underlyingOracleAddr, "pyth");

            console.log("Registered regular tokens with PythOracle in CompositeOracle");

            // Register gtUSDC with ERC4626OracleFeed (NAV-based pricing)
            compositeOracle.setTokenOracleFeedWithType(address(gtusdc), address(erc4626Feed), "erc4626");
            console.log("Registered gtUSDC with ERC4626OracleFeed (NAV-based) in CompositeOracle");

            // USD0 uses its direct USD0/USD Pyth feed.
            bytes32 usd0FeedId = PythConfig.getFeedIdBySymbol("USD0");
            pythOracle.setTokenPriceFeed(address(usd0), usd0FeedId);
            compositeOracle.setTokenOracleFeedWithType(address(usd0), underlyingOracleAddr, "pyth");

            // Register new vault tokens with ERC4626OracleFeed (NAV-based pricing)
            compositeOracle.setTokenOracleFeedWithType(address(mcusd0), address(erc4626Feed), "erc4626");
            compositeOracle.setTokenOracleFeedWithType(address(steakusdc), address(erc4626Feed), "erc4626");
            compositeOracle.setTokenOracleFeedWithType(address(skyusds), address(erc4626Feed), "erc4626");
            console.log("Registered new vault tokens with ERC4626OracleFeed in CompositeOracle");
        }

        // Whitelist tokens with their oracle feeds
        // minCollateralRatioBp: 10000 = 100% (global minimum), 15000 = 150% for volatile assets
        // For local networks: direct-feed assets use dual-feed mode with backup oracle.
        // For testnet/mainnet: use single-feed mode (backup = address(0)), upgrade via governance later
        console.log("\n=== Whitelisting Tokens with Oracle Feeds ===");

        // Determine backup oracle address (set for local networks, address(0) for testnet/mainnet)
        address backupAddr = backupOracleAddr; // Will be address(0) if not set (testnet/mainnet)

        // Standard stablecoins and yield tokens - 100% minimum collateral (global minimum applies)
        factory.addTokenInitial(address(susde), "Staked USDe", "SUSDE", underlyingOracleAddr, backupAddr, 10000);
        factory.addTokenInitial(address(sdai), "Savings DAI", "SDAI", underlyingOracleAddr, backupAddr, 10000);
        factory.addTokenInitial(address(usdy), "Ondo USD Yield", "USDY", underlyingOracleAddr, backupAddr, 10000);
        factory.addTokenInitial(
            address(jaaa), "Janus Henderson Anemoy AAA CLO Fund", "JAAA", underlyingOracleAddr, backupAddr, 10000
        );
        factory.addTokenInitial(
            address(ustb), "U.S. Government Securities Fund", "USTB", underlyingOracleAddr, backupAddr, 10000
        );
        factory.addTokenInitial(address(usyc), "Circle Yield Fund", "USYC", underlyingOracleAddr, backupAddr, 10000);
        factory.addTokenInitial(
            address(rlp), "Resolv Liquidity Provider Token", "RLP", underlyingOracleAddr, backupAddr, 10000
        );
        factory.addTokenInitial(
            address(susds), "Staked USD Sky Protocol", "SUSDS", underlyingOracleAddr, backupAddr, 10000
        );
        // USDC remains an oracle underlying/backup asset, but direct 6-decimal pool assets are unsupported.

        // gtUSDC uses ERC4626OracleFeed for NAV-based pricing.
        address gtUsdcBackup = backupErc4626FeedAddr;
        factory.addTokenInitial(
            address(gtusdc), "Gauntlet USDC Prime", "gtUSDC", address(erc4626Feed), gtUsdcBackup, 10000
        );

        // USD0 underlying token
        factory.addTokenInitial(address(usd0), "USD0 Stablecoin", "USD0", underlyingOracleAddr, backupAddr, 10000);

        // New Morpho vault tokens with ERC4626 NAV pricing.
        address vaultBackup = backupErc4626FeedAddr;
        factory.addTokenInitial(address(mcusd0), "MEV Capital USD0", "mcUSD0", address(erc4626Feed), vaultBackup, 10000);
        factory.addTokenInitial(
            address(steakusdc), "Steakhouse High Yield USDC", "steakUSDC", address(erc4626Feed), vaultBackup, 10000
        );
        factory.addTokenInitial(
            address(skyusds), "Sky.money USDS Risk Capital", "skyUSDS", address(erc4626Feed), vaultBackup, 10000
        );

        // Volatile assets (ETH, BTC derivatives) - 150% minimum collateral when used as backing asset
        factory.addTokenInitial(address(steth), "Lido Staked Ether", "STETH", underlyingOracleAddr, backupAddr, 15000);
        factory.addTokenInitial(address(stone), "Stargate Finance", "STONE", underlyingOracleAddr, backupAddr, 15000);
        factory.addTokenInitial(address(lbtc), "Lightning Bitcoin", "LBTC", underlyingOracleAddr, backupAddr, 15000);

        if (isLocalNetwork) {
            console.log("Whitelisted 17 tokens with local oracle feeds");
        } else {
            console.log("Whitelisted 17 tokens with single-feed oracle mode (testnet/mainnet)");
        }

        console.log("\n=== Enabling Strict Protected Pricing for Direct Launch Assets ===");
        factory.setTokenRequiresStrictProtectedPrice(address(susde), true);
        factory.setTokenRequiresStrictProtectedPrice(address(sdai), true);
        factory.setTokenRequiresStrictProtectedPrice(address(usdy), true);
        factory.setTokenRequiresStrictProtectedPrice(address(jaaa), true);
        factory.setTokenRequiresStrictProtectedPrice(address(ustb), true);
        factory.setTokenRequiresStrictProtectedPrice(address(usyc), true);
        factory.setTokenRequiresStrictProtectedPrice(address(rlp), true);
        factory.setTokenRequiresStrictProtectedPrice(address(susds), true);
        factory.setTokenRequiresStrictProtectedPrice(address(usd0), true);
        factory.setTokenRequiresStrictProtectedPrice(address(steth), true);
        factory.setTokenRequiresStrictProtectedPrice(address(stone), true);
        factory.setTokenRequiresStrictProtectedPrice(address(lbtc), true);
        console.log("Enabled strict protected pricing for 12 direct-feed launch assets");
        console.log("ERC4626 NAV-backed vault tokens remain non-strict until they have a strict circuit-breaker path");

        factory.setCompositeOracleAuthorizedCaller(deployer, false);
        console.log("Removed temporary deployer CompositeOracle authorization");

        factory.finalizeBootstrap();
        require(!factory.bootstrapModeEnabled(), "Factory bootstrap mode not finalized");
        console.log("Factory bootstrap mode finalized");

        // Transfer ownership after token whitelisting is complete
        if (isLocalNetwork) {
            address testAccount = LOCAL_E2E_ACCOUNT;
            console.log("Transferring factory ownership to test account:", testAccount);
            factory.transferOwnership(testAccount);

            require(compositeOracle.owner() == factoryAddr, "CompositeOracle owner should remain factory");

            console.log("SUCCESS: Ownership transferred!");
        } else {
            // Transfer ownership to governance timelock on testnet/mainnet
            address timelock = factory.governanceTimelock();
            console.log("Transferring factory ownership to governance timelock:", timelock);
            factory.transferOwnership(timelock);

            require(compositeOracle.owner() == factoryAddr, "CompositeOracle owner should remain factory");

            console.log("SUCCESS: Ownership transferred to governance!");
        }
    }

    function logGovernanceSummary(address ysTokenAddr, address timelockAddr, address governorAddr, address factoryAddr)
        internal
        view
    {
        console.log("\n=== Governance Deployment Summary ===");
        console.log("YS Token:", ysTokenAddr);
        console.log("Timelock Controller:", timelockAddr);
        console.log("YS Governor:", governorAddr);
        console.log("SplitRiskPoolFactory:", factoryAddr);
        console.log("\n=== IMPORTANT: Update Ponder Config ===");
        console.log("Set PONDER_FACTORY_ADDRESS environment variable to:", factoryAddr);
        console.log("Or update packages/ponder/ponder.config.ts with factory address:", factoryAddr);

        YSGovernor governor = YSGovernor(payable(governorAddr));
        TimelockController timelock = TimelockController(payable(timelockAddr));

        console.log("\n=== Governance Parameters ===");
        console.log("Voting Delay:", governor.votingDelay() / 86400, "days");
        console.log("Voting Period:", governor.votingPeriod() / 86400, "days");
        console.log("Timelock Delay:", timelock.getMinDelay() / 60, "minutes");
        console.log("Proposal Threshold:", governor.proposalThreshold() / 1e18, "YS tokens");
        console.log("Quorum:", "4%");

        console.log("\n=== Next Steps ===");
        console.log("1. Distribute YS tokens to governance participants");
        console.log("2. Delegate voting power to governance participants");
        console.log("3. Create governance proposals to configure protocol parameters");
        console.log("4. Add initial whitelisted tokens via governance");
    }

    function _isLocalNetwork() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }
}
