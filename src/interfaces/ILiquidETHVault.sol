// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title ILiquidETHVault
 * @notice Interface for the LiquidETHVault which handles ETH/WETH deposits
 * @dev Only authorized addresses (Liquid or admin) can withdraw funds
 */
interface ILiquidETHVault {
    /**
     * @notice Get the ERC20 token managed by this vault
     * @return The WETH token address
     */
    function token() external view returns (address);

    /**
     * @notice Deposit WETH into the vault
     * @param amount Amount of WETH to deposit
     */
    function depositWETH(uint256 amount) external;

    /**
     * @notice Withdraw funds from the vault to a target address
     * @param recipient Address to receive the funds
     * @param amount Amount to withdraw
     */
    function withdraw(address recipient, uint256 amount) external;

    /**
     * @notice Update the Liquid contract address
     * @param _liquidV3 New Liquid address
     */
    function setLiquid(address _liquidV3) external;

    /**
     * @notice Get the balance of a user
     * @param user Address of the user
     * @return User's balance in the vault
     */
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Get the WETH contract address
     * @return Address of the WETH contract
     */
    function weth() external view returns (address);

    /**
     * @notice Get the Liquid contract address
     * @return Address of the Liquid contract
     */
    function liquid() external view returns (address);

    /**
     * @notice Get the total amount of deposits in the vault
     * @return Total deposits
     */
    function totalDeposits() external view returns (uint256);

    /**
     * @notice Event emitted when funds are deposited
     * @param depositor Address that deposited funds
     * @param amount Amount deposited
     */
    event Deposited(address indexed depositor, uint256 amount);

    /**
     * @notice Event emitted when funds are withdrawn
     * @param recipient Address that received funds
     * @param amount Amount withdrawn
     */
    event Withdrawn(address indexed recipient, uint256 amount);

    /**
     * @notice Event emitted when the Liquid address is updated
     * @param newLiquid New Liquid address
     */
    event LiquidUpdated(address indexed newLiquid);
}
