// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {TokenHolder_v2, ITokenHolder} from "@bao/TokenHolder_v2.sol";
import {Token} from "@bao/Token.sol";

import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardDistributor_v3} from "@harbor/interfaces/IMultipleRewardDistributor_v3.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IYieldVaultManager} from "@harbor/interfaces/IYieldVaultManager.sol";
import {IYieldVault} from "@harbor/interfaces/IYieldVault.sol";

/// @title StabilityPoolManager_v2
/// @author Based on original Liquidator and Harvester contracts
/// @notice Manages stability pools for rebalancing and harvesting operations.
///         Extends v1 with yield-vault integration: after each harvest() or rebalance(), compound() is triggered
///         on every registered yield vault (see IYieldVaultManager).
/// @dev Uses UUPS proxy, erc7201 storage (same slot as v1 — struct extended safely).
/// @custom:oz-upgrades-from src/minter/StabilityPoolManager_v1.sol:StabilityPoolManager_v1
// solhint-disable-next-line contract-name-capwords
contract StabilityPoolManager_v2 is
    Initializable,
    UUPSUpgradeable,
    HarborOwnableRoles,
    ERC165Upgradeable,
    TokenHolder_v2,
    IStabilityPoolManager_v2,
    IYieldVaultManager
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

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
        /// @notice The receiver of the harvest cut and the no-pool catch-all. Seeded to the owner at initialize,
        /// retargetable via updateFeeReceiver, and never zero.
        // @custom:security non-reentrant
        address feeReceiver;
        /// @notice Gross harvest yield owed to the collateral pool but not yet streamed - deferred past its per-period
        /// reward capacity. Tracked per pool so a deferred backlog is never re-split to the other pool; pre-skim, so
        /// the bounty and cut are taken when the value is actually streamed to the pool, not when it is owed.
        uint256 owedCollateral;
        /// @notice Gross harvest yield owed to the leveraged pool but not yet streamed (see `owedCollateral`).
        uint256 owedLeveraged;
        /// @notice The set of registered yield vaults, each compounded after every harvest and rebalance.
        EnumerableSet.AddressSet yieldVaults;
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
    constructor(address minter_, address stabilityPoolCollateral, address stabilityPoolLeveraged) {
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

        // Validate and store the stability pools
        Token.ensureContract(stabilityPoolCollateral);
        // slither-disable-next-line missing-zero-check
        _STABILITY_POOL_COLLATERAL = stabilityPoolCollateral;
        Token.ensureContract(stabilityPoolLeveraged);
        // slither-disable-next-line missing-zero-check
        _STABILITY_POOL_LEVERAGED = stabilityPoolLeveraged;
    }

    /// @notice Initialize the contract with starting configuration
    /// @param deployerOwner_ The initial owner used for setup (the deployer); it must complete the transfer to
    ///        `pendingOwner_` within the hour (HarborOwnable two-step).
    /// @param pendingOwner_ The address eligible to complete the ownership transfer - the final owner.
    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
        __UUPSUpgradeable_init();
        __ERC165_init();
        // Seed the cut receiver with the final owner - pendingOwner_ (or deployerOwner_ if there is no pending
        // transfer), never owner() which is the temporary deployer during initialize. updateFeeReceiver retargets it
        // later; both paths keep it non-zero.
        _getStabilityPoolManagerStorage().feeReceiver = pendingOwner_ != address(0) ? pendingOwner_ : deployerOwner_;
    }

    /// @notice The check that allows this contract to be upgraded
    /// @dev In UUPS proxies the implementation is responsible for upgrading itself
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(HarborOwnableRoles, ERC165Upgradeable) returns (bool) {
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

    /// @inheritdoc IYieldVaultManager
    function yieldVault(uint256 index) external view override returns (address) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return $.yieldVaults.at(index);
    }

    /// @inheritdoc IYieldVaultManager
    function yieldVaultCount() external view override returns (uint256) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return $.yieldVaults.length();
    }

    /// @inheritdoc IYieldVaultManager
    function addYieldVault(address yieldVault_) external override onlyOwner {
        if (yieldVault_ == address(0)) {
            revert InvalidYieldVault(yieldVault_);
        }
        // add() returns false if already present, so a duplicate is rejected rather than double-compounded
        if (!_getStabilityPoolManagerStorage().yieldVaults.add(yieldVault_)) {
            revert InvalidYieldVault(yieldVault_);
        }
        emit YieldVaultAdded(yieldVault_);
    }

    /// @inheritdoc IYieldVaultManager
    function removeYieldVault(address yieldVault_) external override onlyOwner {
        // remove() returns false if not present
        if (!_getStabilityPoolManagerStorage().yieldVaults.remove(yieldVault_)) {
            revert YieldVaultNotFound(yieldVault_);
        }
        emit YieldVaultRemoved(yieldVault_);
    }

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
        Token.ensureNonZeroAddress(feeReceiver_);
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        address old = $.feeReceiver;
        $.feeReceiver = feeReceiver_;
        emit UpdateFeeReceiver(old, feeReceiver_);
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

    /// @dev Trigger compound() on every registered yield vault. Failures (including NothingToCompound) are
    ///      non-fatal - the harvest/rebalance still completes - and a CompoundFailed event is emitted so off-chain
    ///      monitoring can detect and investigate them.
    function _compoundRegistered() private {
        address[] memory vaults = _getStabilityPoolManagerStorage().yieldVaults.values();
        for (uint256 i = 0; i < vaults.length; ++i) {
            address vault = vaults[i];
            // solhint-disable-next-line no-empty-blocks
            try IYieldVault(vault).compound() {} catch (bytes memory reason) {
                emit CompoundFailed(vault, reason);
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

        // Sweep the pegged backing from each pool into this manager. Each pool caps the sweep at its own solvency
        // headroom above MIN_TOTAL_ASSET_SUPPLY (StabilityPool.sweep), matching the write-down cap in its _notifyLoss,
        // so a pool may hand back less pegged than requested. Measure the balance delta around each sweep to learn
        // what was actually taken, and drive the redeem and notifications off those actuals - we must never redeem or
        // notify more pegged than we hold, or a pool would be left backing supply it no longer has.
        if (peggedForCollateral > 0) {
            uint256 peggedBefore = IERC20(PEGGED_TOKEN).balanceOf(address(this));
            ITokenHolder(_STABILITY_POOL_COLLATERAL).sweep(PEGGED_TOKEN, peggedForCollateral, address(this));
            peggedForCollateral = IERC20(PEGGED_TOKEN).balanceOf(address(this)) - peggedBefore;
        }
        if (peggedForLeveraged > 0) {
            uint256 peggedBefore = IERC20(PEGGED_TOKEN).balanceOf(address(this));
            ITokenHolder(_STABILITY_POOL_LEVERAGED).sweep(PEGGED_TOKEN, peggedForLeveraged, address(this));
            peggedForLeveraged = IERC20(PEGGED_TOKEN).balanceOf(address(this)) - peggedBefore;
        }
        peggedLiquidated = peggedForCollateral + peggedForLeveraged;

        // make sure we actually swept at least the minimum
        if (peggedLiquidated < minPeggedLiquidated) {
            revert InsufficientLiquidation(PEGGED_TOKEN, peggedLiquidated, minPeggedLiquidated);
        }

        uint256 rebalanceBountyRatio_ = $.rebalanceBountyRatio;

        // allow the minter to burn the pegged tokens I've just swept up, then liquidate them into the reward token:
        // * extract the bounty and transfer to the bounty receiver
        // * transfer the remainder to the stability pool, notifying it of that "reward"
        IERC20(PEGGED_TOKEN).safeIncreaseAllowance(MINTER, peggedLiquidated);
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
            IMultipleRewardDistributor_v3(pool).depositReward(WRAPPED_COLLATERAL_TOKEN, amount);
            IERC20(WRAPPED_COLLATERAL_TOKEN).forceApprove(pool, 0);
        }
    }

    /// @dev Split a pool's `owed` into the NET to deposit this harvest and the GROSS it consumes (net + its skim). The
    /// net is the owed's residual share `owed × residualRatio`, capped at the pool's remaining per-period reward
    /// capacity `maxDepositReward` (so `depositReward` cannot overflow the rate field); when capped, the net is that
    /// capacity EXACTLY and the gross is grossed back up from it. A net below one reward period - where its rate
    /// `net / REWARD_PERIOD_LENGTH` floors to zero and would only sit in `queued` - streams nothing, leaving the whole
    /// owed to accumulate rather than transferring dust. A full cut (`residualRatio == 0`) streams nothing to the pool,
    /// so the net is zero and the whole owed is consumed (swept and skimmed).
    function _streamAmounts(
        uint256 owed,
        address pool,
        uint256 residualRatio
    ) private view returns (uint256 gross, uint256 net) {
        if (residualRatio == 0) {
            return (owed, 0);
        }
        uint256 cap = IMultipleRewardDistributor_v3(pool).maxDepositReward(WRAPPED_COLLATERAL_TOKEN);
        net = Math.mulDiv(owed, residualRatio, 1 ether);
        if (net <= cap) {
            gross = owed; // the whole owed fits within one period's capacity
        } else {
            net = cap; // capped: deposit exactly one period's capacity, gross it back up for the skim
            gross = Math.mulDiv(cap, 1 ether, residualRatio);
        }
        if (net < IMultipleRewardDistributor_v3(pool).REWARD_PERIOD_LENGTH()) {
            return (0, 0); // sub-period net: the stream rate floors to zero, so defer the whole owed
        }
    }

    /// @inheritdoc IStabilityPoolManager
    // slither-disable-next-line reentrancy-no-eth
    function harvest(address bountyReceiver, uint256 minBounty) external nonReentrant returns (uint256 harvested) {
        if (bountyReceiver == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(bountyReceiver);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        uint256 harvestableAmount = IMinter(MINTER).harvestable();
        if (harvestableAmount == 0) {
            revert NoHarvestable();
        }
        uint256 residualRatio = 1 ether - $.harvestBountyRatio - $.harvestCutRatio;

        // Allocate the NEW yield - harvestable beyond what is already owed to the pools and still sitting in the minter
        // - to the pools by CURRENT holdings, GROSS (pre-skim), added to each pool's own `owed`. A pool's owed is its
        // own: a share deferred past one period's reward capacity is never re-split to the other pool, so a pool that
        // did not hold when it accrued never receives it. If the minter's excess has shrunk below what is owed (a
        // wrap-rate drop eroding it), write the owed down proportionally so it never claims more than the minter holds.
        uint256 toTreasuryGross;
        {
            uint256 owedBefore = $.owedCollateral + $.owedLeveraged;
            if (harvestableAmount < owedBefore) {
                $.owedCollateral = Math.mulDiv($.owedCollateral, harvestableAmount, owedBefore);
                $.owedLeveraged = harvestableAmount - $.owedCollateral;
            } else {
                uint256 newYield = harvestableAmount - owedBefore;
                (
                    uint256 totalPoolHolding,
                    uint256 poolHoldingCollateral,
                    uint256 poolHoldingLeveraged
                ) = _poolHoldings();
                if (totalPoolHolding > 0) {
                    // Floor BOTH shares; the split remainder (<= 1 wei) stays un-owed harvestable and is re-allocated
                    // next call by then-current holdings - fair, since it is new yield never attributed to a pool, and
                    // so neither pool is handed the remainder as a systematic advantage.
                    $.owedCollateral += Math.mulDiv(newYield, poolHoldingCollateral, totalPoolHolding);
                    $.owedLeveraged += Math.mulDiv(newYield, poolHoldingLeveraged, totalPoolHolding);
                } else {
                    toTreasuryGross = newYield; // no pools hold: the new yield goes to the treasury (no reward stream)
                }
            }
        }

        // Stream each pool's owed up to its remaining per-period capacity; the treasury takes its gross in full. The
        // bounty and cut are the exact ratio slices of the GROSS distributed this call - which equals what is swept
        // from the minter - so they are taken when the value reaches the pool, never on the deferred backlog, and a
        // bounty receiver's reward always matches the harvestable it consumed. The unprocessed owed and the sub-part
        // flooring remainder stay harvestable in the minter for a later call.
        (uint256 grossCollateral, uint256 netCollateral) = _streamAmounts(
            $.owedCollateral,
            _STABILITY_POOL_COLLATERAL,
            residualRatio
        );
        (uint256 grossLeveraged, uint256 netLeveraged) = _streamAmounts(
            $.owedLeveraged,
            _STABILITY_POOL_LEVERAGED,
            residualRatio
        );
        $.owedCollateral -= grossCollateral;
        $.owedLeveraged -= grossLeveraged;

        uint256 totalGross = grossCollateral + grossLeveraged + toTreasuryGross;
        uint256 bountyAmount = Math.mulDiv(totalGross, $.harvestBountyRatio, 1 ether);
        if (bountyAmount < minBounty) {
            revert InsufficientBounty(WRAPPED_COLLATERAL_TOKEN, bountyAmount, minBounty);
        }
        uint256 cutAmount = Math.mulDiv(totalGross, $.harvestCutRatio, 1 ether);
        // The treasury (used only when no pool holds, so it is the whole gross) is uncapped: it takes exactly the
        // remainder after the skim, leaving no dust - unlike a pool, whose sub-part flooring stays harvestable.
        uint256 netTreasury = toTreasuryGross == 0 ? 0 : toTreasuryGross - bountyAmount - cutAmount;

        harvested = bountyAmount + cutAmount + netCollateral + netLeveraged + netTreasury;
        if (harvested > 0) {
            ITokenHolder(MINTER).sweep(WRAPPED_COLLATERAL_TOKEN, harvested, address(this));
            if (bountyAmount > 0) {
                IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(bountyReceiver, bountyAmount);
            }
            if (cutAmount > 0) {
                IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer($.feeReceiver, cutAmount);
            }
            if (netTreasury > 0) {
                IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer($.feeReceiver, netTreasury);
            }
            _harvestToPool(netCollateral, _STABILITY_POOL_COLLATERAL);
            _harvestToPool(netLeveraged, _STABILITY_POOL_LEVERAGED);
        }

        emit Harvested(harvested);
        _compoundRegistered();
    }
}
