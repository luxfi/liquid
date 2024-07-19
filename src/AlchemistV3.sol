// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.26;

import "./interfaces/IAlchemistV3.sol";
import "./libraries/TokenUtils.sol";
import "./libraries/Limiters.sol";
import "./libraries/SafeCast.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {Unauthorized, IllegalArgument} from "./base/Errors.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
contract AlchemistV3 is IAlchemistV3, Initializable {
    using Limiters for Limiters.LinearGrowthLimiter;

    /// @notice A user account.
    struct Account {
        // A signed value which represents the current amount of debt or credit that the account has accrued.
        // Positive values indicate debt, negative values indicate credit.
        int256 debt;
        // account owner balanceof yeild token managed by this alchemist
        uint256 balance;
        // The allowances for mints.
        mapping(address => uint256) mintAllowances;
        // The allowances for withdrawals.
        mapping(address => mapping(address => uint256)) withdrawAllowances;
    }

    string public constant version = "3.0.0";

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    uint256 public constant BPS = 10_000;

    uint256 public maxLTV;

    uint256 public protocolFee;

    address public protocolFeeReceiver;

    address public whitelist;

    address public debtToken;

    address public yieldToken;

    address public admin;

    address public transmuter;

    mapping(address => Account) private _accounts;

    address public transferAdapter;

    Limiters.LinearGrowthLimiter private _mintingLimiter;

    constructor() initializer {}

    function getCDP(address owner) external view returns (uint256 depositedCollateral, int256 debt) {
        Account storage account = _accounts[owner];

        depositedCollateral = totalValue(owner);

        debt = account.debt;

        return (depositedCollateral, debt);
    }

    function getYieldToken()
        external
        view
        returns (uint256 yieldTokenAddress, uint256 underlyingTokenAddress, uint256 yieldTokenTicker, uint256 underlyingTokenTicker)
    {
        /// TODO Return actual data about the yield token in one call to avoid dependency chains in the api
        return (yieldTokenAddress, underlyingTokenAddress, yieldTokenTicker, underlyingTokenTicker);
    }

    function getLoanTerms() external view returns (uint8 LTV, uint8 underlyingTokenAddress, uint8 redemptionFee) {
        /// TODO Return actual LTV, Liquidation ratio, and redemption fee
        return (LTV, underlyingTokenAddress, redemptionFee);
    }

    function getTotalDepositedValue() external view returns (uint256 deposits) {
        /// TODO Return the total amount of yield tokens deposited in the alchemist
        return deposits;
    }

    function getTotalBorrowed() external view returns (uint256 deposits) {
        /// TODO Return the total amount of yield tokens deposited in the alchemist
        return deposits;
    }

    function getMaxBorrowable() external view returns (uint256 mexDebt) {
        /// TODO Return the maximum a user can borrow at any moment. Improves frontend UX becuase if user selects “MAX” deposit, then it will use the
        return mexDebt;
    }

    function getTotalUnderlyingValue() external view returns (uint256 TVL) {
        /// TODO Read the total value of the TVL in the alchemist, denominated in the underlying token.
        return TVL;
    }

    function totalValue(address owner) public view returns (uint256) {
        // TODO This function could be replaced by another to reflect the underlying value based on yield generated
        return _accounts[owner].balance;
    }

    function initialize(InitializationParams memory params) external initializer {
        _checkArgument(params.protocolFee <= BPS);
        debtToken = params.debtToken;
        yieldToken = params.yieldToken;
        admin = params.admin;
        transmuter = params.transmuter;
        maxLTV = params.maxLTV;
        protocolFee = params.protocolFee;
        protocolFeeReceiver = params.protocolFeeReceiver;
        whitelist = params.whitelist;
        _mintingLimiter = Limiters.createLinearGrowthLimiter(params.mintingLimitMaximum, params.mintingLimitBlocks, params.mintingLimitMinimum);
    }

    /// @inheritdoc IAlchemistV3
    function deposit(address user, uint256 collateralamount) external override returns (uint256) {
        _checkArgument(user != address(0));

        // Deposit the yield tokens to the recipient.
        _deposit(collateralamount, user);

        // Transfer tokens from the message sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, address(this), collateralamount);

        return collateralamount;
    }

    /// @inheritdoc IAlchemistV3
    function withdraw(uint256 amount) external override returns (uint256) {
        _checkArgument(msg.sender != address(0));

        // Withdraw the amount from the system.
        _withdraw(msg.sender, amount);

        // Transfer the yield tokens to the recipient.
        TokenUtils.safeTransfer(yieldToken, msg.sender, amount);

        return amount;
    }

    function _withdraw(address owner, uint256 amount) internal returns (uint256) {
        _checkArgument(_accounts[owner].balance >= amount);

        _accounts[owner].balance -= amount;

        // Valid the owner's account to assure that the collateralization invariant is still held.
        _validate(owner);

        return amount;
    }

    function _deposit(uint256 amount, address recipient) internal returns (uint256) {
        _checkArgument(amount > 0);
        _accounts[recipient].balance += amount;
        return amount;
    }

    /// @inheritdoc IAlchemistV3
    function mint(uint256 amount) external override {
        _checkArgument(amount > 0);
        // Mint tokens to msg.sender
        _mint(amount, msg.sender);
    }

    /// @inheritdoc IAlchemistV3
    function maxMint() external override returns (uint256 amount) {
        /// TODO Mints absolute maximum for the position, returns amount minted
        amount = 0;
        return amount;
    }

    /// @inheritdoc IAlchemistV3
    function redeem() external override returns (uint256 amount) {
        /// TODO Utilizes getRedemptionRate from the transmuter to know how much to redeem everyone
        return amount;
    }

    /// @inheritdoc IAlchemistV3
    function burn(uint256 amount, address recipient) external override returns (uint256) {
        // TODO Re-implement when necessary
    }

    /// @inheritdoc IAlchemistV3
    function repay(address user, uint256 amount) external override {
        // TODO repay a user’s debt by burning alAssets
    }

    /// @inheritdoc IAlchemistV3
    function liquidate(address owner) external override returns (uint256 assets, uint256 fee) {
        // TODO checks if a users debt is greater than the underlying value of their collateral + 5%.
        // If so, the users debt is zero’d out and collateral with underlying value equivalent to the debt is sent to the transmuter.
        // The remainder is sent to the liquidator.
        return (assets, fee);
    }

    /// @inheritdoc IAlchemistV3
    function setMaxLoanToValue(uint256 maxltv) external override {
        /// TODO set ltv. (a private variable or struct variable ?)
        _checkArgument(maxltv > 0 && maxltv < 1e18);
        maxLTV = maxltv;
    }

    function _checkArgument(bool expression) internal pure {
        if (!expression) {
            revert IllegalArgument();
        }
    }

    function _mint(uint256 amount, address recipient) internal {
        // Check that the system will allow for the specified amount to be minted.
        // TODO To review and add mint limit checks
        // i.e. _checkMintingLimit(uint256 amount)
        _updateDebt(recipient, SafeCast.toInt256(amount));

        // Validate the owner's account to assure that the collateralization invariant is still held.
        _validate(recipient);

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);
    }

    function _updateDebt(address owner, int256 amount) internal {
        Account storage account = _accounts[owner];
        account.debt += amount;
    }

    function _validate(address owner) internal view {
        int256 debt = _accounts[owner].debt;
        if (debt <= 0) {
            return;
        }
        uint256 collateralization = (totalValue(owner) * maxLTV) / FIXED_POINT_SCALAR;
        if (collateralization < uint256(debt)) {
            revert Undercollateralized();
        }
    }
}
