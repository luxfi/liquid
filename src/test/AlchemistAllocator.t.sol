// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTAllocator} from "../MYTAllocator.sol";
import {Test} from "forge-std/Test.sol";
import {VaultV2} from "../../lib/vault-v2/src/VaultV2.sol";
import {ERC20Mock} from "../../lib/vault-v2/test/mocks/ERC20Mock.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {MYTAdapter} from "../MYTAdapter.sol";
import {IMYTVault} from "../interfaces/IMYTVault.sol";
import {IMYTAdapter} from "../MYTAdapter.sol";
import {MYTVault} from "../MYTVault.sol";

interface IMockYieldToken {
    function deposit(uint256 amount) external returns (uint256);
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256);
    function mockedSupply() external view returns (uint256);
    function underlyingToken() external view returns (address);
    function mint(uint256 amount, address recipient) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function price() external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract MockYieldToken is TestYieldToken {
    constructor(address _underlyingToken) TestYieldToken(_underlyingToken) {}

    // for non eth based depositdeposits
    function deposit(uint256 amount) external returns (uint256) {
        require(amount > 0);
        uint256 shares = _issueSharesForAmount(msg.sender, amount);
        TokenUtils.safeTransferFrom(underlyingToken, msg.sender, address(this), amount);
        return shares;
    }

    function requestWithdraw(address recipient, uint256 amount) external returns (uint256) {
        return amount;
    }
}

contract MockETHMYTStrategy is MYTAdapter {
    event TestLogger(string message, uint256 value);
    event TestLoggerAddress(string message, address value);

    IMockYieldToken public immutable token;

    constructor(address _myt, address _token, IMYTAdapter.StrategyParams memory _params) MYTAdapter(_myt, _token, _params) {
        token = IMockYieldToken(_token);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        // if native eth used, most strats will have theor own function to wrap eth to weth
        // so will assume that all token deposits are done with weth
        TokenUtils.safeApprove(token.underlyingToken(), address(token), 2 * amount);
        depositReturn = token.deposit(amount);
        require(depositReturn == amount);
    }

    function _deallocate(uint256 amount) internal override returns (uint256 amountRequested) {
        amountRequested = token.requestWithdraw(msg.sender, amount);
        require(amountRequested != 0);
    }

    function snapshotYield() external override returns (uint256) {
        // TODO calculate & snapshot yield
    }

    function realAssets() external view override returns (uint256) {
        return (token.balanceOf(address(this)) * token.price()) / 10 ** token.decimals();
    }

    function mockUpdateWhitelistedAllocators(address allocator, bool value) public {}
}

contract MockAlchemistAllocator is MYTAllocator {
    constructor(address _myt, address _admin, address _operator) MYTAllocator(_myt, _admin, _operator) {}
}

contract MockMYTVault is MYTVault {
    constructor(address _vault) MYTVault(_vault) {}
}

contract AlchemistAllocatorTest is Test {
    MockAlchemistAllocator public allocator;
    MockMYTVault public mytVault;
    VaultV2 public vault;
    address public admin = address(0x2222222222222222222222222222222222222222);
    address public operator = address(0x3333333333333333333333333333333333333333);
    address public user1 = address(0x5555555555555555555555555555555555555555);
    address public mockVaultCollateral = address(new TestERC20(100e18, uint8(18)));
    address public mockStrategyYieldToken = address(new MockYieldToken(mockVaultCollateral));
    uint256 public defaultStrategyAbsoluteCap = 200 ether;
    uint256 public defaultStrategyRelativeCap = 1e18; // 100%
    MockETHMYTStrategy public mytStrategy;

    event MockETHMYTStrategyLogBool(string message, bool value);
    event AlchemistAllocatorTestLog(string message, uint256 value);
    event AlchemistAllocatorTestLogBytes32(string message, bytes32 value);

    function setUp() public {
        vm.startPrank(admin);
        vault = _setupVault(mockVaultCollateral, admin);
        mytVault = _setupMYTVault(address(vault));
        mytStrategy = _setupStrategy(address(mytVault), address(mockStrategyYieldToken), admin, "MockToken", "MockTokenProtocol", IMYTAdapter.RiskClass.LOW);
        allocator = new MockAlchemistAllocator(address(mytVault.MYT()), admin, operator);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        vault.setIsAllocator(address(allocator), true);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAdapter, (address(mytStrategy), true)));
        vault.setIsAdapter(address(mytStrategy), true);
        mytVault.setWhitelistedAllocator(address(allocator), true);
        bytes memory idData = abi.encode("MytStrategy", address(mytStrategy));
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, defaultStrategyAbsoluteCap)));
        vault.increaseAbsoluteCap(idData, defaultStrategyAbsoluteCap);
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, defaultStrategyRelativeCap)));
        vault.increaseRelativeCap(idData, defaultStrategyRelativeCap);
        vm.stopPrank();
    }

    function testAllocateUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        allocator.allocate(0, address(0x4444444444444444444444444444444444444444), "", 0);
    }

    function testDeallocateUnauthorizedAccessRevert() public {
        vm.expectRevert(abi.encode("PD"));
        allocator.deallocate(0, address(0x4444444444444444444444444444444444444444), "", 0);
    }

    function testAllocateRevertIfInssufficientVaultBalance() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encode("TransferReverted()"));
        allocator.allocate(0, address(mytStrategy), "", 100);
        vm.stopPrank();
    }

    function testAllocate() public {
        _magicDepositToVault(user1, 150 ether);
        vm.startPrank(admin);
        bytes32 allocationId = mytStrategy.adapterId();
        uint256 absoluteCap = vault.absoluteCap(allocationId);
        allocator.allocate(0, address(mytStrategy), "", 100 ether);
        uint256 mytStrategyYieldTokenBalance = IMockYieldToken(mockStrategyYieldToken).balanceOf(address(mytStrategy));
        uint256 mytStrategyYieldTokenRealAssets = mytStrategy.realAssets();
        uint256 adaptersLength = vault.adaptersLength();
        require(adaptersLength == 1, "adaptersLength is must be 1");
        assertEq(mytStrategyYieldTokenBalance, 100 ether);
        assertEq(mytStrategyYieldTokenRealAssets, 100 ether);
        (uint256 newTotalAssets, uint256 performanceFeeShares, uint256 managementFeeShares) = vault.accrueInterestView();
        assertEq(newTotalAssets, 150 ether);
        assertEq(performanceFeeShares, 0);
        assertEq(managementFeeShares, 0);
        assertEq(vault._totalAssets(), 150 ether);
        assertEq(vault.firstTotalAssets(), 150 ether);
        vm.stopPrank();
    }
    /* 
    function testDeallocate() public {
        vm.startPrank(admin);
        allocator.deallocate(0, address(mytStrategy), "", 100 ether);
        vm.stopPrank();
    }
    */

    function _setupVault(address collateral, address curator) internal returns (VaultV2) {
        // create cault with collateral
        vault = new VaultV2(curator, collateral);
        // set curator
        vault.setCurator(curator);

        return vault;
    }

    function _setupStrategy(address myt, address yieldToken, address owner, string memory name, string memory protocol, IMYTAdapter.RiskClass riskClass)
        internal
        returns (MockETHMYTStrategy)
    {
        IMYTAdapter.StrategyParams memory params = IMYTAdapter.StrategyParams({
            owner: owner,
            name: name,
            protocol: protocol,
            riskClass: riskClass,
            cap: 100 ether,
            globalCap: 100 ether,
            estimatedYield: 100 ether,
            additionalIncentives: false
        });
        mytStrategy = new MockETHMYTStrategy(myt, yieldToken, params);
        return mytStrategy;
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }

    function _setupMYTVault(address morphoV2Vault) internal returns (MockMYTVault) {
        return new MockMYTVault(morphoV2Vault);
    }

    function _magicDepositToVault(address depositor, uint256 amount) internal {
        deal(address(mockVaultCollateral), address(depositor), amount);
        vm.startPrank(depositor);
        TokenUtils.safeApprove(address(mockVaultCollateral), address(vault), amount);
        vault.deposit(amount, address(vault));
        vm.stopPrank();
    }
}
