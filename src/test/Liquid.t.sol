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
import {AggregatorV3Interface} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {LiquidTokenVault} from "../LiquidTokenVault.sol";

contract LiquidTest is Test {
    // ----- [SETUP] Variables for setting up a minimal CDP -----

    // Callable contract variables
    Liquid liquid;
    LiquidTransmuter transmuter;
    LiquidPosition liquidNFT;
    LiquidTokenVault liquidFeeVault;

    // // Proxy variables
    TransparentUpgradeableProxy proxyLiquid;
    TransparentUpgradeableProxy proxyTransmuter;

    // // Contract variables
    // CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
    Liquid liquidLogic;
    LiquidTransmuter transmuterLogic;
    LiquidMintableToken alToken;
    Whitelist whitelist;

    // Token addresses
    TestERC20 fakeUnderlyingToken;
    TestYieldToken fakeYieldToken;

    // Parameters for Liquid MintableTokenV2
    string public _name;
    string public _symbol;
    uint256 public _flashFee;
    address public alOwner;

    mapping(address => bool) users;

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public constant BPS = 10_000;

    uint256 public protocolFee = 100;

    uint256 public liquidatorFeeBPS = 300; // in BPS, 3%

    uint256 public minimumCollateralization = uint256(FIXED_POINT_SCALAR * FIXED_POINT_SCALAR) / 9e17;

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 accountFunds = 2_000_000_000e18;

    // large amount to test with
    uint256 whaleSupply = 20_000_000_000e18;

    // amount of yield/underlying token to deposit
    uint256 depositAmount = 200_000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDeposit = 1000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDepositOrWithdrawalLoss = FIXED_POINT_SCALAR;

    // random EOA for testing
    address externalUser = address(0x69E8cE9bFc01AA33cD2d02Ed91c72224481Fa420);

    // another random EOA for testing
    address anotherExternalUser = address(0x420Ab24368E5bA8b727E9B8aB967073Ff9316969);

    // another random EOA for testing
    address yetAnotherExternalUser = address(0x520aB24368e5Ba8B727E9b8aB967073Ff9316961);

    // another random EOA for testing
    address someWhale = address(0x521aB24368E5Ba8b727e9b8AB967073fF9316961);

    // WETH address
    address public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address public protocolFeeReceiver = address(10);

    struct CalculateLiquidationResult {
        uint256 liquidationAmountInYield;
        uint256 debtToBurn;
        uint256 outSourcedFee;
        uint256 baseFeeInYield;
    }

    struct AccountPosition {
        address user;
        uint256 collateral;
        uint256 debt;
        uint256 tokenId;
    }

    function setUp() external {
        deployCoreContracts(18);
    }

    function deployCoreContracts(uint256 liquidUnderlyingTokenDecimals) public {
        // test maniplulation for convenience
        address caller = address(0xdead);
        address proxyOwner = address(this);
        vm.assume(caller != address(0));
        vm.assume(proxyOwner != address(0));
        vm.assume(caller != proxyOwner);
        vm.startPrank(caller);

        // Fake tokens

        fakeUnderlyingToken = new TestERC20(100e18, uint8(liquidUnderlyingTokenDecimals));
        fakeYieldToken = new TestYieldToken(address(fakeUnderlyingToken));
        alToken = new LiquidMintableToken(_name, _symbol, _flashFee);

        ILiquidTransmuter.TransmuterInitializationParams memory transParams = ILiquidTransmuter.TransmuterInitializationParams({
            syntheticToken: address(alToken), feeReceiver: address(this), timeToTransmute: 5_256_000, transmutationFee: 10, exitFee: 20, graphSize: 52_560_000
        });

        // Contracts and logic contracts
        alOwner = caller;
        transmuterLogic = new LiquidTransmuter(transParams);
        liquidLogic = new Liquid();
        whitelist = new Whitelist();

        // Liquid proxy
        LiquidInitializationParams memory params = LiquidInitializationParams({
            admin: alOwner,
            debtToken: address(alToken),
            underlyingToken: address(fakeUnderlyingToken),
            yieldToken: address(fakeYieldToken),
            blocksPerYear: 2_600_000,
            depositCap: type(uint256).max,
            minimumCollateralization: minimumCollateralization,
            collateralizationLowerBound: 1_052_631_578_950_000_000, // 1.05 collateralization
            globalMinimumCollateralization: 1_111_111_111_111_111_111, // 1.1
            tokenAdapter: address(fakeYieldToken),
            maxPriceDeviation: 1e18,
            transmuter: address(transmuterLogic),
            protocolFee: 0,
            protocolFeeReceiver: protocolFeeReceiver,
            liquidatorFee: liquidatorFeeBPS,
            repaymentFee: 100
        });

        bytes memory alchemParams = abi.encodeWithSelector(Liquid.initialize.selector, params);
        proxyLiquid = new TransparentUpgradeableProxy(address(liquidLogic), proxyOwner, alchemParams);
        liquid = Liquid(address(proxyLiquid));

        // Whitelist liquid proxy for minting tokens
        alToken.setWhitelist(address(proxyLiquid), true);

        whitelist.add(address(0xbeef));
        whitelist.add(externalUser);
        whitelist.add(anotherExternalUser);

        transmuterLogic.setLiquid(address(liquid));
        transmuterLogic.setDepositCap(uint256(type(int256).max));

        liquidNFT = new LiquidPosition(address(liquid));
        liquid.setLiquidPositionNFT(address(liquidNFT));

        liquidFeeVault = new LiquidTokenVault(address(fakeUnderlyingToken), address(liquid), alOwner);
        liquidFeeVault.setAuthorization(address(liquid), true);
        liquid.setLiquidFeeVault(address(liquidFeeVault));
        vm.stopPrank();

        // Add funds to test accounts
        deal(address(fakeYieldToken), address(0xbeef), accountFunds);
        deal(address(fakeYieldToken), address(0xdad), accountFunds);
        deal(address(fakeYieldToken), externalUser, accountFunds);
        deal(address(fakeYieldToken), yetAnotherExternalUser, accountFunds);
        deal(address(fakeYieldToken), anotherExternalUser, accountFunds);
        deal(address(alToken), address(0xdad), 1000e18);
        deal(address(alToken), address(anotherExternalUser), accountFunds);

        deal(address(fakeUnderlyingToken), address(0xbeef), accountFunds);
        deal(address(fakeUnderlyingToken), externalUser, accountFunds);
        deal(address(fakeUnderlyingToken), yetAnotherExternalUser, accountFunds);
        deal(address(fakeUnderlyingToken), anotherExternalUser, accountFunds);
        deal(address(fakeUnderlyingToken), liquid.liquidFeeVault(), 10_000 ether);

        vm.startPrank(anotherExternalUser);

        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), accountFunds);

        vm.stopPrank();
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), accountFunds);
        vm.stopPrank();

        vm.startPrank(someWhale);
        deal(address(fakeYieldToken), someWhale, whaleSupply);
        deal(address(fakeUnderlyingToken), someWhale, whaleSupply);
        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), whaleSupply + 100e18);
        vm.stopPrank();
    }

    function testSetV3PositionNFTAlreadySetRevert() public {
        vm.startPrank(alOwner);
        vm.expectRevert();
        liquid.setLiquidPositionNFT(address(0xdBdb4d16EdA451D0503b854CF79D55697F90c8DF));
        vm.stopPrank();
    }

    function testSetProtocolFeeTooHigh() public {
        vm.startPrank(alOwner);
        vm.expectRevert();
        liquid.setProtocolFee(10_001);
        vm.stopPrank();
    }

    function testSetLiquidationFeeTooHigh() public {
        vm.startPrank(alOwner);
        vm.expectRevert();
        liquid.setLiquidatorFee(10_001);
        vm.stopPrank();
    }

    function testSetRepaymentFeeTooHigh() public {
        vm.startPrank(alOwner);
        vm.expectRevert();
        liquid.setRepaymentFee(10_001);
        vm.stopPrank();
    }

    function testSetProtocolFee() public {
        vm.startPrank(alOwner);
        liquid.setProtocolFee(100);
        vm.stopPrank();

        assertEq(liquid.protocolFee(), 100);
    }

    function testSetLiquidationFee() public {
        vm.startPrank(alOwner);
        liquid.setLiquidatorFee(100);
        vm.stopPrank();

        assertEq(liquid.liquidatorFee(), 100);
    }

    function testSetRepaymentFee() public {
        vm.startPrank(alOwner);
        liquid.setRepaymentFee(100);
        vm.stopPrank();

        assertEq(liquid.repaymentFee(), 100);
    }

    function testSetMinimumCollaterization_Invalid_Ratio_Below_One(uint256 collateralizationRatio) external {
        // ~ all possible ratios below 1
        vm.assume(collateralizationRatio < FIXED_POINT_SCALAR);
        vm.startPrank(alOwner);
        vm.expectRevert(IllegalArgument.selector);
        liquid.setMinimumCollateralization(collateralizationRatio);
        vm.stopPrank();
    }

    function testSetCollateralizationLowerBound_Variable_Upper_Bound(uint256 collateralizationRatio) external {
        collateralizationRatio = bound(collateralizationRatio, FIXED_POINT_SCALAR, minimumCollateralization);
        vm.startPrank(alOwner);
        liquid.setCollateralizationLowerBound(collateralizationRatio);
        vm.assertApproxEqAbs(liquid.collateralizationLowerBound(), collateralizationRatio, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetCollateralizationLowerBound_Invalid_Above_Minimumcollaterization(uint256 collateralizationRatio) external {
        // ~ all possible ratios above minimum collaterization ratio
        vm.assume(collateralizationRatio > minimumCollateralization);
        vm.startPrank(alOwner);
        vm.expectRevert(IllegalArgument.selector);
        liquid.setCollateralizationLowerBound(collateralizationRatio);
        vm.stopPrank();
    }

    function testSetCollateralizationLowerBound_Invalid_Below_One(uint256 collateralizationRatio) external {
        // ~ all possible ratios below minimum collaterization ratio
        vm.assume(collateralizationRatio < FIXED_POINT_SCALAR);
        vm.startPrank(alOwner);
        vm.expectRevert(IllegalArgument.selector);
        liquid.setCollateralizationLowerBound(collateralizationRatio);
        vm.stopPrank();
    }

    function testSetGlobalMinimumCollateralization_Variable_Ratio(uint256 collateralizationRatio) external {
        // The global floor lives at or below the mint bar: at full utilisation
        // every borrower sits at the bar and the protocol-wide ratio equals it.
        collateralizationRatio = bound(collateralizationRatio, FIXED_POINT_SCALAR, minimumCollateralization);
        vm.startPrank(alOwner);
        liquid.setGlobalMinimumCollateralization(collateralizationRatio);
        vm.assertApproxEqAbs(liquid.globalMinimumCollateralization(), collateralizationRatio, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetGlobalMinimumCollateralization_Invalid_Above_MinimumCollateralization(uint256 collateralizationRatio) external {
        // A global floor above the mint bar declares a healthy, fully-drawn
        // protocol insolvent and sends every liquidation down the bad-debt path.
        vm.assume(collateralizationRatio > minimumCollateralization);
        vm.startPrank(alOwner);
        vm.expectRevert(IllegalArgument.selector);
        liquid.setGlobalMinimumCollateralization(collateralizationRatio);
        vm.stopPrank();
    }

    function testSetGlobalMinimumCollateralization_Invalid_Below_One() external {
        vm.startPrank(alOwner);
        vm.expectRevert(IllegalArgument.selector);
        liquid.setGlobalMinimumCollateralization(FIXED_POINT_SCALAR - 1);
        vm.stopPrank();
    }

    function testSetNewAdmin() external {
        vm.prank(alOwner);
        liquid.setPendingAdmin(address(0xbeef));

        vm.prank(address(0xbeef));
        liquid.acceptAdmin();

        assertEq(liquid.admin(), address(0xbeef));
    }

    function testSetNewAdminNotPendingAdmin() external {
        vm.prank(alOwner);
        liquid.setPendingAdmin(address(0xbeef));

        vm.startPrank(address(0xdad));
        vm.expectRevert();
        liquid.acceptAdmin();
        vm.stopPrank();
    }

    function testSetNewAdminNotCurrentAdmin() external {
        vm.expectRevert();
        liquid.setPendingAdmin(address(0xbeef));
    }

    function testSetNewAdminZeroAddress() external {
        vm.expectRevert();
        liquid.acceptAdmin();

        assertEq(liquid.pendingAdmin(), address(0));
    }

    function testSetLiquidFeeVault_Revert_If_Vault_Token_Mismatch() external {
        vm.startPrank(alOwner);
        LiquidTokenVault vault = new LiquidTokenVault(address(fakeYieldToken), address(liquid), alOwner);
        vault.setAuthorization(address(liquid), true);
        vm.expectRevert();
        liquid.setLiquidFeeVault(address(vault));
        vm.stopPrank();
    }

    function testSetGuardianAndRemove() external {
        assertEq(liquid.guardians(address(0xbad)), false);
        vm.prank(alOwner);
        liquid.setGuardian(address(0xbad), true);

        assertEq(liquid.guardians(address(0xbad)), true);

        vm.prank(alOwner);
        liquid.setGuardian(address(0xbad), false);

        assertEq(liquid.guardians(address(0xbad)), false);
    }

    function testSetProtocolFeeReceiver() external {
        vm.prank(alOwner);
        liquid.setProtocolFeeReceiver(address(0xbeef));

        assertEq(liquid.protocolFeeReceiver(), address(0xbeef));
    }

    function testSetProtocolFeeReceiveZeroAddress() external {
        vm.startPrank(alOwner);
        vm.expectRevert();
        liquid.setProtocolFeeReceiver(address(0));

        vm.stopPrank();

        assertEq(liquid.protocolFeeReceiver(), address(10));
    }

    function testSetProtocolFeeReceiverNotAdmin() external {
        vm.expectRevert();
        liquid.setProtocolFeeReceiver(address(0xbeef));
    }

    function testSetMinCollateralization_Variable_Collateralization(uint256 collateralization) external {
        // The mint bar cannot drop below the floors that sit under it.
        collateralization = bound(collateralization, liquid.globalMinimumCollateralization(), 20e18);
        vm.startPrank(address(0xdead));
        liquid.setMinimumCollateralization(collateralization);
        vm.assertApproxEqAbs(liquid.minimumCollateralization(), collateralization, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testSetMinCollateralization_Invalid_Collateralization_Zero() external {
        uint256 collateralization = 0;
        vm.startPrank(address(0xdead));
        vm.expectRevert(IllegalArgument.selector);
        liquid.setMinimumCollateralization(collateralization);
        vm.stopPrank();
    }

    function testSetMinimumCollateralizationNotAdmin() external {
        vm.expectRevert();
        liquid.setMinimumCollateralization(0);
    }

    function testPauseDeposits() external {
        assertEq(liquid.depositsPaused(), false);

        vm.prank(alOwner);
        liquid.pauseDeposits(true);

        assertEq(liquid.depositsPaused(), true);

        vm.prank(alOwner);
        liquid.setGuardian(address(0xbad), true);

        vm.prank(address(0xbad));
        liquid.pauseDeposits(false);

        assertEq(liquid.depositsPaused(), false);

        // Test for onlyAdminOrGuardian modifier
        vm.expectRevert();
        liquid.pauseDeposits(true);

        assertEq(liquid.depositsPaused(), false);
    }

    function testPauseLoans() external {
        assertEq(liquid.loansPaused(), false);

        vm.prank(alOwner);
        liquid.pauseLoans(true);

        assertEq(liquid.loansPaused(), true);

        vm.prank(alOwner);
        liquid.setGuardian(address(0xbad), true);

        vm.prank(address(0xbad));
        liquid.pauseLoans(false);

        assertEq(liquid.loansPaused(), false);

        // Test for onlyAdminOrGuardian modifier
        vm.expectRevert();
        liquid.pauseLoans(true);

        assertEq(liquid.loansPaused(), false);
    }

    function testDeposit_New_Position(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, 1000e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        (uint256 depositedCollateral,,) = liquid.getCDP(tokenId);
        vm.assertApproxEqAbs(depositedCollateral, amount, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        assertEq(liquid.getTotalDeposited(), amount);

        (uint256 deposited, uint256 userDebt,) = liquid.getCDP(tokenId);

        assertEq(deposited, amount);
        assertEq(userDebt, 0);

        assertEq(
            liquid.getMaxBorrowable(tokenId),
            liquid.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / FIXED_POINT_SCALAR) * FIXED_POINT_SCALAR
                / liquid.minimumCollateralization()
        );

        assertEq(liquid.getTotalUnderlyingValue(), liquid.convertYieldTokensToUnderlying(amount));

        assertEq(liquid.totalValue(tokenId), liquid.getTotalUnderlyingValue());
    }

    function testDeposit_ExistingPosition(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, 1000e18);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), (amount * 2) + 100e18);

        // first deposit
        liquid.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        // second deposit to existing position with tokenId
        liquid.deposit(amount, address(0xbeef), tokenId);

        (uint256 depositedCollateral,,) = liquid.getCDP(tokenId);
        vm.assertApproxEqAbs(depositedCollateral, (amount * 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        assertEq(liquid.getTotalDeposited(), (amount * 2));

        assertEq(
            liquid.getMaxBorrowable(tokenId),
            liquid.normalizeUnderlyingTokensToDebt(
                (fakeYieldToken.price() * (amount * 2) / FIXED_POINT_SCALAR) * FIXED_POINT_SCALAR / liquid.minimumCollateralization()
            )
        );

        assertEq(liquid.getTotalUnderlyingValue(), liquid.convertYieldTokensToUnderlying((amount * 2)));

        assertEq(liquid.totalValue(tokenId), liquid.getTotalUnderlyingValue());
    }

    function testDepositZeroAmount() external {
        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        liquid.deposit(0, address(0xbeef), 0);

        vm.stopPrank();
    }

    function testDepositZeroAddress() external {
        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        liquid.deposit(10e18, address(0), 0);
        vm.stopPrank();
    }

    function testDepositPaused() external {
        vm.prank(alOwner);
        liquid.pauseDeposits(true);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 100e18);
        vm.expectRevert(IllegalState.selector);
        liquid.deposit(100e18, address(0xbeef), 0);
        vm.stopPrank();
    }

    function testWithdrawZeroIdRevert() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        vm.expectRevert();
        liquid.withdraw(amount / 2, address(0xbeef), 0);
        vm.stopPrank();
    }

    function testWithdrawInvalidIdRevert(uint256 tokenId) external {
        vm.assume(tokenId > 1);
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        vm.expectRevert();
        liquid.withdraw(0, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testWithdraw(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        liquid.withdraw(amount / 2, address(0xbeef), tokenId);
        (uint256 depositedCollateral,,) = liquid.getCDP(tokenId);
        vm.assertApproxEqAbs(depositedCollateral, amount / 2, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        assertApproxEqAbs(liquid.getTotalDeposited(), amount / 2, 1);

        (uint256 deposited, uint256 userDebt,) = liquid.getCDP(tokenId);

        assertApproxEqAbs(deposited, amount / 2, 1);
        assertApproxEqAbs(userDebt, 0, 1);

        assertApproxEqAbs(
            liquid.getMaxBorrowable(tokenId),
            liquid.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / 2 / FIXED_POINT_SCALAR) * FIXED_POINT_SCALAR
                / liquid.minimumCollateralization(),
            1
        );
        assertApproxEqAbs(liquid.getTotalUnderlyingValue(), liquid.convertYieldTokensToUnderlying(amount / 2), 1);
    }

    function testWithdrawUndercollateralilzed() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        liquid.mint(tokenId, amount / 2, address(0xbeef));
        vm.expectRevert();
        liquid.withdraw(amount, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testWithdrawMoreThanPosition() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        vm.expectRevert();
        liquid.withdraw(amount * 2, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testWithdrawZeroAmount() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        vm.expectRevert();
        liquid.withdraw(0, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testWithdrawZeroAddress() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        vm.expectRevert();
        liquid.withdraw(amount / 2, address(0), tokenId);
        vm.stopPrank();
    }

    function testWithdrawUnauthorizedUserRevert() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        vm.stopPrank();
        vm.startPrank(externalUser);
        vm.expectRevert();
        liquid.withdraw(amount / 2, externalUser, tokenId);
        vm.stopPrank();
    }

    function testOwnershipTransferBeforeWithdraw(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        // tranferring ownership to externalUser
        IERC721(address(liquidNFT)).safeTransferFrom(address(0xbeef), externalUser, tokenId);
        vm.stopPrank();

        vm.startPrank(externalUser);

        liquid.withdraw(amount / 2, externalUser, tokenId);

        vm.stopPrank();

        (uint256 depositedCollateral,,) = liquid.getCDP(tokenId);
        vm.assertApproxEqAbs(depositedCollateral, amount / 2, minimumDepositOrWithdrawalLoss);
        assertApproxEqAbs(liquid.getTotalDeposited(), amount / 2, 1);
        (uint256 deposited, uint256 userDebt,) = liquid.getCDP(tokenId);
        assertApproxEqAbs(deposited, amount / 2, 1);
        assertApproxEqAbs(userDebt, 0, 1);

        assertApproxEqAbs(
            liquid.getMaxBorrowable(tokenId),
            liquid.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / 2 / FIXED_POINT_SCALAR) * FIXED_POINT_SCALAR
                / liquid.minimumCollateralization(),
            1
        );
        assertApproxEqAbs(liquid.getTotalUnderlyingValue(), liquid.convertYieldTokensToUnderlying(amount / 2), 1);
    }

    function testOwnershipTransferBeforeWithdrawUnauthorizedRevert(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        // tranferring ownership to externalUser
        IERC721(address(liquidNFT)).safeTransferFrom(address(0xbeef), externalUser, tokenId);
        vm.expectRevert();
        // 0xbeef no longer has ownership of this account/tokenId
        liquid.withdraw(amount / 2, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testMintUnauthorizedUserRevert() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 100e18);
        liquid.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        vm.stopPrank();
        vm.startPrank(externalUser);
        vm.expectRevert();
        liquid.mint(tokenId, 10e18, externalUser);
        vm.stopPrank();
    }

    function testApproveMintUnauthorizedUserRevert() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 100e18);
        liquid.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        vm.stopPrank();
        vm.startPrank(externalUser);
        vm.expectRevert();
        liquid.approveMint(tokenId, externalUser, 100e18);
        vm.stopPrank();
    }

    function testOwnership_Transfer_Before_Mint_Variable_Amount(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 ltv = 2e17;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        // tranferring ownership to externalUser
        IERC721(address(liquidNFT)).safeTransferFrom(address(0xbeef), externalUser, tokenId);
        vm.stopPrank();

        vm.startPrank(externalUser);

        liquid.mint(tokenId, (amount * ltv) / FIXED_POINT_SCALAR, externalUser);
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        (uint256 deposited, uint256 userDebt,) = liquid.getCDP(tokenId);

        assertApproxEqAbs(deposited, amount, 1);
        assertApproxEqAbs(userDebt, amount * ltv / FIXED_POINT_SCALAR, 1);

        assertApproxEqAbs(
            liquid.getMaxBorrowable(tokenId),
            (liquid.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / FIXED_POINT_SCALAR)
                    * FIXED_POINT_SCALAR
                    / liquid.minimumCollateralization()) - (amount * ltv) / FIXED_POINT_SCALAR,
            1
        );

        assertApproxEqAbs(liquid.getTotalUnderlyingValue(), liquid.convertYieldTokensToUnderlying(amount), 1);
    }

    function testOwnership_Transfer_Before_Mint_UnauthorizedRevert(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 ltv = 2e17;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        // tranferring ownership to externalUser
        IERC721(address(liquidNFT)).safeTransferFrom(address(0xbeef), externalUser, tokenId);

        vm.expectRevert();
        liquid.mint(tokenId, (amount * ltv) / FIXED_POINT_SCALAR, externalUser);
        vm.stopPrank();
    }

    function testOwnership_Transfer_Before_ApproveMint_UnauthorizedRevert() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 100e18);
        liquid.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        // tranferring ownership to externalUser
        IERC721(address(liquidNFT)).safeTransferFrom(address(0xbeef), externalUser, tokenId);
        vm.expectRevert();
        liquid.approveMint(tokenId, yetAnotherExternalUser, 100e18);
        vm.stopPrank();
    }

    function testResetMintAllowances_UnauthorizedRevert() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 100e18);
        liquid.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        vm.stopPrank();

        // Caller that isnt the owner of the token id
        vm.startPrank(externalUser);
        vm.expectRevert();
        liquid.resetMintAllowances(tokenId);
        vm.stopPrank();
    }

    function testResetMintAllowancesOnUserCall() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 100e18);
        liquid.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.approveMint(tokenId, externalUser, 50e18);
        vm.stopPrank();

        uint256 allowanceBeforeReset = liquid.mintAllowance(tokenId, externalUser);

        vm.startPrank(address(0xbeef));
        liquid.resetMintAllowances(tokenId);
        vm.stopPrank();

        uint256 allowanceAfterReset = liquid.mintAllowance(tokenId, externalUser);

        assertEq(allowanceBeforeReset, 50e18);
        assertEq(allowanceAfterReset, 0);
    }

    function testResetMintAllowancesOnTransfer() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 100e18);
        liquid.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.approveMint(tokenId, externalUser, 50e18);
        uint256 allowanceBeforeTransfer = liquid.mintAllowance(tokenId, externalUser);
        IERC721(address(liquidNFT)).safeTransferFrom(address(0xbeef), anotherExternalUser, tokenId);
        vm.stopPrank();

        uint256 allowanceAfterTransfer = liquid.mintAllowance(tokenId, externalUser);
        assertEq(allowanceBeforeTransfer, 50e18);
        assertEq(allowanceAfterTransfer, 0);
    }

    function testMint_Variable_Amount(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 ltv = 2e17;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, (amount * ltv) / FIXED_POINT_SCALAR, address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        (uint256 deposited, uint256 userDebt,) = liquid.getCDP(tokenId);

        assertApproxEqAbs(deposited, amount, 1);
        assertApproxEqAbs(userDebt, amount * ltv / FIXED_POINT_SCALAR, 1);

        assertApproxEqAbs(
            liquid.getMaxBorrowable(tokenId),
            (liquid.normalizeUnderlyingTokensToDebt(fakeYieldToken.price() * amount / FIXED_POINT_SCALAR)
                    * FIXED_POINT_SCALAR
                    / liquid.minimumCollateralization()) - (amount * ltv) / FIXED_POINT_SCALAR,
            1
        );

        assertApproxEqAbs(liquid.getTotalUnderlyingValue(), liquid.convertYieldTokensToUnderlying(amount), 1);
    }

    function testMint_Revert_Exceeds_Min_Collateralization(uint256 amount, uint256 collateralization) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);

        collateralization = bound(collateralization, liquid.globalMinimumCollateralization(), 100e18);
        vm.prank(address(0xdead));
        liquid.setMinimumCollateralization(collateralization);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount);
        liquid.deposit(amount, address(0xbeef), 0);

        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        uint256 mintAmount = ((liquid.totalValue(tokenId) * FIXED_POINT_SCALAR) / collateralization) + 1;
        vm.expectRevert(ILiquidErrors.Undercollateralized.selector);
        liquid.mint(tokenId, mintAmount, address(0xbeef));
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount_Revert_No_Allowance(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 minCollateralization = 2e18;

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        /// Make deposit for external user
        liquid.deposit(amount, externalUser, 0);
        // a single position nft would have been minted to address(0xbeef)
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(externalUser, address(liquidNFT));
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        /// 0xbeef mints tokens from `externalUser` account, to be recieved by `externalUser`.
        /// 0xbeef however, has not been approved for any mint amount for `externalUsers` account.
        vm.expectRevert();
        liquid.mintFrom(tokenId, ((amount * minCollateralization) / FIXED_POINT_SCALAR), externalUser);
        vm.stopPrank();
    }

    function testMintFrom_Variable_Amount(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 ltv = 2e17;

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        /// Make deposit for external user
        liquid.deposit(amount, externalUser, 0);

        // a single position nft would have been minted to externalUser
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(externalUser, address(liquidNFT));

        /// 0xbeef has been approved up to a mint amount for minting from `externalUser` account.
        liquid.approveMint(tokenId, address(0xbeef), amount + 100e18);
        vm.stopPrank();

        assertEq(liquid.mintAllowance(tokenId, address(0xbeef)), amount + 100e18);

        vm.startPrank(address(0xbeef));
        liquid.mintFrom(tokenId, ((amount * ltv) / FIXED_POINT_SCALAR), externalUser);

        assertEq(liquid.mintAllowance(tokenId, address(0xbeef)), (amount + 100e18) - (amount * ltv) / FIXED_POINT_SCALAR);

        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount * ltv) / FIXED_POINT_SCALAR, minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
    }

    function testMintPaused() external {
        vm.prank(alOwner);
        liquid.pauseLoans(true);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 100e18);
        liquid.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        vm.expectRevert(IllegalState.selector);
        liquid.mint(tokenId, 10e18, address(0xbeef));
        vm.stopPrank();
    }

    function testMintZeroIdRevert() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 100e18);
        liquid.deposit(100e18, address(0xbeef), 0);
        vm.expectRevert();
        liquid.mint(0, 10e18, address(0xbeef));
        vm.stopPrank();
    }

    function testMintInvalidIdRevert(uint256 tokenId) external {
        vm.assume(tokenId > 1);
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 100e18);
        liquid.deposit(100e18, address(0xbeef), 0);
        vm.expectRevert();
        liquid.mint(tokenId, 10e18, address(0xbeef));
        vm.stopPrank();
    }

    function testDepositInvalidIdRevert(uint256 tokenId) external {
        vm.assume(tokenId > 1);
        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        liquid.deposit(100, address(0xbeef), tokenId);
        vm.stopPrank();
    }

    function testMintFrom_InvalidIdRevert(uint256 amount, uint256 tokenId) external {
        vm.assume(tokenId > 1);
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        uint256 ltv = 2e17;

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        /// Make deposit for external user
        liquid.deposit(amount, externalUser, 0);

        // a single position nft would have been minted to externalUser
        uint256 realTokenId = LiquidNFTHelper.getFirstTokenId(externalUser, address(liquidNFT));

        /// 0xbeef has been approved up to a mint amount for minting from `externalUser` account.
        liquid.approveMint(realTokenId, address(0xbeef), amount + 100e18);
        vm.stopPrank();

        assertEq(liquid.mintAllowance(realTokenId, address(0xbeef)), amount + 100e18);

        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        liquid.mintFrom(tokenId, ((amount * ltv) / FIXED_POINT_SCALAR), externalUser);
        vm.stopPrank();
    }

    function testMintFeeOnDebt() external {
        vm.prank(alOwner);
        // 1%
        liquid.setProtocolFee(100);

        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 5_256_000);

        (uint256 collateral, uint256 userDebt,) = liquid.getCDP(tokenId);

        assertEq(userDebt, (amount / 2));
        assertApproxEqAbs(collateral, amount, 0);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        assertApproxEqAbs(collateral, amount, 0);

        (collateral, userDebt,) = liquid.getCDP(tokenId);

        assertEq(userDebt, 0);
        assertApproxEqAbs(collateral, (amount / 2) - (amount / 2) * 100 / 10_000, 10e18); // Earmark rework changes residual collateral
    }

    function testMintFeeOnDebtPartial() external {
        vm.prank(alOwner);
        // 1%
        liquid.setProtocolFee(100);

        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 5_256_000 / 2);

        (uint256 collateral, uint256 userDebt,) = liquid.getCDP(tokenId);

        assertEq(userDebt, (amount / 2));
        assertApproxEqAbs(collateral, amount, 0);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        assertApproxEqAbs(collateral, amount, 0);

        (collateral, userDebt,) = liquid.getCDP(tokenId);

        assertEq(userDebt, amount / 4);
        assertApproxEqAbs(collateral, (3 * amount / 4) - (amount / 4) * 100 / 10_000, 1);
    }

    function testMintFeeOnDebtMultipleUsers() external {
        vm.prank(alOwner);
        // 1%
        liquid.setProtocolFee(100);
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, externalUser, 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdForExternalUser = LiquidNFTHelper.getFirstTokenId(externalUser, address(liquidNFT));
        liquid.mint(tokenIdForExternalUser, (amount / 2), externalUser);
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 5_256_000);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        (uint256 collateral, uint256 userDebt,) = liquid.getCDP(tokenIdFor0xBeef);
        (uint256 collateral2, uint256 userDebt2,) = liquid.getCDP(tokenIdForExternalUser);

        assertEq(userDebt, amount / 4);
        assertApproxEqAbs(collateral, (3 * amount / 4) - (amount / 4) * 100 / 10_000, 1);

        assertEq(userDebt2, amount / 4);
        assertApproxEqAbs(collateral2, (3 * amount / 4) - (amount / 4) * 100 / 10_000, 1);
    }

    function testMintFeeOnDebtPartialMultipleUsers() external {
        vm.prank(alOwner);
        // 1%
        liquid.setProtocolFee(100);

        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, externalUser, 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdForExternalUser = LiquidNFTHelper.getFirstTokenId(externalUser, address(liquidNFT));
        liquid.mint(tokenIdForExternalUser, (amount / 2), externalUser);
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 5_256_000 / 2);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        (uint256 collateral, uint256 userDebt,) = liquid.getCDP(tokenIdFor0xBeef);
        (uint256 collateral2, uint256 userDebt2,) = liquid.getCDP(tokenIdForExternalUser);

        assertEq(userDebt, 3 * amount / 8);
        assertApproxEqAbs(collateral, (7 * amount / 8) - (amount / 8) * 100 / 10_000, 1);

        assertEq(userDebt2, 3 * amount / 8);
        assertApproxEqAbs(collateral2, (7 * amount / 8) - (amount / 8) * 100 / 10_000, 1);
    }

    function testRepayUnearmarkedDebtOnly() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));

        uint256 preRepayBalance = fakeYieldToken.balanceOf(address(0xbeef));

        vm.roll(vm.getBlockNumber() + 1);

        liquid.repay(100e18, tokenId);
        vm.stopPrank();

        (, uint256 userDebt,) = liquid.getCDP(tokenId);

        assertEq(userDebt, 0);

        // Test that transmuter received funds
        assertEq(fakeYieldToken.balanceOf(address(transmuterLogic)), liquid.convertDebtTokensToYield(amount / 2));

        // Test that overpayment was not taken from user
        assertEq(fakeYieldToken.balanceOf(address(0xbeef)), preRepayBalance - liquid.convertDebtTokensToYield(amount / 2));
    }

    function testRepaySameBlock() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));

        uint256 preRepayBalance = fakeYieldToken.balanceOf(address(0xbeef));

        vm.expectRevert(ILiquidErrors.CannotRepayOnMintBlock.selector);
        liquid.repay(100e18, tokenId);
        vm.stopPrank();
    }

    function testRepayUnearmarkedDebtOnly_Variable_Amount(uint256 repayAmount) external {
        repayAmount = bound(repayAmount, FIXED_POINT_SCALAR, accountFunds / 2);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 200e18 + repayAmount);
        liquid.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, 100e18 / 2, address(0xbeef));

        uint256 preRepayBalance = fakeYieldToken.balanceOf(address(0xbeef));

        vm.roll(vm.getBlockNumber() + 1);

        liquid.repay(repayAmount, tokenId);
        vm.stopPrank();

        (, uint256 userDebt,) = liquid.getCDP(tokenId);

        uint256 repaidAmount = liquid.convertYieldTokensToDebt(repayAmount) > 100e18 / 2 ? 100e18 / 2 : liquid.convertYieldTokensToDebt(repayAmount);

        assertEq(userDebt, (100e18 / 2) - repaidAmount);

        // Test that transmuter received funds
        assertEq(fakeYieldToken.balanceOf(address(transmuterLogic)), repaidAmount);

        // Test that overpayment was not taken from user
        assertEq(fakeYieldToken.balanceOf(address(0xbeef)), preRepayBalance - repaidAmount);
    }

    function testRepayWithEarmarkedDebt() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, (amount / 2), address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 5_256_000);

        vm.prank(address(0xbeef));
        liquid.repay(25e18, tokenId);

        (, uint256 debt, uint256 earmarked) = liquid.getCDP(tokenId);

        // All debt is earmarked at this point so these values should be the same
        assertEq(debt, (amount / 2) - (amount / 4));

        assertEq(earmarked, (amount / 2) - (amount / 4));
    }

    function testRepayWithEarmarkedDebtWithFee() external {
        vm.prank(alOwner);
        // 1%
        liquid.setProtocolFee(100);

        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, (amount / 2), address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 5_256_000);

        vm.prank(address(0xbeef));
        liquid.repay(25e18, tokenId);

        (, uint256 debt, uint256 earmarked) = liquid.getCDP(tokenId);

        // All debt is earmarked at this point so these values should be the same
        assertEq(debt, (amount / 2) - (amount / 4));

        assertEq(earmarked, (amount / 2) - (amount / 4));

        assertEq(IERC20(fakeYieldToken).balanceOf(address(10)), liquid.convertYieldTokensToDebt(25e18) * 100 / 10_000);
    }

    function testRepayWithEarmarkedDebtPartial() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, (amount / 2), address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 5_256_000 / 2);

        vm.prank(address(0xbeef));
        liquid.repay(25e18, tokenId);

        (, uint256 debt, uint256 earmarked) = liquid.getCDP(tokenId);

        // 50 debt / 2 - 25 repaid
        assertEq(debt, (amount / 2) - (amount / 4));

        // Half of all debt was earmarked which is 25
        // Repay of 25 will pay off all earmarked debt
        assertEq(earmarked, 0);
    }

    function testRepayZeroAmount() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));

        vm.expectRevert();
        liquid.repay(0, tokenId);
        vm.stopPrank();
    }

    function testRepayZeroTokenIdRevert() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));

        vm.expectRevert();
        liquid.repay(100e18, 0);
        vm.stopPrank();
    }

    function testRepayInvalidIdRevert(uint256 tokenId) external {
        vm.assume(tokenId > 1);

        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 realTokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(realTokenId, amount / 2, address(0xbeef));

        vm.expectRevert();
        liquid.repay(100e18, tokenId);
        vm.stopPrank();
    }

    function testBurn() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));

        vm.roll(vm.getBlockNumber() + 1);

        SafeERC20.safeApprove(address(alToken), address(liquid), amount / 2);
        liquid.burn(amount / 2, tokenId);
        vm.stopPrank();

        (, uint256 userDebt,) = liquid.getCDP(tokenId);

        assertEq(userDebt, 0);
    }

    function testBurnWithFee() external {
        vm.prank(alOwner);
        // 1%
        liquid.setProtocolFee(100);

        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));

        vm.roll(vm.getBlockNumber() + 1);

        SafeERC20.safeApprove(address(alToken), address(liquid), amount / 2);
        liquid.burn(amount / 2, tokenId);
        vm.stopPrank();

        (, uint256 userDebt,) = liquid.getCDP(tokenId);

        assertEq(userDebt, 0);
        assertEq(IERC20(fakeYieldToken).balanceOf(address(10)), (amount / 2) * 100 / 10_000);
    }

    function testBurnSameBlock() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));

        SafeERC20.safeApprove(address(alToken), address(liquid), amount / 2);
        vm.expectRevert(ILiquidErrors.CannotRepayOnMintBlock.selector);
        liquid.burn(amount / 2, tokenId);
        vm.stopPrank();
    }

    function testBurn_variable_burn_amounts(uint256 burnAmount) external {
        deal(address(alToken), address(0xbeef), 1000e18);
        uint256 amount = 100e18;
        burnAmount = bound(burnAmount, 1, 1000e18);

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));

        vm.roll(vm.getBlockNumber() + 1);

        SafeERC20.safeApprove(address(alToken), address(liquid), amount / 2);
        liquid.burn(burnAmount, tokenId);
        vm.stopPrank();

        (, uint256 userDebt,) = liquid.getCDP(tokenId);

        uint256 burnedAmount = burnAmount > amount / 2 ? amount / 2 : burnAmount;

        // Test that amount is burned and any extra tokens are not taken from user
        assertEq(userDebt, (amount / 2) - burnedAmount);
        assertEq(alToken.balanceOf(address(0xbeef)) - amount / 2, 1000e18 - burnedAmount);
    }

    function testBurnZeroAmount() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));

        SafeERC20.safeApprove(address(alToken), address(liquid), amount / 2);
        vm.expectRevert();
        liquid.burn(0, tokenId);
        vm.stopPrank();
    }

    function testBurnZeroIdRevert() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));

        SafeERC20.safeApprove(address(alToken), address(liquid), amount / 2);
        vm.expectRevert();
        liquid.burn(amount / 2, 0);
        vm.stopPrank();
    }

    function testBurnWithEarmarkedDebtFullyEarmarked() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + (5_256_000));

        // Will fail since all debt is earmarked and cannot be repaid with burn
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(liquid), amount / 2);
        vm.expectRevert(IllegalState.selector);
        liquid.burn(amount / 8, tokenId);
        vm.stopPrank();
    }

    function testBurnWithEarmarkedDebt() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));
        vm.stopPrank();

        // Deposit and borrow from another position so there is allowance to burn
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xdad), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId2 = LiquidNFTHelper.getFirstTokenId(address(0xdad), address(liquidNFT));
        liquid.mint(tokenId2, amount / 2, address(0xdad));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + (5_256_000 / 2));

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(liquid), amount / 2);
        liquid.burn(amount, tokenId);
        vm.stopPrank();

        (, uint256 userDebt, uint256 earmarked) = liquid.getCDP(tokenId);

        // Only 3/4 debt can be paid off since the rest is earmarked
        assertEq(userDebt, (amount / 8));

        // Burn doesn't repay earmarked debt.
        assertEq(earmarked, (amount / 8));
    }

    function testBurnNoLimit() external {
        uint256 amount = 100e18;

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, amount / 2, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + (5_256_000 / 2));

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(liquid), amount / 2);
        vm.expectRevert();
        liquid.burn(amount, tokenId);
        vm.stopPrank();
    }

    function testLiquidate_Revert_If_Invalid_Token_Id(uint256 amount, uint256 tokenId) external {
        vm.assume(tokenId > 1);
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 realTokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(realTokenId, liquid.totalValue(realTokenId) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        vm.expectRevert();
        liquid.liquidate(tokenId);
        vm.stopPrank();
    }

    function testLiquidate_Undercollateralized_Position() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global liquid collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount * 2);
        liquid.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        uint256 transmuterPreviousBalance = IERC20(fakeYieldToken).balanceOf(address(transmuterLogic));

        // modify yield token price via modifying underlying token supply
        (uint256 prevCollateral, uint256 prevDebt,) = liquid.getCDP(tokenIdFor0xBeef);
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));

        uint256 liquidCurrentCollateralization =
            liquid.normalizeUnderlyingTokensToDebt(liquid.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / liquid.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn, uint256 expectedBaseFee,) = liquid.calculateLiquidation(
            liquid.totalValue(tokenIdFor0xBeef),
            prevDebt,
            liquid.minimumCollateralization(),
            liquidCurrentCollateralization,
            liquid.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYield = liquid.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = liquid.convertDebtTokensToYield(expectedBaseFee);

        // Account is still collateralized, so not pulling from the fee vault for underlying
        uint256 expectedFeeInUnderlying = 0;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.liquidate(tokenIdFor0xBeef);
        (uint256 depositedCollateral, uint256 debt,) = liquid.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebt - expectedDebtToBurn, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure assets is equal to liquidation amount i.e. y in (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (3% of liquidation amount)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYield, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser, liquidatorPrevTokenBalance, liquidatorPrevUnderlyingBalance, feeInYield, feeInUnderlying, assets, expectedLiquidationAmountInYield
        );

        vm.assertEq(liquidFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(fakeYieldToken).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedLiquidationAmountInYield - expectedBaseFeeInYield,
            1e18
        );
    }

    function testLiquidate_Undercollateralized_Position_Underlying_Token_6_Decimals() external {
        // re-deploy the contracts with 6 decimals for the underlying token
        deployCoreContracts(6);
        require(TokenUtils.expectDecimals(liquid.underlyingToken()) == 6);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();
        // just ensureing global liquid collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount * 2);
        liquid.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        uint256 feeVaultPreviousBalance = liquidFeeVault.totalDeposits();
        // modify yield token price via modifying underlying token supply
        (, uint256 prevDebt,) = liquid.getCDP(tokenIdFor0xBeef);
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 4000 bps or 40% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 4000 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);
        // ensure initial debt is correct
        // vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);
        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        uint256 liquidCurrentCollateralization =
            liquid.normalizeUnderlyingTokensToDebt(liquid.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / liquid.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn,,) = liquid.calculateLiquidation(
            liquid.totalValue(tokenIdFor0xBeef),
            prevDebt,
            liquid.minimumCollateralization(),
            liquidCurrentCollateralization,
            liquid.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYield = liquid.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedFeeInDebtTokens = expectedDebtToBurn * liquidatorFeeBPS / 10_000;
        // expected debt to burn is in debt tokens. converting to underlying for testing
        uint256 expectedFeeInUnderlying = liquid.normalizeDebtTokensToUnderlying(expectedFeeInDebtTokens);
        uint256 adjustedExpectedFeeInUnderlying = feeVaultPreviousBalance > expectedFeeInUnderlying ? expectedFeeInUnderlying : feeVaultPreviousBalance;
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.liquidate(tokenIdFor0xBeef);
        // (uint256 depositedCollateral, uint256 debt,) = liquid.getCDP(tokenIdFor0xBeef);
        vm.stopPrank();
        // ensure liquidator fee is correct (3% of surplus (account collateral - debt)
        vm.assertApproxEqAbs(feeInYield, 0, 1e18);
        vm.assertEq(feeInUnderlying, adjustedExpectedFeeInUnderlying);
        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser, liquidatorPrevTokenBalance, liquidatorPrevUnderlyingBalance, feeInYield, feeInUnderlying, assets, expectedLiquidationAmountInYield
        );
        vm.assertApproxEqAbs(liquidFeeVault.totalDeposits(), feeVaultPreviousBalance - adjustedExpectedFeeInUnderlying, 1e18);
    }

    function testLiquidate_Undercollateralized_Position_All_Fees_From_Fee_Vault() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global liquid collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount * 2);
        liquid.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // modify yield token price via modifying underlying token supply
        (, uint256 prevDebt,) = liquid.getCDP(tokenIdFor0xBeef);
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 4000 bps or 40%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 4000 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));

        uint256 liquidCurrentCollateralization =
            liquid.normalizeUnderlyingTokensToDebt(liquid.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / liquid.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn,,) = liquid.calculateLiquidation(
            liquid.totalValue(tokenIdFor0xBeef),
            prevDebt,
            liquid.minimumCollateralization(),
            liquidCurrentCollateralization,
            liquid.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;
        uint256 expectedLiquidationAmountInYield = liquid.convertDebtTokensToYield(liquidationAmount);

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.liquidate(tokenIdFor0xBeef);
        // (uint256 depositedCollateral, uint256 debt,) = liquid.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure liquidator fee is correct (3% of surplus (account collateral - debt)
        vm.assertApproxEqAbs(feeInYield, 0, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser, liquidatorPrevTokenBalance, liquidatorPrevUnderlyingBalance, feeInYield, feeInUnderlying, assets, expectedLiquidationAmountInYield
        );

        vm.assertApproxEqAbs(liquidFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying, 1e18);
    }

    function testLiquidate_Full_Liquidation_Bad_Debt() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global liquid collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount * 2);
        liquid.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        uint256 transmuterPreviousBalance = IERC20(fakeYieldToken).balanceOf(address(transmuterLogic));

        // modify yield token price via modifying underlying token supply
        (, uint256 prevDebt,) = liquid.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 1200 bps or 12%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 1200 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));

        uint256 liquidCurrentCollateralization =
            liquid.normalizeUnderlyingTokensToDebt(liquid.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / liquid.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn, uint256 expectedBaseFee,) = liquid.calculateLiquidation(
            liquid.totalValue(tokenIdFor0xBeef),
            prevDebt,
            liquid.minimumCollateralization(),
            liquidCurrentCollateralization,
            liquid.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYield = liquid.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = liquid.convertDebtTokensToYield(expectedBaseFee);
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.liquidate(tokenIdFor0xBeef);

        (uint256 depositedCollateral, uint256 debt,) = liquid.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, 0, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, 0, minimumDepositOrWithdrawalLoss);

        // ensure assets liquidated is equal (collateral - (90% of collateral))
        vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (3% of 0 if collateral fully liquidated as a result of bad debt)
        vm.assertApproxEqAbs(feeInYield, 0, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser, liquidatorPrevTokenBalance, liquidatorPrevUnderlyingBalance, feeInYield, feeInUnderlying, assets, expectedLiquidationAmountInYield
        );

        vm.assertEq(liquidFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(fakeYieldToken).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedLiquidationAmountInYield - expectedBaseFeeInYield,
            1e18
        );
    }

    function testLiquidate_Full_Liquidation_Globally_Undercollateralized() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        uint256 transmuterPreviousBalance = IERC20(fakeYieldToken).balanceOf(address(transmuterLogic));

        // modify yield token price via modifying underlying token supply
        (uint256 prevCollateral, uint256 prevDebt,) = liquid.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));

        uint256 liquidCurrentCollateralization =
            liquid.normalizeUnderlyingTokensToDebt(liquid.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / liquid.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn,,) = liquid.calculateLiquidation(
            liquid.totalValue(tokenIdFor0xBeef),
            prevDebt,
            liquid.minimumCollateralization(),
            liquidCurrentCollateralization,
            liquid.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYield = liquid.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = 0;

        // Account is still collateralized, but pulling from fee vault for globally bad debt scenario
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.liquidate(tokenIdFor0xBeef);

        (uint256 depositedCollateral, uint256 debt,) = liquid.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, 0, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure assets liquidated is equal (collateral - (90% of collateral))
        vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee in yeild is correct (0 in globally undercollateralized environment, fee will come from external vaults)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYield, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser, liquidatorPrevTokenBalance, liquidatorPrevUnderlyingBalance, feeInYield, feeInUnderlying, assets, expectedLiquidationAmountInYield
        );

        vm.assertEq(liquidFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(fakeYieldToken).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedLiquidationAmountInYield - expectedBaseFeeInYield,
            1e18
        );
    }

    function testLiquidate_Revert_If_Overcollateralized_Position(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        vm.expectRevert(ILiquidErrors.LiquidationError.selector);
        liquid.liquidate(tokenIdFor0xBeef);
        vm.stopPrank();
    }

    function testLiquidate_Revert_If_Zero_Debt(uint256 amount) external {
        amount = bound(amount, FIXED_POINT_SCALAR, accountFunds);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        vm.expectRevert(ILiquidErrors.LiquidationError.selector);
        liquid.liquidate(tokenIdFor0xBeef);
        vm.stopPrank();
    }

    function testEarmarkDebtAndRedeem() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        liquid.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 5_256_000);

        (uint256 deposited, uint256 userDebt, uint256 earmarked) = liquid.getCDP(tokenIdFor0xBeef);

        assertApproxEqAbs(earmarked, amount / 2, 1);

        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        (deposited, userDebt, earmarked) = liquid.getCDP(tokenIdFor0xBeef);

        assertApproxEqAbs(userDebt, 0, 1);
        assertApproxEqAbs(earmarked, 0, 1);

        liquid.poke(tokenIdFor0xBeef);

        (deposited, userDebt, earmarked) = liquid.getCDP(tokenIdFor0xBeef);

        assertApproxEqAbs(userDebt, 0, 1);
        assertApproxEqAbs(earmarked, 0, 1);

        uint256 yieldBalance = liquid.getTotalDeposited();
        uint256 borrowable = liquid.getMaxBorrowable(tokenIdFor0xBeef);

        assertApproxEqAbs(yieldBalance, 50e18, 10e18); // Yield accrues with new earmark math
        assertApproxEqAbs(deposited, 50e18, 10e18);
        assertApproxEqAbs(borrowable, 50e18 * FIXED_POINT_SCALAR / liquid.minimumCollateralization(), 10e18);
    }

    function testEarmarkDebtAndRedeemPartial() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        liquid.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + (5_256_000 / 2));

        (uint256 deposited, uint256 userDebt, uint256 earmarked) = liquid.getCDP(tokenIdFor0xBeef);

        assertApproxEqAbs(earmarked, amount / 4, 1);
        assertApproxEqAbs(userDebt, amount / 2, 1);

        liquid.poke(tokenIdFor0xBeef);

        // Partial redemption halfway through transmutation period
        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();

        liquid.poke(tokenIdFor0xBeef);

        (deposited, userDebt, earmarked) = liquid.getCDP(tokenIdFor0xBeef);

        // User should have half of their previous debt and none earmarked
        assertApproxEqAbs(userDebt, amount / 4, 1);
        assertApproxEqAbs(earmarked, 0, 1);

        uint256 yieldBalance = liquid.getTotalDeposited();
        uint256 borrowable = liquid.getMaxBorrowable(tokenIdFor0xBeef);

        assertApproxEqAbs(yieldBalance, 75e18, 1);
        assertApproxEqAbs(deposited, 75e18, 1);
        assertApproxEqAbs(borrowable, (75e18 * FIXED_POINT_SCALAR / liquid.minimumCollateralization()) - 25e18, 1);
    }

    function testRedemptionNotTransmuter() external {
        vm.expectRevert();
        liquid.redeem(20e18);
    }

    function testUnauthorizedAlchmistV3PositionNFTMint() external {
        vm.startPrank(address(0xbeef));
        vm.expectRevert();
        ILiquidPosition(address(liquidNFT)).mint(address(0xbeef));
        vm.stopPrank();
    }

    function testCreateRedemptionAfterRepay() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        liquid.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));

        vm.roll(vm.getBlockNumber() + 1);

        liquid.repay(liquid.convertDebtTokensToYield(amount / 2), tokenIdFor0xBeef);
        vm.stopPrank();

        assertEq(liquid.totalSyntheticsIssued(), amount / 2);
        assertEq(liquid.totalDebt(), 0);

        // Test that even though there is no active debt, that we can still create a position with the collateral sent to the transmuter.
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();
    }

    function testContractSize() external view {
        // Get size of deployed contract
        uint256 size = address(liquid).code.length;

        // Log the size
        console.log("Contract size:", size, "bytes");

        // Optional: Assert size is under EIP-170 limit (24576 bytes)
        assertTrue(size <= 24_576, "Contract too large");
    }

    function testLiquidTokenUri() public {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));

        vm.stopPrank();

        // Get the token URI
        string memory uri = liquidNFT.tokenURI(tokenIdFor0xBeef);

        // Verify it starts with the data URI prefix
        assertEq(LiquidNFTHelper.slice(uri, 0, 29), "data:application/json;base64,", "URI should start with data:application/json;base64,");

        // Extract and decode the JSON content
        string memory jsonContent = LiquidNFTHelper.jsonContent(uri);

        // Verify JSON contains expected fields
        assertTrue(LiquidNFTHelper.contains(jsonContent, '"name": "Liquid Position #1"'), "JSON should contain the name field");
        assertTrue(LiquidNFTHelper.contains(jsonContent, '"description": "Position token for Liquid"'), "JSON should contain the description field");
        assertTrue(LiquidNFTHelper.contains(jsonContent, '"image": "data:image/svg+xml;base64,'), "JSON should contain the image data URI");

        // revert if the token does not exist
        vm.expectRevert();
        liquidNFT.tokenURI(2);
    }

    function testLiquidate_Undercollateralized_Position_With_Earmarked_Debt_Sufficient_Repayment() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global liquid collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount * 2);
        liquid.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        uint256 mintAmount = liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization;

        liquid.mint(tokenIdFor0xBeef, mintAmount, address(0xbeef));
        vm.stopPrank();

        // Need to start a transmutator deposit, to start earmarking debt
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), mintAmount);
        transmuterLogic.createRedemption(mintAmount);
        vm.stopPrank();

        uint256 transmuterPreviousBalance = IERC20(fakeYieldToken).balanceOf(address(transmuterLogic));

        // skip to a future block. Lets say 60% of the way through the transmutation period (5_256_000 blocks)
        vm.roll(vm.getBlockNumber() + (5_256_000 * 60 / 100));

        // Earmarked debt should be 60% of the total debt
        (uint256 prevCollateral, uint256 prevDebt, uint256 earmarked) = liquid.getCDP(tokenIdFor0xBeef);
        require(earmarked == prevDebt * 60 / 100, "Earmarked debt should be 60% of the total debt");

        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.liquidate(tokenIdFor0xBeef);
        (uint256 depositedCollateral, uint256 debt,) = liquid.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        uint256 repaymentFee = liquid.convertDebtTokensToYield(earmarked) * 100 / BPS;

        // ensure debt is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(debt, prevDebt - earmarked, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - liquid.convertDebtTokensToYield(earmarked) - repaymentFee, minimumDepositOrWithdrawalLoss);

        // ensure assets is equal to repayment of max earmarked amount
        vm.assertApproxEqAbs(assets, liquid.convertDebtTokensToYield(earmarked), minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (i.e.0, since only a repayment is done)
        vm.assertApproxEqAbs(feeInYield, repaymentFee, 1e18);
        vm.assertEq(feeInUnderlying, 0);

        // liquidator gets correct amount of fee, i.e. 0
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            liquid.convertDebtTokensToYield(earmarked)
        );

        vm.assertEq(liquidFeeVault.totalDeposits(), 10_000 ether);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(fakeYieldToken).balanceOf(address(transmuterLogic)), transmuterPreviousBalance + liquid.convertDebtTokensToYield(earmarked), 1e18
        );
    }

    function testLiquidate_with_force_repay_and_successive_account_syncing() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();
        // just ensureing global liquid collateralization stays above the minimum required for regular
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount * 2);
        liquid.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));

        vm.stopPrank();
        // modify yield token price via modifying underlying token supply
        (, uint256 prevDebt,) = liquid.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);
        // create a redemption to start earmarking debt
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 1200 bps or 12% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 1200 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);
        vm.roll(vm.getBlockNumber() + 5_256_000);
        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        liquid.liquidate(tokenIdFor0xBeef);
        // Syncing succeeeds, no reverts
        liquid.poke(tokenIdFor0xBeef);
    }

    function testLiquidate_Undercollateralized_Position_With_Earmarked_Debt_Liquidation_50Percent_Yield_Price_Drop() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global liquid collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount * 2);
        liquid.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        uint256 mintAmount = liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization;

        liquid.mint(tokenIdFor0xBeef, mintAmount, address(0xbeef));
        vm.stopPrank();

        // Need to start a transmutator deposit, to start earmarking debt
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), mintAmount);
        transmuterLogic.createRedemption(mintAmount);
        vm.stopPrank();

        // skip to a future block. Lets say 5% of the way through the transmutation period (5_256_000 blocks)
        // This should result in the account still being undercollateralized, if the liquidation collateralization ratio is 100/95
        // Which means the minimum amount of collateral needed to reduce collateral/debt by is ~ > 5% of the collateral
        vm.roll(vm.getBlockNumber() + (5_256_000 * 5 / 100));

        // Earmarked debt should be 60% of the total debt
        (, uint256 prevDebt, uint256 earmarked) = liquid.getCDP(tokenIdFor0xBeef);
        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // decreasing yeild token suppy by 50%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 5000 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));

        uint256 collateralAfterRepayment = liquid.totalValue(tokenIdFor0xBeef) - earmarked;
        uint256 debtAfterRepayment = prevDebt - earmarked;
        uint256 liquidCurrentCollateralization =
            liquid.normalizeUnderlyingTokensToDebt(liquid.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / liquid.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn, uint256 expectedBaseFee,) = liquid.calculateLiquidation(
            collateralAfterRepayment,
            debtAfterRepayment,
            liquid.minimumCollateralization(),
            liquidCurrentCollateralization,
            liquid.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );

        (uint256 depositedColleteralBeforeLiquidation,, uint256 earmarkedBeforeLiquidation) = liquid.getCDP(tokenIdFor0xBeef);
        uint256 expectedLiquidationAmountInYield = liquid.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = liquid.convertDebtTokensToYield(expectedBaseFee);
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.liquidate(tokenIdFor0xBeef);

        (uint256 depositedCollateral, uint256 debt,) = liquid.getCDP(tokenIdFor0xBeef);

        vm.stopPrank();

        // ensure debt is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(debt, debtAfterRepayment - expectedDebtToBurn, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(depositedCollateral, 0, minimumDepositOrWithdrawalLoss);

        // ensure assets is equal to the entire collateral of the account - any protocol fee
        vm.assertApproxEqAbs(assets, depositedColleteralBeforeLiquidation, minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (i.e.0, since only a repayment is done)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYield, 1e18);
        vm.assertApproxEqAbs(feeInUnderlying, expectedFeeInUnderlying, 1e18);

        // liquidator gets correct amount of fee, i.e. (3% of liquidation amount)
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            expectedLiquidationAmountInYield + liquid.convertDebtTokensToYield(earmarkedBeforeLiquidation)
        );

        vm.assertApproxEqAbs(liquidFeeVault.totalDeposits(), 10_000 ether - expectedFeeInUnderlying, 1e18);
    }

    function testLiquidate_Debt_Exceeds_Collateral_Shortfall_Absorbed_By_Healthy_Account() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // 1. Create a healthy account with no debt, but enough collateral to cover shortfall
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, yetAnotherExternalUser, 0);
        uint256 tokenIdHealthy = LiquidNFTHelper.getFirstTokenId(yetAnotherExternalUser, address(liquidNFT));
        (uint256 healthyInitialCollateral, uint256 healthyInitialDebt,) = liquid.getCDP(tokenIdHealthy);
        require(healthyInitialDebt == 0);
        vm.stopPrank();

        // 2. Create the undercollateralized account
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        uint256 tokenIdBad = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        // Mint so that debt is just below collateral
        liquid.mint(tokenIdBad, liquid.totalValue(tokenIdBad) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        // 3. Drop price so that account debt > account collateral, but system collateral is still enough
        (, uint256 badInitialDebt,) = liquid.getCDP(tokenIdBad);
        uint256 initialSystemCollateral = liquid.getTotalUnderlyingValue();

        // Drop price so that bad account's collateral is less than its debt, but system collateral is still enough
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // Drop price by 50% (increase supply by 100%)
        uint256 modifiedVaultSupply = (initialVaultSupply * 7000 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);

        uint256 badCollateralAfterDrop = liquid.totalValue(tokenIdBad);
        (uint256 liquidationAmount,,,) = liquid.calculateLiquidation(
            badCollateralAfterDrop,
            badInitialDebt,
            liquid.minimumCollateralization(),
            liquid.normalizeUnderlyingTokensToDebt(liquid.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / liquid.totalDebt(),
            liquid.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );

        // Convert liquidationAmount from debt tokens to underlying tokens for comparison
        uint256 liquidationAmountInUnderlying = liquid.normalizeDebtTokensToUnderlying(liquidationAmount);

        // Confirm test preconditions
        require(badInitialDebt > badCollateralAfterDrop, "Account debt should exceed collateral after price drop");
        require(liquid.getTotalUnderlyingValue() > liquidationAmountInUnderlying, "System collateral should be enough to cover liquidation");

        // health account total value
        uint256 healthyTotalValueBefore = liquid.totalValue(tokenIdHealthy);

        // 4. Liquidate the undercollateralized account
        vm.startPrank(externalUser);
        liquid.liquidate(tokenIdBad);
        vm.stopPrank();

        // healthy account total value
        uint256 healthyTotalValueAfter = liquid.totalValue(tokenIdHealthy);

        // 5. Check that the bad account is fully liquidated
        (uint256 badFinalCollateral, uint256 badFinalDebt,) = liquid.getCDP(tokenIdBad);
        vm.assertEq(badFinalCollateral, 0);
        vm.assertApproxEqAbs(badFinalDebt, 0, minimumDepositOrWithdrawalLoss);

        uint256 healthyCollateralLoss = healthyTotalValueBefore - healthyTotalValueAfter;
        vm.assertEq(healthyCollateralLoss, 0);

        vm.prank(yetAnotherExternalUser);

        // account should be able to withdraw all its collateral, the systems bad debt
        uint256 withdrawn = liquid.withdraw(healthyInitialCollateral, yetAnotherExternalUser, tokenIdHealthy);
        vm.assertEq(withdrawn, healthyInitialCollateral);

        // 7. The system's total collateral should decrease by at least the shortfall
        uint256 systemCollateralAfter = liquid.getTotalUnderlyingValue();
        uint256 systemCollateralReduction = initialSystemCollateral - systemCollateralAfter;
        uint256 shortfall = badInitialDebt - badCollateralAfterDrop;

        assert(systemCollateralReduction >= shortfall);
    }

    function testLiquidate_Undercollateralized_Position_With_Earmarked_Debt_Sufficient_Repayment_With_Protocol_Fee() external {
        uint256 amount = 200_000e18; // 200,000 yvdai
        // uint256 protocolFee = 100; // 10%
        vm.prank(alOwner);
        liquid.setProtocolFee(protocolFee);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global liquid collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount * 2);
        liquid.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        uint256 mintAmount = liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization;

        liquid.mint(tokenIdFor0xBeef, mintAmount, address(0xbeef));
        vm.stopPrank();

        // Need to start a transmutator deposit, to start earmarking debt
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), mintAmount);
        transmuterLogic.createRedemption(mintAmount);
        vm.stopPrank();

        uint256 transmuterPreviousBalance = IERC20(fakeYieldToken).balanceOf(address(transmuterLogic));

        // skip to a future block. Lets say 60% of the way through the transmutation period (5_256_000 blocks)
        vm.roll(vm.getBlockNumber() + (5_256_000 * 60 / 100));

        // Earmarked debt should be 60% of the total debt
        (uint256 prevCollateral, uint256 prevDebt, uint256 earmarked) = liquid.getCDP(tokenIdFor0xBeef);
        require(earmarked == prevDebt * 60 / 100, "Earmarked debt should be 60% of the total debt");

        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);

        uint256 credit = earmarked > prevDebt ? prevDebt : earmarked;
        uint256 creditToYield = liquid.convertDebtTokensToYield(credit);
        uint256 protocolFeeInYield = (creditToYield * protocolFee / BPS);

        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.liquidate(tokenIdFor0xBeef);

        (uint256 depositedCollateral, uint256 debt,) = liquid.getCDP(tokenIdFor0xBeef);

        uint256 repaymentFee = liquid.convertDebtTokensToYield(earmarked) * 100 / BPS;

        vm.stopPrank();

        // ensure debt is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(debt, prevDebt - earmarked, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(
            depositedCollateral, prevCollateral - liquid.convertDebtTokensToYield(earmarked) - protocolFeeInYield - repaymentFee, minimumDepositOrWithdrawalLoss
        );

        // ensure assets is equal to repayment of max earmarked amount
        vm.assertApproxEqAbs(assets, liquid.convertDebtTokensToYield(earmarked), minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (i.e.0, since only a repayment is done)
        vm.assertApproxEqAbs(feeInYield, repaymentFee, 1e18);
        vm.assertEq(feeInUnderlying, 0);

        // liquidator gets correct amount of fee, i.e. 0
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            liquid.convertDebtTokensToYield(earmarked)
        );
        vm.assertEq(liquidFeeVault.totalDeposits(), 10_000 ether);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(fakeYieldToken).balanceOf(address(transmuterLogic)), transmuterPreviousBalance + liquid.convertDebtTokensToYield(earmarked), 1e18
        );

        // check protocolfeereciever received the protocl fee transfer from _forceRepay
        vm.assertApproxEqAbs(IERC20(fakeYieldToken).balanceOf(address(protocolFeeReceiver)), protocolFeeInYield, 1e18);
    }

    function testLiquidate_Zero_Adapter_Price_Holds_Last_Valuation() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();
        // just ensureing global liquid collateralization stays above the minimum required for regular
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount * 2);
        liquid.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));

        vm.stopPrank();
        // modify yield token price via modifying underlying token supply
        (, uint256 prevDebt,) = liquid.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);
        // create a redemption to start earmarking debt
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 9900 bps or 99% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * (10_000 * FIXED_POINT_SCALAR) / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);
        vm.roll(vm.getBlockNumber() + 5_256_000);
        // The dilution is severe enough that the adapter's integer price floors
        // to zero. A zero report is the one the engine will not act on: it cannot
        // be told apart from a dead adapter, and acting on it would value every
        // position in the protocol at nothing simultaneously and irreversibly.
        assertEq(fakeYieldToken.price(), 0, "adapter reports zero");
        assertEq(liquid.price(), liquid.lastPrice(), "engine holds its last good price");

        vm.startPrank(externalUser);

        // Collateral keeps its last valuation rather than evaporating, so the
        // position is not swept into liquidation on the strength of a dead feed.
        assertGt(liquid.totalValue(tokenIdFor0xBeef), 0, "collateral survives a dead adapter");
        vm.expectRevert(ILiquidErrors.LiquidationError.selector);
        liquid.liquidate(tokenIdFor0xBeef);
        vm.stopPrank();
    }

    function testLiquidate_Undercollateralized_Position_With_Earmarked_Debt_Sufficient_Repayment_Clears_Total_Debt() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        // just ensureing global liquid collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount * 2);
        liquid.deposit(depositAmount, yetAnotherExternalUser, 0);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount + 100e18);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        uint256 mintAmount = liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization;

        liquid.mint(tokenIdFor0xBeef, mintAmount, address(0xbeef));
        vm.stopPrank();

        // Need to start a transmutator deposit, to start earmarking debt
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), mintAmount);
        transmuterLogic.createRedemption(mintAmount);
        vm.stopPrank();

        uint256 transmuterPreviousBalance = IERC20(fakeYieldToken).balanceOf(address(transmuterLogic));

        // skip to a future block. Lets say 100% of the way through the transmutation period (5_256_000 blocks)
        vm.roll(vm.getBlockNumber() + (5_256_000));

        // Earmarked debt should be 100% of the total debt
        (uint256 prevCollateral, uint256 prevDebt, uint256 earmarked) = liquid.getCDP(tokenIdFor0xBeef);
        require(earmarked == prevDebt, "Earmarked debt should be 60% of the total debt");

        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);

        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.liquidate(tokenIdFor0xBeef);
        (uint256 depositedCollateral, uint256 debt,) = liquid.getCDP(tokenIdFor0xBeef);

        uint256 repaymentFee = liquid.convertDebtTokensToYield(earmarked) * 100 / BPS;

        vm.stopPrank();

        // ensure debt is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(debt, prevDebt - earmarked, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced only by the repayment of max earmarked amount
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - liquid.convertDebtTokensToYield(earmarked) - repaymentFee, minimumDepositOrWithdrawalLoss);

        // ensure assets is equal to repayment of max earmarked amount
        vm.assertApproxEqAbs(assets, liquid.convertDebtTokensToYield(earmarked), minimumDepositOrWithdrawalLoss);

        // ensure liquidator fee is correct (i.e. only repayment fee, since only a repayment is done)
        vm.assertApproxEqAbs(feeInYield, repaymentFee, 1e18);
        vm.assertEq(feeInUnderlying, 0);

        // liquidator gets correct amount of fee, i.e. repayment fee > 0
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            liquid.convertDebtTokensToYield(earmarked)
        );

        vm.assertEq(liquidFeeVault.totalDeposits(), 10_000 ether);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(fakeYieldToken).balanceOf(address(transmuterLogic)), transmuterPreviousBalance + liquid.convertDebtTokensToYield(earmarked), 1e18
        );
    }

    function testBatch_Liquidate_Undercollateralized_Position() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        AccountPosition memory position1 = _setAccountPosition(address(0xbeef), depositAmount, true, minimumCollateralization);

        AccountPosition memory position2 = _setAccountPosition(anotherExternalUser, depositAmount, true, minimumCollateralization);

        uint256 transmuterPreviousBalance = IERC20(fakeYieldToken).balanceOf(address(transmuterLogic));

        _setAccountPosition(yetAnotherExternalUser, depositAmount, false, minimumCollateralization);

        _manipulateYieldTokenPrice(590);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(externalUser);
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(externalUser);

        // Batch Liquidation for 2 user addresses
        uint256[] memory accountsToLiquidate = new uint256[](2);
        accountsToLiquidate[0] = position1.tokenId;
        accountsToLiquidate[1] = position2.tokenId;

        // get expected liquidation results for each account
        CalculateLiquidationResult memory expectedResult1 = _calculateLiquidationForAccount(position1);
        CalculateLiquidationResult memory expectedResult2 = _calculateLiquidationForAccount(position2);

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.batchLiquidate(accountsToLiquidate);

        vm.stopPrank();

        /// Tests for first liquidated User ///
        _validateLiquidatedAccountState(
            position1.tokenId, position1.collateral, position1.debt, expectedResult1.debtToBurn, expectedResult1.liquidationAmountInYield
        );

        /// Tests for second liquidated User ///
        _validateLiquidatedAccountState(
            position2.tokenId, position2.collateral, position2.debt, expectedResult2.debtToBurn, expectedResult2.liquidationAmountInYield
        );

        // Tests for Liquidator ///
        _valudateLiquidationFees(
            feeInYield,
            feeInUnderlying,
            expectedResult1.baseFeeInYield + expectedResult2.baseFeeInYield,
            expectedResult1.outSourcedFee + expectedResult2.outSourcedFee
        );

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            expectedResult1.liquidationAmountInYield + expectedResult2.liquidationAmountInYield
        );

        vm.assertEq(liquidFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(fakeYieldToken).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedResult1.liquidationAmountInYield + expectedResult2.liquidationAmountInYield - expectedResult1.baseFeeInYield
                - expectedResult2.baseFeeInYield,
            1e18
        );
    }

    function testBatch_Liquidate_Undercollateralized_Position_And_Skip_Healthy_Position() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        AccountPosition memory position1 = _setAccountPosition(address(0xbeef), depositAmount, true, minimumCollateralization);

        AccountPosition memory position2 = _setAccountPosition(anotherExternalUser, depositAmount, true, 15e17);

        // just ensureing global liquid collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        _setAccountPosition(yetAnotherExternalUser, depositAmount, false, minimumCollateralization);

        uint256 transmuterPreviousBalance = IERC20(fakeYieldToken).balanceOf(address(transmuterLogic));

        _manipulateYieldTokenPrice(590);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(externalUser);
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(externalUser);
        // Batch Liquidation for 2 user addresses
        uint256[] memory accountsToLiquidate = new uint256[](2);
        accountsToLiquidate[0] = position1.tokenId;
        accountsToLiquidate[1] = position2.tokenId;

        CalculateLiquidationResult memory expectedResult1 = _calculateLiquidationForAccount(position1);
        // CalculateLiquidationResult memory expectedResult2 = _calculateLiquidationForAccount(position2);

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.batchLiquidate(accountsToLiquidate);

        vm.stopPrank();

        /// Tests for first liquidated User ///

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        _validateLiquidatedAccountState(
            position1.tokenId, position1.collateral, position1.debt, expectedResult1.debtToBurn, expectedResult1.liquidationAmountInYield
        );

        /// Tests for second liquidated User ///
        _validateLiquidatedAccountState(position2.tokenId, position2.collateral, position2.debt, 0, 0);

        // Tests for Liquidator ///

        // ensure liquidator fee is correct (3% of liquidation amount)
        _valudateLiquidationFees(feeInYield, feeInUnderlying, expectedResult1.baseFeeInYield, expectedResult1.outSourcedFee);

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            expectedResult1.liquidationAmountInYield
        );
        vm.assertEq(liquidFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(fakeYieldToken).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedResult1.liquidationAmountInYield - expectedResult1.baseFeeInYield,
            1e18
        );
    }

    function testBatch_Liquidate_Undercollateralized_Position_And_Skip_Zero_Ids() external {
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        AccountPosition memory position1 = _setAccountPosition(address(0xbeef), depositAmount, true, minimumCollateralization);

        AccountPosition memory position2 = _setAccountPosition(anotherExternalUser, depositAmount, true, minimumCollateralization);

        // just ensureing global liquid collateralization stays above the minimum required for regular liquidations
        // no need to mint anything
        _setAccountPosition(yetAnotherExternalUser, depositAmount, false, minimumCollateralization);

        uint256 transmuterPreviousBalance = IERC20(fakeYieldToken).balanceOf(address(transmuterLogic));

        _manipulateYieldTokenPrice(590);

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(externalUser);
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(externalUser);

        // Batch Liquidation for 2 user addresses
        uint256[] memory accountsToLiquidate = new uint256[](3);
        accountsToLiquidate[0] = position1.tokenId;
        accountsToLiquidate[1] = 0; // invalid zero ids
        accountsToLiquidate[2] = position2.tokenId;

        // Calculate liquidation amount for 0xBeef
        CalculateLiquidationResult memory expectedResult1 = _calculateLiquidationForAccount(position1);
        CalculateLiquidationResult memory expectedResult2 = _calculateLiquidationForAccount(position2);

        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.batchLiquidate(accountsToLiquidate);

        vm.stopPrank();

        /// Tests for first liquidated User ///
        _validateLiquidatedAccountState(
            position1.tokenId, position1.collateral, position1.debt, expectedResult1.debtToBurn, expectedResult1.liquidationAmountInYield
        );

        /// Tests for second liquidated User ///
        _validateLiquidatedAccountState(
            position2.tokenId, position2.collateral, position2.debt, expectedResult2.debtToBurn, expectedResult2.liquidationAmountInYield
        );

        // Tests for Liquidator ///

        // ensure liquidator fee is correct (3% of liquidation amount)
        _valudateLiquidationFees(
            feeInYield,
            feeInUnderlying,
            expectedResult1.baseFeeInYield + expectedResult2.baseFeeInYield,
            expectedResult1.outSourcedFee + expectedResult2.outSourcedFee
        );

        // liquidator gets correct amount of fee
        _validateLiquidiatorState(
            externalUser,
            liquidatorPrevTokenBalance,
            liquidatorPrevUnderlyingBalance,
            feeInYield,
            feeInUnderlying,
            assets,
            expectedResult1.liquidationAmountInYield + expectedResult2.liquidationAmountInYield
        );
        vm.assertEq(liquidFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);

        // transmuter recieves the liquidation amount in yield token minus the fee
        vm.assertApproxEqAbs(
            IERC20(fakeYieldToken).balanceOf(address(transmuterLogic)),
            transmuterPreviousBalance + expectedResult1.liquidationAmountInYield + expectedResult2.liquidationAmountInYield - expectedResult1.baseFeeInYield
                - expectedResult2.baseFeeInYield,
            1e18
        );
    }

    function testBatch_Liquidate_Revert_If_Overcollateralized_Position(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, anotherExternalUser, 0);
        // a single position nft would have been minted to anotherExternalUser
        uint256 tokenIdForExternalUser = LiquidNFTHelper.getFirstTokenId(anotherExternalUser, address(liquidNFT));
        liquid.mint(tokenIdForExternalUser, liquid.totalValue(tokenIdForExternalUser) * FIXED_POINT_SCALAR / minimumCollateralization, anotherExternalUser);
        vm.stopPrank();

        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        vm.expectRevert(ILiquidErrors.LiquidationError.selector);

        // Batch Liquidation for 2 user addresses
        uint256[] memory accountsToLiquidate = new uint256[](2);
        accountsToLiquidate[0] = tokenIdFor0xBeef;
        accountsToLiquidate[1] = tokenIdForExternalUser;
        liquid.batchLiquidate(accountsToLiquidate);
        vm.stopPrank();
    }

    function testBatch_Liquidate_Revert_If_Missing_Data(uint256 amount) external {
        amount = bound(amount, 1e18, accountFunds);
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();

        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();

        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, anotherExternalUser, 0);
        // a single position nft would have been minted to anotherExternalUser
        uint256 tokenIdForExternalUser = LiquidNFTHelper.getFirstTokenId(anotherExternalUser, address(liquidNFT));
        liquid.mint(tokenIdForExternalUser, liquid.totalValue(tokenIdForExternalUser) * FIXED_POINT_SCALAR / minimumCollateralization, anotherExternalUser);
        vm.stopPrank();

        // let another user batch liquidate with an empty array
        vm.startPrank(externalUser);
        vm.expectRevert(MissingInputData.selector);

        // Batch Liquidation for  empty array
        uint256[] memory accountsToLiquidate = new uint256[](0);
        liquid.batchLiquidate(accountsToLiquidate);
        vm.stopPrank();
    }

    function _calculateLiquidationForAccount(AccountPosition memory position) internal view returns (CalculateLiquidationResult memory result) {
        uint256 liquidCurrentCollateralization =
            liquid.normalizeUnderlyingTokensToDebt(liquid.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / liquid.totalDebt();
        (uint256 liquidationAmount, uint256 debtToBurn, uint256 baseFee, uint256 outSourcedFee) = liquid.calculateLiquidation(
            liquid.totalValue(position.tokenId),
            position.debt,
            liquid.minimumCollateralization(),
            liquidCurrentCollateralization,
            liquid.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );

        uint256 liquidationAmountInYield = liquid.convertDebtTokensToYield(liquidationAmount);
        uint256 baseFeeInYield = liquid.convertDebtTokensToYield(baseFee);

        result = CalculateLiquidationResult({
            liquidationAmountInYield: liquidationAmountInYield, debtToBurn: debtToBurn, outSourcedFee: outSourcedFee, baseFeeInYield: baseFeeInYield
        });

        return result;
    }

    /// helper functions to simplify batch liquidation tests

    function _manipulateYieldTokenPrice(uint256 tokenySupplyBPSIncrease) internal {
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9%  while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * tokenySupplyBPSIncrease / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _setAccountPosition(address user, uint256 deposit, bool doMint, uint256 ltv) internal returns (AccountPosition memory) {
        vm.startPrank(user);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), deposit + 100e18);
        liquid.deposit(deposit, user, 0);
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(user, address(liquidNFT));
        if (doMint) {
            // default max mint
            liquid.mint(tokenId, liquid.totalValue(tokenId) * FIXED_POINT_SCALAR / ltv, user);
        }
        (uint256 collateral, uint256 debt,) = liquid.getCDP(tokenId);
        AccountPosition memory position = AccountPosition({user: user, collateral: collateral, debt: debt, tokenId: tokenId});
        vm.stopPrank();
        return position;
    }

    function _valudateLiquidationFees(uint256 feeInYield, uint256 feeInUnderlying, uint256 expectedFeeInYield, uint256 expectedFeeInUnderlying) internal pure {
        // ensure liquidator fee is correct (3% of liquidation amount)
        vm.assertApproxEqAbs(feeInYield, expectedFeeInYield, 1e18);
        vm.assertEq(feeInUnderlying, expectedFeeInUnderlying);
    }

    function _validateLiquidatedAccountState(
        uint256 tokenId,
        uint256 prevCollateral,
        uint256 prevDebt,
        uint256 expectedDebtToBurn,
        uint256 expectedLiquidationAmountInYield
    ) internal view {
        (uint256 depositedCollateral, uint256 debt,) = liquid.getCDP(tokenId);

        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebt - expectedDebtToBurn, minimumDepositOrWithdrawalLoss);

        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);
    }

    function _validateLiquidiatorState(
        address user,
        uint256 prevTokenBalance,
        uint256 prevUnderlyingBalance,
        uint256 feeInYield,
        uint256 feeInUnderlying,
        uint256 assets,
        uint256 exepctedLiquidationTotalAmountInYield
    ) internal view {
        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(user);
        uint256 liquidatorPostUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(user);
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, prevTokenBalance + feeInYield, 1e18);
        vm.assertApproxEqAbs(liquidatorPostUnderlyingBalance, prevUnderlyingBalance + feeInUnderlying, 1e18);
        vm.assertApproxEqAbs(assets, exepctedLiquidationTotalAmountInYield, minimumDepositOrWithdrawalLoss);
    }

    function testPoc_Invariant_TotalDebt_Vs_CumulativeEarmark_Broken_After_FullRepay() external {
        uint256 debtAmountToMint = 50e18; // 0xbeef mints 50 alToken
        uint256 transmuterRedemptionAmount = 30e18; // 0xdad creates redemption for 30 alToken
        vm.startPrank(address(0xbeef));
        uint256 yieldToDeposit = 100e18;
        uint256 yieldToRepayFullDebt = liquid.convertDebtTokensToYield(debtAmountToMint);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), type(uint256).max); // Approve for
        liquid.deposit(100e18, address(0xbeef), 0);
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, debtAmountToMint, address(0xbeef));
        vm.stopPrank();
        assertEq(liquid.totalDebt(), debtAmountToMint, "Initial total debt mismatch");
        uint256 initialCumulativeEarmarked = liquid.cumulativeEarmarked(); // Should be 0 if no prior activity
        // --- Setup: 0xdad creates redemption in Transmuter ---
        deal(address(alToken), address(0xdad), transmuterRedemptionAmount);
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), type(uint256).max);
        transmuterLogic.createRedemption(transmuterRedemptionAmount);
        vm.stopPrank();
        // --- Advance time to allow earmarking ---
        vm.roll(vm.getBlockNumber() + 100); // Advance some blocks
        // --- 0xbeef fully repays debt ---
        vm.startPrank(address(0xbeef));
        uint256 preRepayBalance = fakeYieldToken.balanceOf(address(0xbeef));
        liquid.repay(yieldToRepayFullDebt, tokenId);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        liquid.poke(tokenId);
    }

    function test_poc_badDebtRatioIncreaseFasterAtClaimRedemption() external {
        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        // 0xbeef transfer some synthetic to 0xdad
        uint256 amountToRedeem = 100_000e18;
        uint256 amountToRedeem2 = 10_000e18;
        alToken.transfer(address(0xdad), amountToRedeem + amountToRedeem2);
        vm.stopPrank();
        // 0xdad create redemption, here we create multiple redemptions to test the poc
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), amountToRedeem + amountToRedeem2);
        transmuterLogic.createRedemption(amountToRedeem);
        transmuterLogic.createRedemption(amountToRedeem2);
        vm.stopPrank();
        // lets full mature the redemption
        vm.roll(vm.getBlockNumber() + (5_256_000) + 1);
        // create global system bad debt
        // modify yield token price via modifying underlying token supply
        (uint256 prevCollateral, uint256 prevDebt,) = liquid.getCDP(tokenIdFor0xBeef);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 12% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 1200 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);
        for (uint256 i = 1; i <= 2; i++) {
            console.log("[*] redemption no: ", i);
            // calculate bad debt ratio
            uint256 currentBadDebt = liquid.totalSyntheticsIssued() * 10 ** TokenUtils.expectDecimals(liquid.yieldToken()) / liquid.getTotalUnderlyingValue();
            console.log("current bad debt ratio before redemption: ", currentBadDebt);
            // 0xdad claim redemption
            vm.startPrank(address(0xdad));
            transmuterLogic.claimRedemption(i);
            vm.stopPrank();
            // calculate bad debt ratio
            currentBadDebt = liquid.totalSyntheticsIssued() * 10 ** TokenUtils.expectDecimals(liquid.yieldToken()) / liquid.getTotalUnderlyingValue();
            console.log("current bad debt ratio after redemption: ", currentBadDebt);
        }
    }

    function testClaimRdemtionNotDebtTokensburned() external {
        //@audit medium 12
        vm.prank(alOwner);
        // 1%
        liquid.setProtocolFee(100);
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, (amount / 2), address(0xbeef));
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(address(0xbeef)), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
        vm.startPrank(externalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, externalUser, 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdForExternalUser = LiquidNFTHelper.getFirstTokenId(externalUser, address(liquidNFT));
        liquid.mint(tokenIdForExternalUser, (amount / 2), externalUser);
        vm.assertApproxEqAbs(IERC20(alToken).balanceOf(externalUser), (amount / 2), minimumDepositOrWithdrawalLoss);
        vm.stopPrank();
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 5_256_000 / 2);
        uint256 synctectiAssetBefore = liquid.totalSyntheticsIssued();
        vm.startPrank(address(0xdad));
        fakeYieldToken.transfer(address(transmuterLogic), amount);
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();
        uint256 synctectiAssetAfter = liquid.totalSyntheticsIssued();
        assertEq(synctectiAssetBefore - (25e18), synctectiAssetAfter);
    }

    function testCrashDueToWeightIncrementCheck() external {
        bytes memory expectedError = "WeightIncrement: increment > total";
        // 1. Create a position
        uint256 amount = 100e18;
        address user = address(0xbeef);
        vm.startPrank(user);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), type(uint256).max);
        liquid.deposit(amount, user, 0);
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(user, address(liquidNFT));
        uint256 borrowedAmount = amount / 2; // Arbitrary, can be fuzzed over.
        liquid.mint(tokenId, borrowedAmount, user);
        vm.stopPrank();
        // 2. Create a redemption
        // This populates the queryGraph with values.
        // After timeToTransmute has passed, the amount to pull with earmarking
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), borrowedAmount);
        transmuterLogic.createRedemption(borrowedAmount);
        vm.stopPrank();
        // 3. Repay any amount.
        // This sends yield tokens to the transmuter and reduces total debt.
        // It does not affect what is in the queryGraph.
        vm.startPrank(user);
        vm.roll(vm.getBlockNumber() + 1);
        liquid.repay(1, tokenId);
        vm.stopPrank();
        // 4. Let the claim mature.
        vm.roll(vm.getBlockNumber() + 5_256_000);
        vm.startPrank(address(0xdad));
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();
        // All regular Liquid operations still succeed
        vm.startPrank(address(0xbeef));
        liquid.poke(tokenId);
        liquid.withdraw(1, user, tokenId);
        liquid.mint(tokenId, 1, user);
        vm.roll(vm.getBlockNumber() + 1);
        liquid.repay(1, tokenId);
        vm.stopPrank();
        liquid.getCDP(tokenId);
    }

    function testDebtMintingRedemptionWithdraw() external {
        uint256 amount = 100e18;
        address debtor = address(0xbeef);
        address redeemer = address(0xdad);
        // Mint debt tokens
        vm.startPrank(debtor);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, debtor, 0);
        uint256 tokenId = 1;
        uint256 maxBorrowable = liquid.getMaxBorrowable(tokenId);
        liquid.mint(tokenId, maxBorrowable, debtor);
        vm.stopPrank();
        // Create Redemption
        vm.startPrank(redeemer);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), maxBorrowable);
        transmuterLogic.createRedemption(maxBorrowable);
        vm.stopPrank();
        // Advance time to complete redemption
        vm.roll(vm.getBlockNumber() + 5_256_000);
        // Claim Redemption
        vm.startPrank(redeemer);
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();
        // Check debt has been reduced to zero
        (uint256 collateral, uint256 debt, uint256 earmarked) = liquid.getCDP(tokenId);
        assertApproxEqAbs(debt, 0, 1);
        assertApproxEqAbs(earmarked, 0, 1);
        // Withdraw available collateral (earmark rework may reduce available amount)
        if (collateral > 0) {
            uint256 available = fakeYieldToken.balanceOf(address(liquid));
            uint256 toWithdraw = collateral > available ? available : collateral;
            if (toWithdraw > 0) {
                vm.prank(debtor);
                liquid.withdraw(toWithdraw, debtor, tokenId);
            }
        }
    }

    function testIncrease_minimumCollateralization_DOS_Redemption() external {
        //set fee to 10% to compensate for wrong deduction of _totalLocked in `redeem()`
        vm.startPrank(alOwner);
        liquid.setProtocolFee(1000);
        uint256 minimumCollateralizationBefore = liquid.minimumCollateralization();
        console.log("minimumCollateralization before", minimumCollateralizationBefore);
        //deposit some tokens
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 100e18);
        liquid.deposit(100e18, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        //mint some alTokens
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();
        //skip a block to be able to repay
        vm.roll(vm.getBlockNumber() + 1);
        //admit increase minimumCollateralization
        vm.startPrank(alOwner);
        liquid.setMinimumCollateralization(uint256(FIXED_POINT_SCALAR * FIXED_POINT_SCALAR) / 88e16); // 88% collateralization
        uint256 minimumCollateralizationAfter = liquid.minimumCollateralization();
        assertGt(minimumCollateralizationAfter, minimumCollateralizationBefore, "minimumCollateralization should be increased");
        console.log("minimumCollateralization after", minimumCollateralizationAfter);
        //try to repay
        vm.startPrank(address(0xbeef));
        uint256 alTokenBalanceBeef = alToken.balanceOf(address(0xbeef));
        //give alowance to liquid to burn
        SafeERC20.safeApprove(address(alToken), address(liquid), alTokenBalanceBeef / 2);
        liquid.burn(alTokenBalanceBeef / 2, tokenIdFor0xBeef);
        //create a redemption request for 50% of the alToken balance
        vm.startPrank(address(0xbeef));
        //give alowance to transmuter to burn
        alToken.approve(address(transmuterLogic), alTokenBalanceBeef / 2);
        transmuterLogic.createRedemption(alTokenBalanceBeef / 2);
        //make sure redemption can be claimed in full
        vm.roll(vm.getBlockNumber() + 6_256_000);
        transmuterLogic.claimRedemption(1);
    }

    function testDepositCanBeDoSed() external {
        // Initial setup - deposit and borrow
        uint256 depositAmount = 1000e18;
        uint256 borrowAmount = 900e18;
        //Malicious user directly transfering token
        address attacker = makeAddr("attacker");
        uint256 depositCap = liquid.depositCap();
        deal(address(fakeYieldToken), attacker, depositCap);
        vm.prank(attacker);
        fakeYieldToken.transfer(address(liquid), depositCap);
        // User makes a deposit and borrows
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        vm.stopPrank();
    }

    function test_Burn() external {
        uint256 depositAmount = 1000e18; // Each user deposits 1,000
        uint256 mintAmount = 500e18; // Each user mints 500
        uint256 repayAmount = 500e18; // User2 repays 500
        uint256 redemptionAmount = 500e18; // User3 creates redemption for 500
        uint256 burnAmount = 400e18; // User1 tries to burn 400
        // Step 1: User1 deposits and mints
        console.log("Step 1: User1 deposits and mints");
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount);
        liquid.deposit(depositAmount, address(0xbeef), 0);
        uint256 tokenIdForUser1 = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdForUser1, mintAmount, address(0xbeef));
        vm.stopPrank();
        // Step 2: User2 deposits and mints
        console.log("Step 2: User2 deposits and mints");
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), depositAmount);
        liquid.deposit(depositAmount, address(0xdad), 0);
        uint256 tokenIdForUser2 = LiquidNFTHelper.getFirstTokenId(address(0xdad), address(liquidNFT));
        liquid.mint(tokenIdForUser2, mintAmount, address(0xdad));
        vm.stopPrank();
        // Step 3: User2 repays all debts
        console.log("Step 3: User2 repays all debts");
        vm.roll(vm.getBlockNumber() + 1000); // Simulate time passing
        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), repayAmount);
        liquid.repay(repayAmount, tokenIdForUser2);
        vm.stopPrank();
        // Step 4: User3 creates redemption
        // Now transmuter has enough yield tokens to cover the redemption
        console.log("Step 4: User3 creates redemption");
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), redemptionAmount);
        transmuterLogic.createRedemption(redemptionAmount);
        vm.stopPrank();
        // Step 5: User1 tries to burn his debt
        // This should succeed because transmuter has enough yield tokens to cover the redemption,
        // However it fails
        console.log("Step 5: User1 tries to burn his debt");
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(liquid), burnAmount);
        liquid.burn(burnAmount, tokenIdForUser1);
        vm.stopPrank();
    }

    function testBDR_price_drop() external {
        uint256 amount = 1e18;
        address debtor = address(0xbeef);
        address alice = address(0xdad);
        vm.startPrank(address(someWhale));
        fakeYieldToken.mint(amount, address(someWhale));
        vm.stopPrank();
        // Mint debt tokens to debtor
        vm.startPrank(debtor);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount * 2);
        liquid.deposit(amount, debtor, 0);
        uint256 tokenDebtor = 1;
        uint256 maxBorrowable = liquid.getMaxBorrowable(tokenDebtor);
        liquid.mint(tokenDebtor, maxBorrowable, debtor);
        vm.stopPrank();
        (, uint256 debt,) = liquid.getCDP(tokenDebtor);
        // Create Redemption
        vm.startPrank(alice);
        uint256 redemption = debt / 2;
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), amount);
        transmuterLogic.createRedemption(redemption);
        uint256 aliceId = 1;
        vm.stopPrank();
        address admin = transmuterLogic.admin();
        vm.startPrank(admin);
        transmuterLogic.setTransmutationFee(0);
        vm.stopPrank();
        // Advance time to complete redemption
        vm.roll(vm.getBlockNumber() + 5_256_000);

        // Mimick bad debt
        fakeYieldToken.siphon(5e17);

        // Check balances after claim
        uint256 liquidYTBefore = fakeYieldToken.balanceOf(address(liquid));
        vm.startPrank(alice);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), amount);
        transmuterLogic.claimRedemption(aliceId);
        vm.stopPrank();
        uint256 liquidYTAfter = fakeYieldToken.balanceOf(address(liquid));
        // Since half of debt has been transmuted then half of collateral should be taken despite the price drop
        // If price drops then 4.5e17 debt tokens would need more collateral to be fulfilled
        // Bad debt ratio of 1.2 makes the redeemed amount equal to 3.75e17 instead
        // Increase in collateral needed from price drop is offset with adjusted redemption amount
        // Half of collateral is redeemed alongside half of debt
        assertEq(liquidYTAfter, amount / 2);
    }

    function testClaimRedemptionRoundUp() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), 99_999e18);
        liquid.deposit(amount, address(0xbeef), 0);
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, 80e18, address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 9999e18);
        for (uint256 i = 1; i < 4; i++) {
            transmuterLogic.createRedemption(1e18);
        }
        vm.roll(vm.getBlockNumber() + 1);
        for (uint256 i = 1; i < 4; i++) {
            transmuterLogic.claimRedemption(i);
        }
        vm.stopPrank();
    }

    function testRepayWithEarmarkedDebt_MultiplePoke_Broken() external {
        uint256 amount = 100e18;
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenId, (amount / 2), address(0xbeef));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), 50e18);
        transmuterLogic.createRedemption(50e18);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        liquid.poke(tokenId);
        vm.roll(vm.getBlockNumber() + 5_256_000);
        vm.prank(address(0xbeef));
        liquid.repay(25e18, tokenId);
    }

    function testLiquidate_WrongTokenTransfer() external {
        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();
        // just ensureing global liquid collateralization stays above the minimum required for regular
        // no need to mint anything
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount * 2);
        liquid.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization, address(0xbeef));
        vm.stopPrank();
        // modify yield token price via modifying underlying token supply
        (uint256 prevCollateral, uint256 prevDebt,) = liquid.getCDP(tokenIdFor0xBeef);
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);
        // ensure initial debt is correct
        vm.assertApproxEqAbs(prevDebt, 180_000_000_000_000_000_018_000, minimumDepositOrWithdrawalLoss);
        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        uint256 liquidatorPrevTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPrevUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        uint256 liquidCurrentCollateralization =
            liquid.normalizeUnderlyingTokensToDebt(liquid.getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / liquid.totalDebt();
        (uint256 liquidationAmount, uint256 expectedDebtToBurn, uint256 expectedBaseFee, uint256 outsourcedFee) = liquid.calculateLiquidation(
            liquid.totalValue(tokenIdFor0xBeef),
            prevDebt,
            liquid.minimumCollateralization(),
            liquidCurrentCollateralization,
            liquid.globalMinimumCollateralization(),
            liquidatorFeeBPS
        );
        uint256 expectedLiquidationAmountInYield = liquid.convertDebtTokensToYield(liquidationAmount);
        uint256 expectedBaseFeeInYield = liquid.convertDebtTokensToYield(expectedBaseFee);
        uint256 expectedFeeInUnderlying = expectedDebtToBurn * liquidatorFeeBPS / 10_000;
        uint256 transmuterBefore = fakeYieldToken.balanceOf(address(transmuter));
        console.log("transmuterBefore", transmuterBefore);
        (uint256 assets, uint256 feeInYield, uint256 feeInUnderlying) = liquid.liquidate(tokenIdFor0xBeef);
        uint256 liquidatorPostTokenBalance = IERC20(fakeYieldToken).balanceOf(address(externalUser));
        uint256 liquidatorPostUnderlyingBalance = IERC20(fakeUnderlyingToken).balanceOf(address(externalUser));
        (uint256 depositedCollateral, uint256 debt,) = liquid.getCDP(tokenIdFor0xBeef);
        uint256 transmuterAfter = fakeYieldToken.balanceOf(address(transmuter));
        console.log("transmuterAfter", transmuterAfter);
        assertEq(transmuterBefore, transmuterAfter);
        vm.stopPrank();
        // ensure debt is reduced by the result of (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(debt, prevDebt - expectedDebtToBurn, minimumDepositOrWithdrawalLoss);
        // ensure depositedCollateral is reduced by the result of (collateral - y)/(debt - y) = minimum collateral
        vm.assertApproxEqAbs(depositedCollateral, prevCollateral - expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);
        // ensure assets is equal to liquidation amount i.e. y in (collateral - y)/(debt - y) = minimum collateral ratio
        vm.assertApproxEqAbs(assets, expectedLiquidationAmountInYield, minimumDepositOrWithdrawalLoss);
        // ensure liquidator fee is correct (3% of liquidation amount)
        vm.assertApproxEqAbs(feeInYield, expectedBaseFeeInYield, 1e18);
        // liquidator gets correct amount of fee
        vm.assertApproxEqAbs(liquidatorPostTokenBalance, liquidatorPrevTokenBalance + feeInYield, 1e18);
        vm.assertEq(liquidatorPostUnderlyingBalance, liquidatorPrevUnderlyingBalance + feeInUnderlying);
        vm.assertEq(liquidFeeVault.totalDeposits(), 10_000 ether - feeInUnderlying);
    }

    function testRepayWithDifferentPrice() external {
        uint256 depositAmount = 100e18;
        uint256 debtAmount = depositAmount / 2;
        uint256 initialFund = depositAmount * 2;
        address alice = makeAddr("alice");
        vm.startPrank(alice);
        // alice has 200 ETH of yield token
        fakeUnderlyingToken.mint(alice, initialFund);
        SafeERC20.safeApprove(address(fakeUnderlyingToken), address(fakeYieldToken), initialFund);
        fakeYieldToken.mint(initialFund, alice);
        // alice deposits 100 ETH to Lux Liquid
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), initialFund);
        liquid.deposit(depositAmount, address(alice), 0);
        // alice mints 50 ETH of debt token
        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(alice, address(liquidNFT));
        liquid.mint(tokenId, debtAmount, alice);
        // forward block number so that alice can repay
        vm.roll(vm.getBlockNumber() + 1);
        // yield token price increased a little in the meantime
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        uint256 modifiedVaultSupply = initialVaultSupply - (initialVaultSupply * 590 / 10_000);
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);
        // alice fully repays her debt
        liquid.repay(debtAmount, tokenId);
        // verify all debt are cleared
        (uint256 collateral, uint256 debt, uint256 earmarked) = liquid.getCDP(tokenId);
        assertEq(debt, 0, "debt == 0");
        assertEq(earmarked, 0, "earmarked == 0");
        assertEq(collateral, depositAmount, "depositAmount == collateral");
        liquid.withdraw(collateral, alice, tokenId);
        vm.stopPrank();
    }

    function test_Poc_claimRedemption_error() external {
        uint256 amount = 200_000e18; // 200,000 yvdai
        vm.startPrank(someWhale);
        fakeYieldToken.mint(whaleSupply, someWhale);
        vm.stopPrank();
        ////////////////////////////////////////////////
        // yetAnotherExternalUser deposits 200_000e18 //
        ////////////////////////////////////////////////
        vm.startPrank(yetAnotherExternalUser);
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount);
        liquid.deposit(amount, yetAnotherExternalUser, 0);
        vm.stopPrank();
        ////////////////////////////////
        // 0xbeef deposits 200_000e18 //
        ////////////////////////////////
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), amount + 100e18);
        liquid.deposit(amount, address(0xbeef), 0);
        // a single position nft would have been minted to 0xbeef
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        uint256 mintAmount = liquid.totalValue(tokenIdFor0xBeef) * FIXED_POINT_SCALAR / minimumCollateralization;
        ////////////////////////////
        // 0xbeef mints debtToken //
        ////////////////////////////
        liquid.mint(tokenIdFor0xBeef, mintAmount, address(0xbeef));
        vm.stopPrank();
        (, uint256 debt,) = liquid.getCDP(tokenIdFor0xBeef);
        // check
        assertEq(debt, mintAmount);
        assertEq(liquid.totalDebt(), mintAmount);
        // Need to start a transmutator deposit, to start earmarking debt
        vm.startPrank(anotherExternalUser);
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), mintAmount);
        transmuterLogic.createRedemption(mintAmount);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + (5_256_000));
        // modify yield token price via modifying underlying token supply
        uint256 initialVaultSupply = IERC20(address(fakeYieldToken)).totalSupply();
        fakeYieldToken.updateMockTokenSupply(initialVaultSupply);
        // increasing yeild token suppy by 59 bps or 5.9% while keeping the unederlying supply unchanged
        uint256 modifiedVaultSupply = (initialVaultSupply * 590 / 10_000) + initialVaultSupply;
        fakeYieldToken.updateMockTokenSupply(modifiedVaultSupply);
        // The engine admits a new price only across a block boundary, so a price
        // move is an inter-block event here as it is on chain.
        vm.roll(vm.getBlockNumber() + 1);
        ////////////////////////////////
        // liquidate tokenIdFor0xBeef //
        ////////////////////////////////
        // let another user liquidate the previous user position
        vm.startPrank(externalUser);
        liquid.liquidate(tokenIdFor0xBeef);
        vm.stopPrank();
        console.log("IERC20(liquid.yieldToken()).balanceOf(address(transmuterLogic)):", IERC20(liquid.yieldToken()).balanceOf(address(transmuterLogic)));
        ///////////////////////////////
        // claimRedemption() success //
        ///////////////////////////////
        vm.startPrank(anotherExternalUser);
        transmuterLogic.claimRedemption(1);
        vm.stopPrank();
    }

    function testRedeemTwiceBetweenSync() external {
        vm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), type(uint256).max);
        liquid.deposit(100_000e18, address(0xbeef), 0);
        uint256 tokenIdFor0xBeef = LiquidNFTHelper.getFirstTokenId(address(0xbeef), address(liquidNFT));
        liquid.mint(tokenIdFor0xBeef, 8500e18, address(0xbeef));
        liquid.mint(tokenIdFor0xBeef, 1000e18, address(0xaaaa));
        liquid.mint(tokenIdFor0xBeef, 500e18, address(0xbbbb));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), type(uint256).max);
        transmuterLogic.createRedemption(3500e18);
        vm.stopPrank();

        vm.startPrank(address(0xaaaa));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), type(uint256).max);
        transmuterLogic.createRedemption(1000e18);
        vm.stopPrank();

        vm.startPrank(address(0xbbbb));
        SafeERC20.safeApprove(address(alToken), address(transmuterLogic), type(uint256).max);
        transmuterLogic.createRedemption(500e18);
        vm.stopPrank();

        vm.startPrank(address(0xdad));
        SafeERC20.safeApprove(address(fakeYieldToken), address(liquid), type(uint256).max);
        liquid.deposit(100_000e18, address(0xdad), 0);
        uint256 tokenIdFor0xdad = LiquidNFTHelper.getFirstTokenId(address(0xdad), address(liquidNFT));
        liquid.mint(tokenIdFor0xdad, 100e18, address(0xdad));
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 5_256_000 * 2 / 5);

        liquid.poke(tokenIdFor0xdad);
        liquid.poke(tokenIdFor0xBeef);

        (uint256 collateral, uint256 debt, uint256 earmarked) = liquid.getCDP(tokenIdFor0xdad);
        (uint256 collateralBeef, uint256 debtBeef, uint256 earmarkedBeef) = liquid.getCDP(tokenIdFor0xBeef);

        // The first redemption
        vm.startPrank(address(0xaaaa));
        transmuterLogic.claimRedemption(2);
        vm.stopPrank();

        vm.roll(vm.getBlockNumber() + 5_256_000 / 10);

        // The second redemption
        vm.startPrank(address(0xbbbb));
        transmuterLogic.claimRedemption(3);
        vm.stopPrank();

        liquid.poke(tokenIdFor0xdad);
        liquid.poke(tokenIdFor0xBeef);

        (collateral, debt, earmarked) = liquid.getCDP(tokenIdFor0xdad);
        (collateralBeef, debtBeef, earmarkedBeef) = liquid.getCDP(tokenIdFor0xBeef);

        assertApproxEqAbs(earmarked + earmarkedBeef, liquid.cumulativeEarmarked(), 3);
        assertApproxEqAbs(debt + debtBeef, liquid.totalDebt(), 3);
    }
}
