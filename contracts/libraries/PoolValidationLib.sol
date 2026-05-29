// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

import { ConstantsLib } from "./ConstantsLib.sol";
import { ErrorsLib } from "./ErrorsLib.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title PoolValidationLib
/// @author David Hawig
/// @notice Library for pool creation validation logic
library PoolValidationLib {
    /**
     * @dev Validates basic pool creation parameters
     * @param _shieldedToken Address of the shielded token
     * @param _backingToken Address of the backing token
     * @param _shieldedTokenSymbol Symbol for the shielded token
     * @param _backingTokenSymbol Symbol for the backing token
     */
    function validateBasicParams(
        address _shieldedToken,
        address _backingToken,
        string memory _shieldedTokenSymbol,
        string memory _backingTokenSymbol
    ) external pure {
        // Basic validation
        if (_shieldedToken == address(0) || _backingToken == address(0) || _shieldedToken == _backingToken) {
            revert ErrorsLib.InvalidTokenAddress();
        }

        // Validate string parameters
        if (bytes(_shieldedTokenSymbol).length == 0 || bytes(_backingTokenSymbol).length == 0) {
            revert ErrorsLib.InvalidShieldedTokenSymbol();
        }
        if (
            bytes(_shieldedTokenSymbol).length > ConstantsLib.MAX_TOKEN_SYMBOL_LENGTH
                || bytes(_backingTokenSymbol).length > ConstantsLib.MAX_TOKEN_SYMBOL_LENGTH
        ) {
            revert ErrorsLib.InvalidBackingTokenSymbols();
        }
    }

    /**
     * @dev Validates pool parameters
     * @param _commissionRate Commission rate for the pool
     * @param _poolFee Pool creator fee rate
     * @param _colleteralRatio Collateral ratio for the pool
     */
    function validatePoolParams(uint256 _commissionRate, uint256 _poolFee, uint256 _colleteralRatio) external pure {
        if (_commissionRate < ConstantsLib.MIN_COMMISSION_RATE || _commissionRate > ConstantsLib.MAX_COMMISSION_RATE) {
            revert ErrorsLib.InvalidCommissionRate();
        }
        if (_poolFee < ConstantsLib.MIN_POOL_FEE || _poolFee > ConstantsLib.MAX_POOL_FEE) {
            revert ErrorsLib.InvalidPoolFee();
        }
        if (
            _colleteralRatio < ConstantsLib.MIN_COLLATERAL_RATIO || _colleteralRatio > ConstantsLib.MAX_COLLATERAL_RATIO
        ) {
            revert ErrorsLib.InvalidCollateralRatio();
        }
    }

    /**
     * @dev Validates token whitelist
     * @param _shieldedToken Address of the shielded token
     * @param _backingToken Address of the backing token
     * @param isWhitelisted Mapping of whitelisted tokens
     */
    function validateWhitelist(
        address _shieldedToken,
        address _backingToken,
        address[] storage, /* whitelistedTokens */
        mapping(address => bool) storage isWhitelisted
    ) external view {
        // Always require both tokens to be whitelisted
        if (!isWhitelisted[_shieldedToken]) {
            revert ErrorsLib.TokenNotWhitelisted();
        }
        if (!isWhitelisted[_backingToken]) {
            revert ErrorsLib.TokenNotWhitelisted();
        }
        // Ensure tokens are different
        if (_shieldedToken == _backingToken) {
            revert ErrorsLib.InvalidTokenAddress();
        }
    }

    /**
     * @dev Validates that ERC4626 vaults don't share the same underlying asset
     * @param _shieldedToken Address of the shielded token
     * @param _backingToken Address of the backing token
     */
    function validateERC4626Underlying(address _shieldedToken, address _backingToken) external view {
        // Try to get underlying asset for shielded token
        address shieldedUnderlying;
        bool shieldedIsERC4626;
        try IERC4626(_shieldedToken).asset() returns (address asset) {
            shieldedUnderlying = asset;
            shieldedIsERC4626 = true;
        } catch {
            shieldedIsERC4626 = false;
        }

        // Try to get underlying asset for backing token
        address backingUnderlying;
        bool backingIsERC4626;
        try IERC4626(_backingToken).asset() returns (address asset) {
            backingUnderlying = asset;
            backingIsERC4626 = true;
        } catch {
            backingIsERC4626 = false;
        }

        // If both are ERC4626 and share same underlying, revert
        if (shieldedIsERC4626 && backingIsERC4626 && shieldedUnderlying == backingUnderlying) {
            revert ErrorsLib.SameUnderlyingAsset(_shieldedToken, _backingToken, shieldedUnderlying);
        }
    }
}
