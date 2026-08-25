// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ILiquid} from "./interfaces/ILiquid.sol";
import {ILiquidTransmuter} from "./interfaces/ILiquidTransmuter.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {NFTMetadataGenerator} from "./libraries/NFTMetadataGenerator.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {StakingGraph} from "./libraries/StakingGraph.sol";
import {TokenUtils} from "./libraries/TokenUtils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Unauthorized, IllegalArgument, IllegalState, InsufficientAllowance} from "./base/Errors.sol";
import "./base/LiquidTransmuterErrors.sol";

/// @title Lux LiquidV3 Transmuter
///
/// @notice A contract which facilitates the exchange of alAssets to yield bearing assets.
contract LiquidTransmuter is ILiquidTransmuter, ERC721, ReentrancyGuard {
    using StakingGraph for StakingGraph.Graph;
    using SafeCast for int256;
    using SafeCast for uint256;

    uint256 public constant BPS = 10_000;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;
    int256 public constant BLOCK_SCALING_FACTOR = 1e8;

    /// @inheritdoc ILiquidTransmuter
    string public constant version = "3.0.0";

    /// @inheritdoc ILiquidTransmuter
    uint256 public depositCap;

    /// @inheritdoc ILiquidTransmuter
    uint256 public exitFee;

    /// @inheritdoc ILiquidTransmuter
    uint256 public graphSize;

    /// @inheritdoc ILiquidTransmuter
    uint256 public transmutationFee;

    /// @inheritdoc ILiquidTransmuter
    uint256 public timeToTransmute;

    /// @inheritdoc ILiquidTransmuter
    uint256 public totalLocked;

    /// @inheritdoc ILiquidTransmuter
    address public admin;

    /// @inheritdoc ILiquidTransmuter
    address public pendingAdmin;

    /// @inheritdoc ILiquidTransmuter
    address public protocolFeeReceiver;

    /// @inheritdoc ILiquidTransmuter
    address public syntheticToken;

    /// @inheritdoc ILiquidTransmuter
    ILiquid public liquid;

    /// @dev Array of registered liquids.
    address[] public liquids;

    /// @dev Map of user positions data.
    mapping(uint256 => StakingPosition) private _positions;

    /// @dev Graph of transmuter positions.
    StakingGraph.Graph private _stakingGraph;

    /// @dev Nonce data used for minting of new nft positions.
    uint256 private _nonce;

    modifier onlyAdmin() {
        _checkArgument(msg.sender == admin);
        _;
    }

    constructor(ILiquidTransmuter.TransmuterInitializationParams memory params) ERC721("Lux Liquid Transmuter", "TRNSMTR") {
        syntheticToken = params.syntheticToken;
        timeToTransmute = params.timeToTransmute;
        transmutationFee = params.transmutationFee;
        exitFee = params.exitFee;
        protocolFeeReceiver = params.feeReceiver;
        admin = msg.sender;
        graphSize = params.graphSize;
    }

    /// @inheritdoc ILiquidTransmuter
    function setPendingAdmin(address value) external onlyAdmin {
        pendingAdmin = value;

        emit PendingAdminUpdated(value);
    }

    /// @inheritdoc ILiquidTransmuter
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

    /// @inheritdoc ILiquidTransmuter
    function setLiquid(address value) external onlyAdmin {
        liquid = ILiquid(value);

        emit LiquidUpdated(value);
    }

    /// @inheritdoc ILiquidTransmuter
    function setDepositCap(uint256 cap) external onlyAdmin {
        _checkArgument(cap <= type(int256).max.toUint256());

        depositCap = cap;
        emit DepositCapUpdated(cap);
    }

    /// @inheritdoc ILiquidTransmuter
    function setTransmutationFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        transmutationFee = fee;
        emit TransmutationFeeUpdated(fee);
    }

    /// @inheritdoc ILiquidTransmuter
    function setExitFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        exitFee = fee;
        emit ExitFeeUpdated(fee);
    }

    /// @inheritdoc ILiquidTransmuter
    function setTransmutationTime(uint256 time) external onlyAdmin {
        timeToTransmute = time;

        emit TransmutationTimeUpdated(time);
    }

    /// @inheritdoc ILiquidTransmuter
    function setProtocolFeeReceiver(address value) external onlyAdmin {
        _checkArgument(value != address(0));
        protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        // revert if the token does not exist
        ERC721(address(this)).ownerOf(id);
        return NFTMetadataGenerator.generateTokenURI(id, "Transmuter V3 Position");
    }

    /// @inheritdoc ILiquidTransmuter
    function getPosition(uint256 id) external view returns (StakingPosition memory) {
        return _positions[id];
    }

    /// @inheritdoc ILiquidTransmuter
    function createRedemption(uint256 syntheticDepositAmount) external nonReentrant {
        if (syntheticDepositAmount == 0) {
            revert DepositZeroAmount();
        }

        if (totalLocked + syntheticDepositAmount > depositCap) {
            revert DepositCapReached();
        }

        if (totalLocked + syntheticDepositAmount > liquid.totalSyntheticsIssued()) {
            revert DepositCapReached();
        }

        TokenUtils.safeTransferFrom(syntheticToken, msg.sender, address(this), syntheticDepositAmount);

        _positions[++_nonce] = StakingPosition(syntheticDepositAmount, block.number, block.number + timeToTransmute);

        // Update Fenwick Tree
        _updateStakingGraph(syntheticDepositAmount.toInt256() * BLOCK_SCALING_FACTOR / timeToTransmute.toInt256(), timeToTransmute);

        totalLocked += syntheticDepositAmount;

        _mint(msg.sender, _nonce);

        emit PositionCreated(msg.sender, syntheticDepositAmount, _nonce);
    }

    /// @inheritdoc ILiquidTransmuter
    function claimRedemption(uint256 id) external nonReentrant {
        StakingPosition storage position = _positions[id];

        if (position.maturationBlock == 0) {
            revert PositionNotFound();
        }

        if (position.startBlock == block.number) {
            revert PrematureClaim();
        }

        uint256 transmutationTime = position.maturationBlock - position.startBlock;
        uint256 blocksLeft = position.maturationBlock > block.number ? position.maturationBlock - block.number : 0;
        uint256 rounded = position.amount * blocksLeft / transmutationTime + (position.amount * blocksLeft % transmutationTime == 0 ? 0 : 1);
        uint256 amountNottransmuted = blocksLeft > 0 ? rounded : 0;
        uint256 amountTransmuted = position.amount - amountNottransmuted;

        if (_requireOwned(id) != msg.sender) {
            revert CallerNotOwner();
        }

        // Burn position NFT
        _burn(id);

        // Synthetics issued against the underlying value backing them. Above 1.0
        // the protocol owes more than it holds, and the shortfall is shared by
        // scaling back what each claim is worth.
        //
        // Both sides must be in the same units for the 1.0 comparison to mean
        // anything: the collateral total is denominated in underlying tokens,
        // the synthetics in debt tokens, and for a market like bridged BTC (8dp)
        // against LBTC (18dp) those differ by ten orders of magnitude. Normalize
        // the collateral into debt units first, then take the ratio in 1e18.
        //
        // Rounded up, so a rounding remainder registers as bad debt rather than
        // disappearing -- the haircut may be a hair too deep, never too shallow.
        uint256 yieldTokenBalance = TokenUtils.safeBalanceOf(liquid.yieldToken(), address(this));
        uint256 backing = liquid.normalizeUnderlyingTokensToDebt(liquid.getTotalUnderlyingValue() + liquid.convertYieldTokensToUnderlying(yieldTokenBalance));
        // Avoid divide by 0
        if (backing == 0) backing = 1;
        uint256 issued = liquid.totalSyntheticsIssued();
        uint256 badDebtRatio = (issued * FIXED_POINT_SCALAR + backing - 1) / backing;

        uint256 scaledTransmuted = amountTransmuted;

        if (badDebtRatio > FIXED_POINT_SCALAR) {
            scaledTransmuted = amountTransmuted * FIXED_POINT_SCALAR / badDebtRatio;
        }

        // If the contract has a balance of yield tokens from liquid repayments then we only need to redeem partial or none from Liquid earmarked
        uint256 debtValue = liquid.convertYieldTokensToDebt(yieldTokenBalance);
        uint256 amountToRedeem = scaledTransmuted > debtValue ? scaledTransmuted - debtValue : 0;

        if (amountToRedeem > 0) liquid.redeem(amountToRedeem);

        uint256 totalYield = liquid.convertDebtTokensToYield(scaledTransmuted);

        // Cap to what we actually hold now (handles redeem() rounding shortfalls).
        uint256 balAfterRedeem = TokenUtils.safeBalanceOf(liquid.yieldToken(), address(this));
        uint256 distributable = totalYield <= balAfterRedeem ? totalYield : balAfterRedeem;

        // Whatever the payout fell short of is synthetic the claimant was never
        // paid for. It goes back to them rather than into the burn: the bad-debt
        // haircut above is a loss they are meant to bear, a liquidity shortfall
        // here is not, and burning through it would destroy the claim silently
        // along with the position.
        uint256 unpaid;
        if (distributable < totalYield) {
            unpaid = liquid.convertYieldTokensToDebt(totalYield - distributable);
            if (unpaid > amountTransmuted) unpaid = amountTransmuted;
        }
        uint256 toBurn = amountTransmuted - unpaid;

        // Split distributable amount. Round fee down; claimant gets the remainder.
        uint256 feeYield = distributable * transmutationFee / BPS;
        uint256 claimYield = distributable - feeYield;

        uint256 syntheticFee = amountNottransmuted * exitFee / BPS;
        uint256 syntheticReturned = amountNottransmuted - syntheticFee + unpaid;

        // Remove untransmuted amount from the staking graph
        if (blocksLeft > 0) _updateStakingGraph(-position.amount.toInt256() * BLOCK_SCALING_FACTOR / transmutationTime.toInt256(), blocksLeft);

        TokenUtils.safeTransfer(liquid.yieldToken(), msg.sender, claimYield);
        TokenUtils.safeTransfer(liquid.yieldToken(), protocolFeeReceiver, feeYield);

        TokenUtils.safeTransfer(syntheticToken, msg.sender, syntheticReturned);
        TokenUtils.safeTransfer(syntheticToken, protocolFeeReceiver, syntheticFee);

        // Burn remaining synths that were not returned
        TokenUtils.safeBurn(syntheticToken, toBurn);
        liquid.reduceSyntheticsIssued(toBurn);
        liquid.setTransmuterTokenBalance(TokenUtils.safeBalanceOf(liquid.yieldToken(), address(this)));

        totalLocked -= position.amount;

        emit PositionClaimed(msg.sender, claimYield, syntheticReturned);

        delete _positions[id];
    }

    /// @inheritdoc ILiquidTransmuter
    function queryGraph(uint256 startBlock, uint256 endBlock) external view returns (uint256) {
        int256 queried = _stakingGraph.queryStake(startBlock, endBlock);

        if (queried == 0) return 0;
        // + 1 for rounding error
        return (queried / BLOCK_SCALING_FACTOR).toUint256() + 1;
    }

    /// @dev Updates staking graphs
    function _updateStakingGraph(int256 amount, uint256 blocks) private {
        _stakingGraph.addStake(amount, block.number, blocks);
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
}
