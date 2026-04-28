// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@luxfi/oz/access/Ownable.sol";
import {IIdentityRegistry} from "@luxfi/erc-3643/contracts/registry/interface/IIdentityRegistry.sol";
import {IIdentity} from "@luxfi/onchain-id/contracts/interface/IIdentity.sol";

/// @title  LiquidComplianceGate
/// @notice Per-vault compliance gate for Liquid redemptions on regulated
///         collateral. **Pure delegation to ERC-3643 + ONCHAINID** — no
///         whitelist tables, no KYC levels stored locally. The Identity
///         Registry is the source of truth for "is verified", and ONCHAINID
///         claim topics encode "what kind of investor".
///
/// @dev    Per vault, configure:
///           - the `IIdentityRegistry` to query (usually one shared registry,
///             but multiple are allowed e.g. for jurisdiction-segmented vaults)
///           - the set of claim topics that must be present on the redeemer's
///             ONCHAINID (e.g. KYC, accreditation, qualified-purchaser)
///           - blocked country codes (ISO 3166-1 numeric)
///         A redeemer passes `canRedeem` iff:
///           1. the registry says they are verified;
///           2. their country is not blocked;
///           3. every required claim topic resolves to a non-empty claim set
///              on their bound ONCHAINID.
contract LiquidComplianceGate is Ownable {
    struct VaultPolicy {
        IIdentityRegistry registry;
        uint256[] requiredTopics;
        mapping(uint16 => bool) blockedCountries;
        bool configured;
    }

    mapping(address => VaultPolicy) private _policy;

    event VaultRegistrySet(address indexed vault, address indexed registry);
    event RequiredTopicsSet(address indexed vault, uint256[] topics);
    event CountryBlockSet(address indexed vault, uint16 indexed country, bool blocked);

    error VaultNotConfigured(address vault);
    error ZeroAddress();

    constructor(address owner_) Ownable(owner_) {}

    // ── Read path ───────────────────────────────────────────────────────────

    /// @notice Returns true iff `account` is allowed to redeem from `vault`
    ///         under `vault`'s configured ERC-3643 / ONCHAINID policy.
    function canRedeem(address account, address vault) external view returns (bool) {
        VaultPolicy storage p = _policy[vault];
        if (!p.configured) return false;
        if (!p.registry.isVerified(account)) return false;
        if (p.blockedCountries[p.registry.investorCountry(account)]) return false;

        uint256[] memory topics = p.requiredTopics;
        if (topics.length == 0) return true;

        IIdentity id = p.registry.identity(account);
        if (address(id) == address(0)) return false;
        for (uint256 i; i < topics.length; ++i) {
            if (id.getClaimIdsByTopic(topics[i]).length == 0) return false;
        }
        return true;
    }

    function vaultRegistry(address vault) external view returns (IIdentityRegistry) {
        return _policy[vault].registry;
    }

    function vaultRequiredTopics(address vault) external view returns (uint256[] memory) {
        return _policy[vault].requiredTopics;
    }

    function isCountryBlocked(address vault, uint16 country) external view returns (bool) {
        return _policy[vault].blockedCountries[country];
    }

    // ── Admin ───────────────────────────────────────────────────────────────

    function setVaultRegistry(address vault, IIdentityRegistry registry) external onlyOwner {
        if (vault == address(0) || address(registry) == address(0)) revert ZeroAddress();
        _policy[vault].registry = registry;
        _policy[vault].configured = true;
        emit VaultRegistrySet(vault, address(registry));
    }

    function setRequiredTopics(address vault, uint256[] calldata topics) external onlyOwner {
        if (!_policy[vault].configured) revert VaultNotConfigured(vault);
        _policy[vault].requiredTopics = topics;
        emit RequiredTopicsSet(vault, topics);
    }

    function setCountryBlock(address vault, uint16 country, bool blocked) external onlyOwner {
        if (!_policy[vault].configured) revert VaultNotConfigured(vault);
        _policy[vault].blockedCountries[country] = blocked;
        emit CountryBlockSet(vault, country, blocked);
    }
}
