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
    uint256 accountFunds = 10_000_000e18;

    // amount of yield/underlying token to deposit
    uint256 depositAmount = 100_000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDeposit = 1000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDepositOrWithdrawalLoss = 1e18;

    // random EOA for testing
    address externalUser = address(0x69E8cE9bFc01AA33cD2d02Ed91c72224481Fa420);

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

        vm.stopPrank();

        // Add funds to test account
        deal(address(fakeYieldToken), address(0xbeef), accountFunds);
    }

    function testDeposit() external {
        vm.prank(address(0xdead));
        whitelist.add(address(0xbeef));
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));
        vm.assertApproxEqAbs(alchemist.totalValue(address(0xbeef)), depositAmount, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testWithdrawal() external {
        vm.prank(address(0xdead));
        whitelist.add(address(0xbeef));
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));
        uint256 shares = alchemist.convertYieldTokensToShares(address(fakeYieldToken), depositAmount);
        alchemist.withdraw(address(fakeYieldToken), shares / 2, address(0xbeef));
        vm.assertApproxEqAbs(alchemist.totalValue(address(0xbeef)), depositAmount / 2, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testCDPWithZeroDebt() external {
        vm.prank(address(0xdead));
        whitelist.add(address(0xbeef));
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));
        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));
        vm.assertApproxEqAbs(deposit, depositAmount, minimumDepositOrWithdrawalLoss);
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), 0, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testCDPPositionWithZeroAPY1Day() external {
        uint256 mintAmount = 80_000e18;

        /// @dev expected debt after 1 day / 86400s for a speicifc user with 80,000 debt
        /// at a mocked redemption rate on a capped amount of total collateral in an Alchemist
        uint256 debAfterOneDay = 79_988_792_120_269_569_764_160;

        /// @dev expected deposit after 1 day / 86400s for a specific user with 100,000 deposit
        /// at a mocked redemption rate on a capped amount of total collateral in an Alchemist
        uint256 depositAfterOneDay = 99_988_792_120_269_569_764_160;

        vm.prank(address(0xdead));

        vm.warp(1_719_590_015);

        whitelist.add(address(0xbeef));

        vm.startPrank(address(0xbeef));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));

        alchemist.mint(mintAmount, address(0xbeef));

        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));

        vm.assertApproxEqAbs(deposit, depositAmount, minimumDepositOrWithdrawalLoss);

        vm.assertApproxEqAbs(SafeCast.toUint256(debt), mintAmount, minimumDepositOrWithdrawalLoss);

        // warp by 1 day / 86400s
        vm.warp(1_719_590_095 + 86_400);

        (deposit, debt) = alchemist.getCDP(address(0xbeef));

        vm.assertApproxEqAbs(deposit, depositAfterOneDay, minimumDepositOrWithdrawalLoss);

        vm.assertApproxEqAbs(SafeCast.toUint256(debt), debAfterOneDay, minimumDepositOrWithdrawalLoss);

        vm.stopPrank();
    }

    function testCDPPositionWithZeroAPY1Month() external {
        uint256 mintAmount = 80_000e18;

        /// @dev expected debt after 1 month for a specific user with 80,000 debt
        /// at a mocked redemption rate on a capped amount of total collateral in an Alchemist
        uint256 debAfterOneMonth = 79_246_832_792_141_005_852_324;

        /// @dev expected deposit after 1 month for a specific user with 100,000 deposit
        /// at a mocked redemption rate on a capped amount of total collateral in an Alchemist
        uint256 depositAfterOneMonth = 99_246_832_792_141_005_852_324;

        /// @dev faking total collateral in aclhemist
        uint256 initialAlchemistCollateral = 909_000e18;

        uint256 initialBorrowedAmount = 280_000e18;

        deal(address(fakeYieldToken), address(0xD4D86f77aC52E0e8a26E474503C51930F022649f), accountFunds);

        vm.startPrank(address(0xdead));

        vm.warp(1_719_590_015);

        whitelist.add(address(0xbeef));

        whitelist.add(address(0xD4D86f77aC52E0e8a26E474503C51930F022649f));

        vm.stopPrank();

        /// simulating mint from a user

        vm.startPrank(address(0xD4D86f77aC52E0e8a26E474503C51930F022649f));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), initialAlchemistCollateral, address(0xD4D86f77aC52E0e8a26E474503C51930F022649f));

        alchemist.mint(initialBorrowedAmount, address(0xD4D86f77aC52E0e8a26E474503C51930F022649f));

        vm.stopPrank();

        /// simulating mint from another user with a smaller resulting debt share

        vm.startPrank(address(0xbeef));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));

        alchemist.mint(mintAmount, address(0xbeef));

        /// cdp of the same user with small debt share after 1 month

        // warp by 1 month. i.e. 86400s per day for Roughly 30 days
        vm.warp(1_719_590_095 + (30 * 86_400));

        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));

        // i.e. 100,000 collateral - ((.001307 alAsset per second * 86400 seconds * 30 days ) * 0.22 share of debt)
        vm.assertApproxEqAbs(deposit, depositAfterOneMonth, minimumDepositOrWithdrawalLoss);

        // i.e. 80,000 debt - ((.001307 alAsset per second * 86400 seconds * 30 days ) * 0.22 share of debt)
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), debAfterOneMonth, minimumDepositOrWithdrawalLoss);

        vm.stopPrank();
    }

    function testCDPPositionWith12PercentAPY1Month() external {
        uint256 mintAmount = 80_000e18;

        /// @dev expected debt after 1 month for a specific user with 80,000 debt
        /// at a mocked redemption rate on a capped amount of total collateral in an Alchemist
        uint256 debAfterOneMonth = 79_924_608_634_297_563_812_243;

        /// @dev expected deposit after 1 month for a specific user with 100,000 deposit
        /// at a mocked redemption rate on a capped amount of total collateral in an Alchemist
        uint256 depositAfterOneMonth = 99_924_608_634_297_563_812_243;

        /// @dev faking total collateral
        uint256 initialAlchemistCollateral = 900_000e18;

        /// @dev collateral after 1 month at 12% APY i.e. 1% increase per month starting from initial 900_000e18 + 100_000e18 deposited
        uint256 alchemistCollateralAfter1Month = 101_000e18;

        uint256 initialBorrowedAmount = 280_000e18;

        deal(address(fakeYieldToken), externalUser, accountFunds);

        vm.warp(1_719_590_015);

        vm.startPrank(address(0xdead));

        whitelist.add(address(0xbeef));

        whitelist.add(externalUser);

        vm.stopPrank();

        /// simulating mint from a user

        vm.startPrank(externalUser);

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), initialAlchemistCollateral, externalUser);

        alchemist.mint(initialBorrowedAmount, externalUser);

        vm.stopPrank();

        /// simulating mint from another user with a smaller resulting debt share

        vm.startPrank(address(0xbeef));

        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);

        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));

        alchemist.mint(mintAmount, address(0xbeef));

        /// cdp of the same user with small debt share after 1 month

        // warp by 1 month. i.e. 86400s per day for Roughly 30 days
        vm.warp(1_719_590_095 + (30 * 86_400));

        // Fake yeild accrual after 1 month @ 12% APY
        deal(address(fakeYieldToken), address(alchemist), alchemistCollateralAfter1Month);

        (uint256 deposit, int256 debt) = alchemist.getCDP(address(0xbeef));

        // i.e. 100,000 collateral + yield - ((.001307 alAsset per second * 86400 seconds * 30 days ) * 0.22 share of debt)
        vm.assertApproxEqAbs(deposit, depositAfterOneMonth, minimumDepositOrWithdrawalLoss);

        // i.e. 80,000 debt - ((.001307 alAsset per second * 86400 seconds * 30 days ) * 0.22 share of debt)
        vm.assertApproxEqAbs(SafeCast.toUint256(debt), debAfterOneMonth, minimumDepositOrWithdrawalLoss);

        vm.stopPrank();
    }
}
