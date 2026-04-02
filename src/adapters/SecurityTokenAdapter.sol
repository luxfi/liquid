// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../libraries/TokenUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ITokenAdapter.sol";

/// @title  SecurityTokenAdapter
/// @author Lux Liquid
///
/// @notice Adapter for ERC-3643 security tokens in the Liquid Protocol.
///
/// Maps regulated securities (ETFs, stocks, bonds) into Liquid vaults.
/// Yield derives from NAV appreciation and dividend distributions.
/// The underlying SecurityToken enforces compliance (whitelist) on transfers,
/// so the adapter inherits compliance automatically at wrap/unwrap boundaries.
///
/// NAV is updated by an authorized oracle. The adapter holds SecurityTokens
/// and the Liquid core treats price() as the yield signal.
contract SecurityTokenAdapter is ITokenAdapter {
    string public constant version = "1.0.0";

    address public immutable token;
    address public immutable underlyingToken;

    address public admin;

    string public ticker; // e.g. "IBIT"
    string public cusip; // e.g. "46438F101"

    uint256 public nav; // NAV per token scaled to underlying decimals
    uint256 public lastNavUpdate; // Timestamp of last NAV update

    event NAVUpdated(uint256 oldNav, uint256 newNav, uint256 timestamp);
    event AdminUpdated(address oldAdmin, address newAdmin);

    error Unauthorized();
    error ZeroAddress();
    error ZeroNav();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    /// @param _token       The ERC-3643 SecurityToken address.
    /// @param _ticker      Security ticker symbol (e.g. "IBIT").
    /// @param _cusip       CUSIP identifier (e.g. "46438F101").
    /// @param _initialNav  Initial NAV per token in underlying decimals.
    constructor(address _token, string memory _ticker, string memory _cusip, uint256 _initialNav) {
        if (_token == address(0)) revert ZeroAddress();
        if (_initialNav == 0) revert ZeroNav();

        admin = msg.sender;
        token = _token;
        underlyingToken = _token; // SecurityToken is both yield and underlying
        ticker = _ticker;
        cusip = _cusip;
        nav = _initialNav;
        lastNavUpdate = block.timestamp;
    }

    /// @notice Current price of the security token.
    /// For a NAV-tracked asset this returns the oracle-set NAV.
    function price() external view override returns (uint256) {
        return nav;
    }

    /// @notice Update NAV -- called by oracle or admin.
    /// @param _nav New NAV per token.
    function updateNAV(uint256 _nav) external onlyAdmin {
        if (_nav == 0) revert ZeroNav();
        uint256 old = nav;
        nav = _nav;
        lastNavUpdate = block.timestamp;
        emit NAVUpdated(old, _nav, block.timestamp);
    }

    /// @notice Transfer admin role.
    /// @param _admin New admin address.
    function setAdmin(address _admin) external onlyAdmin {
        if (_admin == address(0)) revert ZeroAddress();
        address old = admin;
        admin = _admin;
        emit AdminUpdated(old, _admin);
    }
}
