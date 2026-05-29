// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.35;

/// @title FullMath
/// @notice Facilitates multiplication and division that can have overflow of an intermediate value without any loss of precision
/// @dev Vendored from Uniswap v3-core (GPL-2.0-or-later). Upstream:
///      https://github.com/Uniswap/v3-core/blob/v1.0.0/contracts/libraries/FullMath.sol
///      (commit d8b1c635c275d2a9450bd6a78f3fa2484fef73eb). I-4: keep this
///      pin updated when re-syncing.
library FullMath {
    /// @notice Calculates floor(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                return prod0 / denominator;
            }

            require(denominator > prod1);

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // slither-disable-next-line incorrect-exp — XOR (^) not exponentiation; Uniswap v3 Newton-Raphson inverse
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;
            inv *= 2 - denominator * inv;

            result = prod0 * inv;
            return result;
        }
    }
}
