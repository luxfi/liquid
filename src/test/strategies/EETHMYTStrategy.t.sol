// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {EETH} from "../../strategies/EETH.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";

import {EETHMYTStrategy} from "../../strategies/EETH.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {MYTStrategy} from "../../MYTStrategy.sol";
import {AlchemistAllocator} from "../../AlchemistAllocator.sol";

contract MockEETH is EETH, IERC20Metadata {
    string public name = "Mock EETH Token";
    string public symbol = "MEETH";
    uint8 public decimals = 18;
    uint256 public totalSupply = 1e24; // 1 million tokens (1e6 * 1e18)

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        balanceOf[msg.sender] = totalSupply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient");
        require(allowance[from][msg.sender] >= amount, "Not allowed");
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    uint256 public totalDeposited;
    mapping(address => uint256) public balances;

    event WithdrawRequest(address indexed recipient, uint256 amount);
    event Deposit(address indexed sender, uint256 amount);

    function deposit() external payable override returns (uint256) {
        // TODO: use eeth actual implementation
        require(msg.value > 0, "Must deposit some ETH");
        balances[msg.sender] += msg.value;
        totalDeposited += msg.value;
        emit Deposit(msg.sender, msg.value);
        return msg.value; // 1:1 exchange rate for simplicity
    }

    function requestWithdraw(address recipient, uint256 amount) external override returns (uint256) {
        // TODO: implement
        emit WithdrawRequest(recipient, amount);
        return amount;
    }

    // Helper functions for testing
    function getBalance(address account) external view returns (uint256) {
        return balances[account];
    }

    /*function fulfillWithdraw(uint256 requestId) external {
        WithdrawRequest storage request = withdrawRequests[requestId];
        require(!request.fulfilled, "Already fulfilled");
        require(address(this).balance >= request.amount, "Insufficient contract balance");
        
        request.fulfilled = true;
        payable(request.recipient).transfer(request.amount);
    } */

    // Allow contract to receive ETH
    receive() external payable {}
}

contract MockEETHMYTStrategy is EETHMYTStrategy {
    constructor(address _myt, StrategyParams memory _params, address _eeth) EETHMYTStrategy(_myt, _params, _eeth) {}

    function mockUpdateWhitelistedAllocators(address allocator, bool whitelisted) external {
        whitelistedAllocators[allocator] = whitelisted;
    }
}

contract MockAllocator is AlchemistAllocator {
    event MockAllocatorLog(string message, address token);

    constructor(address _vault, address admin, address operator) AlchemistAllocator(_vault, admin, operator) {
        emit MockAllocatorLog("MockAllocator constructor : vault : ", address(_vault));
        emit MockAllocatorLog("MockAllocator constructor : admin : ", admin);
        emit MockAllocatorLog("MockAllocator constructor : operator : ", operator);
    }
}

contract testEETH is Test {
    MockEETH public eeth;
    address public alice = address(0xa11ce11111111111111111111111111111111111);
    address public bob = address(0xB0B0b0B0B0B0B0b0B0B0B0b0b0b0b0B0b0b0B0B0);

    function setUp() public {
        eeth = new MockEETH();

        // Fund test accounts
        vm.deal(alice, 10 ether);
        vm.deal(bob, 5 ether);
        vm.deal(address(eeth), 100 ether); // For withdrawal fulfillment
    }

    function testEETHDeposit() public {
        uint256 depositAmount = 1 ether;

        vm.prank(alice);
        uint256 shares = eeth.deposit{value: depositAmount}();

        assertEq(shares, depositAmount, "Should return 1:1 shares");
        assertEq(eeth.getBalance(alice), depositAmount, "Alice balance should be updated");
        assertEq(eeth.totalDeposited(), depositAmount, "Total deposited should be updated");
    }

    function testEETHRequestWithdraw() public {
        vm.prank(alice);
        eeth.deposit{value: 1 ether}();
        require(eeth.getBalance(alice) == 1 ether, "Alice balance should be 1 ether");
        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true, address(eeth));
        emit MockEETH.WithdrawRequest(address(0), 1 ether); // Expected event
        uint256 requestedAmount = eeth.requestWithdraw(address(0), 1 ether);
        vm.stopPrank();
        assertEq(requestedAmount, 1 ether, "Alice balance should be 0 ether");
    }
}

/*contract testEETHMYTStrategy is Test {
    MockEETHMYTStrategy public mytStrategy;
    MockEETH public eeth;
    MockAllocator public mytAllocator;
    address public alice = address(0xa11ce11111111111111111111111111111111111);
    address public multisig = address(0x1111111111111111111111111111111111111111);
    //address public bob = address(0xB0B0b0B0B0B0B0b0B0B0B0b0b0b0b0B0b0b0B0B0);
    address public immutable WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    VaultV2 public vault;


    event TestLog(string message, address token);


    function setUp() public {
        vm.startPrank(multisig);
        eeth = new MockEETH();
        vault = _setupVault(WETH_ADDRESS, multisig);
        mytStrategy = _setupStrategy(address(vault), address(eeth), multisig, "EETH", "EETH", IMYTStrategy.RiskClass.LOW);

        // set up allocator
        mytAllocator = new MockAllocator(address(vault), address(multisig), address(multisig));

        // Submit the setIsAllocator call (must be done by curator)
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAllocator, (address(mytAllocator), true)));
    
        // Submit the setIsAdapter call (must be done by curator)
        _vaultSubmitAndFastForward(abi.encodeCall(IVaultV2.setIsAdapter, (address(mytStrategy), true)));

        vm.deal(alice, 10 ether);
        vm.deal(address(mytAllocator), 10 ether);

        vm.stopPrank();
    }

    function testAllocateRevertNotWhitelisted() public {
        vm.prank(alice);
        vm.expectRevert();
        mytStrategy.allocate(abi.encode(1), 1 ether, 0x5c9ce04d, address(alice));
        vm.stopPrank();
    }

    function testSetStrategy() public {
        vm.prank(alice);
        mytStrategy.MYT().setIsAllocator(address(mytAllocator), true);
        vm.stopPrank();
    }

    function _vaultSubmitAndFastForward(bytes memory data) internal {
        vault.submit(data);
        bytes4 selector = bytes4(data);
        vm.warp(block.timestamp + vault.timelock(selector));
    }


    function _setupVault(address collateral, address curator) internal returns (VaultV2) {
        // create cault with collateral
        vault = new VaultV2(curator, collateral);
        // set curator 
        vault.setCurator(curator);

        return vault;
    }

    function _setupStrategy(address morphoVault, address yieldToken,address owner, string memory name, string memory protocol, IMYTStrategy.RiskClass riskClass) internal returns (MockEETHMYTStrategy) {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: owner,
            name: name,
            protocol: protocol,
            riskClass: riskClass,
            cap: 100 ether,
            globalCap: 100 ether,
            estimatedYield: 100 ether,
            additionalIncentives: false
        });
        mytStrategy = new MockEETHMYTStrategy(morphoVault, params, yieldToken);
        return mytStrategy;
    }
    
}*/
