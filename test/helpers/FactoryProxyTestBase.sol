// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { SplitRiskPoolFactory } from "../../contracts/SplitRiskPoolFactory.sol";

abstract contract FactoryProxyTestBase {
    function _deployFactory(address initialOwner, address governanceTimelock, address poolImplementation)
        internal
        returns (SplitRiskPoolFactory deployedFactory)
    {
        SplitRiskPoolFactory implementation = new SplitRiskPoolFactory();
        bytes memory initData = abi.encodeWithSelector(
            SplitRiskPoolFactory.initialize.selector, initialOwner, governanceTimelock, poolImplementation
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        deployedFactory = SplitRiskPoolFactory(payable(address(proxy)));
    }
}
