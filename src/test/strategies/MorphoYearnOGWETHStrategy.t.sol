// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {MYTTestHelper} from "../libraries/MYTTestHelper.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {MorphoYearnOGWETHStrategy} from "../../strategies/MorphoYearnOGWETH.sol";

contract MockMorphoYearnOGWETHStrategy is MorphoYearnOGWETHStrategy {
    constructor(address _myt, StrategyParams memory _params, address _vault, address _weth) MorphoYearnOGWETHStrategy(_myt, _params, _vault, _weth) {}
}

contract MorphoYearnOGWETHStrategyTest is Test {
    MockMorphoYearnOGWETHStrategy public mytStrategy;
    IVaultV2 public vault;
    address public morphoYearnOGVault = address(0xE89371eAaAC6D46d4C3ED23453241987916224FC);
    address public WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public admin = address(0x1111111111111111111111111111111111111111);
    address public curator = address(0x2222222222222222222222222222222222222222);

    function setUp() public {
        vm.startPrank(admin);
        vault = MYTTestHelper._setupVault(WETH, admin, curator);
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: address(this),
            name: "MorphoYearnOGWETH",
            protocol: "MorphoYearnOGWETH",
            riskClass: IMYTStrategy.RiskClass.LOW,
            cap: 100 ether,
            globalCap: 100 ether,
            estimatedYield: 100 ether,
            additionalIncentives: false
        });
        mytStrategy = new MockMorphoYearnOGWETHStrategy(address(vault), params, morphoYearnOGVault, WETH);
        vm.stopPrank();
    }

    function test_allocate() public {
        vm.startPrank(address(vault));
        uint256 amount = 100 ether;
        deal(WETH, address(mytStrategy), amount);
        bytes memory prevAllocationAmount = abi.encode(0);
        (bytes32[] memory strategyIds, int256 change) = mytStrategy.allocate(prevAllocationAmount, amount, "", address(vault));
        assertGt(change, int256(0), "positive change");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], mytStrategy.adapterId(), "adapter id not in strategyIds");
        assertApproxEqAbs(mytStrategy.realAssets(), amount, 1e18);
        vm.stopPrank();
    }

    function test_allocated_position_generated_yield() public {
        vm.startPrank(address(vault));
        uint256 amount = 100 ether;
        deal(WETH, address(mytStrategy), amount);
        bytes memory prevAllocationAmount = abi.encode(0);
        mytStrategy.allocate(prevAllocationAmount, amount, "", address(vault));
        uint256 initialRealAssets = mytStrategy.realAssets();
        assertApproxEqAbs(initialRealAssets, amount, 1e18);
        vm.warp(block.timestamp + 180 days);
        uint256 realAssets = mytStrategy.realAssets();
        assertGt(realAssets, initialRealAssets);
        vm.stopPrank();
    }

    function test_deallocate() public {
        vm.startPrank(address(vault));
        uint256 amount = 100 ether;
        deal(WETH, address(mytStrategy), amount);
        bytes memory prevAllocationAmount = abi.encode(0);
        mytStrategy.allocate(prevAllocationAmount, amount, "", address(vault));
        uint256 initialRealAssets = mytStrategy.realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        deal(WETH, address(mytStrategy), amount);
        bytes memory prevAllocationAmount2 = abi.encode(amount);
        (bytes32[] memory strategyIds, int256 change) = mytStrategy.deallocate(prevAllocationAmount2, amount, "", address(vault));
        assertLt(change, int256(0), "negative change");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], mytStrategy.adapterId(), "adapter id not in strategyIds");
        uint256 finalRealAssets = mytStrategy.realAssets();
        require(finalRealAssets < initialRealAssets, "Final real assets is not less than initial real assets");
        vm.stopPrank();
    }
}
