// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {SecurityTokenAdapter} from "../adapters/SecurityTokenAdapter.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

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
    address oracle = makeAddr("oracle");
    address compliance = makeAddr("compliance");

    uint256 constant INITIAL_NAV = 50e18; // $50 per token

    function setUp() public {
        secToken = new MockSecurityToken();
        adapter = new SecurityTokenAdapter(address(secToken), "IBIT", "46438F101", "US46438F1012", "ETF", INITIAL_NAV);
        // Grant roles to dedicated addresses
        adapter.grantRole(adapter.ORACLE_ROLE(), oracle);
        adapter.grantRole(adapter.COMPLIANCE_ROLE(), compliance);
    }

    // -- Constructor --------------------------------------------------------

    function test_constructor() public view {
        assertEq(adapter.token(), address(secToken));
        assertEq(adapter.underlyingToken(), address(secToken));
        assertEq(keccak256(bytes(adapter.ticker())), keccak256(bytes("IBIT")));
        assertEq(keccak256(bytes(adapter.cusip())), keccak256(bytes("46438F101")));
        assertEq(keccak256(bytes(adapter.isin())), keccak256(bytes("US46438F1012")));
        assertEq(keccak256(bytes(adapter.assetClass())), keccak256(bytes("ETF")));
        assertEq(adapter.nav(), INITIAL_NAV);
        assertEq(adapter.navTimestamp(), block.timestamp);
        assertEq(adapter.navStalenessMax(), 86_400);
        assertFalse(adapter.halted());
    }

    function test_version() public view {
        assertEq(keccak256(bytes(adapter.version())), keccak256(bytes("2.0.0")));
    }

    function test_constructor_reverts_zero_token() public {
        vm.expectRevert();
        new SecurityTokenAdapter(address(0), "IBIT", "46438F101", "US46438F1012", "ETF", INITIAL_NAV);
    }

    function test_constructor_reverts_zero_nav() public {
        vm.expectRevert();
        new SecurityTokenAdapter(address(secToken), "IBIT", "46438F101", "US46438F1012", "ETF", 0);
    }

    // -- NAV / price() ------------------------------------------------------

    function test_price_returns_nav() public view {
        assertEq(adapter.price(), INITIAL_NAV);
    }

    function test_updateNAV() public {
        uint256 newNav = 55e18;
        vm.prank(oracle);
        adapter.updateNAV(newNav);
        assertEq(adapter.nav(), newNav);
        assertEq(adapter.navTimestamp(), block.timestamp);
    }

    function test_updateNAV_emits_event() public {
        uint256 newNav = 60e18;
        vm.expectEmit(false, false, false, true);
        emit SecurityTokenAdapter.NAVUpdated(INITIAL_NAV, newNav, block.timestamp);
        vm.prank(oracle);
        adapter.updateNAV(newNav);
    }

    function test_updateNAV_reverts_zero() public {
        vm.prank(oracle);
        vm.expectRevert();
        adapter.updateNAV(0);
    }

    function test_updateNAV_reverts_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.updateNAV(55e18);
    }

    function test_price_tracks_nav_changes() public {
        assertEq(adapter.price(), 50e18);
        vm.prank(oracle);
        adapter.updateNAV(52e18);
        assertEq(adapter.price(), 52e18);
        vm.prank(oracle);
        adapter.updateNAV(48e18);
        assertEq(adapter.price(), 48e18);
    }

    // -- NAV staleness ------------------------------------------------------

    function test_stale_nav_reverts_price() public {
        // Warp past staleness threshold (24h + 1s)
        vm.warp(vm.getBlockTimestamp() + 86_401);
        assertTrue(adapter.isNavStale());
        vm.expectRevert(SecurityTokenAdapter.StaleNAV.selector);
        adapter.price();
    }

    function test_nav_not_stale_within_threshold() public {
        vm.warp(vm.getBlockTimestamp() + 86_399);
        assertFalse(adapter.isNavStale());
        assertEq(adapter.price(), INITIAL_NAV);
    }

    function test_setNavStalenessMax() public {
        // Only admin can set
        adapter.setNavStalenessMax(3600);
        assertEq(adapter.navStalenessMax(), 3600);

        // Warp 2h, now stale with 1h threshold
        vm.warp(vm.getBlockTimestamp() + 7200);
        vm.expectRevert(SecurityTokenAdapter.StaleNAV.selector);
        adapter.price();
    }

    function test_setNavStalenessMax_reverts_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.setNavStalenessMax(3600);
    }

    function test_nav_refresh_clears_staleness() public {
        vm.warp(vm.getBlockTimestamp() + 86_401);
        assertTrue(adapter.isNavStale());

        vm.prank(oracle);
        adapter.updateNAV(51e18);

        assertFalse(adapter.isNavStale());
        assertEq(adapter.price(), 51e18);
    }

    // -- Trading halt -------------------------------------------------------

    function test_halt_blocks_price() public {
        vm.prank(compliance);
        adapter.halt("SEC investigation");
        assertTrue(adapter.halted());

        vm.expectRevert(SecurityTokenAdapter.Halted.selector);
        adapter.price();
    }

    function test_resume_unblocks_price() public {
        vm.prank(compliance);
        adapter.halt("SEC investigation");

        vm.prank(compliance);
        adapter.resume();
        assertFalse(adapter.halted());
        assertEq(adapter.price(), INITIAL_NAV);
    }

    function test_halt_emits_event() public {
        vm.expectEmit(false, false, false, true);
        emit SecurityTokenAdapter.TradingHalted("SEC investigation");
        vm.prank(compliance);
        adapter.halt("SEC investigation");
    }

    function test_resume_emits_event() public {
        vm.prank(compliance);
        adapter.halt("SEC investigation");

        vm.expectEmit(false, false, false, true);
        emit SecurityTokenAdapter.TradingResumed();
        vm.prank(compliance);
        adapter.resume();
    }

    function test_halt_reverts_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.halt("no authority");
    }

    function test_resume_reverts_unauthorized() public {
        vm.prank(compliance);
        adapter.halt("test");

        vm.prank(alice);
        vm.expectRevert();
        adapter.resume();
    }

    // -- Dividends ----------------------------------------------------------

    function test_declareDividend() public {
        // Mint 100 tokens so totalSupply > 0
        secToken.mint(alice, 100e18);

        vm.prank(compliance);
        adapter.declareDividend(10e18, 1000, 2000, 1500, "Q1 2026");

        assertEq(adapter.dividendCount(), 1);
        assertEq(adapter.totalDividendsDistributed(), 10e18);
        // perToken = (10e18 * 1e18) / 100e18 = 0.1e18
        assertEq(adapter.accumulatedDividendPerToken(), 0.1e18);

        (uint256 amount, uint256 perToken, uint256 exDate, uint256 payDate, uint256 recordDate, string memory desc) = adapter.dividendHistory(0);
        assertEq(amount, 10e18);
        assertEq(perToken, 0.1e18);
        assertEq(exDate, 1000);
        assertEq(payDate, 2000);
        assertEq(recordDate, 1500);
        assertEq(keccak256(bytes(desc)), keccak256(bytes("Q1 2026")));
    }

    function test_declareDividend_accumulates() public {
        secToken.mint(alice, 100e18);

        vm.startPrank(compliance);
        adapter.declareDividend(10e18, 1000, 2000, 1500, "Q1");
        adapter.declareDividend(20e18, 3000, 4000, 3500, "Q2");
        vm.stopPrank();

        assertEq(adapter.dividendCount(), 2);
        assertEq(adapter.totalDividendsDistributed(), 30e18);
        // 0.1e18 + 0.2e18 = 0.3e18
        assertEq(adapter.accumulatedDividendPerToken(), 0.3e18);
    }

    function test_declareDividend_zero_supply() public {
        // totalSupply = 0, perToken should be 0 but amount still recorded
        vm.prank(compliance);
        adapter.declareDividend(10e18, 1000, 2000, 1500, "Q1");

        assertEq(adapter.dividendCount(), 1);
        assertEq(adapter.accumulatedDividendPerToken(), 0);
        assertEq(adapter.totalDividendsDistributed(), 10e18);
    }

    function test_declareDividend_emits_event() public {
        secToken.mint(alice, 100e18);

        vm.expectEmit(true, false, false, true);
        emit SecurityTokenAdapter.DividendDeclared(0, 10e18, 0.1e18, 1000);
        vm.prank(compliance);
        adapter.declareDividend(10e18, 1000, 2000, 1500, "Q1");
    }

    function test_declareDividend_reverts_zero_amount() public {
        vm.prank(compliance);
        vm.expectRevert(SecurityTokenAdapter.ZeroAmount.selector);
        adapter.declareDividend(0, 1000, 2000, 1500, "Q1");
    }

    function test_declareDividend_reverts_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.declareDividend(10e18, 1000, 2000, 1500, "Q1");
    }

    // -- Corporate Actions --------------------------------------------------

    function test_declareCorporateAction() public {
        vm.prank(compliance);
        adapter.declareCorporateAction(SecurityTokenAdapter.ActionType.SPLIT, 2, 1, "2:1 stock split");

        assertEq(adapter.corporateActionCount(), 1);

        (SecurityTokenAdapter.ActionType actionType, uint256 timestamp, uint256 ratio, uint256 ratioDenom, string memory desc, bool executed) =
            adapter.corporateActions(0);

        assertEq(uint8(actionType), uint8(SecurityTokenAdapter.ActionType.SPLIT));
        assertEq(timestamp, block.timestamp);
        assertEq(ratio, 2);
        assertEq(ratioDenom, 1);
        assertEq(keccak256(bytes(desc)), keccak256(bytes("2:1 stock split")));
        assertFalse(executed);
    }

    function test_executeCorporateAction_split_adjusts_nav() public {
        // NAV = 50e18. After 2:1 split, NAV = 25e18
        vm.startPrank(compliance);
        adapter.declareCorporateAction(SecurityTokenAdapter.ActionType.SPLIT, 2, 1, "2:1 split");
        adapter.executeCorporateAction(0);
        vm.stopPrank();

        assertEq(adapter.nav(), 25e18);
    }

    function test_executeCorporateAction_reverse_split_adjusts_nav() public {
        // NAV = 50e18. After 1:5 reverse split (ratio=5, denom=1), NAV = 250e18
        vm.startPrank(compliance);
        adapter.declareCorporateAction(SecurityTokenAdapter.ActionType.REVERSE_SPLIT, 5, 1, "1:5 reverse split");
        adapter.executeCorporateAction(0);
        vm.stopPrank();

        assertEq(adapter.nav(), 250e18);
    }

    function test_executeCorporateAction_merger_no_nav_change() public {
        vm.startPrank(compliance);
        adapter.declareCorporateAction(SecurityTokenAdapter.ActionType.MERGER, 0, 0, "Acquired by XYZ");
        adapter.executeCorporateAction(0);
        vm.stopPrank();

        // NAV unchanged for non-split actions
        assertEq(adapter.nav(), INITIAL_NAV);
    }

    function test_executeCorporateAction_reverts_already_executed() public {
        vm.startPrank(compliance);
        adapter.declareCorporateAction(SecurityTokenAdapter.ActionType.SYMBOL_CHANGE, 0, 0, "Ticker change");
        adapter.executeCorporateAction(0);

        vm.expectRevert("already executed");
        adapter.executeCorporateAction(0);
        vm.stopPrank();
    }

    function test_executeCorporateAction_emits_event() public {
        vm.prank(compliance);
        adapter.declareCorporateAction(SecurityTokenAdapter.ActionType.SPINOFF, 0, 0, "Spinoff of subsidiary");

        vm.expectEmit(true, false, false, true);
        emit SecurityTokenAdapter.CorporateActionExecuted(0);
        vm.prank(compliance);
        adapter.executeCorporateAction(0);
    }

    function test_declareCorporateAction_emits_event() public {
        vm.expectEmit(true, false, false, true);
        emit SecurityTokenAdapter.CorporateActionDeclared(0, SecurityTokenAdapter.ActionType.DELISTING, "Delisted from exchange");
        vm.prank(compliance);
        adapter.declareCorporateAction(SecurityTokenAdapter.ActionType.DELISTING, 0, 0, "Delisted from exchange");
    }

    function test_declareCorporateAction_reverts_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.declareCorporateAction(SecurityTokenAdapter.ActionType.SPLIT, 2, 1, "nope");
    }

    function test_executeCorporateAction_reverts_unauthorized() public {
        vm.prank(compliance);
        adapter.declareCorporateAction(SecurityTokenAdapter.ActionType.SPLIT, 2, 1, "split");

        vm.prank(alice);
        vm.expectRevert();
        adapter.executeCorporateAction(0);
    }

    // -- Disclosures --------------------------------------------------------

    function test_fileDisclosure() public {
        vm.prank(compliance);
        adapter.fileDisclosure("10-K", "ipfs://Qm...");

        assertEq(adapter.disclosureCount(), 1);

        (string memory filingType, string memory uri, uint256 filedAt) = adapter.disclosures(0);
        assertEq(keccak256(bytes(filingType)), keccak256(bytes("10-K")));
        assertEq(keccak256(bytes(uri)), keccak256(bytes("ipfs://Qm...")));
        assertEq(filedAt, block.timestamp);
    }

    function test_fileDisclosure_multiple() public {
        vm.startPrank(compliance);
        adapter.fileDisclosure("S-1", "ipfs://a");
        adapter.fileDisclosure("8-K", "ipfs://b");
        adapter.fileDisclosure("prospectus", "https://sec.gov/...");
        vm.stopPrank();

        assertEq(adapter.disclosureCount(), 3);
    }

    function test_fileDisclosure_emits_event() public {
        vm.expectEmit(false, false, false, true);
        emit SecurityTokenAdapter.DisclosureFiled("10-K", "ipfs://Qm...");
        vm.prank(compliance);
        adapter.fileDisclosure("10-K", "ipfs://Qm...");
    }

    function test_fileDisclosure_reverts_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert();
        adapter.fileDisclosure("10-K", "ipfs://Qm...");
    }

    // -- Role-based access control ------------------------------------------

    function test_admin_can_grant_oracle_role() public {
        adapter.grantRole(adapter.ORACLE_ROLE(), bob);

        vm.prank(bob);
        adapter.updateNAV(99e18);
        assertEq(adapter.nav(), 99e18);
    }

    function test_admin_can_revoke_compliance_role() public {
        adapter.revokeRole(adapter.COMPLIANCE_ROLE(), compliance);

        vm.prank(compliance);
        vm.expectRevert();
        adapter.halt("should fail");
    }

    function test_non_admin_cannot_grant_roles() public {
        bytes32 oracleRole = adapter.ORACLE_ROLE();
        vm.prank(alice);
        vm.expectRevert();
        adapter.grantRole(oracleRole, alice);
    }

    // -- Combined scenarios -------------------------------------------------

    function test_halt_then_stale_still_reverts_halted() public {
        // Halt takes priority over stale NAV in price()
        vm.prank(compliance);
        adapter.halt("test");

        vm.warp(vm.getBlockTimestamp() + 86_401);
        vm.expectRevert(SecurityTokenAdapter.Halted.selector);
        adapter.price();
    }

    function test_split_then_dividend() public {
        secToken.mint(alice, 100e18);

        vm.startPrank(compliance);
        // 2:1 split: NAV 50 -> 25
        adapter.declareCorporateAction(SecurityTokenAdapter.ActionType.SPLIT, 2, 1, "2:1");
        adapter.executeCorporateAction(0);
        assertEq(adapter.nav(), 25e18);

        // Dividend after split
        adapter.declareDividend(5e18, 1000, 2000, 1500, "Post-split div");
        vm.stopPrank();

        assertEq(adapter.totalDividendsDistributed(), 5e18);
        // perToken = 5e18 * 1e18 / 100e18 = 0.05e18
        assertEq(adapter.accumulatedDividendPerToken(), 0.05e18);
    }
}
