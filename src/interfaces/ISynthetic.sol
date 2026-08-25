// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.5.0;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @title  ISynthetic
/// @author Lux Liquid
///
/// @notice The debt token the engine issues against collateral.
///
/// @dev This is the surface the engine actually uses, and the whole of it.
///      `mint` creates debt, `burnFrom` retires a borrower's debt through the
///      allowance they granted, `burn` retires the caller's own -- which is how
///      the transmuter destroys the synthetics it has taken custody of.
///
///      The engine holds MINTER_ROLE and nothing more. It never needs to reach
///      a balance it does not own, so the token gives it no way to.
interface ISynthetic is IERC20 {
    /// @notice Creates `amount` tokens and assigns them to `account`.
    ///
    /// @notice Reverts if the caller does not hold MINTER_ROLE.
    function mint(address account, uint256 amount) external;

    /// @notice Destroys `amount` tokens held by the caller.
    function burn(uint256 amount) external;

    /// @notice Destroys `amount` tokens held by `account`, spending the caller's allowance.
    function burnFrom(address account, uint256 amount) external;

    /// @notice Grants `minter` the right to create supply.
    ///
    /// @notice Reverts if the caller is not an admin of the token.
    function grantMinter(address minter) external;

    /// @notice Revokes `minter`'s right to create supply.
    ///
    /// @notice Reverts if the caller is not an admin of the token.
    function revokeMinter(address minter) external;
}
