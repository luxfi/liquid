// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LiquidStrategy} from "../LiquidStrategy.sol";
import {LiquidAllocator} from "../LiquidAllocator.sol";
import {Liquid} from "../Liquid.sol";
import {LiquidInitializationParams} from "../interfaces/ILiquid.sol";
import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILiquidStrategy} from "../interfaces/ILiquidStrategy.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {LiquidPosition} from "../LiquidPosition.sol";
import {LiquidTransmuter} from "../LiquidTransmuter.sol";
import {LiquidMintableToken} from "../test/mocks/LiquidMintableToken.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {ILiquidTransmuter} from "../interfaces/ILiquidTransmuter.sol";
import {IllegalState} from "../base/Errors.sol";
import {LiquidNFTHelper} from "./libraries/LiquidNFTHelper.sol";
import {LiquidTokenVault} from "../LiquidTokenVault.sol";
import {VaultV2Factory} from "../../lib/vault-v2/src/VaultV2Factory.sol";

contract LiquidStrategyTest is Test {
    // Addresses
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address nonWhitelisted = makeAddr("nonWhitelisted");
    address alOwner = makeAddr("alOwner");
    address proxyOwner = makeAddr("proxyOwner");

    // Tokens
    TestERC20 public fakeUnderlyingToken;
    TestYieldToken public fakeYieldToken;
    LiquidMintableToken public alToken;

    // Contracts
    Liquid public liquid;
    IVaultV2 public vault;
    LiquidStrategy public strategy;
    LiquidAllocator public allocator;
    LiquidTransmuter public transmuter;
    LiquidPosition public liquidNFT;
    LiquidTokenVault public feeVault;
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

    /// Seeded into the vault so it has something real to hand a strategy.
    uint256 constant VAULT_SEED = 1000e18;
    uint256 constant VAULT_CAP = 1000e18;
    uint256 constant ALLOCATION = 100e18;
    uint256 constant DEPOSIT = 10e18;

    /// The revert a caller outside the whitelist gets from {deallocateDex}.
    bytes constant PD = abi.encodeWithSignature("Error(string)", "PD");
    /// The revert a caller other than the vault gets from allocate/deallocate.
    bytes constant NOT_VAULT = abi.encodeWithSignature("Error(string)", "Only vault can call this function");

    function setUp() public {
        deployCoreContracts(18);
    }

    function deployCoreContracts(uint256 liquidUnderlyingTokenDecimals) public {
        vm.startPrank(alOwner);

        // Fake tokens. The yield token is its own token adapter, which is what
        // Liquid binds: it wants price/token/underlyingToken, none of which a
        // vault answers.
        fakeUnderlyingToken = new TestERC20(100e18, uint8(liquidUnderlyingTokenDecimals));
        fakeYieldToken = new TestYieldToken(address(fakeUnderlyingToken));
        alToken = new LiquidMintableToken("Liquid Mintable Token", "AL", 0);

        ILiquidTransmuter.TransmuterInitializationParams memory transParams = ILiquidTransmuter.TransmuterInitializationParams({
            syntheticToken: address(alToken), feeReceiver: address(this), timeToTransmute: 5_256_000, transmutationFee: 10, exitFee: 20, graphSize: 52_560_000
        });

        // Contracts and logic contracts
        transmuter = new LiquidTransmuter(transParams);
        Liquid liquidLogic = new Liquid();

        // Liquid proxy
        LiquidInitializationParams memory params = LiquidInitializationParams({
            admin: alOwner,
            debtToken: address(alToken),
            underlyingToken: address(fakeUnderlyingToken),
            yieldToken: address(fakeYieldToken),
            blocksPerYear: 2_600_000,
            depositCap: type(uint256).max,
            minimumCollateralization: 150e18,
            collateralizationLowerBound: 110e18,
            globalMinimumCollateralization: 150e18,
            tokenAdapter: address(fakeYieldToken),
            maxPriceDeviation: 1e18,
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

        transmuter.setLiquid(address(liquid));
        transmuter.setDepositCap(uint256(type(int256).max));

        liquidNFT = new LiquidPosition(address(liquid));
        liquid.setLiquidPositionNFT(address(liquidNFT));

        feeVault = new LiquidTokenVault(address(fakeUnderlyingToken), address(liquid), alOwner);
        feeVault.setAuthorization(address(liquid), true);
        liquid.setLiquidFeeVault(address(feeVault));
        vm.stopPrank();

        // Add funds to test accounts
        fakeUnderlyingToken.mint(user, VAULT_SEED * 2);
        fakeUnderlyingToken.mint(liquid.liquidFeeVault(), 10_000 ether);

        deployVault();
    }

    /// The strategy and the allocator both speak to a real VaultV2: the
    /// allocator reads caps and allocation off it, and the strategy only
    /// accepts allocate/deallocate from it.
    function deployVault() internal {
        vaultFactory = new VaultV2Factory();
        vault = IVaultV2(vaultFactory.createVaultV2(admin, address(fakeUnderlyingToken), bytes32("strategy-vault")));

        // A strategy that reports what it moved. The base class cannot be
        // deployed any more, and could not have been trusted here anyway: its
        // allocation hooks are empty, so every assertion about what the vault
        // booked was reading the zero they return rather than anything the
        // vault did.
        strategy = new CountingStrategy(address(vault), strategyParams);
        allocator = new LiquidAllocator(address(vault), admin, operator);

        vm.startPrank(admin);
        vault.setCurator(admin);
        curate(abi.encodeCall(IVaultV2.setIsAllocator, (address(allocator), true)));
        curate(abi.encodeCall(IVaultV2.addAdapter, (address(strategy))));
        curate(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (strategy.getIdData(), VAULT_CAP)));
        curate(abi.encodeCall(IVaultV2.increaseRelativeCap, (strategy.getIdData(), FIXED_POINT_SCALAR)));
        strategy.setWhitelistedAllocator(address(allocator), true);
        vm.stopPrank();

        vm.startPrank(user);
        fakeUnderlyingToken.approve(address(vault), VAULT_SEED);
        vault.deposit(VAULT_SEED, user);
        vm.stopPrank();
    }

    /// Curator actions are timelocked, and every timelock is zero at birth, so
    /// submitting and executing in the same block is the whole ceremony.
    function curate(bytes memory data) internal {
        vault.submit(data);
        (bool ok, bytes memory ret) = address(vault).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(32, ret), mload(ret))
            }
        }
    }

    /// Calls the strategy expecting failure and hands back the raw revert, so
    /// one rejection can be told from another.
    function refusal(address caller, bytes memory data) internal returns (bytes memory) {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(strategy).call(data);
        assertFalse(ok, "expected the call to revert");
        return ret;
    }

    // Test that only whitelisted allocators can call allocate
    function test_onlyWhitelistedAllocatorCanAllocate() public {
        bytes memory call_ = abi.encodeCall(ILiquidStrategy.allocate, (abi.encode(uint256(0)), ALLOCATION, bytes4(0), address(allocator)));

        // Being on the strategy's whitelist buys nothing here: allocate answers
        // to the vault and to no one else.
        assertEq(refusal(address(allocator), call_), NOT_VAULT);
        assertEq(refusal(nonWhitelisted, call_), NOT_VAULT);

        vm.prank(address(vault));
        (bytes32[] memory ids,) = strategy.allocate(abi.encode(uint256(0)), ALLOCATION, bytes4(0), address(allocator));
        assertEq(ids.length, 1);
        assertEq(ids[0], strategy.adapterId());

        // The whitelist still gates the one function that reads it.
        bytes memory dex = abi.encodeCall(ILiquidStrategy.deallocateDex, (bytes(""), false));
        assertEq(refusal(nonWhitelisted, dex), PD);
    }

    // Test that only whitelisted allocators can call deallocate
    function test_onlyWhitelistedAllocatorCanDeallocate() public {
        bytes memory call_ = abi.encodeCall(ILiquidStrategy.deallocate, (abi.encode(ALLOCATION), ALLOCATION, bytes4(0), address(allocator)));

        assertEq(refusal(address(allocator), call_), NOT_VAULT);
        assertEq(refusal(nonWhitelisted, call_), NOT_VAULT);

        // Allocated first, because releasing what was never received is not a
        // thing this should be asked to do -- the question here is who may ask.
        vm.prank(address(vault));
        strategy.allocate(abi.encode(uint256(0)), ALLOCATION, bytes4(0), address(allocator));

        vm.prank(address(vault));
        (bytes32[] memory ids,) = strategy.deallocate(abi.encode(ALLOCATION), ALLOCATION, bytes4(0), address(allocator));
        assertEq(ids.length, 1);
        assertEq(ids[0], strategy.adapterId());

        // The whitelisted allocator clears "PD" on the one whitelisted path and
        // dies further in, at the settler singleton that has no code here.
        // Distinguishing the two revert payloads is what proves the whitelist
        // admits anyone at all.
        bytes memory dex = abi.encodeCall(ILiquidStrategy.deallocateDex, (bytes(""), false));
        assertEq(refusal(nonWhitelisted, dex), PD);
        assertTrue(keccak256(refusal(address(allocator), dex)) != keccak256(PD), "whitelist must admit the allocator");
    }

    // Test that allocator can allocate and deallocate
    function test_allocatorCanAllocateAndDeallocate() public {
        uint256 vaultBefore = fakeUnderlyingToken.balanceOf(address(vault));

        vm.prank(admin);
        allocator.allocate(address(strategy), ALLOCATION);

        assertEq(fakeUnderlyingToken.balanceOf(address(strategy)), ALLOCATION, "vault must hand the assets over");
        assertEq(fakeUnderlyingToken.balanceOf(address(vault)), vaultBefore - ALLOCATION);

        // The vault moved the assets before asking the strategy how much moved.
        // Its books have to come back agreeing, or the difference is a hole no
        // one is accounting for.
        assertEq(vault.allocation(strategy.adapterId()), ALLOCATION, "vault must book what it allocated");

        vm.prank(admin);
        allocator.deallocate(address(strategy), ALLOCATION / 2);

        assertEq(vault.allocation(strategy.adapterId()), ALLOCATION / 2);
        assertEq(fakeUnderlyingToken.balanceOf(address(vault)), vaultBefore - ALLOCATION / 2);
    }

    // Test that strategy kill switch works
    function test_killSwitchPreventsAllocation() public {
        // The base reports zero allocated whether or not its allocation step
        // ran, so a bypass is invisible on it. This subclass moves a number, and
        // the kill switch either stops that number or it does nothing.
        CountingStrategy counting = new CountingStrategy(address(vault), strategyParams);

        vm.prank(admin);
        counting.setKillSwitch(true);

        vm.prank(address(vault));
        (, int256 change) = counting.allocate(abi.encode(uint256(0)), ALLOCATION, bytes4(0), address(allocator));

        // "the allocation step is simply bypassed without reverts" -- the doc
        // on {LiquidStrategy.killSwitch}.
        assertEq(counting.allocated(), 0, "kill switch must bypass the allocation step");
        assertEq(change, int256(0), "a bypassed allocation must report no change");

        vm.prank(admin);
        counting.setKillSwitch(false);

        vm.prank(address(vault));
        (, change) = counting.allocate(abi.encode(uint256(0)), ALLOCATION, bytes4(0), address(allocator));
        assertEq(counting.allocated(), ALLOCATION);
        assertEq(change, int256(ALLOCATION));
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
        (,,, ILiquidStrategy.RiskClass riskClass,,,, bool additionalIncentives) = strategy.params();
        assertEq(uint8(riskClass), uint8(ILiquidStrategy.RiskClass.HIGH));
        assertEq(additionalIncentives, true);

        // Neither setter answers to anyone but the owner.
        vm.prank(nonWhitelisted);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonWhitelisted));
        strategy.setRiskClass(ILiquidStrategy.RiskClass.LOW);
    }

    // Test that strategy can interact with Liquid system properly
    function test_strategyIntegrationWithLiquid() public {
        vm.startPrank(user);
        fakeUnderlyingToken.approve(address(fakeYieldToken), DEPOSIT);
        fakeYieldToken.mint(DEPOSIT, user);
        fakeYieldToken.approve(address(liquid), DEPOSIT);
        liquid.deposit(DEPOSIT, user, 0);
        vm.stopPrank();

        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(user, address(liquidNFT));
        assertTrue(tokenId != 0, "a deposit mints a position");
        (uint256 collateral,,) = liquid.getCDP(tokenId);
        assertEq(collateral, DEPOSIT, "collateral must equal the deposit");
        assertEq(IERC20(address(fakeYieldToken)).balanceOf(address(liquid)), DEPOSIT);

        // Liquid holds no address for a strategy or an allocator, so a deposit
        // reaches neither. The old comment here claimed the opposite.
        assertEq(fakeUnderlyingToken.balanceOf(address(strategy)), 0, "a deposit does not reach the strategy");
        assertEq(vault.allocation(strategy.adapterId()), 0, "a deposit does not allocate");
    }

    // Test that strategy respects Liquid pause states
    function test_strategyRespectsLiquidPauseStates() public {
        vm.startPrank(user);
        fakeUnderlyingToken.approve(address(fakeYieldToken), DEPOSIT * 2);
        fakeYieldToken.mint(DEPOSIT * 2, user);
        fakeYieldToken.approve(address(liquid), DEPOSIT * 2);
        vm.stopPrank();

        vm.prank(alOwner);
        liquid.pauseDeposits(true);

        // Funded and approved on purpose. An empty caller reverts on the pause
        // check either way, which would let this pass with deposits open.
        vm.prank(user);
        vm.expectRevert(IllegalState.selector);
        liquid.deposit(DEPOSIT, user, 0);

        vm.prank(alOwner);
        liquid.pauseDeposits(false);

        vm.prank(user);
        liquid.deposit(DEPOSIT, user, 0);

        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(user, address(liquidNFT));
        (uint256 collateral,,) = liquid.getCDP(tokenId);
        assertEq(collateral, DEPOSIT, "the deposit lands once deposits reopen");
    }
}

/// A strategy that actually moves a number when it allocates. The base's
/// allocation hooks are empty, which makes "allocated nothing" and "was told
/// not to allocate" the same observation.
contract CountingStrategy is LiquidStrategy {
    uint256 public allocated;

    constructor(address _vault, StrategyParams memory _params) LiquidStrategy(_vault, _params) {}

    function _allocate(uint256 amount) internal override returns (uint256) {
        allocated += amount;
        return amount;
    }

    /// The vault pulls what it deallocates rather than being sent it, so the
    /// allowance is the handover.
    function _deallocate(uint256 amount) internal override returns (uint256) {
        allocated -= amount;
        IERC20(address(VAULT.asset())).approve(address(VAULT), amount);
        return amount;
    }

    /// What it is holding, read off the token rather than off {allocated}. The
    /// counter records what this strategy was told to move, which is the thing
    /// the kill switch either stops or does not; the two answers coincide under
    /// the vault's own protocol and are allowed to differ when a test calls one
    /// half of it directly.
    function realAssets() external view override returns (uint256) {
        return IERC20(address(VAULT.asset())).balanceOf(address(this));
    }
}
