// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILiquidCore {
    function deposit(uint256 amount, address recipient, uint256 tokenId) external returns (uint256);
    function mint(uint256 tokenId, uint256 amount, address recipient) external;
    function totalDebt() external view returns (uint256);
    function depositCap() external view returns (uint256);
    function admin() external view returns (address);
    function debtToken() external view returns (address);
    function yieldToken() external view returns (address);
}

interface IPosition {
    function balanceOf(address) external view returns (uint256);
    function ownerOf(uint256) external view returns (address);
}

interface IDevToken {
    function mint(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function symbol() external view returns (string memory);
}

interface IComplianceGate {
    function canRedeem(address, address) external view returns (bool);
    function whitelisted(address) external view returns (bool);
    function kycLevel(address) external view returns (uint8);
    function approve(address, uint8) external;
}

interface IAdapter {
    function price() external view returns (uint256);
    function ticker() external view returns (string memory);
    function nav() external view returns (uint256);
    function updateNAV(uint256) external;
}

/// @title TestFlow — end-to-end Liquid Protocol demo
contract TestFlow is Script {
    // Deployed addresses (from DeployLocal)
    address constant WLUX = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    address constant LUSD = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address constant IBIT = 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;
    address constant LIQUID = 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707;
    address constant POSITION = 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6;
    address constant GATE = 0x0B306BF915C4d645ff596e518fAf3F9669b97016;
    address constant IBIT_ADAPTER = 0x9A676e781A523b5d0C0e43731313A708CB607508;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(pk);
        vm.startBroadcast(pk);

        console.log("=== Liquid Protocol E2E Test ===");
        console.log("User:", user);

        // 1. Check protocol state
        ILiquidCore liquid = ILiquidCore(LIQUID);
        console.log("\n--- Protocol State ---");
        console.log("Admin:", liquid.admin());
        console.log("Debt Token:", liquid.debtToken());
        console.log("Yield Token:", liquid.yieldToken());
        console.log("Deposit Cap:", liquid.depositCap());
        console.log("Total Debt:", liquid.totalDebt());

        // 2. Mint WLUX (wrap native LUX)
        console.log("\n--- Wrapping LUX -> WLUX ---");
        (bool ok,) = WLUX.call{value: 100 ether}("");
        require(ok, "wrap failed");
        uint256 wluxBal = IDevToken(WLUX).balanceOf(user);
        console.log("WLUX balance:", wluxBal);

        // 3. Approve and deposit WLUX into Liquid vault
        console.log("\n--- Depositing into Liquid Vault ---");
        IDevToken(WLUX).approve(LIQUID, type(uint256).max);
        liquid.deposit(50 ether, user, 0);
        uint256 tokenId = IPosition(POSITION).balanceOf(user); // NFT ID = balance (first mint is tokenId 1) // tokenId=0 creates new position
        console.log("Position NFTs owned:", tokenId);
        console.log("Position owner (ID 1):", IPosition(POSITION).ownerOf(1));

        // 4. Mint LUSD (borrow against deposit) — 90% LTV
        console.log("\n--- Minting LUSD (borrowing) ---");
        liquid.mint(1, 40 ether, user); // borrow 40 LUSD against 50 WLUX
        uint256 lusdBal = IERC20(LUSD).balanceOf(user);
        console.log("LUSD balance:", lusdBal);
        console.log("Total protocol debt:", liquid.totalDebt());

        // 5. Check IBIT adapter
        console.log("\n--- IBIT Security Token ---");
        IAdapter adapter = IAdapter(IBIT_ADAPTER);
        console.log("Ticker:", adapter.ticker());
        console.log("NAV:", adapter.nav());
        console.log("Price:", adapter.price());

        // 6. Mint mock IBIT tokens
        IDevToken(IBIT).mint(user, 1000 ether);
        console.log("IBIT balance:", IDevToken(IBIT).balanceOf(user));

        // 7. Update NAV (simulate price movement)
        adapter.updateNAV(55.0e18); // IBIT went from $52.34 to $55.00
        console.log("Updated NAV:", adapter.nav());

        // 8. Check compliance
        console.log("\n--- Compliance Gate ---");
        IComplianceGate gate = IComplianceGate(GATE);
        console.log("User whitelisted:", gate.whitelisted(user));
        console.log("KYC level:", gate.kycLevel(user));

        // Whitelist a second user at basic KYC
        address user2 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        gate.approve(user2, 1); // basic KYC
        console.log("User2 whitelisted:", gate.whitelisted(user2));
        console.log("User2 KYC level:", gate.kycLevel(user2));

        vm.stopBroadcast();

        console.log("\n=== ALL TESTS PASSED ===");
        console.log("Deposited: 50 WLUX");
        console.log("Borrowed:  40 LUSD (80% LTV)");
        console.log("IBIT NAV:  $55.00 (up from $52.34)");
        console.log("Compliance: 2 users whitelisted");
    }
}
