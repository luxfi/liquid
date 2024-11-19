// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "../../../lib/forge-std/src/Test.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

import {StakingPools} from "../mocks/StakingPoolMock.sol";

import {IERC20Mintable} from "../interfaces/IERC20Mintable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StakingPoolTest is Test {
    ERC20Mock rewardToken;
    ERC20Mock stakingToken;
    StakingPools pool;

	function setUp() public {
        rewardToken = new ERC20Mock("Reward Token", "RWRD");
        stakingToken = new ERC20Mock("Staking Token", "STK");

        pool = new StakingPools(IERC20Mintable(address(rewardToken)), address(this));

        deal(address(stakingToken), address(0xbeef), 100e18);
        deal(address(stakingToken), address(0xdead), 50e18);
        deal(address(stakingToken), address(0xb00ba), 200e18);

        vm.prank(address(0xbeef));
        stakingToken.approve(address(pool), 100e18);

        vm.prank(address(0xdead));
        stakingToken.approve(address(pool), 50e18);

        vm.prank(address(0xb00ba));
        stakingToken.approve(address(pool), 200e18);

        // Example
        // User 1: alchemist debt = 100
        // User 2: alchemist debt = 50
        // User 3: alchemist debt = 200
        // Total debt = 350
        //
        // Transmuter has 75 tokens staked
        // Transmutation time is 1 month 
        // 75/350 = 21.428571428% of debt redeemed in 1 month
        // 216000 blocks in one month on mainnet 
        // 75/216000 = 347222222222222 tokens per block
        // you will always lose precision so what is actually rewarded is slightly less than we want
        // Perhaps round up here in production to avoid under redeeming

        pool.setRewardRate(347222222222222);
        pool.createPool(IERC20(address(stakingToken)));
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;
        pool.setRewardWeights(weights);
    }

    function testOneMonthIntervals() public {
        vm.prank(address(0xbeef));
        pool.deposit(0, 100e18);

        vm.prank(address(0xdead));
        pool.deposit(0, 50e18);

        vm.prank(address(0xb00ba));
        pool.deposit(0, 200e18);
        vm.roll(block.number + 216000);

        pool.setRewardRate(462962962962962);

        // Check that each position has 21.428571428% of their deposit claimable

        uint256 beefAmount = pool.getStakeTotalUnclaimed(address(0xbeef), 0);
        uint256 deadAmount = pool.getStakeTotalUnclaimed(address(0xdead), 0);
        uint256 boobAmount = pool.getStakeTotalUnclaimed(address(0xb00ba), 0);

        assertApproxEqRel( 
            21428571428571428571, 
            beefAmount, 
            500000000000000000
        );

        assertApproxEqRel(
            10714285714285714285, 
            deadAmount, 
            500000000000000000
        );

        assertApproxEqRel(
            42857142857142857142, 
            boobAmount, 
            500000000000000000
        );

        // // Withdraw these amounts to simulate debt being redeemed
        // vm.startPrank(address(0xbeef));
        // pool.claim(0);
        // pool.withdraw(0, beefAmount);
        // vm.stopPrank();

        // vm.startPrank(address(0xdead));
        // pool.claim(0);
        // // pool.withdraw(0, deadAmount);
        // vm.stopPrank();

        // vm.startPrank(address(0xb00ba));
        // pool.claim(0);
        // // pool.withdraw(0, boobAmount);
        // vm.stopPrank();

        // The following month the total debt is 350 -75 = 275
        // Now let's say we need to redeem 100 tokens in the next two month
        // 100/275 = 36.363636363636...%
        // 100/216000 = 462962962962962 tokens per block

        vm.roll(block.number + 4132000);

        // Check that each position has 36.363636363636...% of their remaining deposit claimable

        vm.prank(address(0xbeef));
        pool.claim(0);

        assertApproxEqRel( 
            21428571428571428571, 
            IERC20(rewardToken).balanceOf(address(this)), 
            500000000000000000
        );

        // assertApproxEqRel(
        //     10714285714285714285, 
        //     pool.getStakeTotalUnclaimed(address(0xdead), 0), 
        //     500000000000000000
        // );

        // assertApproxEqRel(
        //     42857142857142857142, 
        //     pool.getStakeTotalUnclaimed(address(0xb00ba), 0), 
        //     500000000000000000
        // );

    }

    function testOneMonthWithRateChange() public {
        
    }
}