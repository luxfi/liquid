// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {MYTAllocator} from "../../myt/MYTAllocator.sol";
import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {IMYTAdapter} from "../../myt/interfaces/IMYTAdapter.sol";
import {MockMYTVault} from "../mocks/MockMYTVault.sol";
import {SfrxETHStrategy} from "../../myt/strategies/SfrxETHStrategy.sol";

contract MockSfrxETHStrategy is SfrxETHStrategy {
    constructor(address _myt, StrategyParams memory _params, address _sfrxEth, address _fraxMinter, address _redemptionQueue)
        SfrxETHStrategy(_myt, _params, _sfrxEth, _fraxMinter, _redemptionQueue)
    {}
}

contract SfrxETHStrategyTest is Test {
    MockSfrxETHStrategy public mytStrategy;
    MockMYTVault public mytVault;
    IVaultV2 public vault;
    address public sfrxEth = address(0xac3E018457B222d93114458476f3E3416Abbe38F);
    address public fraxMinter = address(0x7Bc6bad540453360F744666D625fec0ee1320cA3);
    address public redemptionQueue = address(0xfDC69e6BE352BD5644C438302DE4E311AAD5565b);
    address public WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public admin = address(0x1111111111111111111111111111111111111111);

    function setUp() public {
        vm.startPrank(admin);
        vault = new VaultV2(admin, WETH);
        mytVault = new MockMYTVault(address(vault));
        IMYTAdapter.StrategyParams memory params = IMYTAdapter.StrategyParams({
            owner: address(this),
            name: "SfrxETH",
            protocol: "SfrxETH",
            riskClass: IMYTAdapter.RiskClass.LOW,
            cap: 100 ether,
            globalCap: 100 ether,
            estimatedYield: 100 ether,
            additionalIncentives: false
        });
        mytStrategy = new MockSfrxETHStrategy(address(mytVault), params, sfrxEth, fraxMinter, redemptionQueue);
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
}
