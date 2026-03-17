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
import {MockLiquidStrategy} from "./mocks/MockLiquidStrategy.sol";
import {MockLiquidCurator} from "./mocks/MockLiquidCurator.sol";
import {LiquidStrategyTestHelper} from "./libraries/LiquidStrategyTestHelper.sol";
import {ILiquidStrategy} from "../interfaces/ILiquidStrategy.sol";

contract LiquidCuratorTest is Test {
    using LiquidStrategyTestHelper for *;

    MockLiquidCurator public liquidCuratorProxy;
    VaultV2 public vault;
    address public operator = address(0x2222222222222222222222222222222222222222); // default operator
    address public admin = address(0x4444444444444444444444444444444444444444); // DAO OSX
    address public mockVaultCollateral = address(new TestERC20(100e18, uint8(18)));
    address public mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
    uint256 public defaultStrategyAbsoluteCap = 200 ether;
    uint256 public defaultStrategyRelativeCap = 1e18; // 100%
    MockLiquidStrategy public liquidStrategy;

    function setUp() public {
        vm.startPrank(admin);
        liquidCuratorProxy = new MockLiquidCurator(admin, operator);
        vault = LiquidStrategyTestHelper._setupVault(mockVaultCollateral, admin, address(liquidCuratorProxy));
        liquidStrategy = LiquidStrategyTestHelper._setupStrategy(address(vault), mockStrategyYieldToken, admin, "MockToken", "MockTokenProtocol", ILiquidStrategy.RiskClass.LOW);
        vm.stopPrank();
    }

    // basic success case tests

    function testSubmitSetStrategy() public {
        vm.startPrank(operator);
        liquidCuratorProxy.submitSetStrategy(address(liquidStrategy), address(vault));
        vm.stopPrank();
    }

    function testSetStrategy() public {
        vm.startPrank(operator);
        liquidCuratorProxy.submitSetStrategy(address(liquidStrategy), address(vault));
        _vaultFastForward(abi.encodeCall(IVaultV2.addAdapter, address(liquidStrategy)));
        liquidCuratorProxy.setStrategy(address(liquidStrategy), address(vault));
        vm.stopPrank();
    }

    function testSubmitDecreaseAbsoluteCap() public {
        _submitAndSetStrategy(address(liquidStrategy), address(vault));
        vm.startPrank(admin);
        liquidCuratorProxy.submitDecreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testSubmitDecreaseRelativeCap() public {
        _submitAndSetStrategy(address(liquidStrategy), address(vault));
        vm.startPrank(admin);
        liquidCuratorProxy.submitDecreaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testDecreaseAbsoluteCap() public {
        _submitAndSetStrategy(address(liquidStrategy), address(vault));
        vm.startPrank(admin);
        liquidCuratorProxy.submitIncreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        _vaultFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (liquidStrategy.getIdData(), defaultStrategyAbsoluteCap)));
        liquidCuratorProxy.increaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        liquidCuratorProxy.submitDecreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap / 2);
        _vaultFastForward(abi.encodeCall(IVaultV2.decreaseAbsoluteCap, (liquidStrategy.getIdData(), defaultStrategyAbsoluteCap / 2)));
        liquidCuratorProxy.decreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap / 2);

        // verify absolute cap has decreased
        assertEq(vault.absoluteCap(ILiquidStrategy(address(liquidStrategy)).adapterId()), defaultStrategyAbsoluteCap / 2);
        vm.stopPrank();
    }

    function testDecreaseRelativeCap() public {
        _submitAndSetStrategy(address(liquidStrategy), address(vault));
        vm.startPrank(admin);
        liquidCuratorProxy.submitIncreaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);
        _vaultFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (liquidStrategy.getIdData(), defaultStrategyRelativeCap)));
        liquidCuratorProxy.increaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);

        liquidCuratorProxy.submitDecreaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap / 2);
        _vaultFastForward(abi.encodeCall(IVaultV2.decreaseRelativeCap, (liquidStrategy.getIdData(), defaultStrategyRelativeCap / 2)));
        liquidCuratorProxy.decreaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap / 2);

        // verify relative cap has decreased
        assertEq(vault.relativeCap(ILiquidStrategy(address(liquidStrategy)).adapterId()), defaultStrategyRelativeCap / 2);
        vm.stopPrank();
    }

    function testSubmitIncreaseAbsoluteCap() public {
        _submitAndSetStrategy(address(liquidStrategy), address(vault));
        vm.startPrank(admin);
        liquidCuratorProxy.submitIncreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testSubmitIncreaseRelativeCap() public {
        _submitAndSetStrategy(address(liquidStrategy), address(vault));
        vm.startPrank(admin);
        liquidCuratorProxy.submitIncreaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testIncreaseAbsoluteCap() public {
        _submitAndSetStrategy(address(liquidStrategy), address(vault));
        vm.startPrank(admin);
        liquidCuratorProxy.submitIncreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        _vaultFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (liquidStrategy.getIdData(), defaultStrategyAbsoluteCap)));
        liquidCuratorProxy.increaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);

        // verify absolute cap has increased
        assertEq(vault.absoluteCap(ILiquidStrategy(address(liquidStrategy)).adapterId()), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testIncreaseRelativeCap() public {
        _submitAndSetStrategy(address(liquidStrategy), address(vault));
        vm.startPrank(admin);
        liquidCuratorProxy.submitIncreaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);
        _vaultFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (liquidStrategy.getIdData(), defaultStrategyRelativeCap)));
        liquidCuratorProxy.increaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);

        // verify relative cap has increased
        assertEq(vault.relativeCap(ILiquidStrategy(address(liquidStrategy)).adapterId()), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    /// access control tests

    function testSubmitDecreaseRelativeCapRevertUnauthorizedAccess() public {
        vm.expectRevert(abi.encode("PD"));
        liquidCuratorProxy.submitDecreaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testDecreaseRelativeCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        liquidCuratorProxy.decreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testSubmitDecreaseAbsoluteCapRevertUnauthorizedAccess() public {
        vm.expectRevert(abi.encode("PD"));
        liquidCuratorProxy.submitDecreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testDecreaseAbsoluteCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        liquidCuratorProxy.decreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testIncreaseAbsoluteCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        liquidCuratorProxy.increaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
    }

    function testIncreaseRelativeCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        liquidCuratorProxy.increaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);
    }

    function testSubmitIncreaseAbsoluteCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        liquidCuratorProxy.submitIncreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
    }

    function testSubmitIncreaseRelativeCapUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        liquidCuratorProxy.submitIncreaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);
    }

    function testTransferAdminOwnerShipUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        liquidCuratorProxy.transferAdminOwnerShip(address(0x4444444444444444444444444444444444444444));
    }

    function testAcceptAdminOwnershipUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        liquidCuratorProxy.acceptAdminOwnership();
    }

    function testSetStrategyUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        liquidCuratorProxy.setStrategy(address(liquidStrategy), address(vault));
    }

    function testSetStrategyInvalidAdapterRevert() public {
        vm.prank(operator);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        liquidCuratorProxy.setStrategy(address(0), address(vault));
    }

    function testSetStrategyInvalidVaultRevert() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        liquidCuratorProxy.setStrategy(address(liquidStrategy), address(0));
        vm.expectRevert();
        liquidCuratorProxy.setStrategy(address(liquidStrategy), address(0x1234567890123456789012345678901234567890));
        vm.stopPrank();
    }

    /// revert on invalid address tests

    function testSubmitIncreaseAbsoluteCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        liquidCuratorProxy.submitIncreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testSubmitIncreaseRelativeCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        liquidCuratorProxy.submitIncreaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testIncreaseAbsoluteCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        liquidCuratorProxy.increaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testSubmitDecreaseAbsoluteCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        liquidCuratorProxy.submitDecreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testIncreaseRelativeCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        liquidCuratorProxy.increaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testSubmitDecreaseRelativeCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        liquidCuratorProxy.submitDecreaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testDecreaseAbsoluteCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        liquidCuratorProxy.decreaseAbsoluteCap(address(liquidStrategy), defaultStrategyAbsoluteCap);
        vm.stopPrank();
    }

    function testDecreaseRelativeCapReverOnInvalidAdapter() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("INVALID_ADDRESS"));
        liquidCuratorProxy.decreaseRelativeCap(address(liquidStrategy), defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    /// helpers

    function _vaultFastForward(bytes memory data) internal {
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }

    function _submitAndSetStrategy(address adapter, address vault) internal {
        vm.startPrank(operator);
        liquidCuratorProxy.submitSetStrategy(adapter, vault);
        _vaultFastForward(abi.encodeCall(IVaultV2.addAdapter, adapter));
        liquidCuratorProxy.setStrategy(adapter, vault);
        vm.stopPrank();
    }
}
