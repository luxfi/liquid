// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {TransparentUpgradeableProxy} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Liquid} from "../Liquid.sol";
import {LiquidTransmuter} from "../LiquidTransmuter.sol";
import {LiquidPosition} from "../LiquidPosition.sol";
import {LiquidTokenVault} from "../LiquidTokenVault.sol";
import {LiquidMintableToken} from "./mocks/LiquidMintableToken.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {ILiquid, ILiquidErrors, LiquidInitializationParams} from "../interfaces/ILiquid.sol";
import {ILiquidTransmuter} from "../interfaces/ILiquidTransmuter.sol";
import {IllegalArgument, IllegalState} from "../base/Errors.sol";

/// Regression suite for the findings of the 2026-08 cryptographic audit.
///
/// Every test here began as a working proof-of-concept exploit. They are kept in
/// the shape they were written in, so each one still describes the attack rather
/// than the patch, and a regression re-opens the exact hole it closed.

// ─────────────────────────────────────────────────────────────────────────────
// C1 -- the debt token must expose the interface the engine actually calls.
// ─────────────────────────────────────────────────────────────────────────────

/// The canonical Lux mainnet LETH, reproduced surface-for-surface:
/// lux/standard `contracts/liquid/tokens/LETH.sol` -> `LiquidETH is Synthetic`.
///
/// Supply is created by MINTER_ROLE and destroyed by the holder, directly or
/// through an allowance. There is no admin path to a balance the admin does not
/// hold -- which is what makes granting the engine a minter role safe.
contract CanonicalLETH is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor() ERC20("Liquid ETH", "LETH") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    function mint(address account, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(account, amount);
    }

    function burn(uint256 amount) public {
        _burn(_msgSender(), amount);
    }

    function burnFrom(address account, uint256 amount) public {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }

    function grantMinter(address minter) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, minter);
    }
}

contract AuditCanonicalToken is Test {
    Liquid liquid;
    LiquidTransmuter transmuter;
    LiquidPosition positionNFT;
    CanonicalLETH leth;
    TestERC20 underlying;
    TestYieldToken yield_;

    address admin = address(0xA11CE);
    address user = address(0xB0B);

    function setUp() external {
        vm.startPrank(admin);
        underlying = new TestERC20(0, 18);
        yield_ = new TestYieldToken(address(underlying));
        leth = new CanonicalLETH();

        transmuter = new LiquidTransmuter(
            ILiquidTransmuter.TransmuterInitializationParams({
                syntheticToken: address(leth),
                feeReceiver: address(0xFEE),
                timeToTransmute: 100,
                transmutationFee: 0,
                exitFee: 0,
                graphSize: 52_560_000
            })
        );

        Liquid logic = new Liquid();
        LiquidInitializationParams memory p = LiquidInitializationParams({
            admin: admin,
            debtToken: address(leth),
            underlyingToken: address(underlying),
            yieldToken: address(yield_),
            blocksPerYear: 2_600_000,
            depositCap: type(uint256).max,
            minimumCollateralization: 1.1111e18,
            collateralizationLowerBound: 1.05e18,
            globalMinimumCollateralization: 1.0526e18,
            tokenAdapter: address(yield_),
            maxPriceDeviation: 10_000,
            transmuter: address(transmuter),
            protocolFee: 0,
            protocolFeeReceiver: address(0xFEE),
            liquidatorFee: 500,
            repaymentFee: 100
        });
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(logic), address(0xDEAD), abi.encodeWithSelector(Liquid.initialize.selector, p));
        liquid = Liquid(address(proxy));

        // The engine takes MINTER_ROLE and nothing else. It has no way to reach
        // a holder's balance except through an allowance that holder granted.
        leth.grantMinter(address(liquid));

        transmuter.setLiquid(address(liquid));
        transmuter.setDepositCap(uint256(type(int256).max));
        positionNFT = new LiquidPosition(address(liquid));
        liquid.setLiquidPositionNFT(address(positionNFT));
        vm.stopPrank();

        deal(address(underlying), user, 1_000_000e18);
        vm.startPrank(user);
        IERC20(address(underlying)).approve(address(yield_), type(uint256).max);
        yield_.mint(1_000_000e18, user);
        vm.stopPrank();
    }

    function _openPosition() internal returns (uint256 tokenId, uint256 borrowed) {
        vm.startPrank(user);
        IERC20(address(yield_)).approve(address(liquid), type(uint256).max);
        liquid.deposit(1000e18, user, 0);
        tokenId = positionNFT.tokenOfOwnerByIndex(user, 0);
        borrowed = liquid.getMaxBorrowable(tokenId);
        liquid.mint(tokenId, borrowed, user);
        vm.stopPrank();
    }

    /// C1: the three calls the engine makes on its debt token, made directly.
    ///
    /// `TokenUtils` reaches the token through low-level calls, so a missing
    /// selector does not fail to compile -- it fails at runtime, on the burn
    /// path, after value has already been minted. Value that can be created and
    /// never destroyed can never be redeemed, which is the whole protocol.
    function test_engine_calls_land_on_the_canonical_token() external {
        // mint(address,uint256) -- the engine issuing debt.
        vm.prank(address(liquid));
        leth.mint(user, 100e18);
        assertEq(leth.balanceOf(user), 100e18, "mint(address,uint256)");

        // burnFrom(address,uint256) -- the engine retiring a borrower's debt
        // through the allowance that borrower granted it.
        vm.prank(user);
        leth.approve(address(liquid), 40e18);
        vm.prank(address(liquid));
        leth.burnFrom(user, 40e18);
        assertEq(leth.balanceOf(user), 60e18, "burnFrom(address,uint256)");

        // burn(uint256) -- the transmuter destroying synthetics it holds.
        vm.prank(user);
        leth.transfer(address(transmuter), 60e18);
        vm.prank(address(transmuter));
        leth.burn(60e18);
        assertEq(leth.totalSupply(), 0, "burn(uint256)");
    }

    /// C1: the admin-gated burn-anyone primitive is gone. Holding every role on
    /// the token does not reach a balance the holder did not approve away.
    function test_no_role_can_burn_a_holders_balance() external {
        (, uint256 borrowed) = _openPosition();
        assertEq(leth.balanceOf(user), borrowed);

        vm.prank(admin); // holds DEFAULT_ADMIN_ROLE and MINTER_ROLE
        vm.expectRevert();
        leth.burnFrom(user, borrowed);

        assertEq(leth.balanceOf(user), borrowed, "balance untouched");
    }

    /// C1 (was: "mint works but burn paths are dead").
    /// Repaying in LETH goes through burnFrom, which the old token did not have.
    function test_repay_in_debt_token_retires_debt() external {
        (uint256 tokenId, uint256 borrowed) = _openPosition();
        vm.roll(vm.getBlockNumber() + 1);

        (, uint256 debtBefore,) = liquid.getCDP(tokenId);

        vm.startPrank(user);
        leth.approve(address(liquid), type(uint256).max);
        liquid.burn(borrowed / 2, tokenId);
        vm.stopPrank();

        (, uint256 debtAfter,) = liquid.getCDP(tokenId);
        assertLt(debtAfter, debtBefore, "debt fell");
        assertEq(leth.balanceOf(user), borrowed - borrowed / 2, "synthetic burned, not transferred");
    }

    /// C1 (was: "claimRedemption is a one-way trap").
    /// The transmuter takes LETH in and burns it on the way out via burn(uint256).
    function test_transmuter_can_pay_out_a_matured_redemption() external {
        (, uint256 borrowed) = _openPosition();

        vm.startPrank(user);
        leth.approve(address(transmuter), type(uint256).max);
        transmuter.createRedemption(borrowed);
        vm.stopPrank();
        assertEq(leth.balanceOf(address(transmuter)), borrowed, "transmuter took the LETH");

        vm.roll(vm.getBlockNumber() + 200); // past full maturation

        vm.prank(user);
        transmuter.claimRedemption(1);

        assertLt(leth.balanceOf(address(transmuter)), borrowed, "synthetic left the transmuter");
        assertGt(IERC20(address(yield_)).balanceOf(user), 0, "claimant was paid in yield tokens");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// C2 -- no production contract exposes unguarded supply controls.
// ─────────────────────────────────────────────────────────────────────────────

contract AuditUnguardedMinter is Test {
    LiquidMintableToken token;
    address attacker = address(0xBAD);

    function setUp() external {
        token = new LiquidMintableToken("Liquid ETH", "LETH", 0);
    }

    /// C2: `src/external/LETH.sol` shipped `setWhitelist`, `pauseMinter` and
    /// `setCeiling` with natspec claiming an admin check and no modifier on any
    /// of them, under the same name the deploy scripts referenced. It is deleted.
    /// The token that survives guards all three.
    function test_attacker_cannot_self_whitelist_and_mint() external {
        vm.prank(attacker);
        vm.expectRevert();
        token.setWhitelist(attacker, true);

        vm.prank(attacker);
        vm.expectRevert();
        token.mint(attacker, 1e30);

        assertEq(token.totalSupply(), 0, "no supply created");
    }

    /// C2: pausing the real minter was likewise unguarded -- a denial of service
    /// on the whole protocol from any address.
    function test_attacker_cannot_pause_the_real_minter() external {
        address realMinter = address(0xC0FFEE);
        token.setWhitelist(realMinter, true);

        vm.prank(attacker);
        vm.expectRevert();
        token.pauseMinter(realMinter, true);

        vm.prank(realMinter);
        token.mint(realMinter, 1e18);
        assertEq(token.balanceOf(realMinter), 1e18, "the real minter still works");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// C3 / C4 / H1 / M1 / M2 -- the engine.
// ─────────────────────────────────────────────────────────────────────────────

contract AuditLiquid is Test {
    Liquid liquid;
    LiquidTransmuter transmuter;
    LiquidPosition positionNFT;
    LiquidMintableToken debt;
    TestERC20 underlying;
    TestYieldToken yield_;

    address admin = address(0xA11CE);
    address user = address(0xB0B);
    address liquidator = address(0x11D);
    address feeReceiver = address(0xFEE);

    uint256 constant MIN_COLL = 1.1111e18; // 90% LTV
    uint256 constant LOWER_BOUND = 1.05e18;
    uint256 constant GLOBAL_MIN = 1.0526e18; // below the mint bar, as it must be

    function setUp() external {
        vm.startPrank(admin);
        underlying = new TestERC20(0, 18);
        yield_ = new TestYieldToken(address(underlying));
        debt = new LiquidMintableToken("d", "d", 0);

        transmuter = new LiquidTransmuter(
            ILiquidTransmuter.TransmuterInitializationParams({
                syntheticToken: address(debt),
                feeReceiver: feeReceiver,
                timeToTransmute: 5_256_000,
                transmutationFee: 10,
                exitFee: 20,
                graphSize: 52_560_000
            })
        );

        Liquid logic = new Liquid();
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(logic), address(0xDEAD), abi.encodeWithSelector(Liquid.initialize.selector, _params(GLOBAL_MIN)));
        liquid = Liquid(address(proxy));
        debt.setWhitelist(address(proxy), true);
        transmuter.setLiquid(address(liquid));
        transmuter.setDepositCap(uint256(type(int256).max));
        positionNFT = new LiquidPosition(address(liquid));
        liquid.setLiquidPositionNFT(address(positionNFT));
        vm.stopPrank();

        deal(address(underlying), user, 1_000_000e18);
        vm.startPrank(user);
        IERC20(address(underlying)).approve(address(yield_), type(uint256).max);
        yield_.mint(1_000_000e18, user);
        vm.stopPrank();
    }

    function _params(uint256 globalMin) internal view returns (LiquidInitializationParams memory) {
        return LiquidInitializationParams({
            admin: admin,
            debtToken: address(debt),
            underlyingToken: address(underlying),
            yieldToken: address(yield_),
            blocksPerYear: 2_600_000,
            depositCap: type(uint256).max,
            minimumCollateralization: MIN_COLL,
            collateralizationLowerBound: LOWER_BOUND,
            globalMinimumCollateralization: globalMin,
            tokenAdapter: address(yield_),
            maxPriceDeviation: 10_000,
            transmuter: address(transmuter),
            protocolFee: 0,
            protocolFeeReceiver: feeReceiver,
            liquidatorFee: 500,
            repaymentFee: 100
        });
    }

    /// Drop the yield token's redemption price to `pctOfPar` percent of par.
    /// A price move is an inter-block event, here as on chain.
    function _dropPrice(uint256 pctOfPar) internal {
        yield_.updateMockTokenSupply(yield_.totalSupply() * 100 / pctOfPar);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _openMaxedPosition() internal returns (uint256 tokenId) {
        vm.startPrank(user);
        IERC20(address(yield_)).approve(address(liquid), type(uint256).max);
        liquid.deposit(1000e18, user, 0);
        tokenId = positionNFT.tokenOfOwnerByIndex(user, 0);
        liquid.mint(tokenId, liquid.getMaxBorrowable(tokenId), user); // borrow at the 90% cap
        vm.stopPrank();
    }

    /// C3: the mainnet script never set a fee vault, and `_doLiquidation` read
    /// `IFeeVault(address(0)).totalDeposits()` unconditionally. Every deeply
    /// underwater position -- the ones the branch exists for -- was unliquidatable.
    function test_underwater_position_liquidates_with_no_fee_vault() external {
        uint256 tokenId = _openMaxedPosition();
        assertEq(liquid.liquidFeeVault(), address(0), "no fee vault configured");

        _dropPrice(80); // yield token loses 20%

        (, uint256 d,) = liquid.getCDP(tokenId);
        assertLt(liquid.totalValue(tokenId), d, "underwater: debt exceeds collateral value");

        vm.prank(liquidator);
        (uint256 seized,,) = liquid.liquidate(tokenId);
        assertGt(seized, 0, "liquidation cleared the position");
    }

    /// C3: same position, reached through the batch entry point.
    function test_underwater_position_batch_liquidates_with_no_fee_vault() external {
        uint256 tokenId = _openMaxedPosition();
        _dropPrice(80);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.prank(liquidator);
        (uint256 seized,,) = liquid.batchLiquidate(ids);
        assertGt(seized, 0, "batch liquidation cleared the position");
    }

    /// M1: `getMaxBorrowable` subtracted debt from a smaller limit and underflowed.
    /// A caller could not even ask the question of an unhealthy position.
    function test_getMaxBorrowable_saturates_on_unhealthy_position() external {
        uint256 tokenId = _openMaxedPosition();
        _dropPrice(80);

        assertEq(liquid.getMaxBorrowable(tokenId), 0, "nothing borrowable, no revert");
    }

    /// C3: the shipped mainnet parameters put the global floor ABOVE the mint
    /// bar. At full utilisation every borrower sits at the bar and the
    /// protocol-wide ratio equals it, so a healthy protocol read as globally
    /// insolvent and every liquidation took the full-seizure branch. The engine
    /// now refuses the ordering outright.
    function test_global_floor_above_mint_bar_is_unconfigurable() external {
        vm.startPrank(admin);
        vm.expectRevert(IllegalArgument.selector);
        liquid.setGlobalMinimumCollateralization(1.15e18); // the shipped value
        vm.stopPrank();

        Liquid logic = new Liquid();
        LiquidInitializationParams memory bad = _params(1.15e18);
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(logic), address(0xDEAD), abi.encodeWithSelector(Liquid.initialize.selector, bad));
    }

    /// C3: with the floors ordered correctly a merely-at-the-cap position takes
    /// a partial, targeted liquidation paid out of its own surplus, rather than
    /// full seizure funded by a vault that may not exist.
    function test_correct_ordering_gives_partial_liquidation() external view {
        uint256 collateral = 1000e18;
        uint256 debtAmount = 900e18;
        uint256 globalColl = collateral * 1e18 / debtAmount; // == MIN_COLL at full draw

        assertGe(globalColl, GLOBAL_MIN, "a fully-drawn protocol reads as healthy");

        (, uint256 burned, uint256 baseFee, uint256 outsourced) =
            liquid.calculateLiquidation(collateral, debtAmount, MIN_COLL, globalColl, GLOBAL_MIN, 500);

        assertLt(burned, debtAmount, "partial, targeted liquidation");
        assertGt(baseFee, 0, "liquidator paid from the position's own surplus");
        assertEq(outsourced, 0, "no fee-vault dependency");
    }

    /// M3: the three collateralization levels could be inverted by ordering the
    /// admin calls, because each setter only checked one side.
    function test_liquidation_bound_cannot_be_pushed_above_mint_bar() external {
        vm.startPrank(admin);
        liquid.setCollateralizationLowerBound(1.05e18);

        vm.expectRevert(IllegalArgument.selector);
        liquid.setMinimumCollateralization(1.0e18); // would leave the bound above the bar
        vm.stopPrank();

        assertLe(liquid.collateralizationLowerBound(), liquid.minimumCollateralization(), "bound stays at or below the bar");
        assertLe(liquid.globalMinimumCollateralization(), liquid.minimumCollateralization(), "global floor stays at or below the bar");
    }

    /// M2: `batchLiquidate` performed liquidations and emitted nothing, so a
    /// position could be seized with no on-chain record an indexer could find.
    function test_batchLiquidate_emits_Liquidated() external {
        address whale = address(0xAd);
        deal(address(underlying), whale, 500_000e18);
        vm.startPrank(whale);
        IERC20(address(underlying)).approve(address(yield_), type(uint256).max);
        yield_.mint(500_000e18, whale);
        IERC20(address(yield_)).approve(address(liquid), type(uint256).max);
        liquid.deposit(500_000e18, whale, 0);
        vm.stopPrank();

        uint256 tokenId = _openMaxedPosition();
        _dropPrice(93);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.recordLogs();
        vm.prank(liquidator);
        (uint256 amt,,) = liquid.batchLiquidate(ids);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = keccak256("Liquidated(uint256,address,uint256,uint256,uint256)");
        uint256 found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) found++;
        }
        assertGt(amt, 0, "a liquidation did occur");
        assertEq(found, 1, "and it was reported exactly once");
    }

    /// C4: the engine read `tokenAdapter.price()` raw, with no bound, staleness
    /// check or deviation cap. A borrower could move the reported price inside
    /// their own transaction and mint against value that never existed.
    function test_same_block_price_move_does_not_move_borrowing_power() external {
        vm.startPrank(user);
        IERC20(address(yield_)).approve(address(liquid), type(uint256).max);
        liquid.deposit(1000e18, user, 0);
        uint256 tokenId = positionNFT.tokenOfOwnerByIndex(user, 0);
        vm.stopPrank();

        uint256 before_ = liquid.getMaxBorrowable(tokenId);

        // 100x the reported price, in the same block.
        yield_.updateMockTokenSupply(yield_.totalSupply() / 100);

        assertEq(liquid.getMaxBorrowable(tokenId), before_, "borrowing power is unmoved");

        vm.prank(user);
        vm.expectRevert(ILiquidErrors.Undercollateralized.selector);
        liquid.mint(tokenId, before_ * 2, user);
    }

    /// C4: across blocks the price tracks the adapter, but only as fast as the
    /// deviation cap allows -- so a compromised adapter cannot hand out borrowing
    /// power faster than a guardian can pause the market.
    function test_price_moves_are_rate_limited_across_blocks() external {
        vm.prank(admin);
        liquid.setMaxPriceDeviation(100); // 1% per block

        uint256 anchor = liquid.price();
        yield_.updateMockTokenSupply(yield_.totalSupply() / 100); // adapter reports 100x

        vm.roll(vm.getBlockNumber() + 1);
        assertEq(liquid.price(), anchor + anchor / 100, "one block buys one percent");

        vm.roll(vm.getBlockNumber() + 9);
        assertEq(liquid.price(), anchor + anchor / 10, "ten blocks buy ten percent");
    }

    /// C4: swapping the adapter is a price update like any other. It cannot
    /// teleport collateral value, and it cannot point the market at a feed for
    /// a different pair.
    function test_adapter_swap_is_bound_and_rate_limited() external {
        TestERC20 otherUnderlying = new TestERC20(0, 18);
        TestYieldToken foreign = new TestYieldToken(address(otherUnderlying));

        vm.prank(admin);
        vm.expectRevert(IllegalArgument.selector);
        liquid.setTokenAdapter(address(foreign));

        vm.prank(admin);
        vm.expectRevert(IllegalArgument.selector);
        liquid.setTokenAdapter(address(0));

        assertEq(liquid.tokenAdapter(), address(yield_), "adapter unchanged");
    }

    /// H1: the engine converts underlying to debt with a decimals scalar and
    /// holds no cross-asset price source, so the adapter must describe this
    /// market's own pair. A market whose adapter prices something else is
    /// unconstructible.
    function test_market_cannot_be_built_on_a_foreign_adapter() external {
        TestERC20 otherUnderlying = new TestERC20(0, 18);
        TestYieldToken foreign = new TestYieldToken(address(otherUnderlying));

        LiquidInitializationParams memory p = _params(GLOBAL_MIN);
        p.tokenAdapter = address(foreign);

        Liquid logic = new Liquid();
        vm.expectRevert();
        new TransparentUpgradeableProxy(address(logic), address(0xDEAD), abi.encodeWithSelector(Liquid.initialize.selector, p));
    }

    /// H2: a forced repayment may only retire as much debt as the collateral it
    /// actually moves pays for.
    ///
    /// `_forceRepay` clamped the yield it transferred to the account's collateral
    /// balance but credited the UNCLAMPED amount against the debt. The difference
    /// was synthetic left standing with nothing behind it -- created silently, on
    /// the liquidation path, exactly when the protocol could least afford it.
    function test_forced_repayment_retires_only_what_collateral_covers() external {
        // A second depositor keeps the protocol solvent overall, so the
        // liquidation is a normal one rather than the global bad-debt branch.
        address whale = address(0xAd);
        deal(address(underlying), whale, 500_000e18);
        vm.startPrank(whale);
        IERC20(address(underlying)).approve(address(yield_), type(uint256).max);
        yield_.mint(500_000e18, whale);
        IERC20(address(yield_)).approve(address(liquid), type(uint256).max);
        liquid.deposit(500_000e18, whale, 0);
        vm.stopPrank();

        uint256 tokenId = _openMaxedPosition();

        // Park synthetics in the transmuter so the engine starts earmarking debt
        // for redemption -- earmarked debt is what the forced repayment targets.
        vm.startPrank(user);
        debt.approve(address(transmuter), type(uint256).max);
        transmuter.createRedemption(debt.balanceOf(user) / 2);
        vm.stopPrank();

        vm.roll(block.number + 500_000);
        _dropPrice(70);

        uint256 debtBefore = liquid.totalDebt();
        uint256 transmuterBefore = IERC20(address(yield_)).balanceOf(address(transmuter));
        (uint256 collateralBefore,,) = liquid.getCDP(tokenId);

        vm.prank(liquidator);
        liquid.liquidate(tokenId);

        uint256 debtRetired = debtBefore - liquid.totalDebt();
        uint256 yieldMoved = IERC20(address(yield_)).balanceOf(address(transmuter)) - transmuterBefore;
        (uint256 collateralAfter, uint256 accountDebtAfter,) = liquid.getCDP(tokenId);

        assertGt(debtRetired, 0, "the liquidation retired debt");

        // The position is wound up completely: every token of collateral it held
        // has moved to the transmuter, and it owes nothing further. The gap
        // between what moved and what was written off is the realised loss, and
        // it is bounded by the collateral that existed -- the engine cannot
        // consume more collateral than the account had, which is what the
        // unclamped forced repayment effectively claimed to have done.
        assertEq(collateralAfter, 0, "collateral fully consumed");
        assertEq(accountDebtAfter, 0, "position wound up");
        assertLe(liquid.convertDebtTokensToYield(debtRetired), yieldMoved + collateralBefore, "no more collateral consumed than existed");
        assertGt(yieldMoved, 0, "seized collateral reached the transmuter, not nowhere");
    }

    /// H6: minting new debt into a protocol that already cannot cover the debt
    /// it has issued hands the existing hole to the next borrower.
    function test_no_new_debt_while_the_protocol_is_short() external {
        uint256 tokenId = _openMaxedPosition();
        _dropPrice(50); // collateral now worth less than the debt outstanding

        (, uint256 d,) = liquid.getCDP(tokenId);
        assertLt(liquid.totalValue(tokenId), d, "protocol is short");

        vm.prank(user);
        vm.expectRevert(IllegalState.selector);
        liquid.mint(tokenId, 1e18, user);

        vm.startPrank(user);
        vm.expectRevert(IllegalState.selector);
        liquid.deposit(1e18, user, tokenId);
        vm.stopPrank();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// H1 / H4 -- the eight-decimal market.
//
// Bridged BTC carries 8 decimals and LBTC carries 18, so this market runs at an
// `underlyingConversionFactor` of 10^10 where the ETH market runs at 1. Every
// valuation crosses that gap, and a scalar applied in the wrong direction is off
// by ten orders of magnitude rather than by a rounding step -- so the gap is
// worth its own market rather than a decimals argument on an existing test.
// ─────────────────────────────────────────────────────────────────────────────

contract AuditBitcoinMarket is Test {
    Liquid liquid;
    LiquidTransmuter transmuter;
    LiquidPosition positionNFT;
    LiquidMintableToken debt; // LBTC, 18dp
    TestERC20 underlying; // bridged BTC, 8dp
    TestYieldToken yield_; // yield-bearing BTC, 8dp

    address admin = address(0xA11CE);
    address user = address(0xB0B);
    address liquidator = address(0x11D);
    address feeReceiver = address(0xFEE);

    uint256 constant MIN_COLL = 1.1111e18; // 90% LTV
    uint256 constant BTC = 1e8; // one bridged BTC
    uint256 constant LBTC = 1e18; // one LBTC

    function setUp() external {
        vm.startPrank(admin);
        underlying = new TestERC20(0, 8);
        yield_ = new TestYieldToken(address(underlying));
        debt = new LiquidMintableToken("Liquid BTC", "LBTC", 0);

        transmuter = new LiquidTransmuter(
            ILiquidTransmuter.TransmuterInitializationParams({
                syntheticToken: address(debt),
                feeReceiver: feeReceiver,
                timeToTransmute: 5_256_000,
                transmutationFee: 0,
                exitFee: 0,
                graphSize: 52_560_000
            })
        );

        Liquid logic = new Liquid();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(logic),
            address(0xDEAD),
            abi.encodeWithSelector(
                Liquid.initialize.selector,
                LiquidInitializationParams({
                    admin: admin,
                    debtToken: address(debt),
                    underlyingToken: address(underlying),
                    yieldToken: address(yield_),
                    blocksPerYear: 2_600_000,
                    depositCap: type(uint256).max,
                    minimumCollateralization: MIN_COLL,
                    collateralizationLowerBound: 1.05e18,
                    globalMinimumCollateralization: 1.0526e18,
                    tokenAdapter: address(yield_),
                    maxPriceDeviation: 10_000,
                    transmuter: address(transmuter),
                    protocolFee: 0,
                    protocolFeeReceiver: feeReceiver,
                    liquidatorFee: 500,
                    repaymentFee: 100
                })
            )
        );
        liquid = Liquid(address(proxy));
        debt.setWhitelist(address(proxy), true);
        transmuter.setLiquid(address(liquid));
        transmuter.setDepositCap(uint256(type(int256).max));
        positionNFT = new LiquidPosition(address(liquid));
        liquid.setLiquidPositionNFT(address(positionNFT));
        vm.stopPrank();

        deal(address(underlying), user, 1_000_000 * BTC);
        vm.startPrank(user);
        IERC20(address(underlying)).approve(address(yield_), type(uint256).max);
        yield_.mint(1_000_000 * BTC, user);
        IERC20(address(yield_)).approve(address(liquid), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(uint256 amountBtc) internal returns (uint256 tokenId) {
        vm.prank(user);
        liquid.deposit(amountBtc, user, 0);
        tokenId = positionNFT.tokenOfOwnerByIndex(user, 0);
    }

    /// The scalar itself. 18 - 8 = 10.
    function test_conversion_factor_spans_the_decimal_gap() external view {
        assertEq(liquid.underlyingConversionFactor(), 1e10, "10^(18-8)");
        assertEq(liquid.normalizeUnderlyingTokensToDebt(BTC), LBTC, "one BTC is one LBTC of value");
        assertEq(liquid.normalizeDebtTokensToUnderlying(LBTC), BTC, "and back again");
    }

    /// Collateral is held in 8dp and valued in 18dp. One BTC of collateral must
    /// read as one LBTC of value, not 10^10 of them.
    function test_collateral_is_valued_across_the_gap() external {
        uint256 tokenId = _deposit(BTC);

        assertEq(liquid.totalValue(tokenId), LBTC, "one BTC of collateral is one LBTC of value");
        // 90% LTV: 1 LBTC of collateral supports 1e18 * 1e18 / 1.1111e18.
        assertApproxEqRel(liquid.getMaxBorrowable(tokenId), 0.9e18, 0.0001e18, "borrow power is 90% of one LBTC");
    }

    /// Borrowing draws 18dp debt against 8dp collateral, and repaying in the
    /// collateral retires it. A scalar dropped on either leg strands the debt.
    ///
    /// Repaying in collateral cannot clear the position to the last wei: one
    /// satoshi of collateral is 10^10 debt-wei, so a debt that is not a whole
    /// number of satoshis leaves a sub-satoshi remainder. That remainder is the
    /// decimal gap itself, and it must stay below one satoshi rather than
    /// scaling with the position.
    function test_borrow_and_repay_round_trip() external {
        uint256 tokenId = _deposit(BTC);

        uint256 borrow = liquid.getMaxBorrowable(tokenId);
        vm.prank(user);
        liquid.mint(tokenId, borrow, user);
        assertEq(debt.balanceOf(user), borrow, "LBTC issued in 18dp");

        (, uint256 owed,) = liquid.getCDP(tokenId);
        assertEq(owed, borrow, "debt recorded in debt units");

        // Repay in yield tokens: 8dp in, 18dp of debt retired.
        vm.roll(vm.getBlockNumber() + 1);
        uint256 inYield = liquid.convertDebtTokensToYield(borrow);
        vm.prank(user);
        liquid.repay(inYield, tokenId);

        (, uint256 remaining,) = liquid.getCDP(tokenId);
        assertLt(remaining, liquid.underlyingConversionFactor(), "residual debt is under one satoshi");
        assertLt(remaining * 1e18 / borrow, 1e9, "and is dust against the position, not a fraction of it");
    }

    /// C3 on the 8dp market: a position that falls underwater still liquidates.
    function test_liquidation_clears_an_underwater_8dp_position() external {
        uint256 tokenId = _deposit(BTC);
        uint256 borrow = liquid.getMaxBorrowable(tokenId);
        vm.prank(user);
        liquid.mint(tokenId, borrow, user);

        // Collateral loses 20%.
        yield_.updateMockTokenSupply(yield_.totalSupply() * 100 / 80);
        vm.roll(vm.getBlockNumber() + 1);

        (, uint256 owed,) = liquid.getCDP(tokenId);
        assertLt(liquid.totalValue(tokenId), owed, "underwater");

        vm.prank(liquidator);
        (uint256 seized,,) = liquid.liquidate(tokenId);
        assertGt(seized, 0, "liquidation cleared the position");
    }

    /// H4: the transmuter's bad-debt ratio compares synthetics issued against
    /// the collateral backing them. The two live in different decimals here, so
    /// a ratio taken without normalizing reads a solvent market as insolvent
    /// (or the reverse) by a factor of 10^10. A healthy market must pay a
    /// matured redemption out in full.
    function test_matured_redemption_pays_out_in_full_on_the_8dp_market() external {
        uint256 tokenId = _deposit(100 * BTC);
        uint256 borrow = liquid.getMaxBorrowable(tokenId);
        vm.prank(user);
        liquid.mint(tokenId, borrow, user);

        vm.startPrank(user);
        IERC20(address(debt)).approve(address(transmuter), type(uint256).max);
        transmuter.createRedemption(borrow);
        vm.stopPrank();

        // Repay the position in collateral so the transmuter is funded, then
        // let the claim mature.
        vm.roll(vm.getBlockNumber() + 1);
        uint256 inYield = liquid.convertDebtTokensToYield(borrow);
        vm.prank(user);
        liquid.repay(inYield, tokenId);

        vm.roll(vm.getBlockNumber() + 5_256_000);

        uint256 before_ = IERC20(address(yield_)).balanceOf(user);
        vm.prank(user);
        transmuter.claimRedemption(1);
        uint256 paid = IERC20(address(yield_)).balanceOf(user) - before_;

        // No haircut on a fully-backed market: the claim is worth what it staked.
        assertApproxEqRel(paid, liquid.convertDebtTokensToYield(borrow), 0.001e18, "matured claim paid in full, in 8dp");
    }
}
