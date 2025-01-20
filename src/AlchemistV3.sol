// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./interfaces/IAlchemistV3.sol";
import "./interfaces/ITokenAdapter.sol";
import "./interfaces/ITransmuter.sol";

import "./libraries/TokenUtils.sol";
import "./libraries/Limiters.sol";
import "./libraries/SafeCast.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

import {Unauthorized, IllegalArgument, IllegalState, InsufficientAllowance} from "./base/Errors.sol";

// TODO: Potentially switch from proprietary librariies
// TODO: Set fees
// TODO: Add sentinels
// TODO: Add vault caps here

/// @title  AlchemistV3
/// @author Alchemix Finance
contract AlchemistV3 is IAlchemistV3, Initializable {
    using Limiters for Limiters.LinearGrowthLimiter;

    /// @inheritdoc IAlchemistV3Immutables
    string public constant version = "3.0.0";

    uint256 public constant BPS = 10_000;

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    /// @inheritdoc IAlchemistV3Immutables
    address public debtToken;

    /// @inheritdoc IAlchemistV3State
    uint256 public cumulativeEarmarked;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastEarmarkBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public minimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalDebt;

    /// @inheritdoc IAlchemistV3State
    uint256 public protocolFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public underlyingDecimals;

    /// @inheritdoc IAlchemistV3State
    uint256 public underlyingConversionFactor;

    /// @inheritdoc IAlchemistV3State
    address public protocolFeeReceiver;

    /// @inheritdoc IAlchemistV3State
    address public underlyingToken;
    
    /// @inheritdoc IAlchemistV3State
    address public yieldToken;
    
    /// @inheritdoc IAlchemistV3State
    address public admin;

    /// @inheritdoc IAlchemistV3State
    address public transmuter;

    /// @inheritdoc IAlchemistV3State
    address public pendingAdmin;

    uint256 private _earmarkWeight;

    uint256 private _redemptionWeight;

    mapping(address => Account) private _accounts;

    Limiters.LinearGrowthLimiter private _mintingLimiter;

    modifier onlyAdmin() {
        _checkArgument(msg.sender == admin);
        _;
    }

    modifier onlyTransmuter() {
        _checkArgument(msg.sender == transmuter);
        _;
    }

    constructor() initializer {}

    function initialize(InitializationParams memory params) external initializer {
        _checkArgument(params.protocolFee <= BPS);
        debtToken = params.debtToken;
        underlyingToken = params.underlyingToken;
        underlyingDecimals = TokenUtils.expectDecimals(params.underlyingToken);
        underlyingConversionFactor = 10**(TokenUtils.expectDecimals(params.debtToken) - TokenUtils.expectDecimals(params.underlyingToken));
        yieldToken = params.yieldToken;
        minimumCollateralization = params.minimumCollateralization;
        admin = params.admin;
        transmuter = params.transmuter;
        protocolFee = params.protocolFee;
        protocolFeeReceiver = params.protocolFeeReceiver;
        lastEarmarkBlock = block.number;
        _mintingLimiter = Limiters.createLinearGrowthLimiter(params.mintingLimitMaximum, params.mintingLimitBlocks, params.mintingLimitMinimum);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setPendingAdmin(address value) external onlyAdmin {
        pendingAdmin = value;

        emit PendingAdminUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function acceptAdmin() external {
        _checkState(pendingAdmin != address(0));

        if (msg.sender != pendingAdmin) {
            revert Unauthorized();
        }

        admin = pendingAdmin;
        pendingAdmin = address(0);

        emit AdminUpdated(admin);
        emit PendingAdminUpdated(address(0));
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFeeReceiver(address value) external onlyAdmin {
        _checkArgument(value != address(0));
        protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setTransmuter(address value) external onlyAdmin {
        _checkArgument(value != address(0));
        transmuter = value;
        emit TransmuterUpdated(value);
    }

    /// @inheritdoc IAlchemistV3State
    function getMintLimitInfo()
        external view
        returns (
            uint256 currentLimit,
            uint256 rate,
            uint256 maximum
        )
    {
        return (
            _mintingLimiter.get(),
            _mintingLimiter.rate,
            _mintingLimiter.maximum
        );
    }

    /// @inheritdoc IAlchemistV3State
    function getCDP(address owner) external view returns (uint256, uint256) {
        return (_accounts[owner].collateralBalance, _calculateUnrealizedDebt(owner));
    }

    // function getLoanTerms(address user) external view returns (uint256 LTV, uint256 liquidationRatio, uint256 redemptionFee) {
    //     /// TODO Return actual LTV, Liquidation ratio, and redemption fee
    //     return (LTV, liquidationRatio, redemptionFee);
    // }

    /// @inheritdoc IAlchemistV3State
    function getTotalDeposited() external view returns (uint256) {
        return IERC20(yieldToken).balanceOf(address(this));
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxBorrowable(address user) external view returns (uint256 maxDebt) {
        /// TODO Return the maximum a user can borrow at any moment. Improves frontend UX becuase if user selects “MAX” deposit, then it will use the
    }

    /// @inheritdoc IAlchemistV3State
    function mintAllowance(address owner, address spender)
        external view
        returns (uint256)
    {
        Account storage account = _accounts[owner];
        return account.mintAllowances[spender];
    }

    function getTotalUnderlyingValue() external view returns (uint256 TVL) {
        /// TODO Read the total value of the TVL in the alchemist, denominated in the underlying token.
        uint256 yieldTokenTVL = IERC20(yieldToken).balanceOf(address(this));
        uint256 yieldTokenTVLInUnderlying = convertYieldTokensToUnderlying(yieldTokenTVL);
        TVL = yieldTokenTVLInUnderlying;
    }

    function totalValue(address owner) public view returns (uint256) {
        uint256 totalUnderlying;
        uint256 bal = _accounts[owner].collateralBalance;
        if(bal > 0) totalUnderlying += convertYieldTokensToUnderlying(bal);

        return normalizeUnderlyingTokensToDebt(totalUnderlying);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setMinimumCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value < 1e18);
        minimumCollateralization = value;

        emit MinimumCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3Actions
    function deposit(uint256 amount, address recipient) external returns (uint256) {
        _checkArgument(recipient != address(0));
        _checkArgument(amount > 0);

        _accounts[recipient].collateralBalance += amount;

        // Transfer tokens from msg.sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, address(this), amount);

        emit Deposit(amount, recipient);

        return convertYieldTokensToDebt(amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function withdraw(uint256 amount, address recipient) external returns (uint256) {
        _checkArgument(msg.sender != address(0));
        // TODO potentially remove next check, underflow protection will naturally check
        _checkArgument(_accounts[msg.sender].collateralBalance >= amount);

        _accounts[msg.sender].collateralBalance -= amount;

        // Assure that the collateralization invariant is still held.
        _validate(msg.sender);

        // Transfer the yield tokens to msg.sender
        TokenUtils.safeTransfer(yieldToken, recipient, amount);
        
        emit Withdraw(amount, recipient);

        return amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function mint(uint256 amount, address recipient) external {
        _checkArgument(msg.sender != address(0));
        _checkArgument(amount > 0);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(msg.sender);

        // Validate that user is not breaking LTV constraints
        _validate(msg.sender);

        // Mint tokens to self
        _mint(msg.sender, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function mintFrom(address owner, uint256 amount, address recipient) external {
        _checkArgument(amount > 0);
        _checkArgument(recipient != address(0));

        // Preemptively decrease the minting allowance, saving gas when the allowance is insufficient
        _accounts[owner].mintAllowances[msg.sender] -= amount;

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(owner);

        // Validate that user is not breaking LTV constraints
        _validate(owner);

        // Mint tokens from the owner's account to the recipient.
        _mint(owner, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function burn(uint256 amount, address recipient) external returns (uint256) {
        _checkArgument(amount > 0);
        _checkArgument(recipient != address(0));

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(recipient);

        uint256 debt;
        _checkState((debt = _accounts[recipient].debt) > 0);

        uint256 credit = amount > debt ? debt : amount;

        // Burn the tokens from the message sender.
        TokenUtils.safeBurnFrom(debtToken, msg.sender, credit);

        // Update the recipient's debt.
        _updateDebt(recipient, credit);

        // Increase the global amount of mintable debt tokens.
        _mintingLimiter.increase(amount);

        emit Burn(msg.sender, credit, recipient);

        return credit;
    }

    /// @inheritdoc IAlchemistV3Actions
    function repay(uint256 amount, address recipient) external returns (uint256) {
        _checkArgument(amount > 0);
        _checkArgument(recipient != address(0));

        Account storage account = _accounts[recipient];

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before deciding how much is available to be repaid
        _sync(recipient);

        // TODO: Clean this up
        uint256 maximumEarmarkPayment = normalizeDebtTokensToUnderlying(account.earmarked);

        uint256 actualEarmarkPayment = amount > maximumEarmarkPayment ? maximumEarmarkPayment : amount;

        account.earmarked -= normalizeUnderlyingTokensToDebt(actualEarmarkPayment);

        uint256 maxCredit;

        uint256 actualCredit;

        if (account.debt > 0) {
            maxCredit = normalizeDebtTokensToUnderlying(account.debt);

            actualCredit = (amount - actualEarmarkPayment)  > maxCredit ? maxCredit : (amount - actualEarmarkPayment);

            _updateDebt(recipient, normalizeUnderlyingTokensToDebt(actualCredit));
        }

        // Transfer the repaid tokens to the transmuter.
        TokenUtils.safeTransferFrom(underlyingToken, msg.sender, transmuter, actualEarmarkPayment + actualCredit);

        emit Repay(msg.sender, amount, recipient, actualEarmarkPayment + actualCredit);

        return actualEarmarkPayment + actualCredit;
    }

    /// @inheritdoc IAlchemistV3Actions
    function liquidate(address owner) external returns (uint256 assets, uint256 fee) {
        // TODO checks if a users debt is greater than the underlying value of their collateral.
        // If so, the users debt is zero’d out and collateral with underlying value equivalent to the debt is sent to the transmuter.
        // The remainder is sent to the liquidator.
        // In a multi-yield token model, this will also need to determine which assets to liquidate

        uint256 debt = _accounts[owner].debt;

        if (debt <= 0) {
            revert LiquidationError();
        }

        // not using _isUnderCollateralized to avoid looping through balances twice
        uint256 collateral = totalValue(owner);

        // Sync current user debt before liquidation
        _sync(msg.sender);

        //TODO using placeholder LTV, needs to be updated for multi-yield token
        if ((collateral * minimumCollateralization) / FIXED_POINT_SCALAR < debt) {
            // Liquidator fee i.e. yield token price of underlying - debt owed
            if (collateral > debt) {
                fee = collateral - debt;
            }

            // zero out the liquidated users debt
            _accounts[owner].debt = 0;

            // TODO need to rework the rest of the function, commenting out the rest for now
            // * needs to take into account multiple yield tokens
            // * needs to be able to partially liquidate

            // zero out the liquidated users collateral
            // _accounts[owner].balance = 0;

            // TODO what happens to surplus

            if (fee > 0) {
                // TODO fix next line (placeholder using first token in array)
                // need to determine how fee token gets picked
                TokenUtils.safeTransfer(yieldToken, msg.sender, fee);
            }

            emit Liquidate(owner, assets);

            return (assets, fee);
        } else {
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function redeem(uint256 amount) external onlyTransmuter() {
        _redemptionWeight += amount * FIXED_POINT_SCALAR / cumulativeEarmarked;
        cumulativeEarmarked -= amount;

        uint256 yieldToUnwrap = amount * TokenUtils.expectDecimals(underlyingToken) / ITokenAdapter(yieldToken).price();

        ITokenAdapter(yieldToken).unwrap(yieldToUnwrap, address(this));

        TokenUtils.safeTransfer(underlyingToken, transmuter, amount);

        emit Redeem(amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function poke(address owner) external {
        _sync(owner);
    }

    /// @inheritdoc IAlchemistV3Actions
    function approveMint(address spender, uint256 amount) external {
        _approveMint(msg.sender, spender, amount);
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToDebt(uint256 amount) public view returns (uint256) {
        return normalizeUnderlyingTokensToDebt(convertYieldTokensToUnderlying(amount));
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToUnderlying(uint256 amount) public view returns (uint256) {
        uint8 decimals = TokenUtils.expectDecimals(yieldToken);
        return (amount * ITokenAdapter(yieldToken).price()) / 10 ** decimals;
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeUnderlyingTokensToDebt(uint256 amount) public view returns (uint256) {
        return amount * underlyingConversionFactor;
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeDebtTokensToUnderlying(uint256 amount) public view returns (uint256) {
        return amount / underlyingConversionFactor;
    }

    /// @dev Mints debt tokens to `recipient` using the account owned by `owner`.
    /// @param owner     The owner of the account to mint from.
    /// @param amount    The amount to mint.
    /// @param recipient The recipient of the minted debt tokens.
    function _mint(address owner, uint256 amount, address recipient) internal {
        // Check that the system will allow for the specified amount to be minted.
        // TODO To review and add mint limit checks
        // i.e. _checkMintingLimit(uint256 amount)
        _updateDebt(recipient, amount);

        // Validate the owner's account to assure that the collateralization invariant is still held.
        _validate(owner);

        // Decrease the global amount of mintable debt tokens.
        _mintingLimiter.decrease(amount);

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);

        emit Mint(owner, amount, recipient);
    }

    /// @dev Increases the debt by `amount` for the account owned by `owner`.
    /// @param owner   The address of the account owner.
    /// @param amount  The amount to increase the debt by.
    function _updateDebt(address owner, uint256 amount) internal {
        Account storage account = _accounts[owner];
        account.debt += amount;
        totalDebt += amount;
    }

    /// @dev Set the mint allowance for `spender` to `amount` for the account owned by `owner`.
    /// @param owner   The address of the account owner.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to set the mint allowance to.
    function _approveMint(address owner, address spender, uint256 amount) internal {
        Account storage account = _accounts[owner];
        account.mintAllowances[spender] = amount;
    }

    /// @dev Checks an expression and reverts with an {IllegalArgument} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkArgument(bool expression) internal pure {
        if (!expression) {
            revert IllegalArgument();
        }
    }

    /// @dev Checks an expression and reverts with an {IllegalState} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkState(bool expression) internal pure {
        if (!expression) {
            revert IllegalState();
        }
    }

    /// @dev Checks that the account owned by `owner` is properly collateralized.
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    /// @param owner The address of the account owner.
    function _validate(address owner) internal view {
        if (_isUnderCollateralized(owner)) revert Undercollateralized();
    }

    /// @dev Update the user's earmarked and redeemed debt amounts.
    function _sync(address owner) internal {
        Account storage account = _accounts[owner];

        // Earmark User Debt
        uint256 debtToEarmark = account.debt * (_earmarkWeight - account.lastAccruedEarmarkWeight);
        account.debt -= debtToEarmark;
        account.lastAccruedEarmarkWeight = _earmarkWeight;
        account.earmarked += debtToEarmark;

        // Calculate how much of user earmarked amount has been redeemed and subtract it
        uint256 earmarkToRedeem = account.earmarked * (_redemptionWeight - account.lastAccruedRedemptionWeight);
        account.earmarked -= earmarkToRedeem;
        account.lastAccruedRedemptionWeight = _redemptionWeight;
    }

    function _earmark() internal {
        if(block.number > lastEarmarkBlock) {
            uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);
            cumulativeEarmarked += amount;
            _earmarkWeight += amount * FIXED_POINT_SCALAR / totalDebt;
            lastEarmarkBlock = block.number;
            totalDebt -= amount;
        }
    }

    /// @dev Gets the amount of debt that the account owned by `owner` will have after an sync occurs.
    ///
    /// @param owner The address of the account owner.
    ///
    /// @return The amount of debt that the account owned by `owner` will have after an update.    
    function _calculateUnrealizedDebt(address owner) internal view returns (uint256) {
            Account storage account = _accounts[owner];

            uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);
            uint256 earmarkWeightCopy = _earmarkWeight + (amount * FIXED_POINT_SCALAR / totalDebt);
            uint256 debtToEarmark = account.debt * (earmarkWeightCopy - account.lastAccruedEarmarkWeight) / FIXED_POINT_SCALAR;

            return account.debt - debtToEarmark;
    }

    /// @dev Checks that the account owned by `owner` is properly collateralized.
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    /// @param owner The address of the account owner.
    function _isUnderCollateralized(address owner) internal view returns (bool) {
        uint256 debt = _accounts[owner].debt;
        if (debt == 0) return false;

        uint256 collateralization = totalValue(owner) * FIXED_POINT_SCALAR / debt;
        if (collateralization < minimumCollateralization) {
            return true;
        }
        return false;
    }
}
