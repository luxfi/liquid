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

    uint256 public minimumCollateralization = uint256(1e18 * 1e18) / 9e17;

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

        alToken = new AlchemicTokenV3(_name, _symbol, _flashFee);

        ITransmuter.InitializationParams memory transParams =  ITransmuter.InitializationParams({
            syntheticToken: address(alToken),
            feeReceiver: address(this),
            timeToTransmute: 216000,
            transmutationFee: 10,
            exitFee: 20,
            graphSize: 52560000
        });

        // Contracts and logic contracts
        alOwner = caller;
        transmuterBufferLogic = new TransmuterBuffer();
        transmuterLogic = new Transmuter(transParams);
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // // Proxy contracts
        // // TransmuterBuffer proxy
        // bytes memory transBufParams = abi.encodeWithSelector(TransmuterBuffer.initialize.selector, alOwner, address(alToken));

        // proxyTransmuterBuffer = new TransparentUpgradeableProxy(address(transmuterBufferLogic), proxyOwner, transBufParams);

        // transmuterBuffer = TransmuterBuffer(address(proxyTransmuterBuffer));

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
            transmuter: address(transmuterLogic),
            minimumCollateralization: minimumCollateralization,
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

        transmuterLogic.addAlchemist(address(alchemist));
        transmuterLogic.setDepositCap(uint256(type(int256).max));

        vm.stopPrank();

        // Add funds to test accounts
        deal(address(fakeYieldToken), address(0xbeef), accountFunds);
        deal(address(fakeYieldToken), externalUser, accountFunds);
        deal(address(fakeUnderlyingToken), anotherExternalUser, accountFunds);
        deal(address(fakeUnderlyingToken), address(0xbeef), accountFunds);
        deal(address(alToken), address(0xdad), 1000e18);

        vm.startPrank(anotherExternalUser);

        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), accountFunds);

        vm.stopPrank();
    }

    function testSetNewAdmin() external {
        vm.prank(alOwner);
        alchemist.setPendingAdmin(address(0xbeef));

        vm.prank(address(0xbeef));
        alchemist.acceptAdmin();

        assertEq(alchemist.admin(), address(0xbeef));
    }

    function testSetNewAdminNotPendingAdmin() external {
        vm.prank(alOwner);
        alchemist.setPendingAdmin(address(0xbeef));

        vm.startPrank(address(0xdad));
        vm.expectRevert();
        alchemist.acceptAdmin();
        vm.stopPrank();
    }

    function testSetNewAdminNotCurrentAdmin() external {
        vm.expectRevert();
        alchemist.setPendingAdmin(address(0xbeef));
    }

    function testSetNewAdminZeroAddress() external {
        vm.expectRevert();
        alchemist.acceptAdmin();

        assertEq(alchemist.pendingAdmin(), address(0));
    }

    function testSetProtocolFeeReceiver() external {
        vm.prank(alOwner);
        alchemist.setProtocolFeeReceiver(address(0xbeef));

        assertEq(alchemist.protocolFeeReceiver(), address(0xbeef));
    }

    function testSetProtocolFeeReceiveZeroAddress() external {
        vm.startPrank(alOwner);
        vm.expectRevert();
        alchemist.setProtocolFeeReceiver(address(0));

        vm.stopPrank();

        assertEq(alchemist.protocolFeeReceiver(), address(10));
    }

    function testSetProtocolFeeReceiverNotAdmin() external {
        vm.expectRevert();
        alchemist.setProtocolFeeReceiver(address(0xbeef));
    }

    function testSetTransmuter() external {
        vm.prank(alOwner);
        alchemist.setTransmuter(address(0xbeef));

        assertEq(alchemist.transmuter(), address(0xbeef));
    }

    function testSetTransmuterZeroAddress() external {
        vm.startPrank(alOwner);
        vm.expectRevert();
        alchemist.setTransmuter(address(0));

        vm.stopPrank();

        assertEq(alchemist.transmuter(), address(transmuterLogic));
    }

    function testSetTransmuterNotAdmin() external {
        vm.expectRevert();
        alchemist.setTransmuter(address(0xbeef));
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

    function testSetMinimumCollateralizationNotAdmin() external {
        vm.expectRevert();
        alchemist.setMinimumCollateralization(0);
    }

    function testDeposit(uint256 amount) external {
        amount = bound(amount, 1e18, 1000e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        (uint256 depositedCollateral, uint256 debt, ) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(depositedCollateral, amount, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        assertEq(alchemist.getTotalDeposited(), amount);

        (uint256 deposited, uint256 userDebt, ) = alchemist.getCDP(address(0xbeef));

        assertEq(deposited, amount);
        assertEq(userDebt, 0);

        assertEq(alchemist.getMaxBorrowable(address(0xbeef)), alchemist.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / 1e18) * 1e18 / alchemist.minimumCollateralization());

        assertEq(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount));

        assertEq(alchemist.totalValue(address(0xbeef)), alchemist.getTotalUnderlyingValue());
    }

    function testDepositZeroAmount() external {
        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        alchemist.deposit(0, address(0xbeef));
        vm.stopPrank();
    }

    function testDepositZeroAddress() external {
        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        alchemist.deposit(10e18, address(0));
        vm.stopPrank();
    }

    function testWithdraw(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.withdraw(amount / 2, address(0xbeef));
        (uint256 depositedCollateral, , ) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(depositedCollateral, amount / 2, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        assertApproxEqAbs(alchemist.getTotalDeposited(), amount / 2, 1);

        (uint256 deposited, uint256 userDebt, ) = alchemist.getCDP(address(0xbeef));

        assertApproxEqAbs(deposited, amount / 2, 1);
        assertApproxEqAbs(userDebt, 0, 1);

        assertApproxEqAbs(alchemist.getMaxBorrowable(address(0xbeef)), alchemist.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / 2 / 1e18) * 1e18 / alchemist.minimumCollateralization(), 1);

        assertApproxEqAbs(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount / 2), 1);
    }

    function testWithdrawUndercollateralilzed() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(amount / 2, address(0xbeef));
        vm.expectRevert();
        alchemist.withdraw(amount, address(0xbeef));
        vm.stopPrank();
    }

    function testWithdrawZeroAmount() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        vm.expectRevert();
        alchemist.withdraw(0, address(0xbeef));
        vm.stopPrank();
    }

    function testWithdrawZeroAddress() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        vm.expectRevert();
        alchemist.withdraw(amount/ 2, address(0));
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

        (uint256 deposited, uint256 userDebt, ) = alchemist.getCDP(address(0xbeef));

        assertApproxEqAbs(deposited, amount , 1);
        assertApproxEqAbs(userDebt, amount * ltv / FIXED_POINT_SCALAR, 1);

        assertApproxEqAbs(alchemist.getMaxBorrowable(address(0xbeef)), (alchemist.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / 1e18) * 1e18 / alchemist.minimumCollateralization()) - (amount * ltv) / FIXED_POINT_SCALAR, 1);

        assertApproxEqAbs(alchemist.getTotalUnderlyingValue(), alchemist.convertYieldTokensToUnderlying(amount), 1);
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

        assertEq(alchemist.mintAllowance(externalUser, address(0xbeef)), amount + 100e18);

        vm.startPrank(address(0xbeef));
        alchemist.mintFrom(externalUser, ((amount * ltv) / FIXED_POINT_SCALAR), externalUser);

        assertEq(alchemist.mintAllowance(externalUser, address(0xbeef)), (amount + 100e18) - (amount * ltv) / FIXED_POINT_SCALAR);

        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testRepayUnearmarkedDebtOnly() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(amount / 2, address(0xbeef));

        uint256 preRepayBalance = fakeYieldToken.balanceOf(address(0xbeef));

        alchemist.repay(100e18, address(0xbeef));
        vm.stopPrank();

        (uint256 deposited, uint256 userDebt, ) = alchemist.getCDP(address(0xbeef));

        assertEq(userDebt, 0);

        // Test that transmuter received funds
        assertEq(fakeYieldToken.balanceOf(address(transmuterLogic)), alchemist.convertDebtTokensToYield(amount / 2));

        // Test that overpayment was not taken from user
        assertEq(fakeYieldToken.balanceOf(address(0xbeef)), preRepayBalance - alchemist.convertDebtTokensToYield(amount / 2));
    }

    function testRepayUnearmarkedDebtOnly_Variable_Amount(uint256 repayAmount) external {
        repayAmount = bound(repayAmount, 1e18, accountFunds / 2);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), 200e18 + repayAmount);
        alchemist.deposit(100e18, address(0xbeef));
        alchemist.mint(100e18 / 2, address(0xbeef));

        uint256 preRepayBalance = fakeYieldToken.balanceOf(address(0xbeef));

        alchemist.repay(repayAmount, address(0xbeef));
        vm.stopPrank();

        (uint256 deposited, uint256 userDebt, ) = alchemist.getCDP(address(0xbeef));

        uint256 repaidAmount = alchemist.convertYieldTokensToDebt(repayAmount) > 100e18 / 2 ? 100e18 / 2 : alchemist.convertYieldTokensToDebt(repayAmount);

        assertEq(userDebt, (100e18 / 2) - repaidAmount);

        // Test that transmuter received funds
        assertEq(fakeYieldToken.balanceOf(address(transmuterLogic)), repaidAmount);

        // Test that overpayment was not taken from user
        assertEq(fakeYieldToken.balanceOf(address(0xbeef)), preRepayBalance - repaidAmount);
    }

    // function testRepayWithEarmarkedDebt() external {
    //     uint256 amount = 100e18;
    //     vm.startPrank(address(0xbeef));
    //     SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
    //     alchemist.deposit(amount, address(0xbeef));
    //     alchemist.mint((amount / 2), address(0xbeef));
    //     vm.stopPrank();

    //     vm.startPrank(address(0xdad));
    //     SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
    //     transmuterLogic.createRedemption(address(alchemist), address(fakeYieldToken), 50e18);
    //     vm.stopPrank();

    //     vm.roll(block.number + 5256000);

    //     vm.prank(address(0xbeef));
    //     alchemist.repay(100e18, address(0xbeef));

    //     // TODO: Assert after updating getCDP to show earmarked
    //     (uint256 collateral, uint256 debt, uint256 earmarked) =alchemist.getCDP(address(0xbeef));
    // }

    function testRepayZeroAmount() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(amount / 2, address(0xbeef));

        vm.expectRevert();
        alchemist.repay(0, address(0xbeef));
        vm.stopPrank();
    }

    function testRepayZeroAddress() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(amount / 2, address(0xbeef));
        
        vm.expectRevert();
        alchemist.repay(100e18, address(0));
        vm.stopPrank();
    }

    function testBurn() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(amount / 2, address(0xbeef));

        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        alchemist.burn(amount / 2, address(0xbeef));
        vm.stopPrank();

        (uint256 deposited, uint256 userDebt, ) = alchemist.getCDP(address(0xbeef));

        assertEq(userDebt, 0);
    }

    function testBurn_variable_burn_amounts(uint256 burnAmount) external {
        deal(address(alToken), address(0xbeef), 1000e18);
        uint256 amount = 100e18;
        burnAmount = bound(burnAmount, 1, 1000e18);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(amount / 2, address(0xbeef));

        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        alchemist.burn(burnAmount, address(0xbeef));
        vm.stopPrank();

        (uint256 deposited, uint256 userDebt, ) = alchemist.getCDP(address(0xbeef));

        uint256 burnedAmount = burnAmount > amount / 2 ? amount / 2 : burnAmount;

        // Test that amount is burned and any extra tokens are not taken from user
        assertEq(userDebt, (amount / 2) - burnedAmount);
        assertEq(alToken.balanceOf(address(0xbeef)) - amount / 2, 1000e18 - burnedAmount);
    }

    function testBurnZeroAmount() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(amount / 2, address(0xbeef));

        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        vm.expectRevert();
        alchemist.burn(0, address(0xbeef));
        vm.stopPrank();
    }

    function testBurnZeroAddress() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
        alchemist.deposit(amount, address(0xbeef));
        alchemist.mint(amount / 2, address(0xbeef));

        SafeERC20.safeApprove(address(alToken), address(alchemist), amount / 2);
        vm.expectRevert();
        alchemist.burn(amount / 2, address(0));
        vm.stopPrank();
    }

    // TODO: Set up earmarking so we can see that burn wont pay earmarked debt
    function testBurnWithEarmarkedDebt() external {

    }

    // TODO: Liquidation tests once liquidation function is revamped
    function testLiquidation() external {
        alchemist.liquidate(address(0xbeef));
    }

    // function testEarmarkDebtAndRedeem() external {
    //     uint256 amount = 100e18;
    //     vm.startPrank(address(0xbeef));
    //     SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
    //     alchemist.deposit(amount, address(0xbeef));
    //     alchemist.mint((amount / 2), address(0xbeef));
    //     vm.stopPrank();

    //     vm.startPrank(address(0xdad));
    //     SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
    //     transmuterLogic.createRedemption(address(alchemist), address(fakeYieldToken), 50e18);
    //     vm.stopPrank();

    //     vm.roll(block.number + 5256000);

    //     alchemist.getCDP(address(0xbeef));

    //     vm.startPrank(address(0xbeef));
    //     SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), amount + 100e18);
    //     alchemist.withdraw(amount / 5, address(0xbeef));
    //     vm.stopPrank();

    //     alchemist.poke(address(0xbeef));

    //     vm.prank(address(transmuterLogic));
    //     alchemist.redeem(20e18);

    //     //TODO: Finish this
    // }

    function testRedemptionNotTransmuter() external {
        vm.expectRevert();
        alchemist.redeem(20e18);
    }
}