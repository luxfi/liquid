// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.26;

import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../libraries/SafeCast.sol";
import "../../lib/forge-std/src/Test.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemicTokenV3} from "../AlchemicTokenV3.sol";
import {Transmuter} from "../Transmuter.sol";
import {TransmuterBuffer} from "../TransmuterBuffer.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TokenAdapterMock} from "./mocks/TokenAdapterMock.sol";
import {IAlchemistV3, IAlchemistV3Errors, InitializationParams} from "../interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../interfaces/ITransmuter.sol";
import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";
import {InsufficientAllowance} from "../base/Errors.sol";
import "../interfaces/IYearnVaultV2.sol";

contract AlchemistV3Test is Test {
    // ----- [SETUP] Variables for setting up a minimal CDP -----

    // Callable contract variables
    AlchemistV3 alchemist;
    Transmuter transmuter;
    TransmuterBuffer transmuterBuffer;

    // // Proxy variables
    TransparentUpgradeableProxy proxyAlchemist;
    TransparentUpgradeableProxy proxyTransmuter;
    TransparentUpgradeableProxy proxyTransmuterBuffer;

    // // Contract variables
    // CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    AlchemistV3 alchemistLogic;
    Transmuter transmuterLogic;
    TransmuterBuffer transmuterBufferLogic;
    AlchemicTokenV3 alToken;
    Whitelist whitelist;

    // Token addresses
    TestERC20 fakeUnderlyingToken;
    TestYieldToken fakeYieldToken;

    // Total minted debt
    uint256 public minted;

    // Total debt burned
    uint256 public burned;

    // Total tokens sent to transmuter
    uint256 public sentToTransmuter;

    // Parameters for AlchemicTokenV2
    string public _name;
    string public _symbol;
    uint256 public _flashFee;
    address public alOwner;

    mapping(address => bool) users;

    // LTV
    uint256 public LTV = 1 * 1e17; // .1

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 accountFunds = 2_000_000_000e18;

    // amount of yield/underlying token to deposit
    uint256 depositAmount = 100_000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDeposit = 1000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDepositOrWithdrawalLoss = 1e18;

    // random EOA for testing
    address externalUser = address(0x69E8cE9bFc01AA33cD2d02Ed91c72224481Fa420);

    // another random EOA for testing
    address anotherExternalUser = address(0x420Ab24368E5bA8b727E9B8aB967073Ff9316969);

    function setUp() external {
        // test maniplulation for convenience
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(caller != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(caller != proxyOwner);
        vm.startPrank(caller);

        // Fake tokens

        fakeUnderlyingToken = new TestERC20(100e18, uint8(18));
        fakeYieldToken = new TestYieldToken(address(fakeUnderlyingToken));

        ITransmuter.InitializationParams memory transParams =  ITransmuter.InitializationParams({
            syntheticToken: address(alToken),
            feeReceiver: address(this),
            timeToTransmute: 216000,
            transmutationFee: 10,
            exitFee: 20
        });

        // Contracts and logic contracts
        alOwner = caller;
        alToken = new AlchemicTokenV3(_name, _symbol, _flashFee);
        transmuterBufferLogic = new TransmuterBuffer();
        transmuterLogic = new Transmuter(transParams);
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // Proxy contracts
        // TransmuterBuffer proxy
        bytes memory transBufParams = abi.encodeWithSelector(TransmuterBuffer.initialize.selector, alOwner, address(alToken));

        proxyTransmuterBuffer = new TransparentUpgradeableProxy(address(transmuterBufferLogic), proxyOwner, transBufParams);

        transmuterBuffer = TransmuterBuffer(address(proxyTransmuterBuffer));

        // TransmuterV3 proxy
        // bytes memory transParams = abi.encodeWithSelector(TransmuterV3.initialize.selector, address(alToken), fakeUnderlyingToken, address(transmuterBuffer));

        // proxyTransmuter = new TransparentUpgradeableProxy(address(transmuterLogic), proxyOwner, transParams);
        // transmuter = TransmuterV3(address(proxyTransmuter));

        // AlchemistV3 proxy
        InitializationParams memory params = InitializationParams({
            admin: alOwner,
            debtToken: address(alToken),
            underlyingToken: address(fakeUnderlyingToken),
            yieldToken: address(fakeYieldToken),
            transmuter: address(transmuterBuffer),
            minimumCollateralization: LTV,
            protocolFee: 1000,
            protocolFeeReceiver: address(10),
            mintingLimitMinimum: 1,
            mintingLimitMaximum: uint256(type(uint160).max),
            mintingLimitBlocks: 300
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        // Whitelist alchemist proxy for minting tokens
        alToken.setWhitelist(address(proxyAlchemist), true);

        whitelist.add(address(0xbeef));
        whitelist.add(externalUser);
        whitelist.add(anotherExternalUser);

        vm.stopPrank();

        // Add funds to test accounts
        deal(address(fakeYieldToken), address(0xbeef), accountFunds);
        deal(address(fakeYieldToken), externalUser, accountFunds);
        deal(address(fakeUnderlyingToken), anotherExternalUser, accountFunds);
        deal(address(fakeUnderlyingToken), address(0xbeef), accountFunds);

        vm.startPrank(anotherExternalUser);

        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), accountFunds);

        // faking initial token vault supply
        // ITestYieldToken(address(fakeYieldToken)).mint(15_000_000e18, anotherExternalUser);

        vm.stopPrank();
    }

    function testDeposit(uint256 amount) external {
        amount = bound(amount, 1e18, 1000e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        (uint256 depositedCollateral, uint256 debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(depositedCollateral, amount, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testWithdraw(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.withdraw(amount / 2, address(0xbeef));
        (uint256 depositedCollateral, ) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(depositedCollateral, amount / 2, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetMinCollateralization_Variable_Collateralization(uint256 collateralization) external {
        vm.assume(collateralization >= 1e18);
        vm.assume(collateralization < 20e18);
        vm.startPrank(address(0xdead));
        alchemist.setMinimumCollateralization(collateralization);
        vm.assertApproxEqAbs(alchemist.minimumCollateralization(), collateralization, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetMinCollateralization_Invalid_Collateralization_Zero() external {
        uint256 collateralization = 0;
        vm.startPrank(address(0xdead));
        vm.expectRevert(IllegalArgument.selector);
        alchemist.setMinimumCollateralization(collateralization);
        vm.stopPrank();
    }

    function testMint_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        uint256 ltv = 2e17;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint((amount * ltv) / FIXED_POINT_SCALAR, address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMint_Variable_LTV(uint256 ltv) external {
        uint256 amount = depositAmount;

        // ~ all possible LTVS up to max LTV
        ltv = bound(ltv, 0 + 1e14, LTV - 1e16);
        vm.prank(address(0xdead));
        alchemist.setMinimumCollateralization(1e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint((amount * ltv) / FIXED_POINT_SCALAR, address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMint_Revert_Exceeds_Min_Collateralization(uint256 amount, uint256 collateralization) external {
        amount = bound(amount, 1e18, accountFunds);

        collateralization = bound(collateralization, 1e18, 100e18);
        vm.prank(address(0xdead));
        alchemist.setMinimumCollateralization(collateralization);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount);
        alchemist.deposit(amount, address(0xbeef));
        uint256 mintAmount = ((alchemist.totalValue(address(0xbeef)) * FIXED_POINT_SCALAR) / collateralization) + 1;
        vm.expectRevert(IAlchemistV3Errors.Undercollateralized.selector);
        alchemist.mint(mintAmount, address(0xbeef));
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount_Revert_No_Allowance(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        uint256 minCollateralization = 2e18;

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(amount, externalUser);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        /// 0xbeef mints tokens from `externalUser` account, to be recieved by `externalUser`.
        /// 0xbeef however, has not been approved for any mint amount for `externalUsers` account.
        vm.expectRevert();
        alchemist.mintFrom(externalUser, ((amount * minCollateralization) / FIXED_POINT_SCALAR), externalUser);
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        uint256 ltv = 2e17;

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        /// Make deposit for external user
        alchemist.deposit(amount, externalUser);

        /// 0xbeef has been approved up to a mint amount for minting from `externalUser` account.
        alchemist.approveMint(address(0xbeef), amount + 100e18);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        alchemist.mintFrom(externalUser, ((amount * ltv) / FIXED_POINT_SCALAR), externalUser);

        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    // function testRepay_Variable_Amount(uint256 amount) external {
    //     amount = bound(amount, 1e18, accountFunds);
    //     vm.startPrank(address(0xbeef));
    //     SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
    //     SafeERC20.safeApprove(address(alToken), address(alchemist), amount + 100e18);
    //     alchemist.deposit(amount, address(0xbeef));
    //     alchemist.maxMint();

    //     // max collateral valued in underlying, that can be borrowed for alAsset 1 to 1
    //     uint256 maxCollateralAmount = (alchemist.totalValue(address(0xbeef)) * LTV) / FIXED_POINT_SCALAR;
    //     uint256 supplyBeforeBurn = IERC20(alToken).totalSupply();
    //     uint256 expectedSupplyAfterBurn = supplyBeforeBurn - maxCollateralAmount / 2;
    //     alchemist.repay(address(0xbeef), maxCollateralAmount / 2);
    //     uint256 supplyAfterBurn = IERC20(alToken).totalSupply();
    //     (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));

    //     // User debt updates to correct value
    //     vm.assertApproxEqAbs(uint256(debt), maxCollateralAmount - (maxCollateralAmount / 2), minimumDepositOrWithdrawalLoss);

    //     // The alAsset total supply has updated to the correct amount after burning
    //     vm.assertApproxEqAbs(supplyAfterBurn, expectedSupplyAfterBurn, minimumDepositOrWithdrawalLoss);
    //     vm.stopPrank();
    // }

    function testburn_Variable_Amount(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));

    }

    // TODO: Liquidation tests once liquidation function is revamped

    // function testLiquidate_Undercollateralized_Position() external {
    //     // NOTE testing with --fork-block-number 20592882, totalSupply will change if this is not maintained

    //     uint256 amount = accountFunds;
    //     vm.startPrank(address(0xbeef));
    //     SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
    //     alchemist.deposit(address(0xbeef), amount);
    //     alchemist.mint((amount * LTV) / FIXED_POINT_SCALAR);
    //     vm.stopPrank();

    //     // Now altering the yield tokens price (on the dai Yearn Vault) in underyling by artificially inflating the token supply from  1.54e25 to (1.54e25 + 1.54e26/7.3)
    //     // see https://etherscan.io/address/0xdA816459F1AB5631232FE5e97a05BBBb94970c95#code
    //     vm.store(address(fakeYieldToken), bytes32(uint256(5)), bytes32(uint256(((1.54e25 * FIXED_POINT_SCALAR) / 73e17) + 1.54e25)));
    //     bytes32 modifiedStateVariable = vm.load(address(fakeYieldToken), bytes32(uint256(5)));
    //     uint256 yieldTokenTotalSupply = IYearnVaultV2(address(fakeYieldToken)).totalSupply();

    //     // make sure the right state variable has been modified
    //     vm.assertApproxEqAbs(uint256(modifiedStateVariable), uint256(yieldTokenTotalSupply), minimumDepositOrWithdrawalLoss);

    //     // let another user liquidate the previous user position
    //     vm.startPrank(externalUser);
    //     uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
    //     (uint256 assets, uint256 fees) = alchemist.liquidate(address(0xbeef));
    //     uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
    //     (uint256 depositedCollateral, int256 debt) = alchemist.getCDP(address(0xbeef));
    //     vm.stopPrank();

    //     // ensure debt is zero
    //     vm.assertApproxEqAbs(debt, 0, minimumDepositOrWithdrawalLoss);

    //     // ensure depositedCollateral is zero
    //     vm.assertApproxEqAbs(depositedCollateral, 0, minimumDepositOrWithdrawalLoss);

    //     // ensure assets liquidated is equal to the amount put in
    //     vm.assertApproxEqAbs(assets, accountFunds, minimumDepositOrWithdrawalLoss);

    //     // ensure liquidator fee is correct (total underlying - debt)
    //     vm.assertApproxEqAbs(fees, 191_966_404_330_380_896_000_000_000, 1e18);

    //     // liquidator gets correct amount of fee
    //     vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + fees, 1e18);
    // }

    // function testLiquidate_Revert_If_Overcollateralized_Position() external {
    //     uint256 amount = accountFunds;
    //     vm.startPrank(address(0xbeef));
    //     SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
    //     alchemist.deposit(address(0xbeef), amount);
    //     alchemist.mint((amount * LTV) / FIXED_POINT_SCALAR);
    //     vm.stopPrank();

    //     // let another user liquidate the previous user position
    //     vm.startPrank(externalUser);
    //     uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
    //     vm.expectRevert(IAlchemistV3.LiquidationError.selector);
    //     (uint256 assets, uint256 fees) = alchemist.liquidate(address(0xbeef));
    //     vm.stopPrank();
    // }
}