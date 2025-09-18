// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {MYTAllocator} from "../../myt/MYTAllocator.sol";
import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {IMYTAdapter} from "../../myt/interfaces/IMYTAdapter.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";
import {MYTTestHelper} from "../libraries/MYTTestHelper.sol";
import {MorphoYearnOGWETHStrategy} from "../../myt/strategies/MorphoYearnOGWETHStrategy.sol";

contract MockMorphoYearnOGWETHStrategy is MorphoYearnOGWETHStrategy {
    constructor(address _myt, StrategyParams memory _params, address _vault, address _weth) MorphoYearnOGWETHStrategy(_myt, _params, _vault, _weth) {}
}

contract MorphoYearnOGWETHStrategyTest is Test {
    MockMorphoYearnOGWETHStrategy public mytStrategy;
    MockMYTVault public mytVault;
    IVaultV2 public vault;
    address public morphoYearnOGVault = address(0xE89371eAaAC6D46d4C3ED23453241987916224FC);
    address public WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public admin = address(0x1111111111111111111111111111111111111111);
    address public curator = address(0x2222222222222222222222222222222222222222);

    event TestLog(string message, uint256 amount);
    event TestLogAddress(string message, address value);
    event TestLogString(string message, string value);

    function setUp() public {
        vm.startPrank(admin);
        vault = MYTTestHelper._setupVault(WETH, admin, curator);
        mytVault = new MockMYTVault(address(vault));
        IMYTAdapter.StrategyParams memory params = IMYTAdapter.StrategyParams({
            owner: address(this),
            name: "MorphoYearnOGWETH",
            protocol: "MorphoYearnOGWETH",
            riskClass: IMYTAdapter.RiskClass.LOW,
            cap: 100 ether,
            globalCap: 100 ether,
            estimatedYield: 100 ether,
            additionalIncentives: false
        });
        mytStrategy = new MockMorphoYearnOGWETHStrategy(address(mytVault), params, morphoYearnOGVault, WETH);
        vm.stopPrank();
    }

    function test_allocate() public {
        vm.startPrank(address(vault));
        uint256 amount = 100 ether;
        deal(WETH, address(mytStrategy), amount);
        bytes memory data = abi.encode(amount);
        mytStrategy.allocate(data, amount, "", address(vault));
        assertApproxEqAbs(mytStrategy.realAssets(), amount, 1e18);
        vm.stopPrank();
    }

    /*     function test_allocated_position_generated_yield() public {
        vm.startPrank(address(vault));
        uint256 amount = 100 ether;
        deal(WETH, address(mytStrategy), amount);
        bytes memory data = abi.encode(amount);
        mytStrategy.allocate(data, amount, "", address(vault));
        uint256 initialRealAssets = mytStrategy.realAssets();
        emit TestSfrxETHStrategyTestDebugLog("Initial real assets", initialRealAssets);
        assertApproxEqAbs(initialRealAssets, amount, 1e18);
        vm.warp(block.timestamp + 180 days);
        uint256 realAssets = mytStrategy.realAssets();
        emit TestSfrxETHStrategyTestDebugLog("Real assets", realAssets);
        assertGt(realAssets, initialRealAssets);
        vm.stopPrank();
    }

    function test_deallocate() public {
        vm.startPrank(address(vault));
        uint256 amount = 100 ether;
        deal(WETH, address(mytStrategy), amount);
        bytes memory data = abi.encode(amount);
        mytStrategy.allocate(data, amount, "", address(vault));
        uint256 initialRealAssets = mytStrategy.realAssets();
        require(initialRealAssets > 0, "Initial real assets is 0");
        deal(WETH, address(mytStrategy), amount);
        mytStrategy.deallocate(data, amount, "", address(vault));
        uint256 finalRealAssets = mytStrategy.realAssets();
        require(finalRealAssets < initialRealAssets, "Final real assets is not less than initial real assets");
        vm.stopPrank();
    } */
}
