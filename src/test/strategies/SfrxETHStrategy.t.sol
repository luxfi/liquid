// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {MockLiquidStrategy} from "../mocks/MockLiquidStrategy.sol";
import {LiquidStrategyTestHelper} from "../libraries/LiquidStrategyTestHelper.sol";
import {SfrxETHStrategy} from "../../strategies/SfrxETH.sol";
import {ILiquidStrategy} from "../../interfaces/ILiquidStrategy.sol";

contract MockSfrxETHStrategy is SfrxETHStrategy {
    constructor(address _vault, StrategyParams memory _params, address _sfrxEth, address _fraxMinter, address _redemptionQueue, address _weth)
        SfrxETHStrategy(_vault, _params, _sfrxEth, _fraxMinter, _redemptionQueue, _weth)
    {}
}

contract SfrxETHStrategyTest is Test {
    MockSfrxETHStrategy public liquidStrategy;
    IVaultV2 public vault;
    address public sfrxEth = address(0xac3E018457B222d93114458476f3E3416Abbe38F);
    address public fraxMinter = address(0x7Bc6bad540453360F744666D625fec0ee1320cA3);
    address public redemptionQueue = address(0xfDC69e6BE352BD5644C438302DE4E311AAD5565b);
    address public WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public admin = address(0x1111111111111111111111111111111111111111);
    address public curator = address(0x2222222222222222222222222222222222222222);
    bool private _skipFork;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            _skipFork = true;
            return;
        }
        vm.createSelectFork(rpc);
        vm.startPrank(admin);
        vault = LiquidStrategyTestHelper._setupVault(WETH, admin, curator);
        ILiquidStrategy.StrategyParams memory params = ILiquidStrategy.StrategyParams({
            owner: address(this),
            name: "SfrxETH",
            protocol: "SfrxETH",
            riskClass: ILiquidStrategy.RiskClass.LOW,
            cap: 100 ether,
            globalCap: 100 ether,
            estimatedYield: 100 ether,
            additionalIncentives: false
        });
        liquidStrategy = new MockSfrxETHStrategy(address(vault), params, sfrxEth, fraxMinter, redemptionQueue, WETH);
        vm.stopPrank();
    }

    function test_allocate() public {
        vm.skip(_skipFork);
        vm.startPrank(address(vault));
        uint256 amount = 100 ether;
        deal(WETH, address(liquidStrategy), amount);
        bytes memory data = abi.encode(amount);
        (bytes32[] memory strategyIds, int256 change) = liquidStrategy.allocate(data, amount, "", address(vault));
        assertGt(change, int256(0), "positive change");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], liquidStrategy.adapterId(), "adapter id not in strategyIds");
        assertApproxEqAbs(liquidStrategy.realAssets(), amount, 1e18);
        vm.stopPrank();
    }

    function test_allocated_position_generated_yield() public {
        vm.skip(_skipFork);
        vm.startPrank(address(vault));
        uint256 amount = 100 ether;
        deal(WETH, address(liquidStrategy), amount);
        bytes memory data = abi.encode(amount);
        (bytes32[] memory strategyIds, int256 change) = liquidStrategy.allocate(data, amount, "", address(vault));
        assertGt(change, int256(0), "positive change");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], liquidStrategy.adapterId(), "adapter id not in strategyIds");
        uint256 initialRealAssets = liquidStrategy.realAssets();
        assertApproxEqAbs(initialRealAssets, amount, 1e18);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        uint256 realAssets = liquidStrategy.realAssets();
        assertGt(realAssets, initialRealAssets);
        vm.stopPrank();
    }

    function test_deallocate() public {
        vm.skip(_skipFork);
        vm.startPrank(address(vault));
        uint256 amount = 100 ether;
        deal(WETH, address(liquidStrategy), amount);
        bytes memory data = abi.encode(amount);
        liquidStrategy.allocate(data, amount, "", address(vault));
        uint256 initialRealAssets = liquidStrategy.realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        deal(WETH, address(liquidStrategy), amount);
        (bytes32[] memory strategyIds, int256 change) = liquidStrategy.deallocate(data, amount, "", address(vault));
        assertLt(change, int256(0), "negative change");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], liquidStrategy.adapterId(), "adapter id not in strategyIds");
        uint256 finalRealAssets = liquidStrategy.realAssets();
        require(finalRealAssets < initialRealAssets, "Final real assets is not less than initial real assets");
        vm.stopPrank();
    }
}
