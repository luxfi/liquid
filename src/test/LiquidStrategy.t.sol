// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {LiquidStrategy} from "../LiquidStrategy.sol";
import {LiquidAllocator} from "../LiquidAllocator.sol";
import {Liquid} from "../Liquid.sol";
import {LiquidInitializationParams} from "../interfaces/ILiquid.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidStrategy} from "../interfaces/ILiquidStrategy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {LiquidPosition} from "../LiquidPosition.sol";
import {LiquidTransmuter} from "../LiquidTransmuter.sol";
import {LiquidMintableToken} from "../test/mocks/LiquidMintableToken.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TokenAdapterMock} from "./mocks/TokenAdapterMock.sol";
import {ILiquidErrors, LiquidInitializationParams} from "../interfaces/ILiquid.sol";
import {ILiquidTransmuter} from "../interfaces/ILiquidTransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "../base/Errors.sol";
import {LiquidNFTHelper} from "./libraries/LiquidNFTHelper.sol";
import {ILiquidPosition} from "../interfaces/ILiquidPosition.sol";
import {AggregatorV3Interface} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {LiquidTokenVault} from "../LiquidTokenVault.sol";
import {VaultV2Factory} from "../../lib/vault-v2/src/VaultV2Factory.sol";

contract LiquidStrategyTest is Test {
    using SafeERC20 for IERC20;

    // Addresses
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address whitelistedAllocator = makeAddr("whitelistedAllocator");
    address nonWhitelisted = makeAddr("nonWhitelisted");
    address alOwner = makeAddr("alOwner");
    address proxyOwner = makeAddr("proxyOwner");

    // Tokens
    TestERC20 public fakeUnderlyingToken;
    IVaultV2 public yieldToken;
    LiquidMintableToken public alToken;

    // Contracts
    Liquid public liquid;
    IVaultV2 public vault;
    LiquidStrategy public strategy;
    LiquidAllocator public allocator;
    LiquidTransmuter public transmuter;
    LiquidPosition public liquidNFT;
    Whitelist public whitelist;
    VaultV2Factory public vaultFactory;

    // Strategy parameters
    ILiquidStrategy.StrategyParams public strategyParams = ILiquidStrategy.StrategyParams({
        owner: admin,
        name: "Test Strategy",
        protocol: "Test Protocol",
        riskClass: ILiquidStrategy.RiskClass.LOW,
        cap: 1000e18,
        globalCap: 5000e18,
        estimatedYield: 100e18,
        additionalIncentives: false
    });

    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    uint256 public constant BPS = 10_000;

    function setUp() public {
        deployCoreContracts(18);
    }

    function deployCoreContracts(uint256 liquidUnderlyingTokenDecimals) public {
        vm.startPrank(alOwner);

        // Fake tokens
        fakeUnderlyingToken = new TestERC20(100e18, uint8(liquidUnderlyingTokenDecimals));

        vaultFactory = new VaultV2Factory();
        yieldToken = IVaultV2(vaultFactory.createVaultV2(address(proxyOwner), address(fakeUnderlyingToken), bytes32("salt")));

        alToken = new LiquidMintableToken("Liquid Mintable Token", "AL", 0);

        ILiquidTransmuter.TransmuterInitializationParams memory transParams = ILiquidTransmuter.TransmuterInitializationParams({
            syntheticToken: address(alToken), feeReceiver: address(this), timeToTransmute: 5_256_000, transmutationFee: 10, exitFee: 20, graphSize: 52_560_000
        });

        // Contracts and logic contracts
        transmuter = new LiquidTransmuter(transParams);
        Liquid liquidLogic = new Liquid();
        whitelist = new Whitelist();

        // Liquid proxy
        LiquidInitializationParams memory params = LiquidInitializationParams({
            admin: alOwner,
            debtToken: address(alToken),
            underlyingToken: address(fakeUnderlyingToken),
            yieldToken: address(yieldToken),
            blocksPerYear: 2_600_000,
            depositCap: type(uint256).max,
            minimumCollateralization: 150e18,
            collateralizationLowerBound: 110e18,
            globalMinimumCollateralization: 150e18,
            tokenAdapter: address(yieldToken),
            transmuter: address(transmuter),
            protocolFee: 50,
            protocolFeeReceiver: admin,
            liquidatorFee: 100,
            repaymentFee: 50
        });

        bytes memory alchemParams = abi.encodeWithSelector(Liquid.initialize.selector, params);
        TransparentUpgradeableProxy proxyLiquid = new TransparentUpgradeableProxy(address(liquidLogic), proxyOwner, alchemParams);
        liquid = Liquid(address(proxyLiquid));

        // Whitelist liquid proxy for minting tokens
        alToken.setWhitelist(address(proxyLiquid), true);

        whitelist.add(address(0xbeef));
        whitelist.add(user);

        transmuter.setLiquid(address(liquid));
        transmuter.setDepositCap(uint256(type(int256).max));

        liquidNFT = new LiquidPosition(address(liquid));
        liquid.setLiquidPositionNFT(address(liquidNFT));

        liquid.setLiquidFeeVault(address(yieldToken));
        vm.stopPrank();

        // Add funds to test accounts
        deal(address(yieldToken), address(0xbeef), 1000e18);
        deal(address(yieldToken), user, 1000e18);
        deal(address(alToken), address(0xdad), 1000e18);
        deal(address(alToken), user, 1000e18);

        deal(address(fakeUnderlyingToken), address(0xbeef), 1000e18);
        deal(address(fakeUnderlyingToken), user, 1000e18);
        deal(address(fakeUnderlyingToken), liquid.liquidFeeVault(), 10_000 ether);

        vm.startPrank(user);
        IERC20(fakeUnderlyingToken).approve(address(yieldToken), 1000e18);
        vm.stopPrank();

        // Create vault (mock)
        vault = IVaultV2(address(new MockVault(IERC20(address(fakeUnderlyingToken)), IERC20(address(yieldToken)))));

        // Create strategy
        strategy = new LiquidStrategy(address(vault), strategyParams);

        // Create allocator
        allocator = new LiquidAllocator(address(vault), admin, operator);

        // Whitelist allocator for strategy
        vm.prank(admin);
        strategy.setWhitelistedAllocator(address(allocator), true);
    }
    /*
    // Test that only whitelisted allocators can call allocate
    function test_onlyWhitelistedAllocatorCanAllocate() public {
        // Non-whitelisted address should fail
        vm.expectRevert(bytes("PD"));
        strategy.allocate(100e18);

        // Whitelisted allocator should succeed
        vm.prank(address(allocator));
        strategy.allocate(100e18);
    }

    // Test that only whitelisted allocators can call deallocate
    function test_onlyWhitelistedAllocatorCanDeallocate() public {
        // Non-whitelisted address should fail
        vm.expectRevert(bytes("PD"));
        strategy.deallocate(100e18);

        // Whitelisted allocator should succeed
        vm.prank(address(allocator));
        strategy.deallocate(50e18);
    }

    // Test that allocator can allocate and deallocate
    function test_allocatorCanAllocateAndDeallocate() public {
        // Allocator allocates
        vm.prank(address(allocator));
        strategy.allocate(100e18);

        // Allocator deallocates
        vm.prank(address(allocator));
        strategy.deallocate(50e18);
    }

    // Test that strategy kill switch works
    function test_killSwitchPreventsAllocation() public {
        // Enable kill switch
        vm.prank(admin);
        strategy.setKillSwitch(true);

        // Allocator should fail to allocate
        vm.prank(address(allocator));
        vm.expectRevert(bytes("emergency"));
        strategy.allocate(100e18);

        // Disable kill switch
        vm.prank(admin);
        strategy.setKillSwitch(false);

        // Allocator should succeed
        vm.prank(address(allocator));
        strategy.allocate(100e18);
    }

    // Test that strategy parameters can be updated
    function test_strategyParametersCanBeUpdated() public {
        // Update risk class
        vm.prank(admin);
        strategy.setRiskClass(ILiquidStrategy.RiskClass.HIGH);

        // Update incentives
        vm.prank(admin);
        strategy.setAdditionalIncentives(true);

        // Verify updates
        (, , , ILiquidStrategy.RiskClass riskClass, , , , bool additionalIncentives) = strategy.params();
        assertEq(uint8(riskClass), uint8(ILiquidStrategy.RiskClass.HIGH));
        assertEq(additionalIncentives, true);
    }

    // Test that strategy can interact with Liquid system properly
    function test_strategyIntegrationWithLiquid() public {
        // User deposits into yield token vault first
        vm.prank(user);
        yieldToken.deposit(100e18, user);

        // User approves yield token for Liquid
        vm.prank(user);
        yieldToken.approve(address(liquid), 100e18);

        // User deposits into Liquid
        vm.prank(user);
        liquid.deposit(10e18, user, 0);

        // Verify that allocator was called to allocate
        console.log("Deposit completed - allocation should have been triggered");
    }

    // Test that strategy respects Liquid pause states
    function test_strategyRespectsLiquidPauseStates() public {
        // Pause Liquid deposits
        vm.prank(alOwner);
        liquid.pauseDeposits(true);

        // User should not be able to deposit
        vm.prank(user);
        yieldToken.approve(address(liquid), 100e18);
        vm.expectRevert(IllegalState.selector);
        liquid.deposit(100e18, user, 0);

        // Unpause deposits
        vm.prank(alOwner);
        liquid.pauseDeposits(false);

        // Now deposit should work
        vm.startPrank(user);
        yieldToken.approve(address(liquid), 100e18);
        liquid.deposit(10e18, user, 0);
        vm.stopPrank();
    } */
}

// Mock vault implementation
contract MockVault is ERC4626 {
    constructor(IERC20 asset_, IERC20 yieldToken_) ERC4626(asset_) ERC20("Mock Vault", "MV") {}

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return shares; // 1:1 conversion for simplicity
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return assets; // 1:1 conversion for simplicity
    }

    function inflate(uint256 amount) public {
        ERC20Mock(asset()).mint(address(this), amount);
    }
}

// Mock NFT implementation
contract MockNFT {
    function mint(address to) external returns (uint256) {
        return 1; // Always return token ID 1
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return address(0x123); // Mock owner
    }
}
