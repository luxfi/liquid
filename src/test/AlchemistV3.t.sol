// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import {DSTestPlus} from "./utils/DSTestPlus.sol";
import {IAlchemistV3AdminActions} from "../interfaces/alchemist/IAlchemistV3AdminActions.sol";
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
import {CheatCodes} from "./utils/Cheatcodes.sol";

contract AlchemistV3Test is DSTestPlus {
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
    CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
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

    // ----- Variables for deposits & withdrawals -----

    // account funds to make deposits/test with
    uint256 accountFunds = 1_000_000e18;

    // amount of yield/underlying token to deposit
    uint256 depositAmount = 10_000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDeposit = 1000e18;

    // minimum amount of yield/underlying token to deposit
    uint256 minimumDepositOrWithdrawalLoss = 1e18;

    function setUp() external {
        // test maniplulation for convenience
        address caller = address(0xdead);
        address proxyOwner = address(this);
        cheats.assume(caller != address(0));
        cheats.assume(proxyOwner != address(0));
        cheats.assume(caller != proxyOwner);
        cheats.startPrank(caller);

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
            minimumCollateralization: 2 * 1e18,
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

        cheats.stopPrank();

        // Add funds to test account
        deal(address(fakeYieldToken), address(0xbeef), accountFunds);
    }

    function testDeposit() external {
        hevm.prank(address(0xdead));
        whitelist.add(address(0xbeef));
        hevm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));
        assertApproxEq(alchemist.totalValue(address(0xbeef)), depositAmount, minimumDepositOrWithdrawalLoss);
        hevm.stopPrank();
    }

    function testWithdrawal() external {
        hevm.prank(address(0xdead));
        whitelist.add(address(0xbeef));
        hevm.startPrank(address(0xbeef));
        SafeERC20.safeApprove(address(fakeYieldToken), address(alchemist), accountFunds);
        alchemist.deposit(address(fakeYieldToken), depositAmount, address(0xbeef));
        uint256 shares = alchemist.convertYieldTokensToShares(address(fakeYieldToken), depositAmount);
        alchemist.withdraw(address(fakeYieldToken), shares / 2, address(0xbeef));
        assertApproxEq(alchemist.totalValue(address(0xbeef)), depositAmount / 2, minimumDepositOrWithdrawalLoss);
        hevm.stopPrank();
    }
}
