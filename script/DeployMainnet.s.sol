// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Liquid} from "../src/Liquid.sol";
import {LiquidPosition} from "../src/LiquidPosition.sol";
import {LiquidTransmuter} from "../src/LiquidTransmuter.sol";
import {LiquidTokenVault} from "../src/LiquidTokenVault.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILiquid, LiquidInitializationParams} from "../src/interfaces/ILiquid.sol";
import {ISynthetic} from "../src/interfaces/ISynthetic.sol";
import {ILiquidTransmuter} from "../src/interfaces/ILiquidTransmuter.sol";

/// @title DeployMainnet
/// @notice Deploys Liquid system for ETH on Lux Mainnet
/// @dev Run dry: forge script script/DeployMainnet.s.sol --rpc-url lux_mainnet_public -vvvv
///      Broadcast: forge script script/DeployMainnet.s.sol --rpc-url lux_mainnet_public --broadcast -vvvv
contract DeployMainnet is Script {
    // --- Canonical addresses ---
    // The market is like-kind: ETH-denominated collateral against ETH-denominated
    // debt. The engine converts underlying to debt with a decimals scalar and
    // holds no cross-asset price source, so pairing LETH debt against anything
    // other than bridged ETH would let a borrower mint LETH against collateral
    // the engine cannot value. WLUX is collateral for a LUX market, not this one.
    address constant LETH = 0x60E0a8167FC13dE89348978860466C9ceC24B9ba; // debt token

    // Bridged ETH is the underlying; the yield-bearing wrapper deposited against
    // it is the collateral; the adapter prices one in terms of the other. All
    // three are per-network deployments, and a wrong address here is the one
    // mistake this script cannot detect for itself.
    address immutable BRIDGED_ETH = vm.envAddress("BRIDGED_ETH_ADDRESS");
    address immutable YIELD_ETH = vm.envAddress("YIELD_ETH_ADDRESS");
    address immutable TOKEN_ADAPTER = vm.envAddress("TOKEN_ADAPTER_ADDRESS");

    // --- Protocol parameters ---
    uint256 constant BLOCKS_PER_YEAR = 15_768_000; // ~2s block time
    uint256 constant DEPOSIT_CAP = 10_000_000 ether;
    uint256 constant MIN_COLLATERALIZATION = 1.1111e18; // 90% LTV (100/90)

    // Both floors sit below the mint bar. At full utilisation every borrower is
    // drawn to MIN_COLLATERALIZATION and the protocol-wide ratio equals it, so a
    // global floor at or above the bar marks a healthy protocol insolvent and
    // routes every liquidation through full seizure.
    uint256 constant GLOBAL_MIN_COLLATERALIZATION = 1.0526e18;
    uint256 constant COLLATERALIZATION_LOWER_BOUND = 1.05e18;

    uint256 constant PROTOCOL_FEE = 1000; // 10% in BPS
    uint256 constant LIQUIDATOR_FEE = 500; // 5% in BPS
    uint256 constant REPAYMENT_FEE = 100; // 1% in BPS

    // How far the adapter may move the engine's price, in BPS per block elapsed.
    // At 2s blocks 1 BPS/block is ~18%/hour: fast enough to track real yield
    // accrual and real loss events, slow enough that a compromised adapter
    // cannot move borrowing power before a guardian can pause the market.
    uint256 constant MAX_PRICE_DEVIATION = 1;

    // Seed for the fee vault, in bridged ETH. This is what pays the liquidator
    // bonus on positions too far underwater to fund one from their own collateral.
    uint256 constant FEE_VAULT_SEED = 10 ether;

    // --- LiquidTransmuter parameters ---
    uint256 constant TIME_TO_TRANSMUTE = 90 days / 2; // ~90 days in blocks at 2s
    uint256 constant TRANSMUTATION_FEE = 50; // 0.5% in BPS
    uint256 constant EXIT_FEE = 200; // 2% in BPS
    uint256 constant GRAPH_SIZE = 1000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Lux Mainnet Deployment: Liquid for ETH ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("LETH (debt):", LETH);
        console.log("Bridged ETH (underlying):", BRIDGED_ETH);
        console.log("Yield ETH (collateral):", YIELD_ETH);
        console.log("Token adapter:", TOKEN_ADAPTER);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Liquid (proxy-pattern: empty constructor + initialize)
        Liquid liquid = new Liquid();
        console.log("Liquid deployed:", address(liquid));

        // 2. Deploy LiquidPosition NFT (needs liquid address)
        LiquidPosition position = new LiquidPosition(address(liquid));
        console.log("LiquidPosition deployed:", address(position));

        // 3. Deploy LiquidTransmuter for ETH
        ILiquidTransmuter.TransmuterInitializationParams memory transmuterParams = ILiquidTransmuter.TransmuterInitializationParams({
            syntheticToken: LETH,
            feeReceiver: deployer,
            timeToTransmute: TIME_TO_TRANSMUTE,
            transmutationFee: TRANSMUTATION_FEE,
            exitFee: EXIT_FEE,
            graphSize: GRAPH_SIZE
        });
        LiquidTransmuter transmuter = new LiquidTransmuter(transmuterParams);
        console.log("LiquidTransmuter deployed:", address(transmuter));

        // 4. Deploy the fee vault. It must hold the market's underlying token:
        //    the liquidator bonus is denominated in underlying, and Liquid checks
        //    the vault's token matches before accepting it.
        LiquidTokenVault vault = new LiquidTokenVault(BRIDGED_ETH, address(liquid), deployer);
        console.log("LiquidTokenVault deployed:", address(vault));

        // 5. Initialize Liquid. The adapter must already exist: the engine binds
        //    to it here and checks it reports this market's own token pair.
        LiquidInitializationParams memory params = LiquidInitializationParams({
            admin: deployer,
            debtToken: LETH,
            underlyingToken: BRIDGED_ETH,
            yieldToken: YIELD_ETH,
            depositCap: DEPOSIT_CAP,
            blocksPerYear: BLOCKS_PER_YEAR,
            minimumCollateralization: MIN_COLLATERALIZATION,
            globalMinimumCollateralization: GLOBAL_MIN_COLLATERALIZATION,
            collateralizationLowerBound: COLLATERALIZATION_LOWER_BOUND,
            tokenAdapter: TOKEN_ADAPTER,
            maxPriceDeviation: MAX_PRICE_DEVIATION,
            transmuter: address(transmuter),
            protocolFee: PROTOCOL_FEE,
            protocolFeeReceiver: deployer,
            liquidatorFee: LIQUIDATOR_FEE,
            repaymentFee: REPAYMENT_FEE
        });
        liquid.initialize(params);
        console.log("Liquid initialized");

        // 6. Set position NFT on liquid
        liquid.setLiquidPositionNFT(address(position));
        console.log("Position NFT set on Liquid");

        // 7. Set liquid on transmuter
        transmuter.setLiquid(address(liquid));
        console.log("Liquid set on LiquidTransmuter");

        // 8. Point Liquid at the fee vault and seed it. Liquidation survives an
        //    unset vault; the incentive to perform one on a deeply underwater
        //    position does not.
        liquid.setLiquidFeeVault(address(vault));
        IERC20(BRIDGED_ETH).approve(address(vault), FEE_VAULT_SEED);
        vault.deposit(FEE_VAULT_SEED);
        console.log("Fee vault set and seeded:", FEE_VAULT_SEED);

        // 9. Grant Liquid the minter role on LETH. Minting is the only supply
        //    authority the engine needs -- it retires debt through the borrower's
        //    own allowance -- so it takes MINTER_ROLE, not admin.
        ISynthetic(LETH).grantMinter(address(liquid));
        console.log("Liquid granted MINTER_ROLE on LETH");

        vm.stopBroadcast();

        // --- Deployment Summary ---
        console.log("\n=== Deployment Summary ===");
        console.log("Liquid:         ", address(liquid));
        console.log("LiquidPosition: ", address(position));
        console.log("LiquidTransmuter:          ", address(transmuter));
        console.log("LiquidETHVault:   ", address(vault));
        console.log("LETH (debt token):   ", LETH);
        console.log("Bridged ETH (underlying):", BRIDGED_ETH);
        console.log("Min Collat (90% LTV):", MIN_COLLATERALIZATION);

        console.log("\n=== Post-Deploy Steps ===");
        console.log("1. Deploy LiquidCurator, LiquidAllocator, and strategies");
        console.log("2. Set guardians so deposits and loans can be paused without the admin key");
        console.log("3. Transfer admin to multisig/timelock");
    }
}
