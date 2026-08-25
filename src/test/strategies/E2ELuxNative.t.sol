// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {LuxNativeStrategy, ILiquidLUX} from "../../strategies/LuxNative.sol";
import {ILiquidStrategy} from "../../interfaces/ILiquidStrategy.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {TestERC20} from "../mocks/TestERC20.sol";

// ─── Mock LiquidLUX (xLUX) ────────────────────────────────────────────────
// A simple ERC4626 vault: deposit WLUX, get xLUX shares.
// Protocol fees are simulated by transferring extra WLUX into this vault.
contract MockLiquidLUX is ERC4626 {
    constructor(IERC20 _wlux) ERC4626(_wlux) ERC20("LiquidLUX", "xLUX") {}

    /// @notice Simulate protocol fees arriving (DEX, Bridge, Lending, etc.)
    function simulateFees(uint256 amount) external {
        // Caller must have approved this contract for `amount` of WLUX.
        IERC20(asset()).transferFrom(msg.sender, address(this), amount);
    }
}

// ─── Minimal Mock Vault ────────────────────────────────────────────────────
// Stands in for the Morpho VaultV2. Only the parts LiquidStrategy touches.
contract MockVaultForLux {
    IERC20 public assetToken;

    constructor(IERC20 _asset) {
        assetToken = _asset;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    // allocate() calls strategy.allocate(data, assets, selector, sender)
    // which calls _allocate internally. We simulate the vault calling the strategy.
    function pushToStrategy(address strategy, uint256 amount) external {
        // Transfer WLUX to strategy, then call allocate
        assetToken.transfer(strategy, amount);
        bytes memory data = abi.encode(uint256(0)); // oldAllocation = 0
        LuxNativeStrategy(strategy).allocate(data, amount, bytes4(0), msg.sender);
    }

    // deallocate() calls strategy.deallocate(data, assets, selector, sender)
    function pullFromStrategy(address strategy, uint256 amount, uint256 oldAllocation) external {
        bytes memory data = abi.encode(oldAllocation);
        LuxNativeStrategy(strategy).deallocate(data, amount, bytes4(0), msg.sender);
    }
}

contract E2ELuxNativeTest is Test {
    TestERC20 public wlux;
    MockLiquidLUX public xLUX;
    MockVaultForLux public vault;
    LuxNativeStrategy public strategy;

    address admin = makeAddr("admin");
    address allocator = makeAddr("allocator");
    address user = makeAddr("user");
    address feeSource = makeAddr("feeSource");

    uint256 constant DEPOSIT_AMOUNT = 100e18;
    uint256 constant FEE_AMOUNT = 10e18;

    function setUp() public {
        // 1. Deploy WLUX
        wlux = new TestERC20(0, 18);

        // 2. Deploy xLUX (LiquidLUX vault wrapping WLUX)
        xLUX = new MockLiquidLUX(IERC20(address(wlux)));

        // 3. Deploy mock vault
        vault = new MockVaultForLux(IERC20(address(wlux)));

        // 4. Deploy strategy
        ILiquidStrategy.StrategyParams memory params = ILiquidStrategy.StrategyParams({
            owner: admin,
            name: "LuxNative",
            protocol: "LiquidLUX",
            riskClass: ILiquidStrategy.RiskClass.LOW,
            cap: 1_000_000e18,
            globalCap: 10_000_000e18,
            estimatedYield: 0,
            additionalIncentives: false
        });

        strategy = new LuxNativeStrategy(address(vault), params, address(xLUX));

        // 5. Fund accounts
        wlux.mint(user, 1000e18);
        wlux.mint(address(vault), 1000e18);
        wlux.mint(feeSource, 1000e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: Full L* token lifecycle
    // ═══════════════════════════════════════════════════════════════════════

    function test_fullLStarTokenFlow() public {
        // ── Step 1: User deposits WLUX into vault (mocked: vault has WLUX) ──
        uint256 vaultBalBefore = wlux.balanceOf(address(vault));
        assertGe(vaultBalBefore, DEPOSIT_AMOUNT, "vault should have WLUX");

        // ── Step 2: Allocator deploys WLUX to strategy -> xLUX vault ──
        vault.pushToStrategy(address(strategy), DEPOSIT_AMOUNT);

        // Strategy should now hold xLUX shares
        uint256 xLUXShares = xLUX.balanceOf(address(strategy));
        assertGt(xLUXShares, 0, "strategy should hold xLUX shares");

        // Real assets should equal deposited amount (no yield yet, 1 wei ERC4626 rounding)
        uint256 realBefore = strategy.realAssets();
        assertApproxEqAbs(realBefore, DEPOSIT_AMOUNT, 1, "real assets == deposit before yield");

        // ── Step 3: Take initial yield snapshot ──
        uint256 yieldBefore = strategy.snapshotYield();
        assertEq(yieldBefore, 0, "no yield on first snapshot");

        // ── Step 4: Simulate protocol fees arriving at xLUX vault ──
        vm.startPrank(feeSource);
        wlux.approve(address(xLUX), FEE_AMOUNT);
        xLUX.simulateFees(FEE_AMOUNT);
        vm.stopPrank();

        // xLUX share price should have increased (1 wei rounding tolerance)
        uint256 realAfterFees = strategy.realAssets();
        assertGe(realAfterFees + 1, DEPOSIT_AMOUNT + FEE_AMOUNT, "real assets should increase after fees");

        // ── Step 5: Snapshot yield -- should capture fee income ──
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 yieldCaptured = strategy.snapshotYield();
        assertApproxEqAbs(yieldCaptured, FEE_AMOUNT, 1, "yield should equal fee amount");

        // ── Step 6: Withdraw (deallocate) ──
        // Strategy redeems xLUX shares, sends WLUX back to vault
        uint256 vaultBalBeforeWithdraw = wlux.balanceOf(address(vault));
        vault.pullFromStrategy(address(strategy), DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);

        uint256 vaultBalAfterWithdraw = wlux.balanceOf(address(vault));
        uint256 returned = vaultBalAfterWithdraw - vaultBalBeforeWithdraw;

        // User gets back at least their deposit minus ERC4626 rounding (max 2 wei
        // from two integer divisions: convertToShares and redeem).
        assertApproxEqAbs(returned, DEPOSIT_AMOUNT, 2, "returned ~= deposit amount");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: Multiple fee rounds compound correctly
    // ═══════════════════════════════════════════════════════════════════════

    function test_compoundingFees() public {
        vault.pushToStrategy(address(strategy), DEPOSIT_AMOUNT);
        strategy.snapshotYield(); // baseline

        // Round 1: 5 WLUX fee
        vm.startPrank(feeSource);
        wlux.approve(address(xLUX), 50e18);
        xLUX.simulateFees(5e18);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 yield1 = strategy.snapshotYield();
        assertApproxEqAbs(yield1, 5e18, 1, "round 1 yield == 5");

        // Round 2: another 5 WLUX fee
        vm.startPrank(feeSource);
        xLUX.simulateFees(5e18);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 yield2 = strategy.snapshotYield();
        assertApproxEqAbs(yield2, 5e18, 1, "round 2 yield == 5");

        // Total real assets = deposit + round1 + round2 (1 wei rounding)
        uint256 totalReal = strategy.realAssets();
        assertApproxEqAbs(totalReal, DEPOSIT_AMOUNT + 10e18, 1, "total real = deposit + 10");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: Zero yield when no fees arrive
    // ═══════════════════════════════════════════════════════════════════════

    function test_zeroYieldNoFees() public {
        vault.pushToStrategy(address(strategy), DEPOSIT_AMOUNT);
        strategy.snapshotYield(); // baseline

        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 yield = strategy.snapshotYield();
        assertEq(yield, 0, "no fees means zero yield");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: Constructor rejects zero xLUX address
    // ═══════════════════════════════════════════════════════════════════════

    function test_revertOnZeroXLUX() public {
        ILiquidStrategy.StrategyParams memory params = ILiquidStrategy.StrategyParams({
            owner: admin,
            name: "LuxNative",
            protocol: "LiquidLUX",
            riskClass: ILiquidStrategy.RiskClass.LOW,
            cap: 1_000_000e18,
            globalCap: 10_000_000e18,
            estimatedYield: 0,
            additionalIncentives: false
        });

        vm.expectRevert(LuxNativeStrategy.ZeroXLUXAddress.selector);
        new LuxNativeStrategy(address(vault), params, address(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: realAssets tracks xLUX share value
    // ═══════════════════════════════════════════════════════════════════════

    function test_realAssetsTracksShareValue() public {
        assertEq(strategy.realAssets(), 0, "zero before allocation");

        vault.pushToStrategy(address(strategy), 50e18);
        assertApproxEqAbs(strategy.realAssets(), 50e18, 1, "matches allocation");

        // Add fees
        vm.startPrank(feeSource);
        wlux.approve(address(xLUX), 10e18);
        xLUX.simulateFees(10e18);
        vm.stopPrank();

        assertApproxEqAbs(strategy.realAssets(), 60e18, 1, "includes fees");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: APR tracking via snapshotYield
    // ═══════════════════════════════════════════════════════════════════════

    function test_aprTracking() public {
        vault.pushToStrategy(address(strategy), DEPOSIT_AMOUNT);

        // First snapshot establishes baseline
        strategy.snapshotYield();
        uint256 t0 = block.timestamp;

        // Add 1% fees
        vm.startPrank(feeSource);
        wlux.approve(address(xLUX), 1e18);
        xLUX.simulateFees(1e18);
        vm.stopPrank();

        // Advance 1 day
        vm.warp(t0 + 1 days);
        strategy.snapshotYield();

        // estApr should be non-zero
        assertGt(strategy.estApr(), 0, "APR should be tracked");
        assertGt(strategy.estApy(), 0, "APY should be tracked");
    }
}
