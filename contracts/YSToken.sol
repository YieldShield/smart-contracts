// SPDX-License-Identifier: MIT

pragma solidity ^0.8.35;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { GovernanceConstantsLib } from "./libraries/GovernanceConstantsLib.sol";

/// @title YSToken
/// @author David Hawig
/// @notice YieldShield governance token with voting capabilities
contract YSToken is ERC20, ERC20Permit, ERC20Votes {
    uint256 public constant INITIAL_SUPPLY = 1_000_000 * 10 ** 18; // 1 million YS tokens
    /// @notice Irreducible supply floor matching YSGovernor's maximum proposal threshold
    /// @dev Burns must leave supply strictly above this floor so an account can still
    ///      hold enough votes to meet every proposal threshold governance may configure.
    uint256 public constant MIN_GOVERNANCE_SUPPLY = GovernanceConstantsLib.MIN_GOVERNANCE_SUPPLY;

    error InvalidInitialHolder(address holder);
    error BurnWouldReduceSupplyBelowGovernanceQuorum(uint256 supplyAfterBurn, uint256 minimumSupply);

    constructor(address initialHolder) ERC20("YieldShield", "YS") ERC20Permit("YieldShield") {
        if (initialHolder == address(0)) revert InvalidInitialHolder(initialHolder);
        _mint(initialHolder, INITIAL_SUPPLY);
        _delegate(initialHolder, initialHolder);
    }

    // The functions below are overrides required by Solidity.

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._update(from, to, amount);
    }

    function nonces(address owner) public view virtual override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }

    /**
     * @dev Override clock to use timestamps instead of block numbers (recommended for Arbitrum)
     * @return Current timestamp as uint48
     */
    function clock() public view virtual override returns (uint48) {
        return SafeCast.toUint48(block.timestamp);
    }

    /**
     * @dev Machine-readable description of the clock as specified in ERC-6372
     * @return Clock mode string indicating timestamp-based operation
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view virtual override returns (string memory) {
        return "mode=timestamp";
    }

    /**
     * @dev Burn tokens from caller's balance
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external {
        uint256 currentSupply = totalSupply();
        uint256 supplyAfterBurn = amount < currentSupply ? currentSupply - amount : 0;
        if (supplyAfterBurn <= MIN_GOVERNANCE_SUPPLY) {
            revert BurnWouldReduceSupplyBelowGovernanceQuorum(supplyAfterBurn, MIN_GOVERNANCE_SUPPLY);
        }

        _burn(msg.sender, amount);
    }
}
