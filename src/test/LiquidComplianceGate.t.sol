// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {LiquidComplianceGate} from "../LiquidComplianceGate.sol";
import {IIdentityRegistry} from "@luxfi/erc-3643/contracts/registry/interface/IIdentityRegistry.sol";
import {IIdentity} from "@luxfi/onchain-id/contracts/interface/IIdentity.sol";

contract MockIdentity {
    mapping(uint256 => bytes32[]) private _claims;

    function setClaim(uint256 topic, bytes32 claimId) external {
        _claims[topic].push(claimId);
    }

    function getClaimIdsByTopic(uint256 topic) external view returns (bytes32[] memory) {
        return _claims[topic];
    }
}

contract MockRegistry {
    mapping(address => bool) public verified;
    mapping(address => uint16) public country;
    mapping(address => address) public identityOf;

    function setVerified(address user, bool v) external { verified[user] = v; }
    function setCountry(address user, uint16 c) external { country[user] = c; }
    function setIdentity(address user, address id) external { identityOf[user] = id; }

    function isVerified(address user) external view returns (bool) { return verified[user]; }
    function investorCountry(address user) external view returns (uint16) { return country[user]; }
    function identity(address user) external view returns (IIdentity) {
        return IIdentity(identityOf[user]);
    }
}

contract LiquidComplianceGateTest is Test {
    LiquidComplianceGate gate;
    MockRegistry registry;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address vault = makeAddr("vault");

    uint256 constant TOPIC_KYC = 1;
    uint256 constant TOPIC_ACCREDITED = 10;

    function setUp() public {
        vm.prank(owner);
        gate = new LiquidComplianceGate(owner);
        registry = new MockRegistry();
    }

    function test_unconfigured_vault_blocks() public view {
        assertFalse(gate.canRedeem(alice, vault));
    }

    function test_verified_no_topics_passes() public {
        registry.setVerified(alice, true);
        vm.prank(owner);
        gate.setVaultRegistry(vault, IIdentityRegistry(address(registry)));
        assertTrue(gate.canRedeem(alice, vault));
    }

    function test_unverified_blocks() public {
        vm.prank(owner);
        gate.setVaultRegistry(vault, IIdentityRegistry(address(registry)));
        assertFalse(gate.canRedeem(alice, vault));
    }

    function test_blocked_country_blocks() public {
        registry.setVerified(alice, true);
        registry.setCountry(alice, 408); // PRK
        vm.startPrank(owner);
        gate.setVaultRegistry(vault, IIdentityRegistry(address(registry)));
        gate.setCountryBlock(vault, 408, true);
        vm.stopPrank();
        assertFalse(gate.canRedeem(alice, vault));
    }

    function test_required_topic_present_passes() public {
        MockIdentity id = new MockIdentity();
        id.setClaim(TOPIC_ACCREDITED, bytes32(uint256(0xabc)));

        registry.setVerified(alice, true);
        registry.setIdentity(alice, address(id));

        uint256[] memory topics = new uint256[](1);
        topics[0] = TOPIC_ACCREDITED;

        vm.startPrank(owner);
        gate.setVaultRegistry(vault, IIdentityRegistry(address(registry)));
        gate.setRequiredTopics(vault, topics);
        vm.stopPrank();

        assertTrue(gate.canRedeem(alice, vault));
    }

    function test_required_topic_missing_blocks() public {
        MockIdentity id = new MockIdentity();
        id.setClaim(TOPIC_KYC, bytes32(uint256(0xabc)));

        registry.setVerified(alice, true);
        registry.setIdentity(alice, address(id));

        uint256[] memory topics = new uint256[](1);
        topics[0] = TOPIC_ACCREDITED;

        vm.startPrank(owner);
        gate.setVaultRegistry(vault, IIdentityRegistry(address(registry)));
        gate.setRequiredTopics(vault, topics);
        vm.stopPrank();

        assertFalse(gate.canRedeem(alice, vault));
    }

    function test_only_owner_can_configure() public {
        vm.expectRevert();
        vm.prank(alice);
        gate.setVaultRegistry(vault, IIdentityRegistry(address(registry)));
    }
}
