// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./interfaces/IAlchemistV3.sol";
import "./interfaces/ITokenAdapter.sol";
import "./interfaces/ITransmuter.sol";

import "./libraries/TokenUtils.sol";
import "./libraries/Limiters.sol";
import "./libraries/SafeCast.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";

import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "./base/Errors.sol";

import {console} from "../../lib/forge-std/src/console.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
contract AlchemistV3 is IAlchemistV3, Initializable {
    using Limiters for Limiters.LinearGrowthLimiter;

    /// @inheritdoc IAlchemistV3Immutables
    string public constant version = "3.0.0";

    uint256 public constant BPS = 10_000;

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    // Scaling factor to preserve precission with weighting
    uint256 public constant WEIGHT_SCALING_FACTOR = 1e36;

    /// @inheritdoc IAlchemistV3State
    address public admin;

    /// @inheritdoc IAlchemistV3Immutables
    address public debtToken;

    /// @inheritdoc IAlchemistV3State
    uint8 public underlyingDecimals;

    /// @inheritdoc IAlchemistV3State
    uint256 public underlyingConversionFactor;

    /// @inheritdoc IAlchemistV3State
    uint256 public blocksPerYear;

    /// @inheritdoc IAlchemistV3State
    uint256 public cumulativeEarmarked;

    /// @inheritdoc IAlchemistV3State
    uint256 public depositCap;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastEarmarkBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public lastRedemptionBlock;

    /// @inheritdoc IAlchemistV3State
    uint256 public minimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public collateralizationLowerBound;
    
    /// @inheritdoc IAlchemistV3State
    uint256 public globalMinimumCollateralization;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalDebt;

    /// @inheritdoc IAlchemistV3State
    uint256 public protocolFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public liquidatorFee;

    /// @inheritdoc IAlchemistV3State
    address public protocolFeeReceiver;

    /// @inheritdoc IAlchemistV3State
    address public underlyingToken;
    
    /// @inheritdoc IAlchemistV3State
    address public yieldToken;

    /// @inheritdoc IAlchemistV3State
    address public tokenAdapter;

    /// @inheritdoc IAlchemistV3State
    address public transmuter;

    /// @inheritdoc IAlchemistV3State
    address public pendingAdmin;

    /// @inheritdoc IAlchemistV3State
    bool public depositsPaused;

    /// @inheritdoc IAlchemistV3State
    bool public loansPaused;

    /// @inheritdoc IAlchemistV3State
    mapping(address => bool) public gaurdians;

    uint256 private _feeWeight;

    uint256 private _earmarkWeight;

    uint256 private _redemptionWeight;

    mapping(address => Account) private _accounts;
    
    mapping(uint256 => RedemptionInfo) private _redemptions;

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyAdminOrGaurdian() {
        if (msg.sender != admin && !gaurdians[msg.sender]) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyTransmuter() {
        if (msg.sender != transmuter) {
            revert Unauthorized();
        }
        _;
    }

    constructor() initializer {}

    function initialize(InitializationParams memory params) external initializer {
        _checkArgument(params.protocolFee <= BPS);
        _checkArgument(params.liquidatorFee <= BPS);

        debtToken = params.debtToken;
        underlyingToken = params.underlyingToken;
        underlyingDecimals = TokenUtils.expectDecimals(params.underlyingToken);
        underlyingConversionFactor = 10**(TokenUtils.expectDecimals(params.debtToken) - TokenUtils.expectDecimals(params.underlyingToken));
        yieldToken = params.yieldToken;
        depositCap = params.depositCap;
        blocksPerYear = params.blocksPerYear;
        minimumCollateralization = params.minimumCollateralization;
        globalMinimumCollateralization = params.globalMinimumCollateralization;
        collateralizationLowerBound = params.collateralizationLowerBound;
        admin = params.admin;
        tokenAdapter = params.tokenAdapter;
        transmuter = params.transmuter;
        protocolFee = params.protocolFee;
        protocolFeeReceiver = params.protocolFeeReceiver;
        liquidatorFee = params.liquidatorFee;
        lastEarmarkBlock = block.number;
        lastRedemptionBlock = block.number;
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
    function setDepositCap(uint256 value) external onlyAdmin {
        _checkArgument(value >= IERC20(yieldToken).balanceOf(address(this)));

        depositCap = value;
        emit DepositCapUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFeeReceiver(address value) external onlyAdmin {
        _checkArgument(value != address(0));

        protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setProtocolFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        protocolFee = fee;
        emit ProtocolFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setLiquidatorFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        liquidatorFee = fee;
        emit LiquidatorFeeUpdated(fee);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setTokenAdapter(address value) external onlyAdmin() {
        _checkArgument(value != address(0));

        tokenAdapter = value;
        emit TokenAdapterUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setTransmuter(address value) external onlyAdmin {
        _checkArgument(value != address(0));
        transmuter = value;
        emit TransmuterUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGaurdian(address gaurdian, bool isActive) external onlyAdmin {
        _checkArgument(gaurdian != address(0));

        gaurdians[gaurdian] = isActive;
        emit GaurdianSet(gaurdian, isActive);
    }
    
    /// @inheritdoc IAlchemistV3AdminActions
    function setMinimumCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value >= 1e18);
        minimumCollateralization = value;

        emit MinimumCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGlobalMinimumCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value >= minimumCollateralization);
        globalMinimumCollateralization = value;
        emit GlobalMinimumCollateralizationUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setCollateralizationLowerBound(uint256 value) external onlyAdmin {
        _checkArgument(value <= minimumCollateralization);
        _checkArgument(value >= 1e18);
        collateralizationLowerBound = value;
        emit CollateralizationLowerBoundUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseDeposits(bool isPaused) external onlyAdminOrGaurdian {
        depositsPaused = isPaused;
        emit DepositsPaused(isPaused);
    }
    
    /// @inheritdoc IAlchemistV3AdminActions
    function pauseLoans(bool isPaused) external onlyAdminOrGaurdian {
        loansPaused = isPaused;
        emit LoansPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3State
    function getCDP(address owner) external view returns (uint256, uint256, uint256) {
        (uint256 debt, uint256 earmarked, uint256 collateral) = _calculateUnrealizedDebt(owner);
        return (collateral, debt, earmarked);
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalDeposited() external view returns (uint256) {
        return IERC20(yieldToken).balanceOf(address(this));
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxBorrowable(address owner) external view returns (uint256) {
        (uint256 debt, uint256 earmarked, uint256 collateral) = _calculateUnrealizedDebt(owner);
        uint256 debtValueOfCollateral = convertYieldTokensToDebt(collateral);

        return (debtValueOfCollateral * FIXED_POINT_SCALAR / minimumCollateralization) - debt;
    }

    /// @inheritdoc IAlchemistV3State
    function mintAllowance(address owner, address spender)
        external view
        returns (uint256)
    {
        Account storage account = _accounts[owner];
        return account.mintAllowances[spender];
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalUnderlyingValue() external view returns (uint256) {
        return  _getTotalUnderlyingValue();
    }

    /// @inheritdoc IAlchemistV3State
    function totalValue(address owner) public view returns (uint256) {
        uint256 totalUnderlying;
        (uint256 debt, uint256 earmarked, uint256 collateral) = _calculateUnrealizedDebt(owner);

        if(collateral > 0) totalUnderlying += convertYieldTokensToUnderlying(collateral);

        return normalizeUnderlyingTokensToDebt(totalUnderlying);
    }

    /// @inheritdoc IAlchemistV3Actions
    function deposit(uint256 amount, address recipient) external returns (uint256) {
        _checkArgument(recipient != address(0));
        _checkArgument(amount > 0);
        _checkState(depositsPaused == false);
        _checkState(IERC20(yieldToken).balanceOf(address(this)) + amount <= depositCap);

        _accounts[recipient].collateralBalance += amount;

        // Transfer tokens from msg.sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, address(this), amount);

        emit Deposit(amount, recipient);

        return convertYieldTokensToDebt(amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function withdraw(uint256 amount, address recipient) external returns (uint256) {
        _checkArgument(msg.sender != address(0));
        _checkArgument(amount > 0);

        _earmark();

        _sync(msg.sender);

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
        _checkState(loansPaused == false);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(msg.sender);

        // Mint tokens to recipient
        _mint(msg.sender, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function mintFrom(address owner, uint256 amount, address recipient) external {
        _checkArgument(amount > 0);
        _checkArgument(recipient != address(0));
        _checkState(loansPaused == false);

        // Preemptively try and decrease the minting allowance. This will save gas when the allowance is not sufficient.
        _decreaseMintAllowance(owner, msg.sender, amount);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(owner);

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
        // Burning alAssets can only repay unearmarked debt
        _checkState((debt = _accounts[recipient].debt - _accounts[recipient].earmarked) > 0);

        uint256 credit = amount > debt ? debt : amount;

        // Burn the tokens from the message sender
        TokenUtils.safeBurnFrom(debtToken, msg.sender, credit);

        // Update the recipient's debt.
        _subDebt(recipient, credit);

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

        uint256 debt;

        // Burning yieldTokens will pay off all types of debt
        _checkState((debt = account.debt) > 0);

        uint256 yieldToDebt = convertYieldTokensToDebt(amount);
        uint256 credit = yieldToDebt > debt ? debt : yieldToDebt;
        uint256 creditToYield = convertDebtTokensToYield(credit);

        // Transfer the repaid tokens to the transmuter.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, transmuter, creditToYield);

        _subDebt(recipient, credit);

        // Repay debt from earmarked amount of debt first
        account.earmarked -= credit > account.earmarked ? account.earmarked : credit;

        emit Repay(msg.sender, amount, recipient, creditToYield);

        return creditToYield;
    }

    /// @inheritdoc IAlchemistV3Actions
    function liquidate(address owner) external override returns (uint256 underlyingAmount, uint256 fee) {
        _earmark();

        (underlyingAmount, fee) = _liquidate(owner);
        if (underlyingAmount > 0) {
            emit Liquidated(owner, msg.sender, underlyingAmount, fee);
            return (underlyingAmount, fee);
        } else {
            // no liquidation amount returned, so no liquidation happened
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function batchLiquidate(address[] memory owners) external returns (uint256 totalAmountLiquidated, uint256 totalFees) {
        _earmark();

        if (owners.length == 0) {
            revert MissingInputData();
        }

        for (uint256 i = 0; i < owners.length; i++) {
            address owner = owners[i];
            (uint256 underlyingAmount, uint256 fee) = _liquidate(owner);
            totalAmountLiquidated += underlyingAmount;
            totalFees += fee;
        }

        if (totalAmountLiquidated > 0) {
            emit BatchLiquidated(owners, msg.sender, totalAmountLiquidated, totalFees);
            return (totalAmountLiquidated, totalFees);
        } else {
            // no total liquidation amount returned, so no liquidations happened
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function redeem(uint256 amount) external onlyTransmuter() {
        _earmark();

        _redemptionWeight += amount * WEIGHT_SCALING_FACTOR / cumulativeEarmarked;

        cumulativeEarmarked -= amount;
        totalDebt -= amount;

        lastRedemptionBlock = block.number;

        _redemptions[block.number] = RedemptionInfo(
                cumulativeEarmarked,
                totalDebt,
                _earmarkWeight,
                _feeWeight
            );

        uint256 collateralToRedeem = convertDebtTokensToYield(amount);
        TokenUtils.safeTransfer(yieldToken, transmuter, collateralToRedeem);

        emit Redemption(amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function poke(address owner) external {
        _earmark();

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
    function convertDebtTokensToYield(uint256 amount) public view returns (uint256) {
        return convertUnderlyingTokensToYield(normalizeDebtTokensToUnderlying(amount));
    }

    /// @inheritdoc IAlchemistV3State
    function convertYieldTokensToUnderlying(uint256 amount) public view returns (uint256) {
        uint8 decimals = TokenUtils.expectDecimals(yieldToken);
        return (amount * ITokenAdapter(tokenAdapter).price()) / 10**decimals;
    }

    /// @inheritdoc IAlchemistV3State
    function convertUnderlyingTokensToYield(uint256 amount) public view returns (uint256) {
        uint8 decimals = TokenUtils.expectDecimals(yieldToken);
        return amount * 10**decimals / ITokenAdapter(tokenAdapter).price();
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
        _addDebt(owner, amount);

        // Validate the owner's account to assure that the collateralization invariant is still held.
        _validate(owner);

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);

        emit Mint(owner, amount, recipient);
    }

    /// @dev Fetches and applies the liquidation amount to account `owner` if the account collateral ratio touches `collateralizationLowerBound`.
    /// @param owner  The owner of the account to to liquidate.
    /// @return debtAmount  The liquidation amount removed from the account `owner`.
    /// @return fee The additional fee as a % of the liquidation amount to be sent to the liquidator
    function _liquidate(address owner) internal returns (uint256 debtAmount, uint256 fee) {
        // Get updated earmarking data and sync current user debt before liquidation
        // If a redemption gets triggered before this liquidation call in the block then the users account may fall back into the healthy range
        _sync(owner);

        Account storage account = _accounts[owner];

        uint256 debt = account.debt;
        if (debt == 0) {
            return (0, 0);
        }

        // owner collateral denominated in underlying value
        uint256 collateralInDebt = totalValue(owner);
        uint256 collateralizationRatio;

        collateralizationRatio = collateralInDebt * FIXED_POINT_SCALAR / debt;
        if (collateralizationRatio <= collateralizationLowerBound) {
            uint256 globalCollateralizationRatio = normalizeUnderlyingTokensToDebt(_getTotalUnderlyingValue()) * FIXED_POINT_SCALAR / totalDebt;
            // amount is always <= debt
            uint256 liquidationAmount = _getLiquidationAmount(collateralInDebt, debt, globalCollateralizationRatio);
            uint256 feeInDebt = liquidationAmount * liquidatorFee / BPS;
            uint256 remainingCollateral = collateralInDebt >= liquidationAmount ? collateralInDebt - liquidationAmount : 0;

            if (feeInDebt >= remainingCollateral) {
                feeInDebt = remainingCollateral;
            }

            collateralInDebt = collateralInDebt >= liquidationAmount ? collateralInDebt - (liquidationAmount + feeInDebt) : 0;
            debtAmount = liquidationAmount + feeInDebt;
            uint256 adjustedLiquidationAmount = convertDebtTokensToYield(liquidationAmount);
            fee = convertDebtTokensToYield(feeInDebt);

            // send liquidation amount - any fee to the transmuter. the transmuter only accepts yield tokens
            TokenUtils.safeTransfer(yieldToken, transmuter, adjustedLiquidationAmount);

            // Update users debt
            _subDebt(owner, liquidationAmount);

            // Liquidate debt from earmarked amount of debt first
            account.earmarked -= liquidationAmount > account.earmarked ? account.earmarked : liquidationAmount;

            // update user balance
            account.collateralBalance = convertDebtTokensToYield(collateralInDebt);

            if (fee > 0) {
                TokenUtils.safeTransfer(yieldToken, msg.sender, fee);
            }
        }

        return (debtAmount, fee);
    }

    /// @dev Increases the debt by `amount` for the account owned by `owner`.
    ///
    /// @param owner   The address of the account owner.
    /// @param amount  The amount to increase the debt by.
    function _addDebt(address owner, uint256 amount) internal {
        Account storage account = _accounts[owner];
        account.debt += amount;
        totalDebt += amount;
    }

    /// @dev Increases the debt by `amount` for the account owned by `owner`.
    /// @param owner   The address of the account owner.
    /// @param amount  The amount to increase the debt by.
    function _subDebt(address owner, uint256 amount) internal {
        Account storage account = _accounts[owner];
        account.debt -= amount;
        totalDebt -= amount;
    }

    /// @dev Set the mint allowance for `spender` to `amount` for the account owned by `owner`.
    ///
    /// @param owner   The address of the account owner.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to set the mint allowance to.
    function _approveMint(address owner, address spender, uint256 amount) internal {
        Account storage account = _accounts[owner];
        account.mintAllowances[spender] = amount;
        emit ApproveMint(owner, spender, amount);
    }

    /// @dev Decrease the mint allowance for `spender` by `amount` for the account owned by `owner`.
    ///
    /// @param owner   The address of the account owner.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to decrease the mint allowance by.
    function _decreaseMintAllowance(address owner, address spender, uint256 amount) internal {
        Account storage account = _accounts[owner];
        account.mintAllowances[spender] -= amount;
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
    ///
    /// @param owner The address of the account owner.
    function _validate(address owner) internal view {
        if (_isUnderCollateralized(owner)) revert Undercollateralized();
    }

    /// @dev Update the user's earmarked and redeemed debt amounts.
    function _sync(address owner) internal {
        Account storage account = _accounts[owner];
        RedemptionInfo memory previousRedemption = _redemptions[lastRedemptionBlock];

        // Calculate fee and debt to earmark
        uint256 debtFee = account.debt * (_feeWeight - account.lastAccruedFeeWeight) / WEIGHT_SCALING_FACTOR;
        uint256 debtToEarmark = (account.debt + debtFee) * (_earmarkWeight - account.lastAccruedEarmarkWeight) / WEIGHT_SCALING_FACTOR;

        account.lastAccruedEarmarkWeight = _earmarkWeight;
        account.earmarked += debtToEarmark;

        account.debt += debtFee;
        account.lastAccruedFeeWeight = _feeWeight;

        uint256 earmarkToRedeem = account.earmarked * (_redemptionWeight - account.lastAccruedRedemptionWeight) / WEIGHT_SCALING_FACTOR;

        uint256 earmarkedCopyCopy;
        if (block.number > lastRedemptionBlock && _redemptionWeight != 0) {
            if (previousRedemption.debt != 0) {
                uint256 oldDebtFee = account.debt * (previousRedemption.feeWeight - account.lastAccruedFeeWeight) / WEIGHT_SCALING_FACTOR;
                uint256 debtToEarmarkCopy = (account.debt + oldDebtFee) * (previousRedemption.earmarkWeight - account.lastAccruedEarmarkWeight) / WEIGHT_SCALING_FACTOR;
                earmarkedCopyCopy = account.earmarked + debtToEarmarkCopy;
            }
            
            earmarkToRedeem = earmarkedCopyCopy * (_redemptionWeight - account.lastAccruedRedemptionWeight) / WEIGHT_SCALING_FACTOR;   
        }

        // Calculate how much of user earmarked amount has been redeemed and subtract it
        account.debt -= earmarkToRedeem;
        account.earmarked -= earmarkToRedeem;
        account.lastAccruedRedemptionWeight = _redemptionWeight;

        // Redeem user collateral equal to value of debt tokens redeemed
        account.collateralBalance -= convertDebtTokensToYield(earmarkToRedeem);
    }

    function _earmark() internal {
        if (totalDebt == 0) return;

        if (block.number > lastEarmarkBlock) {
            uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);
            cumulativeEarmarked += amount;
            
            uint256 debtForFee = (protocolFee * totalDebt / BPS) * (block.number - lastEarmarkBlock) / blocksPerYear;
            _feeWeight += debtForFee * WEIGHT_SCALING_FACTOR / totalDebt;
            totalDebt += debtForFee;

            _earmarkWeight += amount * WEIGHT_SCALING_FACTOR / totalDebt;

            lastEarmarkBlock = block.number;
        }
    }

    /// @dev Gets the amount of debt that the account owned by `owner` will have after an sync occurs.
    ///
    /// @param owner The address of the account owner.
    ///
    /// @return The amount of debt that the account owned by `owner` will have after an update.    
    /// @return The amount of debt which is currently earmarked fro redemption.
    /// @return The amount of collateral that has yet to be redeemed.
    function _calculateUnrealizedDebt(address owner) internal view returns (uint256, uint256, uint256) {
        Account storage account = _accounts[owner];
        RedemptionInfo memory previousRedemption = _redemptions[lastRedemptionBlock];

        uint256 amount;
        uint256 earmarkWeightCopy = _earmarkWeight;
        uint256 feeWeightCopy = _feeWeight;

        if (block.number > lastEarmarkBlock) {
            amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);
            if (totalDebt != 0) {
                uint256 debtForFee = (protocolFee * totalDebt / BPS) * (block.number - lastEarmarkBlock) / blocksPerYear;
                feeWeightCopy += debtForFee * WEIGHT_SCALING_FACTOR / (totalDebt);
                earmarkWeightCopy += amount * WEIGHT_SCALING_FACTOR / (totalDebt + debtForFee);
            }
        }

        uint256 debtFee = account.debt * (feeWeightCopy - account.lastAccruedFeeWeight) / WEIGHT_SCALING_FACTOR;
        uint256 debtToEarmark = (account.debt + debtFee) * (earmarkWeightCopy - account.lastAccruedEarmarkWeight) / WEIGHT_SCALING_FACTOR;
        uint256 earmarkedCopy = account.earmarked + debtToEarmark;
        uint256 earmarkToRedeem = earmarkedCopy * (_redemptionWeight - account.lastAccruedRedemptionWeight) / WEIGHT_SCALING_FACTOR;

        // Recreate account state at last redemption block
        uint256 earmarkedCopyCopy;
        if (block.number > lastRedemptionBlock && _redemptionWeight != 0) {
            if (previousRedemption.debt != 0) {
                uint256 oldDebtFee = account.debt * (previousRedemption.feeWeight - account.lastAccruedFeeWeight) / WEIGHT_SCALING_FACTOR;
                uint256 debtToEarmarkCopy = (account.debt + oldDebtFee) * (previousRedemption.earmarkWeight - account.lastAccruedEarmarkWeight) / WEIGHT_SCALING_FACTOR;
                earmarkedCopyCopy = account.earmarked + debtToEarmarkCopy;
            }
            
            earmarkToRedeem = earmarkedCopyCopy * (_redemptionWeight - account.lastAccruedRedemptionWeight) / WEIGHT_SCALING_FACTOR;   
        }


        return (account.debt - earmarkToRedeem + debtFee, earmarkedCopy - earmarkToRedeem, account.collateralBalance - convertDebtTokensToYield(earmarkToRedeem));
    }

    /// @dev Checks that the account owned by `owner` is properly collateralized.
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    ///
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

    /// @dev Calculates the amount required to reduce an accounts debt and collateral by to achieve the target `minimumCollateralization` ratio.
    /// @param collateral  The collateral amount for an account.
    /// @param debt The debt amount for an account.
    /// @param globalRatio  The global collaterilzation ratio for this alchemist.
    /// @return liquidationAmount amount to be liquidated.
    function _getLiquidationAmount(uint256 collateral, uint256 debt, uint256 globalRatio) internal view returns (uint256 liquidationAmount) {
        _checkArgument(minimumCollateralization > 1e18);
        if (debt >= collateral) {
            // fully liquidate bad debt
            return debt;
        }

        if (globalRatio < globalMinimumCollateralization) {
            // fully liquidate debt in high ltv global environment
            return debt;
        }
        // otherwise, partially liquidate using formula : (collateral - amount)/(debt - amount) = globalMinimumCollateralization
        uint256 expectedColltaeralForCurrentDebt = (debt * minimumCollateralization) / FIXED_POINT_SCALAR;
        uint256 collateralDiff = expectedColltaeralForCurrentDebt - collateral;
        uint256 ratioDiff = minimumCollateralization - 1e18;
        liquidationAmount = collateralDiff * FIXED_POINT_SCALAR / ratioDiff;
        return liquidationAmount;
    }

    function _getTotalUnderlyingValue() internal view returns (uint256 totalUnderlyingValue) {
        uint256 yieldTokenTVL = IERC20(yieldToken).balanceOf(address(this));
        uint256 yieldTokenTVLInUnderlying = convertYieldTokensToUnderlying(yieldTokenTVL);
        totalUnderlyingValue = yieldTokenTVLInUnderlying;
    }
}
