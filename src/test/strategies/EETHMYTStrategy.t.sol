// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {EETHMYTStrategy} from "../../strategies/EETH.sol";

contract MockEETHMYTStrategy is EETHMYTStrategy {
    constructor(address _myt, IMYTStrategy.StrategyParams memory _params, address _eeth, address _weth) EETHMYTStrategy(_myt, _params, _eeth, _weth) {}
}

contract EETHMYTStrategyTest is Test {
    MockEETHMYTStrategy public mytStrategy;
    address public weth_mannet = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {}

    function test_allocate() public {}
}
