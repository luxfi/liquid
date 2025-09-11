// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

// Adjust these imports to your layout  // <<<
import {PeapodsETHStrategy, WETH, IERC4626} from "src/strategies/PeapodsETH.sol";
import {MYTStrategy} from "src/MYTStrategy.sol";
import {IMYTStrategy} from "src/interfaces/IMYTStrategy.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

contract PeapodsETHStrategyTest is Test {
    address public constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public vaultAddr = 0x9a42e1bEA03154c758BeC4866ec5AD214D4F2191;

    WETH public weth;
    IERC4626 public vault;
    PeapodsETHStrategy public strat;

    address public constant MYT = address(0xbeef);

    uint256 private _forkId;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        _forkId = vm.createFork(rpc, 22089302);
        vm.selectFork(_forkId);

        weth  = WETH(WETH_ADDRESS);
        vault = IERC4626(vaultAddr);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: address(this),
            name: "peapodsETH",
            protocol: "peapods",
            riskClass: IMYTStrategy.RiskClass.HIGH,
            cap: type(uint256).max,
            globalCap: type(uint256).max,
            estimatedYield: 0,
            additionalIncentives: false
        });

        strat = new PeapodsETHStrategy(
            MYT,
            params,
            vaultAddr,
            WETH_ADDRESS
        );

        strat.setWhitelistedAllocator(address(0xbeef), true);

        vm.prank(address(strat));
        IERC20(WETH_ADDRESS).approve(vaultAddr, type(uint256).max);

        vm.makePersistent(address(strat));
    }

    function testAllocate() public {
        uint256 ethAmt = 0.2 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        uint256 sharesOut = strat.allocate{value: ethAmt}(ethAmt);

        // vault mints shares to the external caller (receiver = msg.sender in _allocate)
        assertGt(sharesOut, 0, "no shares minted");
        assertEq(IERC20(address(vault)).balanceOf(address(0xbeef)), sharesOut, "shares not received by caller");
    }

    function testDeallocate() public {
        uint256 ethAmt = 0.15 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        uint256 shares = strat.allocate{value: ethAmt}(ethAmt);
        assertGt(shares, 0, "allocate failed");

        IERC20(address(vault)).approve(address(strat), shares);

        uint256 beforeBal = address(0xbeef).balance; 
        uint256 assetsOut = strat.deallocate(shares);
        vm.stopPrank();

        // redeem amount should be > 0 and ETH returned to caller by strategy’s unwrap
        assertGt(assetsOut, 0, "redeem returned 0");
        assertEq(address(0xbeef).balance, beforeBal + assetsOut, "ETH not returned to caller");
        assertEq(IERC20(address(vault)).balanceOf(address(this)), 0, "shares not burned");
    }

    function testSnapshotYield() public {
        uint256 ethAmt = 0.2 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        strat.allocate{value: ethAmt}(ethAmt);

        // First snapshot seeds lastIndex; first return commonly 0
        uint256 first = strat.snapshotYield();
        assertEq(first, 0, "first snapshot should be 0");

        vm.rollFork(23281065);

        // Second snapshot should now reflect PPS drift (usually > 0)
        uint256 second = strat.snapshotYield();
        assertGt(second, 0, "APY should be > 0 after moving to later block");
    }
}