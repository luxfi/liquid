// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidCurator} from "../../LiquidCurator.sol";

contract MockLiquidCurator is LiquidCurator {
    constructor(address _admin, address _operator) LiquidCurator(_admin, _operator) {}
}
