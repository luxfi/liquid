// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AlchemistV3} from "../src/AlchemistV3.sol";
import {AlchemistV3Position} from "../src/AlchemistV3Position.sol";
import {Transmuter} from "../src/Transmuter.sol";
import {AlchemistETHVault} from "../src/AlchemistETHVault.sol";
import {IAlchemistV3, AlchemistInitializationParams} from "../src/interfaces/IAlchemistV3.sol";
import {IAlchemicToken} from "../src/interfaces/IAlchemicToken.sol";
import {ITransmuter} from "../src/interfaces/ITransmuter.sol";

/// @title DeployMainnet
/// @notice Deploys AlchemistV3 system for ETH on Lux Mainnet
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

    // --- Transmuter parameters ---
    uint256 constant TIME_TO_TRANSMUTE = 90 days / 2; // ~90 days in blocks at 2s
    uint256 constant TRANSMUTATION_FEE = 50; // 0.5% in BPS
    uint256 constant EXIT_FEE = 200; // 2% in BPS
    uint256 constant GRAPH_SIZE = 1000;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Lux Mainnet Deployment: AlchemistV3 for ETH ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("LETH:", LETH);
        console.log("WLUX:", WLUX);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy AlchemistV3 (proxy-pattern: empty constructor + initialize)
        AlchemistV3 alchemist = new AlchemistV3();
        console.log("AlchemistV3 deployed:", address(alchemist));

        // 2. Deploy AlchemistV3Position NFT (needs alchemist address)
        AlchemistV3Position position = new AlchemistV3Position(address(alchemist));
        console.log("AlchemistV3Position deployed:", address(position));

        // 3. Deploy Transmuter for ETH
        ITransmuter.TransmuterInitializationParams memory transmuterParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: LETH,
            feeReceiver: deployer,
            timeToTransmute: TIME_TO_TRANSMUTE,
            transmutationFee: TRANSMUTATION_FEE,
            exitFee: EXIT_FEE,
            graphSize: GRAPH_SIZE
        });
        Transmuter transmuter = new Transmuter(transmuterParams);
        console.log("Transmuter deployed:", address(transmuter));

        // 4. Deploy ETH Vault (weth, alchemist, owner)
        AlchemistETHVault vault = new AlchemistETHVault(WLUX, address(alchemist), deployer);
        console.log("AlchemistETHVault deployed:", address(vault));

        // 5. Initialize AlchemistV3
        //    Note: tokenAdapter must be set separately after adapter deployment
        AlchemistInitializationParams memory params = AlchemistInitializationParams({
            admin: deployer,
            debtToken: LETH,
            underlyingToken: WLUX,
            yieldToken: WLUX, // Initially set to WLUX; update to MYT yield token post-deploy
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
        alchemist.initialize(params);
        console.log("AlchemistV3 initialized");

        // 6. Set position NFT on alchemist
        alchemist.setAlchemistPositionNFT(address(position));
        console.log("Position NFT set on AlchemistV3");

        // 7. Set alchemist on transmuter
        transmuter.setAlchemist(address(alchemist));
        console.log("Alchemist set on Transmuter");

        // 8. Whitelist AlchemistV3 as minter on LETH
        IAlchemicToken(LETH).setWhitelist(address(alchemist), true);
        console.log("AlchemistV3 whitelisted as LETH minter");

        // 9. Set mint ceiling for AlchemistV3 on LETH
        IAlchemicToken(LETH).setCeiling(address(alchemist), DEPOSIT_CAP);
        console.log("LETH mint ceiling set for AlchemistV3");

        vm.stopBroadcast();

        // --- Deployment Summary ---
        console.log("\n=== Deployment Summary ===");
        console.log("AlchemistV3:         ", address(alchemist));
        console.log("AlchemistV3Position: ", address(position));
        console.log("Transmuter:          ", address(transmuter));
        console.log("AlchemistETHVault:   ", address(vault));
        console.log("LETH (debt token):   ", LETH);
        console.log("WLUX (underlying):   ", WLUX);
        console.log("Min Collat (90% LTV):", MIN_COLLATERALIZATION);

        console.log("\n=== Post-Deploy Steps ===");
        console.log("1. Deploy TokenAdapter for yield token and call alchemist.setTokenAdapter()");
        console.log("2. Update yieldToken if using MYT strategy (not raw WLUX)");
        console.log("3. Deploy AlchemistCurator, AlchemistAllocator, and strategies");
        console.log("4. Transfer admin to multisig/timelock");
    }
}
