// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {MockLiquidStrategy} from "../mocks/MockLiquidStrategy.sol";
import {ILiquidStrategy} from "../../interfaces/ILiquidStrategy.sol";
import {EETHLiquidStrategy} from "../../strategies/EETH.sol";

contract MockEETHLiquidStrategy is EETHLiquidStrategy {
    constructor(address _vault, ILiquidStrategy.StrategyParams memory _params, address _eeth, address _weth)
        EETHLiquidStrategy(_vault, _params, _eeth, _weth)
    {}
}

contract EETHLiquidStrategyTest is Test {
    MockEETHLiquidStrategy public liquidStrategy;
    address public weth_mannet = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {}

    function test_allocate() public {}
}
