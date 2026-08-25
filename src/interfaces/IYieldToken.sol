pragma solidity ^0.8.23;

interface IYieldToken {
    function price() external view returns (uint256);

    /// @notice The underlying token this yield token wraps.
    function underlyingToken() external view returns (address);
}
