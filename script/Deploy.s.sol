//SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { DeployYieldShield } from "./DeployYieldShield.s.sol";

/**
 * @notice Main deployment script for all contracts
 * @dev Run this when you want to deploy multiple contracts at once
 *
 * Example: yarn deploy # runs this script(without`--file` flag)
 */
contract DeployScript is ScaffoldETHDeploy {
    error ProductionDeploymentRequiresExplicitScript(uint256 chainId);

    function run() external {
        if (_isLocalNetwork()) {
            DeployYieldShield deployYourContract = new DeployYieldShield();
            deployYourContract.run();
            return;
        }

        revert ProductionDeploymentRequiresExplicitScript(block.chainid);
    }

    function _isLocalNetwork() internal view returns (bool) {
        return block.chainid == 31337 || block.chainid == 1337;
    }
}
