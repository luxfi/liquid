// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import {DSTestPlus} from "./utils/DSTestPlus.sol";
import {IAlchemistV3AdminActions} from "../interfaces/alchemist/IAlchemistV3AdminActions.sol";
import "../../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../libraries/SafeERC20.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemicTokenV3} from "../AlchemicTokenV3.sol";
import {TransmuterV3} from "../TransmuterV3.sol";
import {TransmuterBuffer} from "../TransmuterBuffer.sol";
import {Whitelist} from "../utils/Whitelist.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestYieldToken} from "./mocks/TestYieldToken.sol";
import {TestYieldTokenAdapter} from "./mocks/TestYieldTokenAdapter.sol";
import "../../../lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "../libraries/SafeCast.sol";
import {console} from "../../lib/forge-std/src/console.sol";
import "../libraries/SafeCast.sol";
import "../../lib/forge-std/src/Test.sol";

import {ITestYieldToken} from "../interfaces/test/ITestYieldToken.sol";

contract AlchemistV3Test is Test {
    // ----- [SETUP] Variables for setting up a minimal CDP -----

    // Callable contract variables
    AlchemistV3 alchemist;
    TransmuterV3 transmuter;
    TransmuterBuffer transmuterBuffer;

    // // Proxy variables
    TransparentUpgradeableProxy proxyAlchemist;
    TransparentUpgradeableProxy proxyTransmuter;
    TransparentUpgradeableProxy proxyTransmuterBuffer;

    // // Contract variables
    // CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    AlchemistV3 alchemistLogic;
    TransmuterV3 transmuterLogic;
    TransmuterBuffer transmuterBufferLogic;
    AlchemicTokenV3 alToken;
    TestYieldTokenAdapter tokenAdapter;
    Whitelist whitelist;

    // Token addresses
    address fakeUnderlyingToken;
    address fakeYieldToken;

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
    uint256 public LTV = 11e17; // 1.1, prev = 2 * 1e18

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 accountFunds = 20_000_000e18;

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

    // Real Tokens
    IERC20 constant dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 constant yvDai = IERC20(0xdA816459F1AB5631232FE5e97a05BBBb94970c95);

    function setUp() external {
        // test maniplulation for convenience
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(caller != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(caller != proxyOwner);
        vm.startPrank(caller);

        // Fake tokens

        TestERC20 testToken = new TestERC20(0, 18);
        fakeUnderlyingToken = address(testToken);
        TestYieldToken testYieldToken = new TestYieldToken(fakeUnderlyingToken);
        fakeYieldToken = address(testYieldToken);

        // Contracts and logic contracts
        alOwner = caller;
        alToken = new AlchemicTokenV3(_name, _symbol, _flashFee);
        tokenAdapter = new TestYieldTokenAdapter(fakeYieldToken);
        transmuterBufferLogic = new TransmuterBuffer();
        transmuterLogic = new TransmuterV3();
        alchemistLogic = new AlchemistV3();
        whitelist = new Whitelist();

        // Proxy contracts
        // TransmuterBuffer proxy
        bytes memory transBufParams = abi.encodeWithSelector(TransmuterBuffer.initialize.selector, alOwner, address(alToken));

        proxyTransmuterBuffer = new TransparentUpgradeableProxy(address(transmuterBufferLogic), proxyOwner, transBufParams);

        transmuterBuffer = TransmuterBuffer(address(proxyTransmuterBuffer));

        // TransmuterV3 proxy
        bytes memory transParams =
            abi.encodeWithSelector(TransmuterV3.initialize.selector, address(alToken), fakeUnderlyingToken, address(transmuterBuffer), whitelist);

        proxyTransmuter = new TransparentUpgradeableProxy(address(transmuterLogic), proxyOwner, transParams);
        transmuter = TransmuterV3(address(proxyTransmuter));

        // AlchemistV3 proxy
        IAlchemistV3AdminActions.InitializationParams memory params = IAlchemistV3AdminActions.InitializationParams({
            admin: alOwner,
            debtToken: address(alToken),
            transmuter: address(transmuterBuffer),
            minimumCollateralization: LTV,
            protocolFee: 1000,
            protocolFeeReceiver: address(10),
            mintingLimitMinimum: 1,
            mintingLimitMaximum: uint256(type(uint160).max),
            mintingLimitBlocks: 300,
            whitelist: address(whitelist)
        });

        bytes memory alchemParams = abi.encodeWithSelector(AlchemistV3.initialize.selector, params);
        proxyAlchemist = new TransparentUpgradeableProxy(address(alchemistLogic), proxyOwner, alchemParams);
        alchemist = AlchemistV3(address(proxyAlchemist));

        // Whitelist alchemist proxy for minting tokens
        alToken.setWhitelist(address(proxyAlchemist), true);

        // Create token adapter configs for both yeild and underlying tokens
        // Must add underlying  config before yeild token

        IAlchemistV3AdminActions.UnderlyingTokenConfig memory underlyingTokenConfig = IAlchemistV3AdminActions.UnderlyingTokenConfig({
            repayLimitMinimum: 1,
            repayLimitMaximum: 1000,
            repayLimitBlocks: 10,
            liquidationLimitMinimum: 1,
            liquidationLimitMaximum: 1000,
            liquidationLimitBlocks: 7200
        });

        alchemist.addUnderlyingToken(address(fakeUnderlyingToken), underlyingTokenConfig);

        IAlchemistV3AdminActions.YieldTokenConfig memory yieldTokenConfig =
            IAlchemistV3AdminActions.YieldTokenConfig({adapter: address(tokenAdapter), maximumLoss: 1, maximumExpectedValue: 1e50, creditUnlockBlocks: 1});

        alchemist.addYieldToken(address(fakeYieldToken), yieldTokenConfig);

        // Enable token adapters for both yeild and underlying tokens
        alchemist.setYieldTokenEnabled(address(fakeYieldToken), true);
        alchemist.setUnderlyingTokenEnabled(address(fakeUnderlyingToken), true);

        // Skipping all transmuter interaction until transmuter v3 is implemented

        // // Set the alchemist for the transmuterBuffer
        // transmuterBuffer.setAlchemist(address(proxyAlchemist));
        // // Set the transmuter buffer's transmuter
        // transmuterBuffer.setTransmuter(fakeUnderlyingToken, address(transmuter));
        // // Set alOwner as a keeper
        // alchemist.setKeeper(alOwner, true);
        // // Set flow rate for transmuter buffer
        // transmuterBuffer.setFlowRate(fakeUnderlyingToken, 325e18);

        whitelist.add(address(0xbeef));
        whitelist.add(externalUser);
        whitelist.add(anotherExternalUser);

        vm.stopPrank();

        // Add funds to test accounts
        deal(address(fakeYieldToken), address(0xbeef), accountFunds);
        deal(address(fakeYieldToken), externalUser, accountFunds);
        deal(address(fakeUnderlyingToken), anotherExternalUser, accountFunds);

        vm.startPrank(anotherExternalUser);

        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), accountFunds);

        // faking initial token vault supply
        ITestYieldToken(address(fakeYieldToken)).mint(15_000_000e18, anotherExternalUser);

        vm.stopPrank();
    }

    function testDeposit() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));
        vm.assertApproxEqAbs(alchemist.totalValue(address(0xbeef)), depositAmount, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testWithdrawal() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));
        uint256 shares = alchemist.convertYieldTokensToShares(address(fakeYieldToken), depositAmount);
        alchemist.withdraw(address(fakeYieldToken), shares / 2, address(0xbeef));
        vm.assertApproxEqAbs(alchemist.totalValue(address(0xbeef)), depositAmount / 2, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testCDPWithZeroDebt() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));
        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(deposit, depositAmount, minimumDepositOrWithdrawalLoss);
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), 0, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    /// High LTV Cases ------------------------------------------------------------------------------- ///

    /// APY : 0% | Share of Debt : 22.22% | LTV : 80%  | Duration : 1 day  ///

    function testCDP0PercentAPY1DayHighShare1() external {
        /// @dev mint amount used in this for the cdp postion test
        uint256 mintAmountSmall = 80_000e18;

        /// @dev starting debt position of this alchemist before user test
        uint256 mintAmountLarge = 280_000e18;

        /// @dev expected debt after 1 day for a specific user with 80,000 debt
        /// at a mocked redemption rate
        uint256 debAfter1Day = 79_925_865_227_552_000_000_000;

        /// @dev expected deposit after 1 day for a specific user with 100,000 deposit
        /// at a mocked redemption rate
        uint256 depositAfter1Day = 99_925_865_227_552_000_000_000;

        /// @dev faking total collateral
        uint256 depositAmountLarge = 800_000e18;

        /// @dev faking underlying token supply of vault after 1 day at 12% APY i.e. 1% increase per month starting from the initial 15_000_000
        uint256 vaultTotalSupplyAfter1Day = 15_000_000e18;

        // warp to a start time
        vm.warp(1_719_590_015);

        /// simulating a desposit and mint from a user

        vm.startPrank(externalUser);

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmountLarge, externalUser);

        alchemist.mint(mintAmountLarge, externalUser);

        vm.stopPrank();

        /// simulating mint from another user with a smaller resulting debt share

        vm.startPrank(address(0xbeef));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));

        alchemist.mint(mintAmountSmall, address(0xbeef));

        // Fake yield accrual after 1 day @ 0% APY
        deal(address(fakeUnderlyingToken), address(fakeYieldToken), vaultTotalSupplyAfter1Day, true);

        // warp by 1 day. i.e. 86400s
        vm.warp(1_719_590_095 + 86_400);

        /// cdp of the same user with small debt share after 1 month
        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));

        // i.e. 100,000 collateral + yield - ((.001307 alAsset per second * 86_400 seconds * 1 day ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(deposit, depositAfter1Day, minimumDepositOrWithdrawalLoss);

        // i.e. 80,000 debt - ((.001307 alAsset per second * 86_400 seconds * 1 day ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), debAfter1Day, minimumDepositOrWithdrawalLoss);

        vm.stopPrank();
    }

    /// APY : 0% | Share of Debt : 22.22% | LTV : 80%  | Duration : 1 month ///

    function testCDP0PercentAPY1MonthHighShare1() external {
        /// @dev mint amount used in this for the cdp postion test
        uint256 mintAmountSmall = 80_000e18;

        /// @dev starting debt position of this alchemist before user test
        uint256 mintAmountLarge = 280_000e18;

        /// @dev expected debt after 1 month for a specific user with 80,000 debt
        /// at a mocked redemption rate
        uint256 debAfter1Month = 77_777_945_640_992_000_000_000;

        /// @dev expected deposit after 1 month for a specific user with 100,000 deposit
        /// at a mocked redemption rate
        uint256 depositAfter1Month = 97_777_945_640_992_000_000_000;

        /// @dev faking total collateral
        uint256 depositAmountLarge = 800_000e18;

        /// @dev faking underlying token supply of vault after 1 month at 0% APY i.e. 1% increase per month starting from the initial 15_000_000
        uint256 vaultTotalSupplyAfter1Month = 15_000_000e18;

        // warp to a start time
        vm.warp(1_719_590_015);

        /// simulating a desposit and mint from a user

        vm.startPrank(externalUser);

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmountLarge, externalUser);

        alchemist.mint(mintAmountLarge, externalUser);

        vm.stopPrank();

        /// simulating mint from another user with a smaller resulting debt share

        vm.startPrank(address(0xbeef));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));

        alchemist.mint(mintAmountSmall, address(0xbeef));

        // Fake yield accrual after 1 month @ 0% APY
        deal(address(fakeUnderlyingToken), address(fakeYieldToken), vaultTotalSupplyAfter1Month, true);

        // warp by 1 month. i.e. 86400s per day for 1 month / Roughly 30 days
        vm.warp(1_719_590_095 + (30 * 86_400));

        /// cdp of the same user with small debt share after 1 month
        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));

        // i.e. 100,000 collateral + yield - ((.001307 alAsset per second * 86_400 seconds * 30 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(deposit, depositAfter1Month, minimumDepositOrWithdrawalLoss);

        // i.e. 80,000 debt - ((.001307 alAsset per second * 86_400 seconds * 30 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), debAfter1Month, minimumDepositOrWithdrawalLoss);

        vm.stopPrank();
    }

    /// APY : 12% | Share of Debt : 22.22% | LTV : 80%  | Duration : 1 month ///

    function testCDP12PercentAPY1MonthHighShare1() external {
        /// @dev mint amount used in this for the cdp postion test
        uint256 mintAmountSmall = 80_000e18;

        /// @dev starting debt position of this alchemist before user test
        uint256 mintAmountLarge = 280_000e18;

        /// @dev expected debt after 1 month for a specific user with 80,000 debt
        /// at a mocked redemption rate
        uint256 debAfter1Month = 77_777_945_640_992_000_000_000;

        /// @dev expected deposit after 1 month for a specific user with 100,000 deposit
        /// at a mocked redemption rate
        uint256 depositAfter1Month = 98_777_945_640_991_999_999_997;

        /// @dev faking total collateral
        uint256 depositAmountLarge = 800_000e18;

        /// @dev faking underlying token supply of vault after 1 month at 12% APY i.e. 1% increase per month starting from the initial 15_000_000
        uint256 vaultTotalSupplyAfter1Month = 15_150_000e18;

        // warp to a start time
        vm.warp(1_719_590_015);

        /// simulating a desposit and mint from a user

        vm.startPrank(externalUser);

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmountLarge, externalUser);

        alchemist.mint(mintAmountLarge, externalUser);

        vm.stopPrank();

        /// simulating mint from another user with a smaller resulting debt share

        vm.startPrank(address(0xbeef));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));

        alchemist.mint(mintAmountSmall, address(0xbeef));

        // Fake yield accrual after 1 month @ 12% APY
        deal(address(fakeUnderlyingToken), address(fakeYieldToken), vaultTotalSupplyAfter1Month, true);

        // warp by 1 month. i.e. 86400s per day for 1 month / Roughly 30 days
        vm.warp(1_719_590_095 + (30 * 86_400));

        /// cdp of the same user with small debt share after 1 month
        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));

        // i.e. 100,000 collateral + yield - ((.001307 alAsset per second * 86_400 seconds * 30 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(deposit, depositAfter1Month, minimumDepositOrWithdrawalLoss);

        // i.e. 80,000 debt - ((.001307 alAsset per second * 86_400 seconds * 30 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), debAfter1Month, minimumDepositOrWithdrawalLoss);

        vm.stopPrank();
    }

    // /// APY : 12% | Share of Debt : 22.22% | LTV : 80%  | Duration : 6 months ///

    function testCDP12PercentAPY6MonthsHighShare1() external {
        /// @dev mint amount used in this for the cdp postion test
        uint256 mintAmountSmall = 80_000e18;

        /// @dev starting debt position of this alchemist before user test
        uint256 mintAmountLarge = 280_000e18;

        /// @dev expected debt after 6 months for a specific user with 80,000 debt
        /// at a mocked redemption rate
        uint256 debAfter6Months = 66_668_016_744_992_000_000_000;

        /// @dev expected deposit after 6 months for a specific user with 100,000 deposit
        /// at a mocked redemption rate
        uint256 depositAfter6Months = 92_820_030_078_325_333_299_997;

        /// @dev faking total collateral
        uint256 depositAmountLarge = 800_000e18;

        /// @dev faking underlying token supply of vault after 6 months at 12% APY i.e. 1% increase per month starting from the initial 15_000_000
        uint256 vaultTotalSupplyAfter6Months = 15_922_802e18;

        // warp to a start time
        vm.warp(1_719_590_015);

        /// simulating a desposit and mint from a user

        vm.startPrank(externalUser);

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmountLarge, externalUser);

        alchemist.mint(mintAmountLarge, externalUser);

        vm.stopPrank();

        /// simulating mint from another user with a smaller resulting debt share

        vm.startPrank(address(0xbeef));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));

        alchemist.mint(mintAmountSmall, address(0xbeef));

        // Fake yield accrual after 6 months @ 12% APY
        deal(address(fakeUnderlyingToken), address(fakeYieldToken), vaultTotalSupplyAfter6Months, true);

        // warp by 6 months. i.e. 86400s per day for 1 month / Roughly 180 days
        vm.warp(1_719_590_095 + (180 * 86_400));

        /// cdp of the same user with small debt share after 6 months
        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));

        // i.e. 100,000 collateral + yield - ((.001307 alAsset per second * 86_400 seconds * 180 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(deposit, depositAfter6Months, minimumDepositOrWithdrawalLoss);

        // i.e. 80,000 debt - ((.001307 alAsset per second * 86_400 seconds * 180 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), debAfter6Months, minimumDepositOrWithdrawalLoss);

        vm.stopPrank();
    }

    /// APY : 12% | Share of Debt : 22.22% | LTV : 80%  | Duration : 12 months ///

    function testCDP12PercentAPY12MonthsHighShare1() external {
        /// @dev mint amount used in this for the cdp postion test
        uint256 mintAmountSmall = 80_000e18;

        /// @dev starting debt position of this alchemist before user test
        uint256 mintAmountLarge = 280_000e18;

        /// @dev expected debt after 12 months for a specific user with 80,000 debt
        /// at a mocked redemption rate
        uint256 debAfter12Months = 52_965_771_106_592_000_000_000;

        /// @dev expected deposit after 12 months for a specific user with 100,000 deposit
        /// at a mocked redemption rate
        uint256 depositAfter12Months = 79_117_784_439_925_333_299_997;

        /// @dev faking total collateral
        uint256 depositAmountLarge = 800_000e18;

        /// @dev faking underlying token supply of vault after 12 months at 12% APY i.e. 1% increase per month starting from the initial 15_000_000
        uint256 vaultTotalSupplyAfter6Months = 15_922_802e18;

        // warp to a start time
        vm.warp(1_719_590_015);

        /// simulating a desposit and mint from a user

        vm.startPrank(externalUser);

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmountLarge, externalUser);

        alchemist.mint(mintAmountLarge, externalUser);

        vm.stopPrank();

        /// simulating mint from another user with a smaller resulting debt share

        vm.startPrank(address(0xbeef));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));

        alchemist.mint(mintAmountSmall, address(0xbeef));

        // Fake yield accrual after 12 months @ 12% APY
        deal(address(fakeUnderlyingToken), address(fakeYieldToken), vaultTotalSupplyAfter6Months, true);

        // warp by 12 months. i.e. 86400s per day for 12 month / Roughly 365 days
        vm.warp(1_719_590_095 + (365 * 86_400));

        /// cdp of the same user with small debt share after 12 months
        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));

        // i.e. 100,000 collateral + yield - ((.001307 alAsset per second * 86_400 seconds * 365 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(deposit, depositAfter12Months, minimumDepositOrWithdrawalLoss);

        // i.e. 80,000 debt - ((.001307 alAsset per second * 86_400 seconds * 365 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), debAfter12Months, minimumDepositOrWithdrawalLoss);

        vm.stopPrank();
    }

    /// Low LTV Cases ------------------------------------------------------------------------------- ///

    // APY : 12% | Share of Debt : 2.78% | LTV : 10%  | Duration : 1 month ///

    function testCDP12PercentAPY1MonthLowShare1() external {
        /// @dev mint amount used in this for the cdp postion test
        uint256 mintAmountSmall = 10_000e18;

        /// @dev starting debt position of this alchemist before user test
        uint256 mintAmountLarge = 350_000e18;

        /// @dev expected debt after 1 month month for a specific user with 10,000 debt
        /// at a mocked redemption rate
        uint256 debAfter1Month = 9_722_993_223_472_000_000_000;

        /// @dev expected deposit after 1 month for a specific user with 100,000 deposit
        /// at a mocked redemption rate
        uint256 depositAfter1Month = 100_722_993_223_471_999_999_997;

        /// @dev faking total collateral
        uint256 depositAmountLarge = 800_000e18;

        /// @dev faking underlying token supply of vault after 1 month at 12% APY i.e. 1% increase per month starting from the initial 15_000_000
        uint256 vaultTotalSupplyAfter6Months = 15_150_000e18;

        // warp to a start time
        vm.warp(1_719_590_015);

        /// simulating a desposit and mint from a user

        vm.startPrank(externalUser);

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmountLarge, externalUser);

        alchemist.mint(mintAmountLarge, externalUser);

        vm.stopPrank();

        /// simulating a desposit and mint from another user with a smaller resulting debt share

        vm.startPrank(address(0xbeef));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));

        alchemist.mint(mintAmountSmall, address(0xbeef));

        // Fake yield accrual after 1 month @ 12% APY
        deal(address(fakeUnderlyingToken), address(fakeYieldToken), vaultTotalSupplyAfter6Months, true);

        // warp by 1 month. i.e. 86400s per day for 6 months / Roughly 180 days
        vm.warp(1_719_590_095 + (30 * 86_400));

        /// cdp of the same user with small debt share after 1 month
        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));

        // i.e. 100,000 collateral + yield - ((.001307 alAsset per second * 86_400 seconds * 30 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(deposit, depositAfter1Month, minimumDepositOrWithdrawalLoss);

        // i.e. 10,000 debt - ((.001307 alAsset per second * 86_400 seconds * 30 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), debAfter1Month, minimumDepositOrWithdrawalLoss);

        vm.stopPrank();
    }

    // APY : 12% | Share of Debt : 2.78% | LTV : 10%  | Duration : 6 months ///

    function testCDP12PercentAPY6MonthsLowShare1() external {
        /// @dev mint amount used in this for the cdp postion test
        uint256 mintAmountSmall = 10_000e18;

        /// @dev starting debt position of this alchemist before user test
        uint256 mintAmountLarge = 350_000e18;

        /// @dev expected debt after 6 monghs month for a specific user with 10,000 debt
        /// at a mocked redemption rate
        uint256 debAfter6Months = 8_338_002_087_472_000_000_000;

        /// @dev expected deposit after 6 months for a specific user with 100,000 deposit
        /// at a mocked redemption rate
        uint256 depositAfter6Months = 104_490_015_420_805_333_299_997;

        /// @dev faking total collateral
        uint256 depositAmountLarge = 800_000e18;

        /// @dev faking underlying token supply of vault after 6 months at 12% APY i.e. 1% increase per month starting from the initial 15_000_000
        uint256 vaultTotalSupplyAfter6Months = 15_922_802e18;

        // warp to a start time
        vm.warp(1_719_590_015);

        /// simulating a desposit and mint from a user

        vm.startPrank(externalUser);

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmountLarge, externalUser);

        alchemist.mint(mintAmountLarge, externalUser);

        vm.stopPrank();

        /// simulating a desposit and mint from another user with a smaller resulting debt share

        vm.startPrank(address(0xbeef));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));

        alchemist.mint(mintAmountSmall, address(0xbeef));

        // Fake yield accrual after 6 months @ 12% APY
        deal(address(fakeUnderlyingToken), address(fakeYieldToken), vaultTotalSupplyAfter6Months, true);

        // warp by 6 months. i.e. 86400s per day for 6 months / Roughly 180 days
        vm.warp(1_719_590_095 + (180 * 86_400));

        /// cdp of the same user with small debt share after 6 months
        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));

        // i.e. 100,000 collateral + yield - ((.001307 alAsset per second * 86_400 seconds * 180 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(deposit, depositAfter6Months, minimumDepositOrWithdrawalLoss);

        // i.e. 10,000 debt - ((.001307 alAsset per seconds * 86_400 seconds * 180 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), debAfter6Months, minimumDepositOrWithdrawalLoss);

        vm.stopPrank();
    }

    /// APY : 12% | Share of Debt : 2.78% | LTV : 10%  | Duration : 12 months ///

    function testCDP12PercentAPY12MonthsLowShare1() external {
        /// @dev mint amount used in this for the cdp postion test
        uint256 mintAmountSmall = 10_000e18;

        /// @dev starting debt position of this alchemist before user test
        uint256 mintAmountLarge = 350_000e18;

        /// @dev expected debt after 12 monghs month for a specific user with 10,000 debt
        /// at a mocked redemption rate
        uint256 debAfter6Months = 6_629_846_353_072_000_000_000;

        /// @dev expected deposit after 12 months for a specific user with 100,000 deposit
        /// at a mocked redemption rate
        uint256 depositAfter6Months = 109_312_346_353_071_999_999_997;

        /// @dev faking total collateral
        uint256 depositAmountLarge = 800_000e18;

        /// @dev faking underlying token supply of vault after 12 months at 12% APY i.e. 1% increase per month starting from the initial 15_000_000
        uint256 vaultTotalSupplyAfter6Months = 16_902_375e18;

        // warp to a start time
        vm.warp(1_719_590_015);

        /// simulating a desposit and mint from a user

        vm.startPrank(externalUser);

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmountLarge, externalUser);

        alchemist.mint(mintAmountLarge, externalUser);

        vm.stopPrank();

        /// simulating mint from another user with a smaller resulting debt share

        vm.startPrank(address(0xbeef));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));

        alchemist.mint(mintAmountSmall, address(0xbeef));

        // Fake yield accrual after 12 months @ 12% APY
        deal(address(fakeUnderlyingToken), address(fakeYieldToken), vaultTotalSupplyAfter6Months, true);

        // warp by 12 months. i.e. 86400s per day for 12 months / Roughly 365 days
        vm.warp(1_719_590_095 + (365 * 86_400));

        /// cdp of the same user with small debt share after 6 months
        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));

        // i.e. 100,000 collateral + yield - ((.001307 alAsset per second * 86_400 seconds * 365 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(deposit, depositAfter6Months, minimumDepositOrWithdrawalLoss);

        // i.e. 10,000 debt - ((.001307 alAsset per second * 86_400 seconds * 365 days ) * 0.0278 share of debt)
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), debAfter6Months, minimumDepositOrWithdrawalLoss);

        vm.stopPrank();
    }
}
