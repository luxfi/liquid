// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
// import {MYTStrategy} from "../MYTStrategy.sol";

import {IWETH} from "../interfaces/IWETH.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {MYTStrategy} from "../MYTStrategy.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";

interface FraxMinter {
    function submitAndDeposit(address recipient) external payable returns (uint256);
}

interface FraxRedemptionQueue {
    function enterRedemptionQueueViaSfrxEth(address _recipient, uint120 _sfrxEthAmount) external returns (uint256 _nftId);
    function burnRedemptionTicketNft(uint256 nftId, address payable recipient) external;
}

interface StakedFraxEth {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SfrxETHStrategy is MYTStrategy {
    FraxMinter public immutable minter;
    FraxRedemptionQueue public immutable redemptionQueue;
    StakedFraxEth public immutable sfrxEth;
    address public immutable WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    event SfrxETHStrategyDebugLog(string message, uint256 amount);

    constructor(address _myt, StrategyParams memory _params, address _sfrxEth, address _fraxMinter, address _redemptionQueue) MYTStrategy(_myt, _params) {
        minter = FraxMinter(_fraxMinter);
        redemptionQueue = FraxRedemptionQueue(_redemptionQueue);
        sfrxEth = StakedFraxEth(_sfrxEth);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        // need to unwrap ether since this strategy only recieves weth (morpho v2 vault cannot hold native eth by default)
        IWETH(WETH).withdraw(amount);
        // check that eth balance is equal to amount
        require(address(this).balance >= amount, "ETH balance is less than amount");
        depositReturn = minter.submitAndDeposit{value: amount}(address(this));
    }

    function _deallocate(uint256 amount) internal override returns (uint256 requestedAmount) {
        // protection for uint120 requirement
        require(amount <= type(uint120).max);
        // faking dex swap here
        requestedAmount = _doDexSwap(amount);
        TokenUtils.safeTransfer(WETH, msg.sender, requestedAmount);
    }

    function _doDexSwap(uint256 amount) internal returns (uint256 amountReturned) {
        // TODO: implement dex swap
        address fakeDexAddress = address(0);
        uint256 sfrxEthBalance = sfrxEth.balanceOf(address(this));
        emit SfrxETHStrategyDebugLog("SfrxETH balance", sfrxEthBalance);
        uint256 adjusted = amount < sfrxEthBalance ? amount : sfrxEthBalance;
        emit SfrxETHStrategyDebugLog("Adjusted", adjusted);
        TokenUtils.safeApprove(address(sfrxEth), fakeDexAddress, adjusted);
        // sfrxEth balance should for this address should now be reduced by amount
        TokenUtils.safeTransfer(address(sfrxEth), fakeDexAddress, adjusted);
        amountReturned = adjusted;
    }

    function _claimWithdrawalQueue(uint256 positionId) internal override returns (uint256 ethOut) {
        redemptionQueue.burnRedemptionTicketNft(positionId, payable(address(this)));
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        uint256 currentPPS = sfrxEth.convertToAssets(1e18);

        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }

    function realAssets() external view override returns (uint256) {
        return sfrxEth.convertToAssets(sfrxEth.balanceOf(address(this)));
    }

    receive() external payable {
        require(msg.sender == WETH, "Only WETH unwrap");
    }
}
