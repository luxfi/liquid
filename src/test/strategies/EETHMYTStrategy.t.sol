// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {MYTAllocator} from "../../myt/MYTAllocator.sol";
import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {IMYTAdapter} from "../../myt/interfaces/IMYTAdapter.sol";
import {EETHMYTStrategy} from "../../myt/strategies/EETHStrategy.sol";

contract MockEETHMYTStrategy is EETHMYTStrategy {
    constructor(address _myt, address _eeth, IMYTAdapter.StrategyParams memory _params) EETHMYTStrategy(_myt, _eeth, _params) {}
}

contract testEETHMYTStrategy is Test {
    MockEETHMYTStrategy public mytStrategy;
    address public weth_mannet = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {}
}
