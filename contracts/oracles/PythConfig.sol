// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title PythConfig
/// @author David Hawig
/// @notice Library for Pyth Network configuration including contract addresses and price feed IDs
/// @dev Network-specific Pyth contract addresses and price feed IDs for supported tokens
library PythConfig {
    /// @notice Chain ID for Arbitrum Sepolia testnet
    uint256 public constant ARBITRUM_SEPOLIA_CHAIN_ID = 421614;

    /// @notice Chain ID for Arbitrum mainnet
    uint256 public constant ARBITRUM_MAINNET_CHAIN_ID = 42161;

    /// @notice Pyth contract address on Arbitrum Sepolia
    /// @dev Get the latest address from: https://docs.pyth.network/price-feeds/contract-addresses/evm
    /// @dev Official Arbitrum Sepolia address: 0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF
    /// @dev This contract accepts Pyth update format (PNAU) from Hermes API
    address public constant PYTH_ARBITRUM_SEPOLIA = 0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF;

    /// @notice Pyth contract address on Arbitrum mainnet
    /// @dev Get the latest address from: https://docs.pyth.network/price-feeds/contract-addresses/evm
    address public constant PYTH_ARBITRUM_MAINNET = 0xff1A0f4744E8582DF1AE09D5615B5c36420C63ea;

    /// @notice Price feed ID for sUSDe/USD
    /// @dev Get the feed ID from: https://pyth.network/developers/price-feed-ids
    /// Search for "Crypto.SUSDE/USD" and convert the hex string to bytes32
    bytes32 public constant SUSDE_USD_FEED_ID = 0xca3ba9a619a4b3755c10ac7d5e760275aa95e9823d38a84fedd416856cdba37c;

    /// @notice Price feed ID for sDAI/USD
    /// @dev Get the feed ID from: https://pyth.network/developers/price-feed-ids
    /// Search for "Crypto.SDAI/USD" and convert the hex string to bytes32
    bytes32 public constant SDAI_USD_FEED_ID = 0x710659c5a68e2416ce4264ca8d50d34acc20041d91289110eea152c52ff3dc39;

    /// @notice Price feed ID for USDY/USD
    /// @dev Get the feed ID from: https://pyth.network/developers/price-feed-ids
    /// Search for "Crypto.USDY/USD" and convert the hex string to bytes32
    bytes32 public constant USDY_USD_FEED_ID = 0xe393449f6aff8a4b6d3e1165a7c9ebec103685f3b41e60db4277b5b6d10e7326;

    /// @notice Price feed ID for USDC/USD (used as fallback for tokens without direct feeds)
    /// @dev Get the feed ID from: https://pyth.network/developers/price-feed-ids
    bytes32 public constant USDC_USD_FEED_ID = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    /// @notice Price feed ID for USD0/USD (Usual USD)
    /// @dev Feed available at: https://hermes.pyth.network/v2/price_feeds?query=USD0
    bytes32 public constant USD0_USD_FEED_ID = 0x5e8c65917af89ed66d03d082b1ae5ac93b8ed8e32363a61842c33f7d66cb2e00;

    /// @notice Price feed ID for stETH/USD
    /// @dev Get the feed ID from: https://pyth.network/developers/price-feed-ids
    /// Search for "Crypto.STETH/USD" and convert the hex string to bytes32
    bytes32 public constant STETH_USD_FEED_ID = 0x846ae1bdb6300b817cee5fdee2a6da192775030db5615b94a465f53bd40850b5;

    /// @notice Price feed ID for LBTC/USD (Lombard Staked Bitcoin)
    /// @dev Feed available at: https://insights.pyth.network/price-feeds/Crypto.LBTC%2FUSD
    bytes32 public constant LBTC_USD_FEED_ID = 0x8f257aab6e7698bb92b15511915e593d6f8eae914452f781874754b03d0c612b;

    /// @notice Price feed ID for DEJAAA/USD (Janus Henderson Anemoy AAA CLO Fund)
    /// @dev Feed available at: https://insights.pyth.network/price-feeds/Crypto.DEJAAA%2FUSD.RR
    bytes32 public constant DEJAAA_USD_FEED_ID = 0x5ca9c34d00214bf9416439970caf29eb7f379536fcb82ee21e7d7cf69acadf2a;

    /// @notice Price feed ID for NAV.USTB/USD (Superstate Short Duration US Government Securities Fund)
    /// @dev Feed available at: https://insights.pyth.network/price-feeds/Crypto.NAV.USTB%2FUSD
    bytes32 public constant NAV_USTB_USD_FEED_ID = 0xdea78edd10cd7ae4524cc1744216788746306623bc3553014eeab6062860795d;

    /// @notice Price feed ID for USYC/USD (US Yield Coin)
    /// @dev Feed available at: https://insights.pyth.network/price-feeds/Crypto.USYC%2FUSD.RR
    bytes32 public constant USYC_USD_FEED_ID = 0x01cb900802d74a2e3d36bd9bf100523532b650c47dcac2e8202ba1e972eab305;

    /// @notice Price feed ID for STONE/USD (StakeStone ETH)
    /// @dev Feed available at: https://insights.pyth.network/price-feeds/Crypto.STONE%2FUSD
    bytes32 public constant STONE_USD_FEED_ID = 0x4dcc2fb96fb89a802ef9712f6bd2246d3607cf95ca5540cb24490d37003f8c46;

    /// @notice Price feed ID for RLP/USD (Resolv Liquidity Provider Token)
    /// @dev Feed available at: https://insights.pyth.network/price-feeds/Crypto.RLP%2FUSD.RR
    /// @dev Feed ID: 0x796bcb684fdfbba2b071c165251511ab61f08c8949afd9e05665a26f69d9a839
    bytes32 public constant RLP_USD_FEED_ID = 0x796bcb684fdfbba2b071c165251511ab61f08c8949afd9e05665a26f69d9a839;

    /// @notice Price feed ID for SUSDS/USD (Staked USD from Sky Protocol)
    /// @dev Feed available at: https://insights.pyth.network/price-feeds/Crypto.SUSDS%2FUSDS.RR
    /// @dev Feed ID: 0x6968a8641208463d17ae3b9cfa0e4841a7aa7a5d54122b9f692b84fe9ce3409f
    bytes32 public constant SUSDS_USD_FEED_ID = 0x6968a8641208463d17ae3b9cfa0e4841a7aa7a5d54122b9f692b84fe9ce3409f;

    /// @notice Get Pyth contract address for a given chain ID
    /// @param chainId The chain ID to get the Pyth contract address for
    /// @return pythAddress The Pyth contract address for the given chain ID
    /// @dev Reverts if chain ID is not supported
    function getPythAddress(uint256 chainId) internal pure returns (address pythAddress) {
        if (chainId == ARBITRUM_SEPOLIA_CHAIN_ID) {
            return PYTH_ARBITRUM_SEPOLIA;
        } else if (chainId == ARBITRUM_MAINNET_CHAIN_ID) {
            return PYTH_ARBITRUM_MAINNET;
        } else {
            revert("Unsupported chain ID");
        }
    }

    /// @notice Get price feed ID for a token symbol
    /// @param symbol The token symbol (e.g., "SUSDE", "SDAI", "USDY", "STETH", "LBTC", "JAAA", "USTB", "USYC", "STONE", "RLP", "SUSDS", "USDC", "GTUSDC", "USD0")
    /// @return feedId The price feed ID for the token
    /// @dev Reverts if symbol is not supported
    /// @dev JAAA uses DEJAAA/USD feed, USTB uses NAV.USTB/USD feed, USYC uses USYC/USD feed
    /// @dev STONE uses STONE/USD feed (direct USD price feed)
    /// @dev RLP uses RLP/USD feed (direct USD price feed)
    /// @dev SUSDS uses SUSDS/USD feed (Sky Protocol staked USD)
    /// @dev USDC uses USDC/USD feed, GTUSDC/gtUSDC uses USDC/USD feed (backed by USDC)
    /// @dev USD0 uses USD0/USD feed (Usual Protocol stablecoin)
    function getFeedIdBySymbol(string memory symbol) internal pure returns (bytes32 feedId) {
        bytes32 symbolHash = keccak256(bytes(symbol));

        if (symbolHash == keccak256(bytes("SUSDE"))) {
            return SUSDE_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("SDAI"))) {
            return SDAI_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("USDY"))) {
            return USDY_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("STETH"))) {
            return STETH_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("LBTC"))) {
            // LBTC uses LBTC/USD feed (direct USD price feed)
            return LBTC_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("JAAA"))) {
            // JAAA uses DEJAAA/USD feed
            return DEJAAA_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("USTB"))) {
            // USTB uses NAV.USTB/USD feed
            return NAV_USTB_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("USYC"))) {
            // USYC uses USYC/USD feed
            return USYC_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("STONE"))) {
            // STONE uses STONE/USD feed (direct USD price feed)
            return STONE_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("RLP"))) {
            // RLP uses RLP/USD feed (direct USD price feed)
            return RLP_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("SUSDS"))) {
            // SUSDS uses SUSDS/USD feed (Sky Protocol staked USD)
            return SUSDS_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("USDC"))) {
            // USDC uses USDC/USD feed
            return USDC_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("GTUSDC")) || symbolHash == keccak256(bytes("gtUSDC"))) {
            // gtUSDC (Gauntlet USDC Prime vault) uses USDC/USD feed since it's backed by USDC
            return USDC_USD_FEED_ID;
        } else if (symbolHash == keccak256(bytes("USD0")) || symbolHash == keccak256(bytes("usd0"))) {
            // USD0 (Usual Protocol stablecoin) uses its direct USD0/USD feed.
            return USD0_USD_FEED_ID;
        } else {
            revert("Unsupported token symbol");
        }
    }
}
