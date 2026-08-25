// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {MockLiquidStrategy} from "../mocks/MockLiquidStrategy.sol";
import {LiquidStrategyTestHelper} from "../libraries/LiquidStrategyTestHelper.sol";
import {ILiquidStrategy} from "../../interfaces/ILiquidStrategy.sol";
import {MorphoYearnOGWETHStrategy} from "../../strategies/MorphoYearnOGWETH.sol";

contract MockMorphoYearnOGWETHStrategy is MorphoYearnOGWETHStrategy {
    constructor(address _vault, StrategyParams memory _params, address _morphoVault, address _weth)
        MorphoYearnOGWETHStrategy(_vault, _params, _morphoVault, _weth)
    {}
}

contract MorphoYearnOGWETHStrategyTest is Test {
    MockMorphoYearnOGWETHStrategy public liquidStrategy;
    IVaultV2 public vault;
    address public morphoYearnOGVault = address(0xE89371eAaAC6D46d4C3ED23453241987916224FC);
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
            name: "MorphoYearnOGWETH",
            protocol: "MorphoYearnOGWETH",
            riskClass: ILiquidStrategy.RiskClass.LOW,
            cap: 100 ether,
            globalCap: 100 ether,
            estimatedYield: 100 ether,
            additionalIncentives: false
        });
        liquidStrategy = new MockMorphoYearnOGWETHStrategy(address(vault), params, morphoYearnOGVault, WETH);
        vm.stopPrank();
    }

    function test_allocate() public {
        vm.skip(_skipFork);
        vm.startPrank(address(vault));
        uint256 amount = 100 ether;
        deal(WETH, address(liquidStrategy), amount);
        bytes memory prevAllocationAmount = abi.encode(0);
        (bytes32[] memory strategyIds, int256 change) = liquidStrategy.allocate(prevAllocationAmount, amount, "", address(vault));
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
        bytes memory prevAllocationAmount = abi.encode(0);
        liquidStrategy.allocate(prevAllocationAmount, amount, "", address(vault));
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
        bytes memory prevAllocationAmount = abi.encode(0);
        liquidStrategy.allocate(prevAllocationAmount, amount, "", address(vault));
        uint256 initialRealAssets = liquidStrategy.realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        deal(WETH, address(liquidStrategy), amount);
        bytes memory prevAllocationAmount2 = abi.encode(amount);
        (bytes32[] memory strategyIds, int256 change) = liquidStrategy.deallocate(prevAllocationAmount2, amount, "", address(vault));
        assertLt(change, int256(0), "negative change");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], liquidStrategy.adapterId(), "adapter id not in strategyIds");
        uint256 finalRealAssets = liquidStrategy.realAssets();
        require(finalRealAssets < initialRealAssets, "Final real assets is not less than initial real assets");
        vm.stopPrank();
    }
}
