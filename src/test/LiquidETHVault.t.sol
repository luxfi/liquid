// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {TransparentUpgradeableProxy} from "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {Test} from "../../lib/forge-std/src/Test.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {Liquid} from "../Liquid.sol";
import {LiquidMintableToken} from "../test/mocks/LiquidMintableToken.sol";
import {LiquidTransmuter} from "../LiquidTransmuter.sol";
import {LiquidPosition} from "../LiquidPosition.sol";

import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TokenAdapterMock} from "./mocks/TokenAdapterMock.sol";
import {ILiquid, ILiquidErrors, LiquidInitializationParams} from "../interfaces/ILiquid.sol";
import {ILiquidTransmuter} from "../interfaces/ILiquidTransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "../base/Errors.sol";
import {LiquidNFTHelper} from "./libraries/LiquidNFTHelper.sol";
import {ILiquidPosition} from "../interfaces/ILiquidPosition.sol";
import {LiquidETHVault} from "../LiquidETHVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";

import {VmSafe} from "../../lib/forge-std/src/Vm.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {AbstractFeeVault} from "../adapters/AbstractFeeVault.sol";

/// @dev Minimal WETH mock for local testing (no mainnet fork required)
contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }

    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract LiquidETHVaultTest is Test {
    LiquidETHVault public ethVault;
    address public owner = address(1);
    address public liquid = address(2);
    address public user = address(3);
    address public otherUser = address(4);
    address public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // mainnent weth example

    uint256 public constant AMOUNT = 100 * 10 ** 18;

    function setUp() external {
        // Deploy a mock WETH and etch it at the mainnet WETH address so tests
        // work without a mainnet fork.
        MockWETH mockWeth = new MockWETH();
        vm.etch(weth, address(mockWeth).code);

        // Deploy vault
        vm.prank(owner);
        ethVault = new LiquidETHVault(address(weth), liquid, owner);
    }

    // === CONSTRUCTOR TESTS ===
    function testConstructor() public view {
        assertEq(ethVault.token(), weth);
        assertEq(ethVault.authorized(address(liquid)), true);
    }

    function testConstructorZeroAddressReverts() public {
        vm.expectRevert(AbstractFeeVault.ZeroAddress.selector);
        new LiquidETHVault(address(0), address(liquid), owner);
    }

    function testDeposit() public {
        uint256 amount = 1 ether;
        uint256 startingAmount = 10 ether;
        // Give some ETH to the external user
        vm.deal(user, startingAmount);
        uint256 initialBalance = address(user).balance;
        vm.startPrank(user);

        // Deposit ETH
        ethVault.deposit{value: amount}();

        // Verify the user's ETH balance decreased
        assertEq(address(user).balance, initialBalance - amount);
        assertEq(ethVault.totalDeposits(), amount);
        vm.stopPrank();
    }

    function testSendETHRawCall() public {
        uint256 amount = 1 ether;
        uint256 startingAmount = 10 ether;
        // Give some ETH to the external user
        vm.deal(user, startingAmount);
        uint256 initialBalance = address(user).balance;
        vm.startPrank(user);

        // Deposit ETH to ethVault instead of back to self
        (bool success,) = address(ethVault).call{value: amount}("");
        assertTrue(success, "ETH transfer failed");

        vm.stopPrank();

        // Verify the user's ETH balance decreased
        assertEq(address(user).balance, initialBalance - amount);
        // Verify the vault received the ETH
        assertEq(ethVault.totalDeposits(), amount);

        vm.stopPrank();
    }

    function testWithdrawETH() public {
        uint256 amount = 2 ether;
        uint256 initialBalance = address(user).balance;

        vm.startPrank(otherUser);

        // Give some ETH to the external user
        vm.deal(otherUser, 10 ether);
        // Deposit ETH
        (bool success,) = address(ethVault).call{value: amount}("");
        assertTrue(success, "ETH transfer failed");

        vm.stopPrank();

        // Set up the vault with some ETH
        vm.deal(address(ethVault), amount);

        // Verify the user's ETH balance decreased
        assertEq(ethVault.totalDeposits(), amount);

        vm.startPrank(address(liquid));

        // Withdraw ETH
        ethVault.withdraw(user, amount / 2);

        // Verify the user's ETH balance increased
        assertEq(address(user).balance, initialBalance + amount / 2);

        vm.stopPrank();
    }

    function testWithdrawETHRevertsUnauthorized() public {
        uint256 withdrawAmount = 1 ether;
        // Set up the vault with some ETH
        vm.deal(address(ethVault), withdrawAmount);

        vm.startPrank(user);

        vm.expectRevert();
        // Withdraw ETH
        ethVault.withdraw(user, withdrawAmount);

        vm.stopPrank();
    }

    function testOnlyOwnerFunctions() public {
        // Test setting a new liquid address
        address newLiquid = address(0x123);

        // Non-owner tries to call an owner-only function
        vm.startPrank(user);
        vm.expectRevert();
        ethVault.setAuthorization(newLiquid, true);
        vm.stopPrank();

        // Owner calls the same function
        vm.startPrank(owner);
        ethVault.setAuthorization(newLiquid, true);
        assertEq(ethVault.authorized(newLiquid), true);
        vm.stopPrank();
    }

    function testDepositETHWithZeroAmountReverts() public {
        vm.startPrank(user);
        vm.expectRevert();
        ethVault.depositWETH(0);
        vm.stopPrank();
    }

    function testETHReceivedViaCallback() public {
        uint256 amount = 1 ether;

        // Give ETH to the test contract
        vm.deal(address(this), amount);

        // Mock a callback from the liquid (e.g., after withdrawing WETH)
        // First, ensure the vault has no ETH
        assertEq(ethVault.totalDeposits(), 0);

        // Send ETH to the vault as if it's a callback
        (bool success,) = address(ethVault).call{value: amount}("");
        assertTrue(success, "ETH transfer failed");

        // Verify the vault received the ETH
        assertEq(ethVault.totalDeposits(), amount);
    }

    function testDepositWETH() public {
        uint256 amount = 1 ether;
        uint256 startingAmount = 10 ether;
        // Give some ETH to the external user
        vm.deal(user, startingAmount);
        uint256 initialBalance = address(user).balance;

        vm.startPrank(user);
        IWETH(weth).deposit{value: amount}();
        IERC20(weth).approve(address(ethVault), amount);

        // Expect the correct event with the right parameters
        vm.expectEmit(true, true, true, true);
        emit AbstractFeeVault.Deposited(user, amount);

        // Start recording logs to count events
        vm.recordLogs();

        // Make the deposit
        ethVault.depositWETH(amount);

        // Get logs and count Deposited events
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bytes32 depositedEventSignature = keccak256("Deposited(address,uint256)");

        uint256 eventCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == depositedEventSignature) {
                eventCount++;
            }
        }

        assertEq(address(user).balance, initialBalance - amount);
        assertEq(ethVault.totalDeposits(), amount);

        // Verify only one event was emitted
        assertEq(eventCount, 1, "Deposited event should be emitted exactly once");

        vm.stopPrank();
    }
}
