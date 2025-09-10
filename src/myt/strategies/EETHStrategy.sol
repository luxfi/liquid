pragma solidity 0.8.28;

import {MYTAdapter} from "../MYTAdapter.sol";
import {IMYTAdapter} from "../interfaces/IMYTAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";

interface IEETH is IERC20 {
    function balanceOf(address _user) external view override returns (uint256);
    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
}

interface IDepositAdapter {
    function depositWETHForWeETH(uint256 _amount, address _referral) external returns (uint256);
}

interface WithdrawRequestNFT {
    function requestWithdraw(uint96 amountOfEEth, uint96 shareOfEEth, address recipient, uint256 fee) external returns (uint256);
    function batchClaimWithdraw(uint256[] calldata tokenIds) external;
}

contract EETHMYTStrategy is MYTAdapter {
    IEETH public immutable eeth;
    address public immutable depositAdapter = address(0xcfC6d9Bd7411962Bfe7145451A7EF71A24b6A7A2);
    address public immutable withdrawRequestNFT = address(0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c);

    constructor(address _myt, address _eeth, IMYTAdapter.StrategyParams memory _params) MYTAdapter(_myt, _eeth, _params) {
        eeth = IEETH(_eeth);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        depositReturn = IDepositAdapter(depositAdapter).depositWETHForWeETH(amount, address(this));
        require(depositReturn == amount);
    }

    function _deallocate(uint256 amount) internal override returns (uint256 amountRequested) {
        amountRequested = WithdrawRequestNFT(withdrawRequestNFT).requestWithdraw(uint96(amount), uint96(amount), address(this), 0);
        require(amountRequested != 0);
    }

    function snapshotYield() external override returns (uint256) {
        // TODO calculate & snapshot yield
    }

    function realAssets() external view override returns (uint256) {
        return eeth.balanceOf(address(this));
    }
}
