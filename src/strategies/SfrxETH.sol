// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {MYTStrategy} from "../MYTStrategy.sol";

interface FraxMinter {
    function submitAndDeposit(address recipient) external payable returns (uint256);
}

interface FraxRedemptionQueue {
    function enterRedemptionQueueViaSfrxEth(uint256 sfrxEthShares, address recipient) external returns (uint256 nftId);
    function fullRedeemNft(uint256 nftId, address recipient) external returns (uint256 ethOut);
}

interface StakedFraxEth {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

contract SfrxETHStrategy is MYTStrategy {
    FraxMinter public immutable minter;
    FraxRedemptionQueue public immutable redemptionQueue;
    StakedFraxEth public immutable sfrxEth;

    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    constructor(address _myt, StrategyParams memory _params, address _sfrxEth, address _fraxMinter, address _redemptionQueue) MYTStrategy(_myt, _params) {
        minter = FraxMinter(_fraxMinter);
        redemptionQueue = FraxRedemptionQueue(_redemptionQueue);
        sfrxEth = StakedFraxEth(_sfrxEth);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        require(msg.value == amount);
        depositReturn = minter.submitAndDeposit{value: amount}(msg.sender);
    }

    function _deallocate(uint256 amount) internal override returns (uint256 positionId) {
        positionId = redemptionQueue.enterRedemptionQueueViaSfrxEth(amount, msg.sender);
        require(positionId != 0);
    }

    function _claimWithdrawalQueue(uint256 positionId) internal override returns(uint256 ethOut) {
        ethOut = redemptionQueue.fullRedeemNft(positionId, msg.sender);
    }

    function snapshotYield() public override returns (uint256) {
        uint256 currentTime = block.timestamp;

        // todo decide to implement this
        // if (lastSnapshotTime != 0 && currentTime - lastSnapshotTime < MIN_SNAPSHOT_INTERVAL) {
        //     return estApy;
        // }

        // Base rate of strategy
        (uint256 baseRatePerSec, uint256 newIndex) = _computeBaseRatePerSecond();

        // Add incentives to calculation if applicable 
        uint256 rewardsRatePerSec; 
        if (params.additionalIncentives == true) rewardsRatePerSec = _computeRewardsRatePerSecond();

        // Combine rates
        uint256 totalRatePerSec = baseRatePerSec + rewardsRatePerSec;
        uint256 apr = totalRatePerSec * SECONDS_PER_YEAR; // simple annualization (APR)
        uint256 apy = _approxAPY(totalRatePerSec);

        // Smoothing
        uint256 alpha = 7e17;
        estApr = lastSnapshotTime == 0 ? apr : _lerp(estApr, apr, alpha);
        estApy = lastSnapshotTime == 0 ? apy : _lerp(estApy, apy, alpha);

        lastSnapshotTime = uint64(currentTime);
        lastIndex = newIndex;

        emit YieldUpdated(estApy);

        return estApy;
    }

    function _computeBaseRatePerSecond() internal view returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        uint256 currentPPS = sfrxEth.convertToAssets(1e18);

        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }
    
    function _computeRewardsRatePerSecond() internal view returns (uint256) {

    }

    function _approxAPY(uint256 ratePerSecWad) internal pure returns (uint256) {
        uint256 apr = ratePerSecWad * SECONDS_PER_YEAR;
        uint256 aprSq = apr * apr / FIXED_POINT_SCALAR;
        return apr + aprSq / (2 * SECONDS_PER_YEAR);
    }

    function _lerp(uint256 oldVal, uint256 newVal, uint256 alpha) internal pure returns (uint256) {
        return alpha * oldVal / FIXED_POINT_SCALAR + (FIXED_POINT_SCALAR - alpha) * newVal / FIXED_POINT_SCALAR;
    }
}