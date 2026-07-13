// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ProtectorCommissionEscrow
/// @author David Hawig
/// @notice Holds an expired protector commission for its original NFT owner when direct payout is unavailable.
/// @dev The beneficiary is immutable and there is deliberately no governance, rescue, or recipient-redirection path.
contract ProtectorCommissionEscrow {
    using SafeERC20 for IERC20;

    error EmptyEscrow();
    error InvalidEscrowConfiguration();
    error ReentrantClaim();
    error UnauthorizedClaimant(address caller);
    error UnexpectedEscrowTokenDebit(uint256 expected, uint256 actual);
    error UnexpectedEscrowTokenReceipt(uint256 expected, uint256 actual);

    event CommissionClaimed(address indexed beneficiary, address indexed token, uint256 amount);

    IERC20 public immutable token;
    address public immutable beneficiary;

    uint256 private _claimStatus = 1;

    constructor(IERC20 token_, address beneficiary_) {
        if (address(token_) == address(0) || beneficiary_ == address(0)) {
            revert InvalidEscrowConfiguration();
        }
        token = token_;
        beneficiary = beneficiary_;
    }

    /// @notice Claims the escrow's entire token balance to the immutable beneficiary.
    /// @return received Exact amount credited to the beneficiary.
    function claim() external returns (uint256 received) {
        if (msg.sender != beneficiary) revert UnauthorizedClaimant(msg.sender);
        if (_claimStatus != 1) revert ReentrantClaim();

        _claimStatus = 2;

        uint256 escrowBalanceBefore = token.balanceOf(address(this));
        if (escrowBalanceBefore == 0) revert EmptyEscrow();
        uint256 beneficiaryBalanceBefore = token.balanceOf(beneficiary);

        token.safeTransfer(beneficiary, escrowBalanceBefore);

        uint256 escrowBalanceAfter = token.balanceOf(address(this));
        uint256 debited = escrowBalanceAfter <= escrowBalanceBefore ? escrowBalanceBefore - escrowBalanceAfter : 0;
        if (debited != escrowBalanceBefore) {
            revert UnexpectedEscrowTokenDebit(escrowBalanceBefore, debited);
        }

        uint256 beneficiaryBalanceAfter = token.balanceOf(beneficiary);
        received = beneficiaryBalanceAfter >= beneficiaryBalanceBefore
            ? beneficiaryBalanceAfter - beneficiaryBalanceBefore
            : 0;
        if (received != escrowBalanceBefore) {
            revert UnexpectedEscrowTokenReceipt(escrowBalanceBefore, received);
        }

        _claimStatus = 1;
        emit CommissionClaimed(beneficiary, address(token), received);
    }
}
