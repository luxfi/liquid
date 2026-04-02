// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {SecurityTokenAdapter} from "../adapters/SecurityTokenAdapter.sol";

/// @dev Minimal ERC-3643-style token mock for testing the adapter.
/// Real ERC-3643 tokens enforce KYC on transfer; this mock just tracks balances.
contract MockSecurityToken {
    string public name = "iShares Bitcoin Trust";
    string public symbol = "IBIT";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not allowed");
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SecurityTokenAdapterTest is Test {
    SecurityTokenAdapter adapter;
    MockSecurityToken secToken;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant INITIAL_NAV = 50e18; // $50 per token

    function setUp() public {
        secToken = new MockSecurityToken();
        adapter = new SecurityTokenAdapter(address(secToken), "IBIT", "46438F101", INITIAL_NAV);
    }

    function test_constructor() public view {
        assertEq(adapter.token(), address(secToken));
        assertEq(adapter.underlyingToken(), address(secToken));
        assertEq(adapter.admin(), address(this));
        assertEq(keccak256(bytes(adapter.ticker())), keccak256(bytes("IBIT")));
        assertEq(keccak256(bytes(adapter.cusip())), keccak256(bytes("46438F101")));
        assertEq(adapter.nav(), INITIAL_NAV);
        assertEq(adapter.lastNavUpdate(), block.timestamp);
    }

    function test_version() public view {
        assertEq(keccak256(bytes(adapter.version())), keccak256(bytes("1.0.0")));
    }

    function test_price_returns_nav() public view {
        assertEq(adapter.price(), INITIAL_NAV);
    }

    function test_updateNAV() public {
        uint256 newNav = 55e18;
        adapter.updateNAV(newNav);

        assertEq(adapter.price(), newNav);
        assertEq(adapter.nav(), newNav);
        assertEq(adapter.lastNavUpdate(), block.timestamp);
    }

    function test_updateNAV_emits_event() public {
        uint256 newNav = 60e18;
        vm.expectEmit(false, false, false, true);
        emit SecurityTokenAdapter.NAVUpdated(INITIAL_NAV, newNav, block.timestamp);
        adapter.updateNAV(newNav);
    }

    function test_updateNAV_reverts_zero() public {
        vm.expectRevert(SecurityTokenAdapter.ZeroNav.selector);
        adapter.updateNAV(0);
    }

    function test_updateNAV_reverts_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(SecurityTokenAdapter.Unauthorized.selector);
        adapter.updateNAV(55e18);
    }

    function test_setAdmin() public {
        adapter.setAdmin(alice);
        assertEq(adapter.admin(), alice);
    }

    function test_setAdmin_reverts_zero() public {
        vm.expectRevert(SecurityTokenAdapter.ZeroAddress.selector);
        adapter.setAdmin(address(0));
    }

    function test_setAdmin_reverts_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(SecurityTokenAdapter.Unauthorized.selector);
        adapter.setAdmin(bob);
    }

    function test_setAdmin_new_admin_can_update_nav() public {
        adapter.setAdmin(alice);

        // Old admin cannot update
        vm.expectRevert(SecurityTokenAdapter.Unauthorized.selector);
        adapter.updateNAV(99e18);

        // New admin can
        vm.prank(alice);
        adapter.updateNAV(99e18);
        assertEq(adapter.price(), 99e18);
    }

    function test_constructor_reverts_zero_token() public {
        vm.expectRevert(SecurityTokenAdapter.ZeroAddress.selector);
        new SecurityTokenAdapter(address(0), "IBIT", "46438F101", INITIAL_NAV);
    }

    function test_constructor_reverts_zero_nav() public {
        vm.expectRevert(SecurityTokenAdapter.ZeroNav.selector);
        new SecurityTokenAdapter(address(secToken), "IBIT", "46438F101", 0);
    }

    function test_price_tracks_nav_changes() public {
        assertEq(adapter.price(), 50e18);

        adapter.updateNAV(52e18);
        assertEq(adapter.price(), 52e18);

        adapter.updateNAV(48e18);
        assertEq(adapter.price(), 48e18);
    }
}
