// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./interfaces/IAlchemistV3.sol";
import "./interfaces/ITokenAdapter.sol";
import "./interfaces/ITransmuter.sol";
import "./interfaces/IAlchemistV3Position.sol";
import "./libraries/TokenUtils.sol";
import "./libraries/SafeCast.sol";
import "./libraries/PositionDecay.sol";

import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Unauthorized, IllegalArgument, IllegalState, MissingInputData} from "./base/Errors.sol";

import {console} from "../../lib/forge-std/src/console.sol";

/// @title  AlchemistV3
/// @author Alchemix Finance
contract AlchemistV3 is IAlchemistV3, Initializable {
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeCast for int128;
    using SafeCast for uint128;

    /// @inheritdoc IAlchemistV3Immutables
    string public constant version = "3.0.0";

    uint256 public constant BPS = 10_000;

    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    // Scaling factor to preserve precission with weighting
    uint256 public constant DEBT_SCALING_FACTOR = 1e27;

    /// @inheritdoc IAlchemistV3State
    address public admin;

    /// @inheritdoc IAlchemistV3Immutables
    address public debtToken;

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
    uint256 public scaledDebt;
    
    /// @inheritdoc IAlchemistV3State
    uint256 public debtScalingWeight;

    /// @inheritdoc IAlchemistV3State
    uint256 public totalSyntheticsIssued;

    /// @inheritdoc IAlchemistV3State
    uint256 public protocolFee;

    /// @inheritdoc IAlchemistV3State
    uint256 public liquidatorFee;

    /// @inheritdoc IAlchemistV3State
    address public alchemistPositionNFT;

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
    mapping(address => bool) public guardians;

    uint256 private _earmarkWeight;

    uint256 private _redemptionWeight;

    mapping(uint256 => Account) private _accounts;

    mapping(uint256 => RedemptionInfo) private _redemptions;

    modifier onlyAdmin() {
        if (msg.sender != admin) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyAdminOrGuardian() {
        if (msg.sender != admin && !guardians[msg.sender]) {
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
        underlyingConversionFactor = 10 ** (TokenUtils.expectDecimals(params.debtToken) - TokenUtils.expectDecimals(params.underlyingToken));
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
        debtScalingWeight = DEBT_SCALING_FACTOR;
    }

    /// @notice Emitted when a new Position NFT is minted.
    event AlchemistV3PositionNFTMinted(address indexed to, uint256 indexed tokenId);

    // Setter for the NFT position token, callable by admin.
    function setAlchemistPositionNFT(address nft) external onlyAdmin {
        if (nft == address(0)) {
            revert AlchemistV3NFTZeroAddressError();
        }

        if (alchemistPositionNFT != address(0)) {
            revert AlchemistV3NFTAlreadySetError();
        }

        alchemistPositionNFT = nft;
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
    function setTokenAdapter(address value) external onlyAdmin {
        _checkArgument(value != address(0));

        tokenAdapter = value;
        emit TokenAdapterUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setTransmuter(address value) external onlyAdmin {
        _checkArgument(value != address(0));

        // Check that old transmuter has enough funds to cover all future transmutations before allowing a swap
        require(convertYieldTokensToDebt(TokenUtils.safeBalanceOf(yieldToken, transmuter)) >= ITransmuter(transmuter).totalLocked());

        transmuter = value;
        emit TransmuterUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setGuardian(address guardian, bool isActive) external onlyAdmin {
        _checkArgument(guardian != address(0));

        guardians[guardian] = isActive;
        emit GuardianSet(guardian, isActive);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function setMinimumCollateralization(uint256 value) external onlyAdmin {
        _checkArgument(value >= FIXED_POINT_SCALAR);
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
        _checkArgument(value >= FIXED_POINT_SCALAR);
        collateralizationLowerBound = value;
        emit CollateralizationLowerBoundUpdated(value);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseDeposits(bool isPaused) external onlyAdminOrGuardian {
        depositsPaused = isPaused;
        emit DepositsPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3AdminActions
    function pauseLoans(bool isPaused) external onlyAdminOrGuardian {
        loansPaused = isPaused;
        emit LoansPaused(isPaused);
    }

    /// @inheritdoc IAlchemistV3State
    function getCDP(uint256 tokenId) external view returns (uint256, uint256, uint256) {
        (uint256 debt, uint256 earmarked, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
        return (collateral, debt, earmarked);
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalDeposited() external view returns (uint256) {
        return IERC20(yieldToken).balanceOf(address(this));
    }

    /// @inheritdoc IAlchemistV3State
    function getMaxBorrowable(uint256 tokenId) external view returns (uint256) {
        (uint256 debt, uint256 earmarked, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
        uint256 debtValueOfCollateral = convertYieldTokensToDebt(collateral);
        return (debtValueOfCollateral * FIXED_POINT_SCALAR / minimumCollateralization) - debt;
    }

    /// @inheritdoc IAlchemistV3State
    function mintAllowance(uint256 ownerTokenId, address spender) external view returns (uint256) {
        Account storage account = _accounts[ownerTokenId];
        return account.mintAllowances[account.allowancesVersion][spender];
    }

    /// @inheritdoc IAlchemistV3State
    function getTotalUnderlyingValue() external view returns (uint256) {
        return _getTotalUnderlyingValue();
    }

    /// @inheritdoc IAlchemistV3State
    function totalValue(uint256 tokenId) public view returns (uint256) {
        uint256 totalUnderlying;
        (uint256 debt, uint256 earmarked, uint256 collateral) = _calculateUnrealizedDebt(tokenId);
        if (collateral > 0) totalUnderlying += convertYieldTokensToUnderlying(collateral);
        return normalizeUnderlyingTokensToDebt(totalUnderlying);
    }

    /// @inheritdoc IAlchemistV3Actions
    function deposit(uint256 amount, address recipient, uint256 recipientId) external returns (uint256) {
        _checkArgument(recipient != address(0));
        _checkArgument(amount > 0);
        _checkState(!depositsPaused);
        _checkState(IERC20(yieldToken).balanceOf(address(this)) + amount <= depositCap);
        uint256 tokenId = recipientId;

        // Only mint a new position if the id is 0
        if (tokenId == 0) {
            tokenId = IAlchemistV3Position(alchemistPositionNFT).mint(recipient);
            emit AlchemistV3PositionNFTMinted(recipient, tokenId);
        } else {
            _checkForValidAccountId(tokenId);
        }
        _accounts[tokenId].collateralBalance += amount;

        // Transfer tokens from msg.sender now that the internal storage updates have been committed.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, address(this), amount);

        emit Deposit(amount, tokenId);

        return convertYieldTokensToDebt(amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function withdraw(uint256 amount, address recipient, uint256 tokenId) external returns (uint256) {
        _checkArgument(recipient != address(0));
        _checkForValidAccountId(tokenId);
        _checkArgument(amount > 0);
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);
        _earmark();

        _sync(tokenId);

        _checkArgument(_accounts[tokenId].collateralBalance >= amount);

        _accounts[tokenId].collateralBalance -= amount;

        // Assure that the collateralization invariant is still held.
        _validate(tokenId);

        // Transfer the yield tokens to msg.sender
        TokenUtils.safeTransfer(yieldToken, recipient, amount);

        emit Withdraw(amount, tokenId, recipient);

        return amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function mint(uint256 tokenId, uint256 amount, address recipient) external {
        _checkArgument(recipient != address(0));
        _checkForValidAccountId(tokenId);
        _checkArgument(amount > 0);
        _checkState(loansPaused == false);
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(tokenId);

        // Mint tokens to recipient
        _mint(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function mintFrom(uint256 tokenId, uint256 amount, address recipient) external {
        _checkArgument(amount > 0);
        _checkForValidAccountId(tokenId);
        _checkArgument(recipient != address(0));
        _checkState(loansPaused == false);

        // Preemptively try and decrease the minting allowance. This will save gas when the allowance is not sufficient.
        _decreaseMintAllowance(tokenId, msg.sender, amount);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(tokenId);

        // Mint tokens from the tokenId's account to the recipient.
        _mint(tokenId, amount, recipient);
    }

    /// @inheritdoc IAlchemistV3Actions
    function burn(uint256 amount, uint256 recipientId) external returns (uint256) {
        _checkArgument(amount > 0);
        _checkForValidAccountId(recipientId);

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before more is taken
        _sync(recipientId);

        uint256 debt;
        // Burning alAssets can only repay unearmarked debt
        _checkState((debt = _accounts[recipientId].debt - _accounts[recipientId].earmarked) > 0);

        uint256 credit = amount > debt ? debt : amount;

        // Must only burn enough tokens that the transmuter positions can still be fulfilled
        if (credit > totalDebt - ITransmuter(transmuter).totalLocked()) {
            revert BurnLimitExceeded(credit, totalDebt - ITransmuter(transmuter).totalLocked());
        }

        // Burn the tokens from the message sender
        TokenUtils.safeBurnFrom(debtToken, msg.sender, credit);

        // Update the recipient's debt.
        _subDebt(recipientId, credit);

        uint256 scaledAmount = credit * DEBT_SCALING_FACTOR / debtScalingWeight;
        _accounts[recipientId].scaledDebt -= scaledAmount;
        scaledDebt -= scaledAmount;

        totalSyntheticsIssued -= credit;

        emit Burn(msg.sender, credit, recipientId);

        return credit;
    }

    /// @inheritdoc IAlchemistV3Actions
    function repay(uint256 amount, uint256 recipientTokenId) external returns (uint256) {
        _checkArgument(amount > 0);
        _checkForValidAccountId(recipientTokenId);
        Account storage account = _accounts[recipientTokenId];

        // Query transmuter and earmark global debt
        _earmark();

        // Sync current user debt before deciding how much is available to be repaid
        _sync(recipientTokenId);

        uint256 debt;

        // Burning yieldTokens will pay off all types of debt
        _checkState((debt = account.debt) > 0);

        uint256 yieldToDebt = convertYieldTokensToDebt(amount);
        uint256 credit = yieldToDebt > debt ? debt : yieldToDebt;
        uint256 creditToYield = convertDebtTokensToYield(credit);

        _subDebt(recipientTokenId, credit);

        uint256 scaledAmount = credit * DEBT_SCALING_FACTOR / debtScalingWeight;
        account.scaledDebt -= scaledAmount;
        scaledDebt -= scaledAmount;

        // Repay debt from earmarked amount of debt first
        account.earmarked -= credit > account.earmarked ? account.earmarked : credit;

        // Transfer the repaid tokens to the transmuter.
        TokenUtils.safeTransferFrom(yieldToken, msg.sender, transmuter, creditToYield);

        emit Repay(msg.sender, amount, recipientTokenId, creditToYield);

        return creditToYield;
    }

    /// @inheritdoc IAlchemistV3Actions
    function liquidate(uint256 accountId) external override returns (uint256 underlyingAmount, uint256 fee) {
        _checkForValidAccountId(accountId);
        _earmark();

        (underlyingAmount, fee) = _liquidate(accountId);
        if (underlyingAmount > 0) {
            emit Liquidated(accountId, msg.sender, underlyingAmount, fee);
            return (underlyingAmount, fee);
        } else {
            // no liquidation amount returned, so no liquidation happened
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function batchLiquidate(uint256[] memory accountIds) external returns (uint256 totalAmountLiquidated, uint256 totalFees) {
        _earmark();

        if (accountIds.length == 0) {
            revert MissingInputData();
        }

        for (uint256 i = 0; i < accountIds.length; i++) {
            uint256 accountId = accountIds[i];
            if (accountId == 0 || !_tokenExists(alchemistPositionNFT, accountId)) {
                continue;
            }
            (uint256 underlyingAmount, uint256 fee) = _liquidate(accountId);
            totalAmountLiquidated += underlyingAmount;
            totalFees += fee;
        }

        if (totalAmountLiquidated > 0) {
            return (totalAmountLiquidated, totalFees);
        } else {
            // no total liquidation amount returned, so no liquidations happened
            revert LiquidationError();
        }
    }

    /// @inheritdoc IAlchemistV3Actions
    function redeem(uint256 amount) external onlyTransmuter {
        _earmark();

        _redemptionWeight += PositionDecay.WeightIncrement(amount,cumulativeEarmarked);

        cumulativeEarmarked -= amount;
        totalDebt -= amount;

        uint256 totalEffective = scaledDebt * debtScalingWeight / DEBT_SCALING_FACTOR;
        uint256 newEffective = totalEffective - amount;
        uint256 factor = newEffective * DEBT_SCALING_FACTOR / totalEffective;
        debtScalingWeight = debtScalingWeight * factor / DEBT_SCALING_FACTOR;

        lastRedemptionBlock = block.number;

        // TODO
        _redemptions[block.number] = RedemptionInfo(cumulativeEarmarked, totalDebt, _earmarkWeight, 0);

        uint256 collateralToRedeem = convertDebtTokensToYield(amount);
        TokenUtils.safeTransfer(yieldToken, transmuter, collateralToRedeem);

        emit Redemption(amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function adjustTotalSyntheticsIssued(uint256 amount) external onlyTransmuter {
        totalSyntheticsIssued -= amount;
    }

    /// @inheritdoc IAlchemistV3Actions
    function poke(uint256 tokenId) external {
        _checkForValidAccountId(tokenId);
        _earmark();
        _sync(tokenId);
    }

    /// @inheritdoc IAlchemistV3Actions
    function approveMint(uint256 tokenId, address spender, uint256 amount) external {
        _checkAccountOwnership(IAlchemistV3Position(alchemistPositionNFT).ownerOf(tokenId), msg.sender);
        _approveMint(tokenId, spender, amount);
    }

    /// @inheritdoc IAlchemistV3Actions
    function resetMintAllowances(uint256 tokenId) external {
        // Allow calls from either the token owner or the NFT contract
        if (msg.sender != address(alchemistPositionNFT)) {
            // Direct call - verify caller is current owner
            address tokenOwner = IERC721(alchemistPositionNFT).ownerOf(tokenId);
            if (msg.sender != tokenOwner) {
                revert Unauthorized();
            }
        }
        // increment version to start the mapping from a fresh state
        _accounts[tokenId].allowancesVersion += 1;
        // Emit event to notify allowance clearing
        emit MintAllowancesReset(tokenId);
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
        return (amount * ITokenAdapter(tokenAdapter).price()) / 10 ** decimals;
    }

    /// @inheritdoc IAlchemistV3State
    function convertUnderlyingTokensToYield(uint256 amount) public view returns (uint256) {
        uint8 decimals = TokenUtils.expectDecimals(yieldToken);
        return amount * 10 ** decimals / ITokenAdapter(tokenAdapter).price();
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeUnderlyingTokensToDebt(uint256 amount) public view returns (uint256) {
        return amount * underlyingConversionFactor;
    }

    /// @inheritdoc IAlchemistV3State
    function normalizeDebtTokensToUnderlying(uint256 amount) public view returns (uint256) {
        return amount / underlyingConversionFactor;
    }

    /// @dev Mints debt tokens to `recipient` using the account owned by `tokenId`.
    /// @param tokenId     The tokenId of the account to mint from.
    /// @param amount    The amount to mint.
    /// @param recipient The recipient of the minted debt tokens.
    function _mint(uint256 tokenId, uint256 amount, address recipient) internal {
        _addDebt(tokenId, amount);

        totalSyntheticsIssued += amount;

        // Validate the tokenId's account to assure that the collateralization invariant is still held.
        _validate(tokenId);

        // Mint the debt tokens to the recipient.
        TokenUtils.safeMint(debtToken, recipient, amount);

        emit Mint(tokenId, amount, recipient);
    }

    /// @dev Fetches and applies the liquidation amount to account `tokenId` if the account collateral ratio touches `collateralizationLowerBound`.
    /// @param accountId  The tokenId of the account to to liquidate.
    /// @return debtAmount  The liquidation amount removed from the account `tokenId`.
    /// @return fee The additional fee as a % of the liquidation amount to be sent to the liquidator
    function _liquidate(uint256 accountId) internal returns (uint256 debtAmount, uint256 fee) {
        // Get updated earmarking data and sync current user debt before liquidation
        // If a redemption gets triggered before this liquidation call in the block then the users account may fall back into the healthy range
        _sync(accountId);

        Account storage account = _accounts[accountId];

        uint256 debt = account.debt;
        if (debt == 0) {
            return (0, 0);
        }

        // tokenId collateral denominated in underlying value
        uint256 collateralInDebt = totalValue(accountId);
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
            _subDebt(accountId, liquidationAmount);

            uint256 scaledAmount = liquidationAmount * DEBT_SCALING_FACTOR / debtScalingWeight;
            account.scaledDebt -= scaledAmount;
            scaledDebt -= scaledAmount;

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

    /// @dev Increases the debt by `amount` for the account owned by `tokenId`.
    ///
    /// @param tokenId   The account owned by tokenId.
    /// @param amount  The amount to increase the debt by.
    function _addDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];
        account.debt += amount;
        totalDebt += amount;

        uint256 scaledAmount = amount * DEBT_SCALING_FACTOR / debtScalingWeight;
        _accounts[tokenId].scaledDebt += scaledAmount;
        scaledDebt += scaledAmount;
    }

    /// @dev Increases the debt by `amount` for the account owned by `tokenId`.
    /// @param tokenId   The account owned by tokenId.
    /// @param amount  The amount to increase the debt by.
    function _subDebt(uint256 tokenId, uint256 amount) internal {
        Account storage account = _accounts[tokenId];
        account.debt -= amount;
        totalDebt -= amount;
    }

    /// @dev Set the mint allowance for `spender` to `amount` for the account owned by `tokenId`.
    ///
    /// @param ownerTokenId   The id of the account granting approval.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to set the mint allowance to.
    function _approveMint(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] = amount;
        emit ApproveMint(ownerTokenId, spender, amount);
    }

    /// @dev Decrease the mint allowance for `spender` by `amount` for the account owned by `ownerTokenId`.
    ///
    /// @param ownerTokenId The id of the account owner.
    /// @param spender The address of the spender.
    /// @param amount  The amount of debt tokens to decrease the mint allowance by.
    function _decreaseMintAllowance(uint256 ownerTokenId, address spender, uint256 amount) internal {
        Account storage account = _accounts[ownerTokenId];
        account.mintAllowances[account.allowancesVersion][spender] -= amount;
    }

    /// @dev Checks an expression and reverts with an {IllegalArgument} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkArgument(bool expression) internal pure {
        if (!expression) {
            revert IllegalArgument();
        }
    }

    /// @dev Checks if owner == sender and reverts with an {UnauthorizedAccountAccessError} error if the result is {false}.
    ///
    /// @param owner The address of the owner of an account.
    /// @param user The address of the user attempting to access an account.
    function _checkAccountOwnership(address owner, address user) internal pure {
        if (owner != user) {
            revert UnauthorizedAccountAccessError();
        }
    }

    /// @dev reverts {UnknownAccountOwnerIDError} error by if no owner exists.
    ///
    /// @param tokenId The id of an account.
    function _checkForValidAccountId(uint256 tokenId) internal {
        if (!_tokenExists(alchemistPositionNFT, tokenId)) {
            revert UnknownAccountOwnerIDError();
        }
    }

    /**
     * @notice Checks whether a token id is linked to an owner. Non blocking / no reverts.
     * @param nft The address of the ERC721 based contract.
     * @param tokenId The token id to check.
     * @return exists A boolean that is true if the token exists.
     */
    function _tokenExists(address nft, uint256 tokenId) internal view returns (bool exists) {
        if (tokenId == 0) {
            // token ids start from 1
            return false;
        }
        try IERC721(nft).ownerOf(tokenId) {
            // If the call succeeds, the token exists.
            exists = true;
        } catch {
            // If the call fails, then the token does not exist.
            exists = false;
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

    /// @dev Checks that the account owned by `tokenId` is properly collateralized.
    /// @dev If the account is undercollateralized then this will revert with an {Undercollateralized} error.
    ///
    /// @param tokenId The id of the account owner.
    function _validate(uint256 tokenId) internal view {
        if (_isUnderCollateralized(tokenId)) revert Undercollateralized();
    }

    /// @dev Update the user's earmarked and redeemed debt amounts.
    function _sync(uint256 tokenId) internal {
        Account storage account = _accounts[tokenId];
        RedemptionInfo memory previousRedemption = _redemptions[lastRedemptionBlock];

        uint256 userDebtBalance = account.scaledDebt * debtScalingWeight / DEBT_SCALING_FACTOR;

        uint256 debtToEarmark = PositionDecay.ScaleByWeightDelta(account.debt - account.earmarked, _earmarkWeight - account.lastAccruedEarmarkWeight);
        
        account.lastAccruedEarmarkWeight = _earmarkWeight;
        account.earmarked += debtToEarmark;
        account.debt = userDebtBalance;

        uint256 earmarkToRedeem = PositionDecay.ScaleByWeightDelta(account.earmarked, _redemptionWeight - account.lastAccruedRedemptionWeight);

        // Recreate account state at last redemption block
        uint256 earmarkedCopyCopy;
        if (block.number > lastRedemptionBlock && _redemptionWeight != 0) {
            if (previousRedemption.debt != 0) {
                uint256 debtToEarmark = PositionDecay.ScaleByWeightDelta(account.debt - account.earmarked, previousRedemption.earmarkWeight - account.lastAccruedEarmarkWeight);
                earmarkedCopyCopy = account.earmarked + debtToEarmark;
            }

            earmarkToRedeem = PositionDecay.ScaleByWeightDelta(earmarkedCopyCopy, _redemptionWeight - account.lastAccruedRedemptionWeight);
        }

        // Calculate how much of user earmarked amount has been redeemed and subtract it
        account.earmarked -= earmarkToRedeem;
        account.lastAccruedRedemptionWeight = _redemptionWeight;

        // Redeem user collateral equal to value of debt tokens redeemed
        account.collateralBalance -= convertDebtTokensToYield(earmarkToRedeem);
    }

    function _earmark() internal {
        if (totalDebt == 0) return;

        if (block.number > lastEarmarkBlock) {
            uint256 amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);
            if (amount > 0) {
                _earmarkWeight += PositionDecay.WeightIncrement(amount, totalDebt - cumulativeEarmarked);
                cumulativeEarmarked += amount;
            }

            if (protocolFee > 0) {
                uint256 debtForFee = (protocolFee * totalDebt / BPS) * (block.number - lastEarmarkBlock) / blocksPerYear;
                totalDebt += debtForFee;

                debtScalingWeight = debtScalingWeight * (DEBT_SCALING_FACTOR + ((protocolFee * DEBT_SCALING_FACTOR / BPS) * (block.number - lastEarmarkBlock) / blocksPerYear)) / DEBT_SCALING_FACTOR;
            }
            lastEarmarkBlock = block.number;
        }
    }

    /// @dev Gets the amount of debt that the account owned by `owner` will have after a sync occurs.
    ///
    /// @param tokenId The id of the account owner.
    ///
    /// @return The amount of debt that the account owned by `owner` will have after an update.
    /// @return The amount of debt which is currently earmarked fro redemption.
    /// @return The amount of collateral that has yet to be redeemed.
    function _calculateUnrealizedDebt(uint256 tokenId) internal view returns (uint256, uint256, uint256) {
        Account storage account = _accounts[tokenId];
        RedemptionInfo memory previousRedemption = _redemptions[lastRedemptionBlock];

        uint256 amount;
        uint256 earmarkWeightCopy = _earmarkWeight;
        uint256 debtForFee;
        uint256 debtScalingWeightCopy = debtScalingWeight;

        // If earmark was not this block then simulate and earmark and store temporary variables for proper debt calculation
        if (block.number > lastEarmarkBlock) {
            amount = ITransmuter(transmuter).queryGraph(lastEarmarkBlock + 1, block.number);
            if (totalDebt > 0) {
                if (protocolFee > 0) {
                    debtForFee = (protocolFee * totalDebt / BPS) * (block.number - lastEarmarkBlock) / blocksPerYear;

                    debtScalingWeightCopy = debtScalingWeight * (DEBT_SCALING_FACTOR + ((protocolFee * DEBT_SCALING_FACTOR / BPS) * (block.number - lastEarmarkBlock) / blocksPerYear)) / DEBT_SCALING_FACTOR;
                }

                if (amount > 0) {
                    earmarkWeightCopy += PositionDecay.WeightIncrement(amount, totalDebt - cumulativeEarmarked);
                }
            }
        }

        uint256 debtToEarmark = PositionDecay.ScaleByWeightDelta(account.debt - account.earmarked, earmarkWeightCopy - account.lastAccruedEarmarkWeight);
        uint256 earmarkedState = account.earmarked + debtToEarmark;

        // Recreate account state at last redemption block
        uint256 earmarkedPreviousState;
        uint256 earmarkToRedeem;
        if (block.number > lastRedemptionBlock && _redemptionWeight != 0) {
            if (previousRedemption.debt != 0) {
                uint256 debtToEarmarkCopy = PositionDecay.ScaleByWeightDelta(account.debt - account.earmarked, previousRedemption.earmarkWeight - account.lastAccruedEarmarkWeight);
                earmarkedPreviousState = account.earmarked + debtToEarmarkCopy;
            }

            earmarkToRedeem = PositionDecay.ScaleByWeightDelta(earmarkedPreviousState, _redemptionWeight - account.lastAccruedRedemptionWeight);
        } else {
            earmarkToRedeem = PositionDecay.ScaleByWeightDelta(earmarkedState, _redemptionWeight - account.lastAccruedRedemptionWeight);
        }

        uint256 userDebtBalance = account.scaledDebt * debtScalingWeightCopy / DEBT_SCALING_FACTOR;

        return (userDebtBalance, earmarkedState - earmarkToRedeem, account.collateralBalance - convertDebtTokensToYield(earmarkToRedeem));
    }

    /// @dev Checks that the account owned by `tokenId` is properly collateralized.
    /// @dev Returns true only if the account is undercollateralized
    ///
    /// @param tokenId The id of the account owner.
    function _isUnderCollateralized(uint256 tokenId) internal view returns (bool) {
        uint256 debt = _accounts[tokenId].debt;
        if (debt == 0) return false;

        uint256 collateralization = totalValue(tokenId) * FIXED_POINT_SCALAR / debt;
        return collateralization < minimumCollateralization;
    }

    /// @dev Calculates the amount required to reduce an accounts debt and collateral by to achieve the target `minimumCollateralization` ratio.
    /// @param collateral  The collateral amount for an account.
    /// @param debt The debt amount for an account.
    /// @param globalRatio  The global collaterilzation ratio for this alchemist.
    /// @return liquidationAmount amount to be liquidated.
    function _getLiquidationAmount(uint256 collateral, uint256 debt, uint256 globalRatio) internal view returns (uint256 liquidationAmount) {
        _checkState(minimumCollateralization > FIXED_POINT_SCALAR);
        if (debt >= collateral) {
            // fully liquidate bad debt
            return debt;
        }

        if (globalRatio < globalMinimumCollateralization) {
            // fully liquidate debt in high ltv global environment
            return debt;
        }
        // otherwise, partially liquidate using formula : (collateral - amount)/(debt - amount) = globalMinimumCollateralization
        uint256 expectedCollateralForCurrentDebt = (debt * minimumCollateralization) / FIXED_POINT_SCALAR;
        uint256 collateralDiff = expectedCollateralForCurrentDebt - collateral;
        uint256 ratioDiff = minimumCollateralization - FIXED_POINT_SCALAR;
        liquidationAmount = collateralDiff * FIXED_POINT_SCALAR / ratioDiff;
        return liquidationAmount;
    }

    function _getTotalUnderlyingValue() internal view returns (uint256 totalUnderlyingValue) {
        uint256 yieldTokenTVL = IERC20(yieldToken).balanceOf(address(this));
        uint256 yieldTokenTVLInUnderlying = convertYieldTokensToUnderlying(yieldTokenTVL);
        totalUnderlyingValue = yieldTokenTVLInUnderlying;
    }
}
