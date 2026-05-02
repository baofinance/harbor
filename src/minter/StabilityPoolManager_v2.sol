// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";
import {Token} from "@bao/Token.sol";

import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IAutoCompounder} from "@harbor/interfaces/IAutoCompounder.sol";

/// @title StabilityPoolManager_v2
/// @author Based on original Liquidator and Harvester contracts
/// @notice Manages stability pools for rebalancing and harvesting operations.
///         Extends v1 with auto-compounder integration: after each harvest() or rebalance(),
///         compound() is triggered on any registered AutoCompounder for each stability pool.
/// @dev Uses UUPS proxy, erc7201 storage (same slot as v1 — struct extended safely).
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-capwords
contract StabilityPoolManager_v2 is
    Initializable,
    UUPSUpgradeable,
    BaoOwnableRoles,
    ERC165Upgradeable,
    ReentrancyGuardTransientUpgradeable,
    IStabilityPoolManager_v2
{
    using SafeERC20 for IERC20;

    /*************
     * Variables *
     *************/

    // Immutable variables
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable PEGGED_TOKEN;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable WRAPPED_COLLATERAL_TOKEN;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable LEVERAGED_TOKEN;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable TREASURY;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable _STABILITY_POOL_COLLATERAL;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable _STABILITY_POOL_LEVERAGED;

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.StabilityPoolManager
    struct StabilityPoolManagerStorage {
        /// @notice Fixed bounty amount for rebalancing
        uint256 rebalanceBountyRatio;
        /// @notice The collateral ratio at which rebalancing should occur
        uint256 rebalanceThreshold;
        /// @notice Percentage-based bounty for harvesting (as a ratio of the harvested amount)
        uint256 harvestBountyRatio;
        /// @notice Percentage-based cut for harvesting (as a ratio of the harvested amount)
        uint256 harvestCutRatio;
        /// @notice The fee receiver that receives the harvest cut
        // @custom:security non-reentrant
        address feeReceiver;
        /// @notice Auto-compounder registered for each stability pool (0 = none).
        mapping(address sp => address ac) autoCompounder;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.StabilityPoolManager")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _STABILITYPOOL_MANAGER_STORAGE =
        0x3cb83b3e94c8a4ad8337f0089bb72418805efcd5c4adb4969513c1b21fc84100;

    function _getStabilityPoolManagerStorage() private pure returns (StabilityPoolManagerStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _STABILITYPOOL_MANAGER_STORAGE
        }
    }

    /// @notice In UUPS proxies the constructor sets immutables
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address minter_, address treasury_, address stabilityPoolCollateral, address stabilityPoolLeveraged) {
        _disableInitializers();

        Token.ensureContract(minter_);
        // slither-disable-next-line missing-zero-check
        MINTER = minter_;

        // slither-disable-next-line missing-zero-check
        PEGGED_TOKEN = IMinter(minter_).PEGGED_TOKEN();
        Token.sanityCheckERC20Token(PEGGED_TOKEN);

        // slither-disable-next-line missing-zero-check
        WRAPPED_COLLATERAL_TOKEN = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        Token.sanityCheckERC20Token(WRAPPED_COLLATERAL_TOKEN);

        // slither-disable-next-line missing-zero-check
        LEVERAGED_TOKEN = IMinter(minter_).LEVERAGED_TOKEN();
        Token.sanityCheckERC20Token(LEVERAGED_TOKEN);

        Token.ensureNonZeroAddress(treasury_);
        // slither-disable-next-line missing-zero-check
        TREASURY = treasury_;

        // Validate and store the stability pools
        Token.ensureContract(stabilityPoolCollateral);
        // slither-disable-next-line missing-zero-check
        _STABILITY_POOL_COLLATERAL = stabilityPoolCollateral;
        Token.ensureContract(stabilityPoolLeveraged);
        // slither-disable-next-line missing-zero-check
        _STABILITY_POOL_LEVERAGED = stabilityPoolLeveraged;
    }

    /// @notice Initialize the contract with starting configuration
    /// @param owner_ The owner address
    function initialize(address owner_) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __ERC165_init();
        __ReentrancyGuardTransient_init();
    }

    /// @notice The check that allows this contract to be upgraded
    /// @dev In UUPS proxies the implementation is responsible for upgrading itself
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaoOwnableRoles, ERC165Upgradeable) returns (bool) {
        return
            interfaceId == type(IStabilityPoolManager).interfaceId ||
            interfaceId == type(ITokenHolder).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /*************************
     * Public View Functions *
     *************************/

    /// @inheritdoc IStabilityPoolManager
    function stabilityPools() external view returns (address[] memory pools) {
        pools = new address[](2);
        pools[0] = _STABILITY_POOL_COLLATERAL;
        pools[1] = _STABILITY_POOL_LEVERAGED;
    }

    /// @inheritdoc IStabilityPoolManager
    function hasStabilityPool(address stabilityPool) external view returns (bool) {
        return (_STABILITY_POOL_COLLATERAL == stabilityPool) || _STABILITY_POOL_LEVERAGED == stabilityPool;
    }

    /// @inheritdoc IStabilityPoolManager
    function harvestable() external view returns (uint256) {
        return IMinter(MINTER).harvestable();
    }

    function _rebalanceable(
        uint256 collateralRatio,
        uint256 rebalanceThreshold_
    ) private pure returns (bool rebalanceable_) {
        // Check if collateral ratio is below the rebalance threshold
        rebalanceable_ = collateralRatio < rebalanceThreshold_;
    }

    /// @inheritdoc IStabilityPoolManager
    function rebalanceable() external view returns (bool rebalanceable_) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        rebalanceable_ = _rebalanceable(IMinter(MINTER).collateralRatio(), $.rebalanceThreshold);
    }

    /// @inheritdoc IStabilityPoolManager
    function harvestBountyRatio() external view returns (uint256 harvestBountyRatio_) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        harvestBountyRatio_ = $.harvestBountyRatio;
    }

    /// @inheritdoc IStabilityPoolManager
    function harvestCutRatio() external view returns (uint256 harvestCutRatio_) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        harvestCutRatio_ = $.harvestCutRatio;
    }
    /// @inheritdoc IStabilityPoolManager
    function rebalanceBountyRatio() external view returns (uint256 rebalanceBountyRatio_) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        rebalanceBountyRatio_ = $.rebalanceBountyRatio;
    }

    /// @inheritdoc IStabilityPoolManager
    function rebalanceThreshold() external view returns (uint256) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return $.rebalanceThreshold;
    }

    /// @inheritdoc IStabilityPoolManager
    function feeReceiver() external view override returns (address) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return $.feeReceiver;
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function autoCompounder(address sp) external view override returns (address) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return $.autoCompounder[sp];
    }

    /*************************
     * Admin Functions *
     *************************/

    /// @notice Updates the rebalance threshold collateral ratio
    /// @param newRatio The new rebalance threshold
    function updateRebalanceThreshold(uint256 newRatio) external onlyOwner {
        if (newRatio <= 1 ether) {
            revert InvalidRebalanceThreshold(newRatio);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.rebalanceThreshold = newRatio;

        emit RebalanceThresholdUpdated(newRatio);
    }

    /// @inheritdoc IStabilityPoolManager
    function updateRebalanceBountyRatio(uint256 rebalanceRatio_) external onlyOwner {
        if (rebalanceRatio_ > 1 ether) {
            revert InvalidRebalanceBountyRatio(rebalanceRatio_);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.rebalanceBountyRatio = rebalanceRatio_;

        emit RebalanceBountyUpdated(rebalanceRatio_);
    }

    /// @inheritdoc IStabilityPoolManager
    function updateHarvestBountyRatio(uint256 harvestRatio_) external onlyOwner {
        if (harvestRatio_ > 1 ether) {
            revert InvalidHarvestBountyRatio(harvestRatio_);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        if (harvestRatio_ + $.harvestCutRatio > 1 ether) {
            revert InvalidHarvestRatioSum(harvestRatio_, $.harvestCutRatio);
        }
        $.harvestBountyRatio = harvestRatio_;

        emit HarvestBountyUpdated(harvestRatio_);
    }

    /// @inheritdoc IStabilityPoolManager
    function updateHarvestCutRatio(uint256 harvestCutRatio_) external onlyOwner {
        if (harvestCutRatio_ > 1 ether) {
            revert InvalidHarvestBountyRatio(harvestCutRatio_);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        if ($.harvestBountyRatio + harvestCutRatio_ > 1 ether) {
            revert InvalidHarvestRatioSum($.harvestBountyRatio, harvestCutRatio_);
        }
        $.harvestCutRatio = harvestCutRatio_;

        emit HarvestCutUpdated(harvestCutRatio_);
    }

    function updateFeeReceiver(address feeReceiver_) external override onlyOwner {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        address old = $.feeReceiver;
        $.feeReceiver = feeReceiver_;
        emit UpdateFeeReceiver(old, feeReceiver_);
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function setAutoCompounder(address stabilityPool, address autoCompounder_) external override onlyOwner {
        if (stabilityPool != _STABILITY_POOL_COLLATERAL && stabilityPool != _STABILITY_POOL_LEVERAGED) {
            revert InvalidStabilityPool(stabilityPool);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.autoCompounder[stabilityPool] = autoCompounder_;
        emit AutoCompounderSet(stabilityPool, autoCompounder_);
    }

    /*************************
     * Core Functions *
     *************************/

    function _poolHoldings()
        private
        view
        returns (uint256 totalPoolHolding, uint256 poolHoldingCollateral, uint256 poolHoldingLeveraged)
    {
        poolHoldingCollateral = IERC20(PEGGED_TOKEN).balanceOf(_STABILITY_POOL_COLLATERAL);
        poolHoldingLeveraged = IERC20(PEGGED_TOKEN).balanceOf(_STABILITY_POOL_LEVERAGED);
        totalPoolHolding = poolHoldingCollateral + poolHoldingLeveraged;
    }

    /// @dev Trigger compound() on any registered auto-compounder for each stability pool.
    ///      Failures (including NothingToCompound) are non-fatal — harvest/rebalance still
    ///      completes. A CompoundFailed event is emitted so off-chain monitoring can detect
    ///      and investigate failures.
    function _compoundRegistered() private {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        address collateralAutoCompounder = $.autoCompounder[_STABILITY_POOL_COLLATERAL];
        address leveragedAutoCompounder = $.autoCompounder[_STABILITY_POOL_LEVERAGED];
        if (collateralAutoCompounder != address(0)) {
            // solhint-disable-next-line no-empty-blocks
            try IAutoCompounder(collateralAutoCompounder).compound() {} catch (bytes memory reason) {
                emit CompoundFailed(collateralAutoCompounder, reason);
            }
        }
        if (leveragedAutoCompounder != address(0)) {
            // solhint-disable-next-line no-empty-blocks
            try IAutoCompounder(leveragedAutoCompounder).compound() {} catch (bytes memory reason) {
                emit CompoundFailed(leveragedAutoCompounder, reason);
            }
        }
    }

    /// @inheritdoc IStabilityPoolManager
    // slither-disable-next-line reentrancy-no-eth
    function rebalance(
        address bountyReceiver,
        uint256 minPeggedLiquidated
    ) external nonReentrant returns (uint256 peggedLiquidated) {
        if (bountyReceiver == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(bountyReceiver);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        uint256 rebalanceThreshold_ = $.rebalanceThreshold;
        if (!_rebalanceable(IMinter(MINTER).collateralRatio(), rebalanceThreshold_)) {
            // it's an lower bound for non-rebalance mode
            revert CollateralRatioNotBelowRebalanceThreshold(IMinter(MINTER).collateralRatio(), rebalanceThreshold_);
        }

        // sum up the relative sizes of the stability pools - this is the pegged token holdings
        // note that these holdings are depleted by the liquidation process
        (uint256 totalPoolHolding, uint256 poolHoldingCollateral, uint256 poolHoldingLeveraged) = _poolHoldings();
        // slither-disable-next-line incorrect-equality
        if (totalPoolHolding == 0) {
            revert NoTokensToLiquidate(PEGGED_TOKEN);
        }

        // Get the amount of pegged tokens needed to be liquidated to reach target collateral ratio
        (uint256 peggedForCollateral, uint256 peggedForLeveraged) = IMinter(MINTER).redeemPeggedForCollateralRatio(
            rebalanceThreshold_
        );

        // Distribute between pools based on weighted holdings if both have tokens
        if (poolHoldingCollateral > 0 && poolHoldingLeveraged > 0) {
            // Weight each pool by its holdings, adjusting the leveraged pool by effectiveness
            uint256 weightedLeveraged = Math.mulDiv(poolHoldingLeveraged, peggedForCollateral, peggedForLeveraged);
            uint256 totalWeight = poolHoldingCollateral + weightedLeveraged;

            // Calculate the proportional contribution of each pool
            uint256 collateralLiquidationFraction = Math.mulDiv(poolHoldingCollateral, 1 ether, totalWeight);
            uint256 leveragedLiquidationFraction = 1 ether - collateralLiquidationFraction;

            // Apply the fractions to determine how much each pool should liquidate
            peggedForCollateral = Math.mulDiv(
                peggedForCollateral,
                collateralLiquidationFraction,
                1 ether,
                Math.Rounding.Ceil
            );

            peggedForLeveraged = Math.mulDiv(
                peggedForLeveraged,
                leveragedLiquidationFraction,
                1 ether,
                Math.Rounding.Ceil
            );
        }

        // Cap the liquidation amounts to what each pool actually holds
        peggedForCollateral = Math.min(peggedForCollateral, poolHoldingCollateral);
        peggedForLeveraged = Math.min(peggedForLeveraged, poolHoldingLeveraged);
        peggedLiquidated = peggedForCollateral + peggedForLeveraged;

        // make sure we're going to liquidate at least the minimum
        if (peggedLiquidated < minPeggedLiquidated) {
            revert InsufficientLiquidation(PEGGED_TOKEN, peggedLiquidated, minPeggedLiquidated);
        }

        // do the actual liquidation for each pool
        // * take the pegged tokens to be liquidated
        // * liquidate them into the other token (collateral/leveraged)
        // * extract the feed and transfer to the fee receiver
        // * transfer the remainder to the stability pool, notifying it of that "reward"

        uint256 rebalanceBountyRatio_ = $.rebalanceBountyRatio;

        // allow the minter to burn my pegged tokens I've just swept up
        IERC20(PEGGED_TOKEN).safeIncreaseAllowance(MINTER, peggedLiquidated);

        // sweep the pegged from each pool - this just snaffles the tokens, no accounting: that is done later
        if (peggedForCollateral > 0) {
            ITokenHolder(_STABILITY_POOL_COLLATERAL).sweep(PEGGED_TOKEN, peggedForCollateral, address(this));
        }
        if (peggedForLeveraged > 0) {
            ITokenHolder(_STABILITY_POOL_LEVERAGED).sweep(PEGGED_TOKEN, peggedForLeveraged, address(this));
        }

        // now liquidate the tokens to be liquidated for the reward
        (uint256 wrappedCollateralReturned, uint256 leveragedReturned) = IMinter(MINTER).freeRedeemPeggedToken(
            peggedForCollateral,
            peggedForLeveraged,
            address(this)
        );

        if (peggedForCollateral > 0) {
            // extract the collateral bounty
            uint256 collateralBounty = (wrappedCollateralReturned * rebalanceBountyRatio_) / 1 ether;
            wrappedCollateralReturned -= collateralBounty;
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(bountyReceiver, collateralBounty);
            // transfer the amounts and update the stability pool accounts
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(_STABILITY_POOL_COLLATERAL, wrappedCollateralReturned);
            IStabilityPool(_STABILITY_POOL_COLLATERAL).notifyLiquidation(
                peggedForCollateral,
                wrappedCollateralReturned
            );
        }
        if (peggedForLeveraged > 0) {
            // extract the leveraged bounty
            uint256 leveragedBounty = (leveragedReturned * rebalanceBountyRatio_) / 1 ether;
            leveragedReturned -= leveragedBounty;
            IERC20(LEVERAGED_TOKEN).safeTransfer(bountyReceiver, leveragedBounty);
            // transfer the amounts and update the stability pool accounts
            IERC20(LEVERAGED_TOKEN).safeTransfer(_STABILITY_POOL_LEVERAGED, leveragedReturned);
            IStabilityPool(_STABILITY_POOL_LEVERAGED).notifyLiquidation(peggedForLeveraged, leveragedReturned);
        }

        emit Rebalanced(peggedLiquidated, wrappedCollateralReturned, leveragedReturned);
        _compoundRegistered();
    }

    function _harvestToPool(uint256 amount, address pool) private {
        if (amount > 0) {
            IERC20(WRAPPED_COLLATERAL_TOKEN).forceApprove(pool, amount);
            IMultipleRewardDistributor(pool).depositReward(WRAPPED_COLLATERAL_TOKEN, amount);
            IERC20(WRAPPED_COLLATERAL_TOKEN).forceApprove(pool, 0);
        }
    }

    /// @inheritdoc IStabilityPoolManager
    // slither-disable-next-line reentrancy-no-eth
    function harvest(
        address bountyReceiver,
        uint256 minBounty
    ) external nonReentrant returns (uint256 harvestedAmount) {
        if (bountyReceiver == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(bountyReceiver);
        }
        // Check if there's anything to harvest
        uint256 harvestableAmount = IMinter(MINTER).harvestable();
        if (harvestableAmount == 0) {
            revert NoHarvestable();
        }
        uint256 harvestableRemaining = harvestableAmount;

        // Calculate bounty
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        uint256 bountyAmount = (harvestableAmount * $.harvestBountyRatio) / 1 ether;
        if (bountyAmount < minBounty) {
            revert InsufficientBounty(WRAPPED_COLLATERAL_TOKEN, bountyAmount, minBounty);
        }
        uint256 cutAmount = (harvestableAmount * $.harvestCutRatio) / 1 ether;

        // harvest everything - one loss recorded in stability pool (which is expensive in gas)
        ITokenHolder(MINTER).sweep(WRAPPED_COLLATERAL_TOKEN, harvestableAmount, address(this));

        // distribute the harvest deductions
        if (bountyAmount > 0) {
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(bountyReceiver, bountyAmount);
            harvestableRemaining -= bountyAmount;
        }
        if (cutAmount > 0) {
            address cutReceiver = $.feeReceiver == address(0) ? TREASURY : $.feeReceiver;
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(cutReceiver, cutAmount);
            harvestableRemaining -= cutAmount;
        }

        // Calculate total pool balances (similar to Harvester_v1)
        (uint256 totalPoolHolding, uint256 poolHoldingCollateral, ) = _poolHoldings();

        // Distribute proportionally based on current holdings
        if (totalPoolHolding > 0) {
            uint256 harvestedToCollateral = Math.mulDiv(harvestableRemaining, poolHoldingCollateral, totalPoolHolding);
            _harvestToPool(harvestedToCollateral, _STABILITY_POOL_COLLATERAL);
            _harvestToPool(harvestableRemaining - harvestedToCollateral, _STABILITY_POOL_LEVERAGED);
        } else {
            // Send to treasury if no pools have a balance
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(TREASURY, harvestableRemaining);
        }

        emit Harvested(harvestableAmount);
        _compoundRegistered();
        return harvestableAmount;
    }
}
