// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title  LiquidComplianceGate
/// @author Lux Liquid
///
/// @notice Enforces KYC/whitelist checks before allowing redemption from
/// Liquid vaults holding regulated securities.
///
/// Deposits into Liquid are open (the alToken is a standard ERC-20).
/// Redemptions go through this gate which checks a whitelist and KYC level.
///
/// The whitelist is maintained by the regulated ATS/BD operator.
///
/// KYC levels:
///   0 = none
///   1 = basic KYC
///   2 = accredited investor (Reg D)
///   3 = qualified purchaser (Reg S / institutional)
contract LiquidComplianceGate is Ownable {
    /// @notice Whether an address is whitelisted for redemptions.
    mapping(address => bool) public whitelisted;

    /// @notice KYC level assigned to each address.
    mapping(address => uint8) public kycLevel;

    /// @notice Required KYC level per vault (vault address => level).
    /// e.g., Reg D vault = level 2, Reg A+ vault = level 1.
    mapping(address => uint8) public requiredLevel;

    /// @notice Combined authorization: vault => account => authorized.
    /// Mirrors LiquidGate pattern for direct vault-level gating.
    mapping(address => mapping(address => bool)) public authorized;

    event Approved(address indexed account, uint8 level);
    event Removed(address indexed account);
    event LevelRequired(address indexed vault, uint8 level);

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Check if an address can redeem from a specific vault.
    /// @param account The address attempting redemption.
    /// @param vault   The vault address holding the security.
    /// @return True if the account meets whitelist and KYC requirements.
    function canRedeem(address account, address vault) external view returns (bool) {
        return whitelisted[account] && kycLevel[account] >= requiredLevel[vault];
    }

    /// @notice Whitelist an address with a KYC level.
    /// @param account The address to approve.
    /// @param level   The KYC level (1=basic, 2=accredited, 3=qualified).
    function approve(address account, uint8 level) external onlyOwner {
        whitelisted[account] = true;
        kycLevel[account] = level;
        emit Approved(account, level);
    }

    /// @notice Batch approve multiple addresses at the same KYC level.
    /// @param accounts Array of addresses to approve.
    /// @param level    The KYC level to assign.
    function approveBatch(address[] calldata accounts, uint8 level) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelisted[accounts[i]] = true;
            kycLevel[accounts[i]] = level;
            emit Approved(accounts[i], level);
        }
    }

    /// @notice Remove an address from the whitelist.
    /// @param account The address to remove.
    function remove(address account) external onlyOwner {
        whitelisted[account] = false;
        kycLevel[account] = 0;
        emit Removed(account);
    }

    /// @notice Set the required KYC level for a vault.
    /// @param vault The vault address.
    /// @param level The minimum KYC level required for redemption.
    function setRequiredLevel(address vault, uint8 level) external onlyOwner {
        requiredLevel[vault] = level;
        emit LevelRequired(vault, level);
    }

    /// @notice Set direct vault-level authorization (mirrors LiquidGate).
    /// @param vault  The vault address.
    /// @param to     The account to authorize/deauthorize.
    /// @param value  True to authorize, false to deauthorize.
    function setAuthorization(address vault, address to, bool value) external onlyOwner {
        authorized[vault][to] = value;
    }
}
