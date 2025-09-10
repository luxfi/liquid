// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTCuratorProxy} from "../../myt/MYTCuratorProxy.sol";

contract MockMYTCuratorProxy is MYTCuratorProxy {
    constructor(address _admin, address _operator) MYTCuratorProxy(_admin, _operator) {}
}
