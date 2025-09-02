// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

// Adjust these imports to your layout  // <<<
import {PeapodsETHStrategy, WETH, IERC4626} from "src/strategies/PeapodsETH.sol";
import {MYTStrategy} from "src/MYTStrategy.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

// Harness: exposes internal _allocate/_deallocate 
contract PeapodsETHStrategyHarness is PeapodsETHStrategy {
    constructor(address myt, MYTStrategy.StrategyParams memory p, address peapodsEth_, address weth_)
        PeapodsETHStrategy(myt, p, peapodsEth_, weth_) {}

    function allocateEx(uint256 amount) external payable returns (uint256) {
        return _allocate(amount);
    }

    function deallocateEx(uint256 shares) external returns (uint256) {
        return _deallocate(shares);
    }
}

contract PeapodsETHStrategyTest is Test {
    address public constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public vaultAddr = 0x9a42e1bEA03154c758BeC4866ec5AD214D4F2191;

    WETH public weth;
    IERC4626 public vault;
    PeapodsETHStrategyHarness public strat;

    address public constant MYT = address(0xbeef);

    function setUp() public {
        weth  = WETH(WETH_ADDRESS);
        vault = IERC4626(vaultAddr);

        MYTStrategy.StrategyParams memory params;

        strat = new PeapodsETHStrategyHarness(
            MYT,
            params,
            vaultAddr,
            WETH_ADDRESS
        );

        vm.prank(address(strat));
        IERC20(WETH_ADDRESS).approve(vaultAddr, type(uint256).max);
    }

    function testAllocate() public {
        uint256 ethAmt = 0.2 ether;
        vm.deal(address(this), ethAmt);

        // call internal allocate via harness (payable)
        uint256 sharesOut = strat.allocateEx{value: ethAmt}(ethAmt);

        // vault mints shares to the external caller (receiver = msg.sender in _allocate)
        assertGt(sharesOut, 0, "no shares minted");
        assertEq(IERC20(address(vault)).balanceOf(address(this)), sharesOut, "shares not received by caller");
    }

    function testDeallocate() public {
        uint256 ethAmt = 0.15 ether;
        vm.deal(address(this), ethAmt);

        uint256 shares = strat.allocateEx{value: ethAmt}(ethAmt);
        assertGt(shares, 0, "allocate failed");

        // ERC-4626 redeem(owner) requires allowance when msg.sender != owner
        IERC20(address(vault)).approve(address(strat), shares);

        uint256 beforeBal = address(this).balance;
        uint256 assetsOut = strat.deallocateEx(shares);

        // redeem amount should be > 0 and ETH returned to caller by strategy’s unwrap
        assertGt(assetsOut, 0, "redeem returned 0");
        assertEq(address(this).balance, beforeBal + assetsOut, "ETH not returned to caller");
        assertEq(IERC20(address(vault)).balanceOf(address(this)), 0, "shares not burned");
    }

    function testSnapshotYield() public {
        // First snapshot seeds lastIndex; first return commonly 0
        uint256 first = strat.snapshotYield();
        assertEq(first, 0, "first snapshot should be 0");

        // Advance the fork to a later block where PPS realistically changed
        uint256 blockB = vm.envUint("BLOCK_B");
        vm.rollFork(blockB);

        // Second snapshot should now reflect PPS drift (usually > 0)
        uint256 second = strat.snapshotYield();
        assertGt(second, 0, "APY should be > 0 after moving to later block");
    }
}