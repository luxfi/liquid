// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

// Adjust these imports to your layout
import {TokeAutoEthStrategy} from "src/strategies/TokeAutoEth.sol";
import {ILiquidStrategy} from "src/interfaces/ILiquidStrategy.sol";
import {IMainRewarder, IAutopilotRouter} from "src/strategies/interfaces/ITokemac.sol";
import {IERC4626} from "../../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

contract TokeAutoEthStrategyTest is Test {
    // Addresses sourced from environment so you can swap networks/blocks easily
    address public constant AUTOETH = 0x0A2b94F6871c1D7A32Fe58E1ab5e6deA2f114E56;
    address public constant ROUTER = 0x37dD409f5e98aB4f151F4259Ea0CC13e97e8aE21;
    address public constant REWARDER = 0x60882D6f70857606Cdd37729ccCe882015d1755E;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant ORACLE = 0x61F8BE7FD721e80C0249829eaE6f0DAf21bc2CaC;

    IERC20 public autoEth;
    IAutopilotRouter public router;
    IMainRewarder public rewarder;

    TokeAutoEthStrategy public strat;

    address public constant VAULT = address(0xbeef);

    uint256 private _forkId;
    bool private _skipFork;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            _skipFork = true;
            return;
        }
        _forkId = vm.createFork(rpc, 22_089_302);
        vm.selectFork(_forkId);

        autoEth = IERC20(AUTOETH);
        router = IAutopilotRouter(ROUTER);
        rewarder = IMainRewarder(REWARDER);

        ILiquidStrategy.StrategyParams memory params = ILiquidStrategy.StrategyParams({
            owner: address(this),
            name: "autoETH",
            protocol: "tokemak",
            riskClass: ILiquidStrategy.RiskClass.MEDIUM,
            cap: type(uint256).max,
            globalCap: type(uint256).max,
            estimatedYield: 0,
            additionalIncentives: false
        });

        strat = new TokeAutoEthStrategy(VAULT, params, AUTOETH, ROUTER, REWARDER, WETH, ORACLE);

        strat.setWhitelistedAllocator(address(0xbeef), true);

        vm.prank(address(strat));
        IERC20(WETH).approve(ROUTER, type(uint256).max);

        vm.makePersistent(address(strat));
    }

    function testAllocate() public {
        vm.skip(_skipFork);
        uint256 ethAmt = 0.2 ether;
        deal(WETH, address(strat), ethAmt);

        vm.startPrank(address(0xbeef));
        bytes memory prevAllocationAmount = abi.encode(0);
        (bytes32[] memory strategyIds, int256 change) = strat.allocate(prevAllocationAmount, ethAmt, "", address(VAULT));
        vm.stopPrank();

        assertGt(change, int256(0), "positive change expected");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], strat.adapterId(), "adapter id not in strategyIds");
        uint256 shares = IMainRewarder(REWARDER).balanceOf(address(strat));
        assertGe(strat.realAssets(), shares, "ETH not deposited into strategy");
        // assertEq(strat.realAssets(), ethAmt, "ETH not deposited into strategy");
    }

    function testDeallocate() public {
        vm.skip(_skipFork);
        uint256 ethAmt = 0.15 ether;
        deal(WETH, address(strat), ethAmt);
        vm.startPrank(address(0xbeef));
        bytes memory prevAllocationAmount = abi.encode(0);
        strat.allocate(prevAllocationAmount, ethAmt, "", address(VAULT));
        bytes memory prevAllocationAmount2 = abi.encode(ethAmt);
        (bytes32[] memory strategyIds, int256 change) = strat.deallocate(prevAllocationAmount2, ethAmt, "", address(VAULT));
        vm.stopPrank();
        assertLt(change, int256(0), "negative change expected");
        assertGt(strategyIds.length, 0, "strategyIds is empty");
        assertEq(strategyIds[0], strat.adapterId(), "adapter id not in strategyIds");
        assertEq(strat.realAssets(), 0, "ETH not deallocated from strategy");
    }

    // TODO find blocks to test where we actually will acrue rewards
    // Currently earned 0
    /*function testClaim() public {
        uint256 ethAmt = 0.15 ether;
        vm.deal(address(0xbeef), ethAmt);

        vm.startPrank(address(0xbeef));
        uint256 shares = strat.allocate{value: ethAmt}(ethAmt);
        vm.stopPrank();
        assertGt(shares, 0, "allocate failed");

        vm.rollFork(23281065);

        strat.claimRewards();
    }*/

    function testSnapshotYield() public {
        vm.skip(_skipFork);
        uint256 ethAmt = 0.2 ether;
        deal(WETH, address(strat), ethAmt);

        vm.startPrank(address(0xbeef));
        bytes memory prevAllocationAmount = abi.encode(0);
        (bytes32[] memory strategyIds, int256 change) = strat.allocate(prevAllocationAmount, ethAmt, "", address(VAULT));
        vm.stopPrank();

        uint256 first = strat.snapshotYield();
        assertEq(first, 0, "first snapshot should be 0");

        vm.rollFork(23_281_065);

        uint256 second = strat.snapshotYield();
        assertGt(second, 0, "APY should be > 0 after moving to later block");
    }
}
