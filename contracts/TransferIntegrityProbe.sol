// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice One-shot helper used to verify that a token can round-trip through a third party exactly.
contract TransferIntegrityProbe {
    using SafeERC20 for IERC20;

    address public immutable pool;

    error UnauthorizedProbeCaller(address caller);

    constructor(address pool_) {
        pool = pool_;
    }

    function returnToken(address token, uint256 amount) external {
        if (msg.sender != pool) revert UnauthorizedProbeCaller(msg.sender);
        IERC20(token).safeTransfer(pool, amount);
    }
}
