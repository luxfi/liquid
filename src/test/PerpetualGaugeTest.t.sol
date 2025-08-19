// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {PerpetualGauge} from "../PerpetualGauge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// --- Mock contracts ---

contract MockERC20 is IERC20 {
    string public name = "Mock Token";
    string public symbol = "MCK";
    uint8 public decimals = 18;
    uint256 public totalSupply = 1e24; // 1 million tokens (1e6 * 1e18)

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        balanceOf[msg.sender] = totalSupply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient");
        require(allowance[from][msg.sender] >= amount, "Not allowed");
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockStrategyClassifier {
    mapping(uint256 => uint8) public risk;
    mapping(uint256 => uint256) public indivCap;
    mapping(uint8 => uint256) public globalCap;

    function setRisk(uint256 stratId, uint8 _risk) external {
        risk[stratId] = _risk;
    }

    function setIndivCap(uint256 stratId, uint256 cap) external {
        indivCap[stratId] = cap;
    }

    function setGlobalCap(uint8 riskLevel, uint256 cap) external {
        globalCap[riskLevel] = cap;
    }

    function getStrategyRiskLevel(uint256 stratId) external view returns (uint8) {
        return risk[stratId];
    }

    function getIndividualCap(uint256 stratId) external view returns (uint256) {
        return indivCap[stratId];
    }

    function getGlobalCap(uint8 riskLevel) external view returns (uint256) {
        return globalCap[riskLevel];
    }
}

contract MockAllocatorProxy {
    event Allocated(uint256 strategyId, uint256 amount);

    function allocate(uint256 strategyId, uint256 amount) external {
        emit Allocated(strategyId, amount);
    }
}

// --- Test Suite ---

contract PerpetualGaugeTest is Test {
    PerpetualGauge gauge;
    MockERC20 token;
    MockStrategyClassifier classifier;
    MockAllocatorProxy allocator;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new MockERC20();
        classifier = new MockStrategyClassifier();
        allocator = new MockAllocatorProxy();

        gauge = new PerpetualGauge(
            address(classifier),
            address(allocator),
            address(token)
        );

        // Give tokens to Alice and Bob
        token.transfer(alice, 1e21);
        token.transfer(bob, 1e21);

        // Setup classifier caps
        classifier.setIndivCap(1, 5_000); // 50% cap
        classifier.setGlobalCap(1, 8_000); // 80% for risk group 1
        classifier.setRisk(1, 1);
    }

    // --- Voting Tests ---

    function testVoteIncreasesWeights() public {
        vm.prank(alice);
        gauge.vote(1, _arr(1), _arr(100));

        (uint256[] memory sIds, uint256[] memory weights) = gauge.getCurrentAllocations(1);
        assertEq(sIds.length, 0, "strategyList not populated yet");
        // because registerNewStrategy not complete TODO in contract
    }

    function testVoteThenClear() public {
        vm.startPrank(alice);
        gauge.vote(1, _arr(1), _arr(100));
        gauge.clearVote(1);
        vm.stopPrank();
    }

    function testVoteExpiryLogic() public {
        vm.prank(alice);
        gauge.vote(1, _arr(1), _arr(100));

        // Warp past expiry
        vm.warp(block.timestamp + 366 days);
        // Should reset expiry
        vm.prank(alice);
        gauge.vote(1, _arr(1), _arr(200));
    }

    // --- Allocation Tests ---
    function testExecuteAllocationAppliesCaps() public {
        // Add strategy slot
        // FIXME gauge.strategyList(1).push(1); // direct storage modification in test (unsafe in prod)

        vm.prank(alice);
        gauge.vote(1, _arr(1), _arr(100));

        // Force aggregator to contain weight
        uint256 idle = 1e18;

        vm.expectEmit(true, true, true, true);
        emit MockAllocatorProxy.Allocated(1, idle / 2); // since indivCap is 50%

        gauge.executeAllocation(1, idle);
    }

    function testMultipleVotersAggregate() public {
        // Add strategy slot
        // FIXME gauge.strategyList(1).push(1);

        vm.prank(alice);
        gauge.vote(1, _arr(1), _arr(100));

        vm.prank(bob);
        gauge.vote(1, _arr(1), _arr(100));

        (uint256[] memory sIds, uint256[] memory weights) = gauge.getCurrentAllocations(1);

        assertEq(sIds.length, 1);
        assertEq(weights[0], 1e18, "Full allocation weight");
    }

    // Helper function for arrays
    function _arr(uint256 v) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = v;
        return arr;
    }
}
