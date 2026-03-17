// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Liquid} from "../src/Liquid.sol";
import {LiquidPosition} from "../src/LiquidPosition.sol";
import {LiquidTransmuter} from "../src/LiquidTransmuter.sol";
import {LiquidETHVault} from "../src/LiquidETHVault.sol";
import {ILiquid, LiquidInitializationParams} from "../src/interfaces/ILiquid.sol";
import {ILiquidMintable} from "../src/interfaces/ILiquidMintable.sol";
import {ILiquidTransmuter} from "../src/interfaces/ILiquidTransmuter.sol";

/// @title DeployMainnet
/// @notice Deploys Liquid system for ETH on Lux Mainnet
/// @dev Run dry: forge script script/DeployMainnet.s.sol --rpc-url lux_mainnet_public -vvvv
///      Broadcast: forge script script/DeployMainnet.s.sol --rpc-url lux_mainnet_public --broadcast -vvvv
contract DeployMainnet is Script {
    // --- Canonical addresses ---
    address constant LETH = 0x60E0a8167FC13dE89348978860466C9ceC24B9ba;
    address constant WLUX = 0x4888E4a2Ee0F03051c72D2BD3ACf755eD3498B3E;
    address constant LBTC = 0x1E48D32a4F5e9f08DB9aE4959163300FaF8A6C8e;

    // --- Protocol parameters ---
    uint256 constant BLOCKS_PER_YEAR = 15_768_000; // ~2s block time
    uint256 constant DEPOSIT_CAP = 10_000_000 ether;
    uint256 constant MIN_COLLATERALIZATION = 1.1111e18; // 90% LTV (100/90)
    uint256 constant GLOBAL_MIN_COLLATERALIZATION = 1.15e18;
    uint256 constant COLLATERALIZATION_LOWER_BOUND = 1.05e18;
    uint256 constant PROTOCOL_FEE = 1000; // 10% in BPS
    uint256 constant LIQUIDATOR_FEE = 500; // 5% in BPS
    uint256 constant REPAYMENT_FEE = 100; // 1% in BPS

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
        console.log("LETH:", LETH);
        console.log("WLUX:", WLUX);

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

        // 4. Deploy ETH Vault (weth, liquid, owner)
        LiquidETHVault vault = new LiquidETHVault(WLUX, address(liquid), deployer);
        console.log("LiquidETHVault deployed:", address(vault));

        // 5. Initialize Liquid
        //    Note: tokenAdapter must be set separately after adapter deployment
        LiquidInitializationParams memory params = LiquidInitializationParams({
            admin: deployer,
            debtToken: LETH,
            underlyingToken: WLUX,
            yieldToken: WLUX, // Initially set to WLUX; update to VAULT yield token post-deploy
            depositCap: DEPOSIT_CAP,
            blocksPerYear: BLOCKS_PER_YEAR,
            minimumCollateralization: MIN_COLLATERALIZATION,
            globalMinimumCollateralization: GLOBAL_MIN_COLLATERALIZATION,
            collateralizationLowerBound: COLLATERALIZATION_LOWER_BOUND,
            tokenAdapter: address(0), // Set after adapter deployment
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

        // 8. Whitelist Liquid as minter on LETH
        ILiquidMintable(LETH).setWhitelist(address(liquid), true);
        console.log("Liquid whitelisted as LETH minter");

        // 9. Set mint ceiling for Liquid on LETH
        ILiquidMintable(LETH).setCeiling(address(liquid), DEPOSIT_CAP);
        console.log("LETH mint ceiling set for Liquid");

        vm.stopBroadcast();

        // --- Deployment Summary ---
        console.log("\n=== Deployment Summary ===");
        console.log("Liquid:         ", address(liquid));
        console.log("LiquidPosition: ", address(position));
        console.log("LiquidTransmuter:          ", address(transmuter));
        console.log("LiquidETHVault:   ", address(vault));
        console.log("LETH (debt token):   ", LETH);
        console.log("WLUX (underlying):   ", WLUX);
        console.log("Min Collat (90% LTV):", MIN_COLLATERALIZATION);

        console.log("\n=== Post-Deploy Steps ===");
        console.log("1. Deploy TokenAdapter for yield token and call liquid.setTokenAdapter()");
        console.log("2. Update yieldToken if using VAULT strategy (not raw WLUX)");
        console.log("3. Deploy LiquidCurator, LiquidAllocator, and strategies");
        console.log("4. Transfer admin to multisig/timelock");
    }
}
