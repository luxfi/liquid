// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {LiquidComplianceGate} from "../LiquidComplianceGate.sol";

contract LiquidComplianceGateTest is Test {
    LiquidComplianceGate gate;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address vault = makeAddr("vault");
    address vaultRegD = makeAddr("vaultRegD");

    function setUp() public {
        vm.prank(owner);
        gate = new LiquidComplianceGate(owner);
    }

    function test_constructor() public view {
        assertEq(gate.owner(), owner);
    }

    function test_approve_and_canRedeem() public {
        // No KYC level required for vault => level 0 required
        vm.prank(owner);
        gate.approve(alice, 1);

        assertTrue(gate.whitelisted(alice));
        assertEq(gate.kycLevel(alice), 1);
        assertTrue(gate.canRedeem(alice, vault));
    }

    function test_canRedeem_fails_without_whitelist() public view {
        assertFalse(gate.canRedeem(alice, vault));
    }

    function test_canRedeem_fails_insufficient_level() public {
        vm.startPrank(owner);
        gate.setRequiredLevel(vaultRegD, 2); // accredited required
        gate.approve(alice, 1); // basic KYC only
        vm.stopPrank();

        assertFalse(gate.canRedeem(alice, vaultRegD));
    }

    function test_canRedeem_passes_sufficient_level() public {
        vm.startPrank(owner);
        gate.setRequiredLevel(vaultRegD, 2);
        gate.approve(alice, 2); // accredited
        vm.stopPrank();

        assertTrue(gate.canRedeem(alice, vaultRegD));
    }

    function test_canRedeem_passes_higher_level() public {
        vm.startPrank(owner);
        gate.setRequiredLevel(vaultRegD, 2);
        gate.approve(alice, 3); // qualified purchaser > accredited
        vm.stopPrank();

        assertTrue(gate.canRedeem(alice, vaultRegD));
    }

    function test_remove() public {
        vm.startPrank(owner);
        gate.approve(alice, 2);
        assertTrue(gate.canRedeem(alice, vault));

        gate.remove(alice);
        vm.stopPrank();

        assertFalse(gate.whitelisted(alice));
        assertEq(gate.kycLevel(alice), 0);
        assertFalse(gate.canRedeem(alice, vault));
    }

    function test_approveBatch() public {
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = makeAddr("charlie");

        vm.prank(owner);
        gate.approveBatch(accounts, 2);

        for (uint256 i = 0; i < accounts.length; i++) {
            assertTrue(gate.whitelisted(accounts[i]));
            assertEq(gate.kycLevel(accounts[i]), 2);
        }
    }

    function test_setRequiredLevel() public {
        vm.prank(owner);
        gate.setRequiredLevel(vaultRegD, 2);

        assertEq(gate.requiredLevel(vaultRegD), 2);
    }

    function test_setAuthorization() public {
        vm.prank(owner);
        gate.setAuthorization(vault, alice, true);

        assertTrue(gate.authorized(vault, alice));
    }

    function test_approve_reverts_nonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        gate.approve(bob, 1);
    }

    function test_remove_reverts_nonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        gate.remove(bob);
    }

    function test_approveBatch_reverts_nonOwner() public {
        address[] memory accounts = new address[](1);
        accounts[0] = bob;

        vm.prank(alice);
        vm.expectRevert();
        gate.approveBatch(accounts, 1);
    }

    function test_setRequiredLevel_reverts_nonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        gate.setRequiredLevel(vault, 2);
    }

    function test_setAuthorization_reverts_nonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        gate.setAuthorization(vault, bob, true);
    }

    function test_approve_emits_event() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit LiquidComplianceGate.Approved(alice, 2);
        gate.approve(alice, 2);
    }

    function test_remove_emits_event() public {
        vm.startPrank(owner);
        gate.approve(alice, 1);

        vm.expectEmit(true, false, false, false);
        emit LiquidComplianceGate.Removed(alice);
        gate.remove(alice);
        vm.stopPrank();
    }

    function test_setRequiredLevel_emits_event() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit LiquidComplianceGate.LevelRequired(vault, 2);
        gate.setRequiredLevel(vault, 2);
    }

    function test_multiple_vaults_different_levels() public {
        address vaultRegA = makeAddr("vaultRegA");

        vm.startPrank(owner);
        gate.setRequiredLevel(vaultRegA, 1); // Reg A+ = basic KYC
        gate.setRequiredLevel(vaultRegD, 2); // Reg D = accredited
        gate.approve(alice, 1); // basic KYC
        vm.stopPrank();

        assertTrue(gate.canRedeem(alice, vaultRegA));
        assertFalse(gate.canRedeem(alice, vaultRegD));
    }
}
