// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC4626 } from "./MockERC4626.sol";

/// @title MockERC4626WithDecimalsOffset
/// @notice Test-only ERC4626 vault with a configurable share decimals offset.
contract MockERC4626WithDecimalsOffset is MockERC4626 {
    uint8 private immutable shareDecimalsOffset;

    constructor(IERC20 asset, string memory name, string memory symbol, uint8 _shareDecimalsOffset)
        MockERC4626(asset, name, symbol)
    {
        shareDecimalsOffset = _shareDecimalsOffset;
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return shareDecimalsOffset;
    }
}
