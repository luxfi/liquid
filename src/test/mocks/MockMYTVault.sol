// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTVault} from "../../myt/MYTVault.sol";

contract MockMYTVault is MYTVault {
    constructor(address _vault) MYTVault(_vault) {}
}
