// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

import { ISplitRiskPool } from "../interfaces/ISplitRiskPool.sol";
import { TokenWhitelistLib } from "./TokenWhitelistLib.sol";
import { ISplitRiskPoolFactory } from "../interfaces/ISplitRiskPoolFactory.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ShieldReceiptNFT } from "../ShieldReceiptNFT.sol";
import { ProtectorReceiptNFT } from "../ProtectorReceiptNFT.sol";

/// @title PoolCreationLib
/// @author David Hawig
/// @notice Library for pool creation and management
library PoolCreationLib {
    /**
     * @dev Creates and stores a new pool
     * @param implementation Address of the SplitRiskPool implementation contract
     * @param shieldedTokenInfo Token info for the shielded token
     * @param backingTokenInfo Token info for the backing token
     * @param _commissionRate Commission rate for the pool
     * @param _poolFee Pool creator fee rate
     * @param _colleteralRatio Collateral ratio for the pool
     * @param _poolCreator Address of the pool creator
     * @param governanceTimelock Governance timelock address for the pool
     * @param compositeOracle Oracle address used by the pool
     * @param defaultProtocolFeeRecipient Protocol fee recipient for the pool
     * @return poolAddress Address of the created pool
     * @return info Pool info struct
     */
    function createAndStorePool(
        address implementation,
        TokenWhitelistLib.TokenInfo memory shieldedTokenInfo,
        TokenWhitelistLib.TokenInfo memory backingTokenInfo,
        uint256 _commissionRate,
        uint256 _poolFee,
        uint256 _colleteralRatio,
        address _poolCreator,
        address governanceTimelock,
        address compositeOracle,
        address defaultProtocolFeeRecipient,
        address initialAccessControl
    ) external returns (address poolAddress, ISplitRiskPoolFactory.PoolInfo memory info) {
        string memory shieldReceiptSymbol = string.concat("s", shieldedTokenInfo.symbol);
        string memory shieldReceiptName = shieldReceiptSymbol;
        string memory protectorReceiptSymbol = string.concat("p", backingTokenInfo.symbol);
        string memory protectorReceiptName = protectorReceiptSymbol;

        ShieldReceiptNFT shieldReceiptNFT = new ShieldReceiptNFT(shieldReceiptName, shieldReceiptSymbol);
        ProtectorReceiptNFT protectorReceiptNFT = new ProtectorReceiptNFT(protectorReceiptName, protectorReceiptSymbol);

        bytes memory initCalldata = abi.encodeWithSelector(
            ISplitRiskPool.initializeWithAccessControl.selector,
            shieldedTokenInfo,
            backingTokenInfo,
            _commissionRate,
            _poolFee,
            _poolCreator,
            _colleteralRatio,
            governanceTimelock,
            compositeOracle,
            defaultProtocolFeeRecipient,
            address(shieldReceiptNFT),
            address(protectorReceiptNFT),
            address(this),
            initialAccessControl
        );

        ERC1967Proxy proxy = new ERC1967Proxy(implementation, initCalldata);
        poolAddress = address(proxy);

        // L-10: the deploy → init → setPool → transferOwnership sequence is
        // not atomic in the formal sense (each is a separate state mutation
        // within the same external call), but every step is internal to this
        // delegate-called library: if any reverts, the entire library call
        // reverts and the proxy/NFTs are not persisted in factory storage.
        // The factory.createPool transaction is therefore atomic at the
        // top-level call boundary. No rescue path is needed because partial
        // state cannot survive — but document this here for any future change
        // that adds external calls between these steps.
        shieldReceiptNFT.setPool(poolAddress);
        protectorReceiptNFT.setPool(poolAddress);
        shieldReceiptNFT.transferOwnership(poolAddress);
        protectorReceiptNFT.transferOwnership(poolAddress);

        // Create pool info struct
        info = ISplitRiskPoolFactory.PoolInfo({
            shieldedToken: shieldedTokenInfo.token,
            backingToken: backingTokenInfo.token,
            shieldedTokenSymbol: shieldedTokenInfo.symbol,
            backingTokenSymbol: backingTokenInfo.symbol,
            commissionRate: _commissionRate,
            poolFee: _poolFee,
            colleteralRatio: _colleteralRatio,
            createdAt: block.timestamp,
            creator: _poolCreator
        });
    }
}
