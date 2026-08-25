// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaultV2} from "../../lib/vault-v2/src/VaultV2.sol";
import {ERC20Mock} from "../../lib/vault-v2/test/mocks/ERC20Mock.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {MockYieldToken} from "./mocks/MockYieldToken.sol";
import {IMockYieldToken} from "./mocks/MockYieldToken.sol";
import {LiquidStrategyTestHelper} from "./libraries/LiquidStrategyTestHelper.sol";
import {MockLiquidStrategy} from "./mocks/MockLiquidStrategy.sol";
import {LiquidAllocator} from "../LiquidAllocator.sol";
import {ILiquidAllocator} from "../interfaces/ILiquidAllocator.sol";
import {ILiquidStrategy} from "../interfaces/ILiquidStrategy.sol";

contract MockLiquidAllocator is LiquidAllocator {
    constructor(address _vault, address _admin, address _operator) LiquidAllocator(_vault, _admin, _operator) {}
}

contract LiquidAllocatorTest is Test {
    using LiquidStrategyTestHelper for *;

    MockLiquidAllocator public allocator;
    VaultV2 public vault;
    address public admin = address(0x2222222222222222222222222222222222222222);
    address public operator = address(0x3333333333333333333333333333333333333333);
    address public curator = address(0x8888888888888888888888888888888888888888);
    address public user1 = address(0x5555555555555555555555555555555555555555);
    address public mockVaultCollateral = address(new TestERC20(100e18, uint8(18)));
    address public mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
    uint256 public defaultStrategyAbsoluteCap = 200 ether;
    uint256 public defaultStrategyRelativeCap = 1e18; // 100%
    MockLiquidStrategy public liquidStrategy;

    function setUp() public {
        vm.startPrank(admin);
        vault = LiquidStrategyTestHelper._setupVault(mockVaultCollateral, admin, curator);
        liquidStrategy = LiquidStrategyTestHelper._setupStrategy(
            address(vault), mockStrategyYieldToken, admin, "MockToken", "MockTokenProtocol", ILiquidStrategy.RiskClass.LOW
        );
        allocator = new MockLiquidAllocator(address(vault), admin, operator);
        vm.stopPrank();
        vm.startPrank(curator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        vault.setIsAllocator(address(allocator), true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.addAdapter, address(liquidStrategy)));
        vault.addAdapter(address(liquidStrategy));
        // bytes memory idData = abi.encode("MockTokenProtocol", address(liquidStrategy));
        bytes memory idData = liquidStrategy.getIdData();
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, defaultStrategyAbsoluteCap)));
        vault.increaseAbsoluteCap(idData, defaultStrategyAbsoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, defaultStrategyRelativeCap)));
        vault.increaseRelativeCap(idData, defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testAllocateUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        allocator.allocate(address(0x4444444444444444444444444444444444444444), 0);
    }

    function testDeallocateUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        allocator.deallocate(address(0x4444444444444444444444444444444444444444), 0);
    }

    function testAllocateRevertIfInssufficientVaultBalance() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("TransferReverted()"));
        allocator.allocate(address(liquidStrategy), 100);
        vm.stopPrank();
    }

    function testAllocate() public {
        require(vault.adaptersLength() == 1, "adaptersLength is must be 1");
        _magicDepositToVault(address(vault), user1, 150 ether);
        vm.startPrank(admin);
        bytes32 allocationId = liquidStrategy.adapterId();
        allocator.allocate(address(liquidStrategy), 100 ether);
        uint256 liquidStrategyYieldTokenBalance = IMockYieldToken(mockStrategyYieldToken).balanceOf(address(liquidStrategy));
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = vault.accrueInterestView();
        uint256 liquidStrategyYieldTokenRealAssets = liquidStrategy.realAssets();

        // verify all state state changes that happen after an allocation
        assertEq(liquidStrategyYieldTokenBalance, 100 ether);
        assertEq(liquidStrategyYieldTokenRealAssets, 100 ether);
        assertEq(newTotalAssets, 150 ether);
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertEq(vault._totalAssets(), 150 ether);
        assertEq(vault.firstTotalAssets(), 150 ether);
        assertEq(vault.allocation(allocationId), 100 ether);
        vm.stopPrank();
    }

    function testDeallocate() public {
        _magicDepositToVault(address(vault), user1, 150 ether);
        vm.startPrank(admin);
        allocator.allocate(address(liquidStrategy), 100 ether);
        bytes32 allocationId = liquidStrategy.adapterId();
        uint256 allocation = vault.allocation(allocationId);
        require(allocation == 100 ether);
        allocator.deallocate(address(liquidStrategy), 50 ether);
        allocation = vault.allocation(allocationId);
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = vault.accrueInterestView();
        uint256 liquidStrategyYieldTokenBalance = IMockYieldToken(mockStrategyYieldToken).balanceOf(address(liquidStrategy));
        uint256 liquidStrategyYieldTokenRealAssets = liquidStrategy.realAssets();

        // verify all state state changes that happen after a deallocation
        assertEq(liquidStrategyYieldTokenBalance, 50 ether);
        assertEq(liquidStrategyYieldTokenRealAssets, 50 ether);
        assertEq(newTotalAssets, 150 ether);
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertEq(vault._totalAssets(), 150 ether);
        assertEq(vault.firstTotalAssets(), 150 ether);
        assertEq(allocation, 50 ether);
        vm.stopPrank();
    }

    function _magicDepositToVault(address vault, address depositor, uint256 amount) internal {
        deal(address(mockVaultCollateral), address(depositor), amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(address(mockVaultCollateral), vault, amount);
        IVaultV2(vault).deposit(amount, vault);
        vm.stopPrank();
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(vm.getBlockTimestamp() + vault.timelock(selector));
    }
}
