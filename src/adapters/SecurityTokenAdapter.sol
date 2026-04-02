// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../libraries/TokenUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ITokenAdapter.sol";

/// @title  SecurityTokenAdapter
/// @author Lux Liquid
///
/// @notice Adapter for ERC-3643 security tokens in the Liquid Protocol.
///
/// Handles the full lifecycle of regulated securities:
///   - NAV tracking (oracle-fed, with staleness checks)
///   - Dividend accrual and distribution
///   - Corporate actions (splits, mergers, symbol changes)
///   - Trading halts (SEC Rule 12k-1)
///   - Regulatory disclosure references
///
/// The underlying SecurityToken (ERC-3643) enforces transfer compliance.
/// This adapter adds the financial lifecycle layer on top.
contract SecurityTokenAdapter is ITokenAdapter, AccessControl, ReentrancyGuard {
    string public constant version = "2.0.0";

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    // -- Identity -----------------------------------------------------------

    address public immutable token;
    address public immutable underlyingToken;

    string public ticker;      // e.g. "IBIT"
    string public cusip;       // CUSIP: "46438F101"
    string public isin;        // ISIN: "US46438F1012"
    string public assetClass;  // "ETF", "equity", "bond", "reit"

    // -- NAV ----------------------------------------------------------------

    uint256 public nav;              // Current NAV per token (18 decimals)
    uint256 public navTimestamp;     // When NAV was last updated
    uint256 public navStalenessMax;  // Max seconds before NAV is stale (default 24h)

    // -- Dividends ----------------------------------------------------------

    /// @notice Accumulated dividends per token (scaled by 1e18).
    /// Dividends are NOT auto-distributed -- they accrue here and
    /// repay vault loans. Excess is claimable through ComplianceGate.
    uint256 public accumulatedDividendPerToken;
    uint256 public totalDividendsDistributed;

    struct DividendRecord {
        uint256 amount;         // Total dividend amount
        uint256 perToken;       // Per-token amount at time of distribution
        uint256 exDate;         // Ex-dividend date
        uint256 payDate;        // Payment date
        uint256 recordDate;     // Record date
        string  description;    // "Q1 2026 Distribution" etc.
    }
    DividendRecord[] public dividendHistory;

    // -- Corporate Actions --------------------------------------------------

    enum ActionType { SPLIT, REVERSE_SPLIT, MERGER, SPINOFF, SYMBOL_CHANGE, DELISTING }

    struct CorporateAction {
        ActionType actionType;
        uint256 timestamp;
        uint256 ratio;          // For splits: numerator (e.g. 2 for 2:1 split)
        uint256 ratioDenom;     // For splits: denominator (e.g. 1 for 2:1 split)
        string  description;
        bool    executed;
    }
    CorporateAction[] public corporateActions;

    // -- Regulatory ---------------------------------------------------------

    bool public halted;         // SEC trading halt active

    struct Disclosure {
        string  filingType;     // "10-K", "8-K", "S-1", "prospectus"
        string  uri;            // IPFS or HTTPS link to filing
        uint256 filedAt;
    }
    Disclosure[] public disclosures;

    // -- Events -------------------------------------------------------------

    event NAVUpdated(uint256 oldNav, uint256 newNav, uint256 timestamp);
    event DividendDeclared(uint256 indexed index, uint256 amount, uint256 perToken, uint256 exDate);
    event CorporateActionDeclared(uint256 indexed index, ActionType actionType, string description);
    event CorporateActionExecuted(uint256 indexed index);
    event TradingHalted(string reason);
    event TradingResumed();
    event DisclosureFiled(string filingType, string uri);

    // -- Errors -------------------------------------------------------------

    error Halted();
    error StaleNAV();
    error ZeroAmount();

    constructor(
        address _token,
        string memory _ticker,
        string memory _cusip,
        string memory _isin,
        string memory _assetClass,
        uint256 _initialNav
    ) {
        require(_token != address(0) && _initialNav > 0);
        token = _token;
        underlyingToken = _token;
        ticker = _ticker;
        cusip = _cusip;
        isin = _isin;
        assetClass = _assetClass;
        nav = _initialNav;
        navTimestamp = block.timestamp;
        navStalenessMax = 86_400; // 24 hours
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
    }

    // -- ITokenAdapter ------------------------------------------------------

    function price() external view override returns (uint256) {
        if (halted) revert Halted();
        if (block.timestamp > navTimestamp + navStalenessMax) revert StaleNAV();
        return nav;
    }

    // -- NAV ----------------------------------------------------------------

    function updateNAV(uint256 _nav) external onlyRole(ORACLE_ROLE) {
        require(_nav > 0);
        uint256 old = nav;
        nav = _nav;
        navTimestamp = block.timestamp;
        emit NAVUpdated(old, _nav, block.timestamp);
    }

    function setNavStalenessMax(uint256 _seconds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        navStalenessMax = _seconds;
    }

    function isNavStale() external view returns (bool) {
        return block.timestamp > navTimestamp + navStalenessMax;
    }

    // -- Dividends ----------------------------------------------------------

    /// @notice Declare a dividend. Called by the compliance/admin role
    ///         when the underlying security pays a distribution.
    ///         The dividend amount is used by the Liquid core to repay
    ///         vault loans. Excess accrues for KYC'd claim.
    function declareDividend(
        uint256 amount,
        uint256 exDate,
        uint256 payDate,
        uint256 recordDate,
        string calldata description
    ) external onlyRole(COMPLIANCE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        uint256 supply = IERC20(token).totalSupply();
        uint256 perToken = supply > 0 ? (amount * 1e18) / supply : 0;
        accumulatedDividendPerToken += perToken;
        totalDividendsDistributed += amount;
        dividendHistory.push(DividendRecord({
            amount: amount,
            perToken: perToken,
            exDate: exDate,
            payDate: payDate,
            recordDate: recordDate,
            description: description
        }));
        emit DividendDeclared(dividendHistory.length - 1, amount, perToken, exDate);
    }

    function dividendCount() external view returns (uint256) {
        return dividendHistory.length;
    }

    // -- Corporate Actions --------------------------------------------------

    function declareCorporateAction(
        ActionType actionType,
        uint256 ratio,
        uint256 ratioDenom,
        string calldata description
    ) external onlyRole(COMPLIANCE_ROLE) {
        corporateActions.push(CorporateAction({
            actionType: actionType,
            timestamp: block.timestamp,
            ratio: ratio,
            ratioDenom: ratioDenom,
            description: description,
            executed: false
        }));
        emit CorporateActionDeclared(corporateActions.length - 1, actionType, description);
    }

    function executeCorporateAction(uint256 index) external onlyRole(COMPLIANCE_ROLE) {
        CorporateAction storage action = corporateActions[index];
        require(!action.executed, "already executed");
        action.executed = true;

        // For splits/reverse splits, adjust NAV proportionally
        if (action.actionType == ActionType.SPLIT) {
            nav = (nav * action.ratioDenom) / action.ratio;
        } else if (action.actionType == ActionType.REVERSE_SPLIT) {
            nav = (nav * action.ratio) / action.ratioDenom;
        }
        navTimestamp = block.timestamp;
        emit CorporateActionExecuted(index);
    }

    function corporateActionCount() external view returns (uint256) {
        return corporateActions.length;
    }

    // -- Trading Halt -------------------------------------------------------

    function halt(string calldata reason) external onlyRole(COMPLIANCE_ROLE) {
        halted = true;
        emit TradingHalted(reason);
    }

    function resume() external onlyRole(COMPLIANCE_ROLE) {
        halted = false;
        emit TradingResumed();
    }

    // -- Disclosures --------------------------------------------------------

    function fileDisclosure(
        string calldata filingType,
        string calldata uri
    ) external onlyRole(COMPLIANCE_ROLE) {
        disclosures.push(Disclosure({
            filingType: filingType,
            uri: uri,
            filedAt: block.timestamp
        }));
        emit DisclosureFiled(filingType, uri);
    }

    function disclosureCount() external view returns (uint256) {
        return disclosures.length;
    }
}
