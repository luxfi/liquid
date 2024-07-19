pragma solidity >=0.5.0;

import "./IAlchemistV3Errors.sol";

/// @title  IAlchemistV3
/// @author Alchemix Finance
///
/// @notice Specifies user actions.
interface IAlchemistV3 is IAlchemistV3Errors {
    /// @notice Contract initialization parameters.
    struct InitializationParams {
        // The initial admin account.
        address admin;
        // The ERC20 token used to represent debt.
        address debtToken;
        // The address of the whitelist.
        address yieldToken;
        // The initial transmuter or transmuter buffer.
        address transmuter;
        // The max ltv
        uint256 maxLTV;
        // The percentage fee taken from each harvest measured in units of basis points.
        uint256 protocolFee;
        // The address that receives protocol fees.
        address protocolFeeReceiver;
        // A limit used to prevent administrators from making minting functionality inoperable.
        uint256 mintingLimitMinimum;
        // The maximum number of tokens that can be minted per period of time.
        uint256 mintingLimitMaximum;
        // The number of blocks that it takes for the minting limit to be refreshed.
        uint256 mintingLimitBlocks;
        // The address of the whitelist.
        address whitelist;
    }

    /// @notice deposit yield tokens to `user` with amount `collateralamount`.
    /// @param user The address of user to credit with deposit
    /// @param collateralamount  The amount of yield tokens to deposit.
    ///
    /// @return sharesIssued The number of shares issued to `recipient`.
    function deposit(address user, uint256 collateralamount) external returns (uint256 sharesIssued);

    /// @notice Withdraw yield tokens to `recipient` by burning `share` shares.
    /// @param amount The number of shares to burn.
    ///
    /// @return amountWithdrawn The number of yield tokens that were withdrawn to `recipient`.
    function withdraw(uint256 amount) external returns (uint256 amountWithdrawn);

    /// @notice Mint `amount` debt tokens.
    /// @param amount    The amount of tokens to mint.
    function mint(uint256 amount) external;

    /// @notice Burn `amount` debt tokens to credit the account owned by `recipient`.
    ///
    /// @param amount    The amount of tokens to burn.
    /// @param recipient The address of the recipient.
    ///
    /// @return amountBurned The amount of tokens that were burned.
    function burn(uint256 amount, address recipient) external returns (uint256 amountBurned);

    /// @notice Sets the maximum LTV at which a loan can be taken
    /// @param maxltv Maximum LTV
    function setMaxLoanToValue(uint256 maxltv) external;

    /// @notice Reduces a user’s debt by burning alAssets. Callable by anyone. Capped at existing debt of user.
    /// @param user Address of user to have debt repaid
    /// @param amount Amount of alAsset debt to repay
    function repay(address user, uint256 amount) external;

    /// @notice Checks if a users debt is greater than the underlying value of their collateral + 5%.
    /// @notice If so, the users debt is zero’d out and collateral with underlying value equivalent to the debt is sent to the transmuter.
    /// @notice The remainder is sent to the liquidator.
    ///
    /// @param owner The address of account owner.
    ///
    /// @return assets Yield assets sent to the transmuter
    /// @return fee Yield assets sent to the liquidator
    function liquidate(address owner) external returns (uint256 assets, uint256 fee);

    /// @notice QoL function to set the mint 'amount' to be the absolute maximum for the position.
    ///
    /// @return amount Minted alAsset sent to user address
    function maxMint() external returns (uint256 amount);

    /// @notice Globally redeems all users for their pending built up redemption 'amount'.
    /// @notice Callable by anyone.
    ///
    /// @return amount Amount of yield tokens sent to the transmuter
    function redeem() external returns (uint256 amount);
}
