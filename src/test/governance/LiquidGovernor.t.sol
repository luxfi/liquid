// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../governance/LiquidGovernor.sol";
import "../../governance/LiquidToken.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract LiquidGovernorTest is Test {
    LiquidToken token;
    TimelockController timelock;
    LiquidGovernor governor;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        // Deploy token
        token = new LiquidToken(address(this));

        // Deploy timelock (1 day delay)
        address[] memory proposers = new address[](0);
        address[] memory executors = new address[](1);
        executors[0] = address(0); // Anyone can execute

        timelock = new TimelockController(1 days, proposers, executors, address(this));

        // Deploy governor
        governor = new LiquidGovernor(token, timelock);

        // Grant proposer role to governor
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // Mint tokens and delegate
        token.mint(alice, 1_000_000 * 1e18);
        vm.prank(alice);
        token.delegate(alice);
    }

    function test_GovernorSettings() public view {
        assertEq(governor.name(), "Liquid Governor");
        assertEq(governor.votingDelay(), 7200);
        assertEq(governor.votingPeriod(), 50400);
        assertEq(governor.proposalThreshold(), 0);
    }

    function test_TokenSettings() public view {
        assertEq(token.name(), "Liquid");
        assertEq(token.symbol(), "LIQ");
        assertEq(token.MAX_SUPPLY(), 100_000_000 * 1e18);
    }

    function test_TokenMint() public {
        token.mint(bob, 1000 * 1e18);
        assertEq(token.balanceOf(bob), 1000 * 1e18);
    }

    function test_TokenMintExceedsMaxSupply() public {
        token.mint(alice, 99_000_000 * 1e18); // Already has 1M
        vm.expectRevert("LiquidToken: exceeds max supply");
        token.mint(alice, 1); // Would exceed 100M cap
    }

    function test_Delegation() public view {
        assertEq(token.delegates(alice), alice);
        assertEq(token.getVotes(alice), 1_000_000 * 1e18);
    }

    function test_CreateProposal() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(token);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1000 * 1e18);

        vm.roll(block.number + 1); // Advance block for voting power checkpoint

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Mint tokens to Bob");

        assertTrue(proposalId > 0);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));
    }

    function test_VoteAndExecute() public {
        // Transfer timelock admin to governance
        timelock.grantRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock));
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        // Transfer token ownership to timelock for governance control
        token.transferOwnership(address(timelock));

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(token);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature("mint(address,uint256)", bob, 1000 * 1e18);

        vm.roll(block.number + 1);

        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Mint tokens to Bob");

        // Advance past voting delay
        vm.roll(block.number + governor.votingDelay() + 1);

        // Vote
        vm.prank(alice);
        governor.castVote(proposalId, 1); // For

        // Advance past voting period
        vm.roll(block.number + governor.votingPeriod() + 1);

        // Queue
        governor.queue(targets, values, calldatas, keccak256(bytes("Mint tokens to Bob")));

        // Advance past timelock delay
        vm.warp(block.timestamp + 1 days + 1);

        // Execute
        governor.execute(targets, values, calldatas, keccak256(bytes("Mint tokens to Bob")));

        assertEq(token.balanceOf(bob), 1000 * 1e18);
    }
}
