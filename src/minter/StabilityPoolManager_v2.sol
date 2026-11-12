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

import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IMultipleRewardDistributor_v3} from "@harbor/interfaces/IMultipleRewardDistributor_v3.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
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
        /// @notice The share of each rebalance payment paid to the rebalance's caller
        uint256 rebalanceBountyRatio;
        /// @notice The collateral ratio at which rebalancing should occur
        uint256 rebalanceThreshold;
        /// @notice Percentage-based bounty for harvesting (as a ratio of the harvested amount)
        uint256 harvestBountyRatio;
        /// @notice Percentage-based cut for harvesting (as a ratio of the harvested amount)
        uint256 harvestCutRatio;
        /// @notice The receiver of the harvest cut, the rebalance cut and the no-pool catch-all. Seeded to the owner at
        /// initialize, retargetable via updateFeeReceiver, and never zero.
        // @custom:security non-reentrant
        address feeReceiver;
        /// @notice Gross harvest yield owed to the collateral pool but not yet streamed - deferred past its
        /// `maxDepositReward`. Tracked per pool so a deferred backlog is never re-split to the other pool; pre-skim, so
        /// the bounty and cut are taken when the value is actually streamed to the pool, not when it is owed.
        uint256 owedCollateral;
        /// @notice Gross harvest yield owed to the leveraged pool but not yet streamed (see `owedCollateral`).
        uint256 owedLeveraged;
        /// @notice The set of registered yield vaults, each compounded after every harvest and rebalance.
        EnumerableSet.AddressSet yieldVaults;
        /// @notice The most a harvest pays its caller, in wrapped collateral; zero is no ceiling.
        uint256 harvestBountyCeiling;
        /// @notice The most a rebalance pays its caller in all, measured in wrapped collateral; zero is no ceiling.
        uint256 rebalanceBountyCeiling;
        /// @notice The share of each rebalance payment paid to the cut receiver.
        uint256 rebalanceCutRatio;
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
    /// @dev Calls no other contract, so the implementation deploys whatever state the minter, its tokens and the pools
    ///      are in - not yet deployed, or paused. The deploy checks they are this market's, and the tokens answer as
    ///      ERC-20s, once they and this contract all exist.
    /// @param minter_ The market's minter.
    /// @param wrappedCollateralToken_ The minter's wrapped collateral token.
    /// @param peggedToken_ The minter's pegged token.
    /// @param leveragedToken_ The minter's leveraged token.
    /// @param stabilityPoolCollateral The market's collateral stability pool.
    /// @param stabilityPoolLeveraged The market's leveraged stability pool.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address minter_,
        address wrappedCollateralToken_,
        address peggedToken_,
        address leveragedToken_,
        address stabilityPoolCollateral,
        address stabilityPoolLeveraged
    ) {
        _disableInitializers();

        Token.ensureNonZeroAddress(minter_);
        // slither-disable-next-line missing-zero-check
        MINTER = minter_;
        Token.ensureNonZeroAddress(wrappedCollateralToken_);
        // slither-disable-next-line missing-zero-check
        WRAPPED_COLLATERAL_TOKEN = wrappedCollateralToken_;
        Token.ensureNonZeroAddress(peggedToken_);
        // slither-disable-next-line missing-zero-check
        PEGGED_TOKEN = peggedToken_;
        Token.ensureNonZeroAddress(leveragedToken_);
        // slither-disable-next-line missing-zero-check
        LEVERAGED_TOKEN = leveragedToken_;
        Token.ensureNonZeroAddress(stabilityPoolCollateral);
        // slither-disable-next-line missing-zero-check
        _STABILITY_POOL_COLLATERAL = stabilityPoolCollateral;
        Token.ensureNonZeroAddress(stabilityPoolLeveraged);
        // slither-disable-next-line missing-zero-check
        _STABILITY_POOL_LEVERAGED = stabilityPoolLeveraged;
    }

    /// @notice Initialize the contract with starting configuration
    /// @param deployerOwner_ The initial owner used for setup (the deployer); it must complete the transfer to
    ///        `pendingOwner_` within the hour (HarborOwnable two-step).
    /// @param pendingOwner_ The address eligible to complete the ownership transfer - the final owner.
    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
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
            interfaceId == type(IStabilityPoolManager_v2).interfaceId ||
            interfaceId == type(IYieldVaultManager).interfaceId ||
            interfaceId == type(ITokenHolder).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /*************************
     * Public View Functions *
     *************************/

    /// @inheritdoc IStabilityPoolManager_v2
    function stabilityPools() external view returns (address[] memory pools) {
        pools = new address[](2);
        pools[0] = _STABILITY_POOL_COLLATERAL;
        pools[1] = _STABILITY_POOL_LEVERAGED;
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function hasStabilityPool(address stabilityPool) external view returns (bool) {
        return (_STABILITY_POOL_COLLATERAL == stabilityPool) || _STABILITY_POOL_LEVERAGED == stabilityPool;
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function harvestable() external view returns (uint256) {
        return IMinter_v3(MINTER).harvestable();
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function rebalanceable() external view returns (bool rebalanceable_) {
        (uint256 recorded, uint256 held) = IMinter_v3(MINTER).impairment();
        rebalanceable_ =
            IMinter_v3(MINTER).collateralRatio() < _getStabilityPoolManagerStorage().rebalanceThreshold &&
            recorded <= held &&
            recorded > 0 &&
            IMinter_v3(MINTER).peggedTokenBalance() > 0 &&
            (IStabilityPool_v3(_STABILITY_POOL_COLLATERAL).maxAssetLoss() > 0 ||
                IStabilityPool_v3(_STABILITY_POOL_LEVERAGED).maxAssetLoss() > 0);
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function harvestBountyRatio() external view returns (uint256 harvestBountyRatio_) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        harvestBountyRatio_ = $.harvestBountyRatio;
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function harvestCutRatio() external view returns (uint256 harvestCutRatio_) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        harvestCutRatio_ = $.harvestCutRatio;
    }
    /// @inheritdoc IStabilityPoolManager_v2
    function rebalanceBountyRatio() external view returns (uint256 rebalanceBountyRatio_) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        rebalanceBountyRatio_ = $.rebalanceBountyRatio;
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function rebalanceCutRatio() external view returns (uint256) {
        return _getStabilityPoolManagerStorage().rebalanceCutRatio;
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function harvestBountyCeiling() external view returns (uint256) {
        return _getStabilityPoolManagerStorage().harvestBountyCeiling;
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function rebalanceBountyCeiling() external view returns (uint256) {
        return _getStabilityPoolManagerStorage().rebalanceBountyCeiling;
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function rebalanceThreshold() external view returns (uint256) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return $.rebalanceThreshold;
    }

    /// @inheritdoc IStabilityPoolManager_v2
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

    /// @inheritdoc IStabilityPoolManager_v2
    function updateHarvestConfig(uint256 bountyRatio, uint256 bountyCeiling, uint256 cutRatio) external onlyOwner {
        // Each ratio is bounded on its own first, so the one that is out of range is the one reported and the sum
        // below cannot wrap. The terms are written whole, so there is no moment at which the stored pair is a split
        // harvest cannot make.
        if (bountyRatio > 1 ether) {
            revert InvalidHarvestBountyRatio(bountyRatio);
        }
        if (cutRatio > 1 ether) {
            revert InvalidHarvestCutRatio(cutRatio);
        }
        if (bountyRatio + cutRatio > 1 ether) {
            revert InvalidHarvestRatioSum(bountyRatio, cutRatio);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.harvestBountyRatio = bountyRatio;
        $.harvestBountyCeiling = bountyCeiling;
        $.harvestCutRatio = cutRatio;
        emit HarvestConfigUpdated(bountyRatio, bountyCeiling, cutRatio);
    }

    /// @inheritdoc IStabilityPoolManager_v2
    function updateRebalanceConfig(uint256 bountyRatio, uint256 bountyCeiling, uint256 cutRatio) external onlyOwner {
        // Bounded as the harvest's terms are, and for the same reasons.
        if (bountyRatio > 1 ether) {
            revert InvalidRebalanceBountyRatio(bountyRatio);
        }
        if (cutRatio > 1 ether) {
            revert InvalidRebalanceCutRatio(cutRatio);
        }
        if (bountyRatio + cutRatio > 1 ether) {
            revert InvalidRebalanceRatioSum(bountyRatio, cutRatio);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.rebalanceBountyRatio = bountyRatio;
        $.rebalanceBountyCeiling = bountyCeiling;
        $.rebalanceCutRatio = cutRatio;
        emit RebalanceConfigUpdated(bountyRatio, bountyCeiling, cutRatio);
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

    /// @dev What each pool has had deposited - its supply, never the pegged it holds, so pegged sent straight to a pool
    ///      moves no pool's share of a harvest or a rebalance.
    function _poolSupplies()
        private
        view
        returns (uint256 totalPoolSupply, uint256 collateralPoolSupply, uint256 leveragedPoolSupply)
    {
        collateralPoolSupply = IERC20(_STABILITY_POOL_COLLATERAL).totalSupply();
        leveragedPoolSupply = IERC20(_STABILITY_POOL_LEVERAGED).totalSupply();
        totalPoolSupply = collateralPoolSupply + leveragedPoolSupply;
    }

    /// @dev Trigger compound() on every registered yield vault. Failures (including NothingToCompound) are
    ///      non-fatal - the harvest/rebalance still completes - and a CompoundFailed event is emitted so off-chain
    ///      monitoring can detect and investigate them.
    function _compoundRegistered() private returns (uint256 totalCompounded) {
        address[] memory vaults = _getStabilityPoolManagerStorage().yieldVaults.values();
        for (uint256 i = 0; i < vaults.length; ++i) {
            address vault = vaults[i];
            // slither-disable-next-line calls-loop
            try IYieldVault(vault).compound() returns (uint256 compounded) {
                totalCompounded += compounded;
            } catch (bytes memory reason) {
                emit CompoundFailed(vault, reason);
            }
        }
    }

    /// @dev The terms one rebalance pays on, carried through its steps: the bounty and cut ratios, who receives each,
    ///      and each pool's remaining share of the rebalance bounty ceiling, in wrapped collateral - unbounded
    ///      (`type(uint256).max`) where no ceiling is set. Each pool's legs draw on its own share.
    struct RebalanceTerms {
        uint256 bountyRatio;
        uint256 cutRatio;
        address bountyReceiver;
        address cutReceiver;
        uint256 collateralPoolBudget;
        uint256 leveragedPoolBudget;
    }

    /// @inheritdoc IStabilityPoolManager_v2
    // slither-disable-next-line reentrancy-no-eth
    function rebalance(
        address bountyReceiver,
        uint256 minPeggedLiquidated
    ) external nonReentrant returns (uint256 peggedLiquidated) {
        if (bountyReceiver == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(bountyReceiver);
        }
        uint256 rebalanceThreshold_ = _getStabilityPoolManagerStorage().rebalanceThreshold;
        RebalanceTerms memory terms = RebalanceTerms({
            bountyRatio: _getStabilityPoolManagerStorage().rebalanceBountyRatio,
            cutRatio: _getStabilityPoolManagerStorage().rebalanceCutRatio,
            bountyReceiver: bountyReceiver,
            cutReceiver: _getStabilityPoolManagerStorage().feeReceiver,
            collateralPoolBudget: type(uint256).max,
            leveragedPoolBudget: type(uint256).max
        });
        {
            uint256 collateralRatio_ = IMinter_v3(MINTER).collateralRatio();
            if (collateralRatio_ >= rebalanceThreshold_) {
                revert CollateralRatioNotBelowRebalanceThreshold(collateralRatio_, rebalanceThreshold_);
            }
            (uint256 totalPoolSupply, uint256 collateralPoolSupply, uint256 leveragedPoolSupply) = _poolSupplies();
            // slither-disable-next-line incorrect-equality
            if (totalPoolSupply == 0) {
                revert NoTokensToLiquidate(PEGGED_TOKEN);
            }
            // The ceiling is shared between the pools by what each has had deposited when the rebalance starts, each
            // share floored, so the two together never exceed it. A share is its pool's alone: what its legs leave of
            // it does not pass to the other pool. A ceiling of zero is none.
            uint256 ceiling = _getStabilityPoolManagerStorage().rebalanceBountyCeiling;
            if (ceiling > 0) {
                terms.collateralPoolBudget = Math.mulDiv(ceiling, collateralPoolSupply, totalPoolSupply);
                terms.leveragedPoolBudget = Math.mulDiv(ceiling, leveragedPoolSupply, totalPoolSupply);
            }
        }
        uint256 collateralPaid;
        uint256 leveragedPaid;

        // Below the minter's floor it sells no leverage, so the leveraged pool cannot convert. Both pools' pegged take
        // the collateral route to the floor - or to the threshold, if that is lower - each pool its share of what the
        // two have had deposited, within the most it can give (`_maxPeggedFrom`), the excess sliding to the other. Both
        // are paid in collateral.
        // Where the backing is worth no more than the pegged the minter has minted - a ratio at or below the peg - no
        // amount reaches the floor: a pegged token redeems for its share of the backing and takes that share with it.
        // The minter then sizes all the pegged it has minted, so the step takes all of it the pools can give and does
        // not lift the ratio. A ratio that reads exactly the peg can hide backing worth more than the pegged by less
        // than the ratio's last digit. That market is above the peg: the step is sized to reach the floor, and leaves
        // only the dust of pegged that the excess backs there.
        if (!IMinter_v3(MINTER).leveragedMintable()) {
            uint256 peggedFromCollateralPool;
            uint256 peggedFromLeveragedPool;
            {
                uint256 maxFromCollateralPool = _maxPeggedFrom(_STABILITY_POOL_COLLATERAL, false);
                uint256 maxFromLeveragedPool = _maxPeggedFrom(_STABILITY_POOL_LEVERAGED, false);
                (uint256 totalPoolSupply, uint256 collateralPoolSupply, ) = _poolSupplies();
                // slither-disable-next-line unused-return the leveraged route is closed, so its leg is zero
                (uint256 pegged, ) = IMinter_v3(MINTER).redeemPeggedForCollateralRatio(
                    Math.min(IMinter_v3(MINTER).MINIMUM_COLLATERAL_RATIO(), rebalanceThreshold_),
                    maxFromCollateralPool + maxFromLeveragedPool,
                    0,
                    totalPoolSupply,
                    0
                );
                peggedFromCollateralPool = Math.min(
                    Math.mulDiv(pegged, collateralPoolSupply, totalPoolSupply),
                    maxFromCollateralPool
                );
                peggedFromLeveragedPool = pegged - peggedFromCollateralPool;
                if (peggedFromLeveragedPool > maxFromLeveragedPool) {
                    peggedFromLeveragedPool = maxFromLeveragedPool;
                    peggedFromCollateralPool = pegged - maxFromLeveragedPool;
                }
            }
            (peggedFromCollateralPool, peggedFromLeveragedPool) = _clampLegs(
                peggedFromCollateralPool,
                peggedFromLeveragedPool,
                true
            );
            (peggedLiquidated, collateralPaid, ) = _liquidate(
                peggedFromCollateralPool,
                peggedFromLeveragedPool,
                true,
                terms
            );
        }

        // At or above the floor - from the start, or once the step above has reached it - both legs to the threshold:
        // the collateral pool's pegged redeemed for collateral, the leveraged pool's converted into leveraged tokens.
        // The minter splits the distance between them by their supplies, each within the most its pool can give
        // (`_maxPeggedFrom`), the shortfall of one sliding into the other's leg.
        if (IMinter_v3(MINTER).leveragedMintable() && IMinter_v3(MINTER).collateralRatio() < rebalanceThreshold_) {
            (uint256 peggedFromCollateralPool, uint256 peggedFromLeveragedPool) = _legsTo(
                rebalanceThreshold_,
                _maxPeggedFrom(_STABILITY_POOL_COLLATERAL, false),
                _maxPeggedFrom(_STABILITY_POOL_LEVERAGED, true)
            );
            uint256 pegged;
            uint256 collateral;
            (pegged, collateral, leveragedPaid) = _liquidate(
                peggedFromCollateralPool,
                peggedFromLeveragedPool,
                false,
                terms
            );
            peggedLiquidated += pegged;
            collateralPaid += collateral;
        }

        // Nothing taken - both pools at their floors, none of the minter's pegged outstanding, or no leg that would be
        // paid anything - reverts by name rather than pass as a rebalance.
        // slither-disable-next-line incorrect-equality
        if (peggedLiquidated == 0) {
            revert NoTokensToLiquidate(PEGGED_TOKEN);
        }
        if (peggedLiquidated < minPeggedLiquidated) {
            revert InsufficientLiquidation(PEGGED_TOKEN, peggedLiquidated, minPeggedLiquidated);
        }
        emit Rebalanced(peggedLiquidated, collateralPaid, leveragedPaid);
        // slither-disable-next-line unused-return
        _compoundRegistered();
    }

    /// @dev The most pegged a leg may take from `pool`, given to the sizing so that each of the pool's two caps passes
    ///      its shortfall to the other pool: its `maxAssetLoss`, held within its `maxLiquidationReward`
    ///      (`_capLiquidation`). The payment is priced by a dry run of the leg - in leveraged tokens where
    ///      `paidInLeveraged`, in collateral otherwise - of no more than the minter has minted, as its dry run redeems
    ///      no more than that and would price a larger leg as that much. The minter prices each leg on its own, at one
    ///      rate floored once, so a leg of no more than this is paid no more than `maxLiquidationReward`.
    function _maxPeggedFrom(address pool, bool paidInLeveraged) private view returns (uint256 maxPegged) {
        maxPegged = Math.min(IStabilityPool_v3(pool).maxAssetLoss(), IMinter_v3(MINTER).peggedTokenBalance());
        // slither-disable-next-line incorrect-equality
        if (maxPegged == 0) {
            return 0;
        }
        uint256 payment;
        if (paidInLeveraged) {
            // slither-disable-next-line unused-return the leg is converted, so no collateral is paid for it
            (, payment) = IMinter_v3(MINTER).freeRedeemDryRun(0, maxPegged);
        } else {
            // slither-disable-next-line unused-return no pegged is converted, so no leveraged is minted
            (payment, ) = IMinter_v3(MINTER).freeRedeemDryRun(maxPegged, 0);
        }
        maxPegged = _capLiquidation(maxPegged, payment, pool);
    }

    /// @dev The legs of the step by both legs: what the minter sizes to lift the market to `target` with no more than
    ///      `maxFromCollateralPool` and `maxFromLeveragedPool` from the pools, weighted by their supplies, then clamped
    ///      (`_clampLegs`). A pool that may give pegged and yet is left with no leg, as when its leg would be paid
    ///      nothing, is sized out as a pool at its floor is: the legs are sized again with nothing from it. Where one
    ///      pool is left out, the other's leg then covers the distance where it can. Where both are, both are sized
    ///      out and nothing is taken. Each such pass takes a pool out, so there are at most two.
    function _legsTo(
        uint256 target,
        uint256 maxFromCollateralPool,
        uint256 maxFromLeveragedPool
    ) private view returns (uint256 peggedFromCollateralPool, uint256 peggedFromLeveragedPool) {
        (, uint256 collateralPoolSupply, uint256 leveragedPoolSupply) = _poolSupplies();
        (peggedFromCollateralPool, peggedFromLeveragedPool) = IMinter_v3(MINTER).redeemPeggedForCollateralRatio(
            target,
            maxFromCollateralPool,
            maxFromLeveragedPool,
            collateralPoolSupply,
            leveragedPoolSupply
        );
        (peggedFromCollateralPool, peggedFromLeveragedPool) = _clampLegs(
            peggedFromCollateralPool,
            peggedFromLeveragedPool,
            false
        );
        bool collateralPoolLeftOut = peggedFromCollateralPool == 0 && maxFromCollateralPool > 0;
        bool leveragedPoolLeftOut = peggedFromLeveragedPool == 0 && maxFromLeveragedPool > 0;
        if (collateralPoolLeftOut || leveragedPoolLeftOut) {
            (peggedFromCollateralPool, peggedFromLeveragedPool) = _legsTo(
                target,
                collateralPoolLeftOut ? 0 : maxFromCollateralPool,
                leveragedPoolLeftOut ? 0 : maxFromLeveragedPool
            );
        }
    }

    /// @dev Clamp one step's legs before anything is swept, so the swept, redeemed and notified pegged all agree. The
    ///      dry run gives each pool's proceeds. The minter reverts a redemption with a leg that would be paid nothing,
    ///      so such a leg is not taken: the one leg of the collateral route (`leveragedPoolPaidInCollateral`), where
    ///      nothing is then taken, or either leg of the two. Each pool's share is then held within its
    ///      `maxLiquidationReward` and its `maxAssetLoss` (`_capLiquidation`): pegged is burned in the redeem, so this
    ///      must precede it, and the dry run turns the proceeds bound into a pegged bound. The legs were sized within
    ///      both already (`_maxPeggedFrom`), so this cuts no leg paid on its own. Below the floor the two legs share
    ///      one payment, and a pool's share of it can be a wei over its own rate: that wei is cut here, and does not
    ///      slide.
    /// @return The pegged to take from the collateral pool and from the leveraged pool.
    function _clampLegs(
        uint256 peggedFromCollateralPool,
        uint256 peggedFromLeveragedPool,
        bool leveragedPoolPaidInCollateral
    ) private view returns (uint256, uint256) {
        uint256 previewForCollateralPool;
        uint256 previewForLeveragedPool;
        if (leveragedPoolPaidInCollateral) {
            uint256 pegged = peggedFromCollateralPool + peggedFromLeveragedPool;
            // slither-disable-next-line incorrect-equality
            if (pegged == 0) {
                return (0, 0);
            }
            // slither-disable-next-line unused-return no pegged is converted, so no leveraged is minted
            (uint256 collateralOut, ) = IMinter_v3(MINTER).freeRedeemDryRun(pegged, 0);
            // The two pools' pegged is one leg here. Where it would be paid nothing, nothing is taken.
            if (collateralOut == 0) {
                return (0, 0);
            }
            previewForCollateralPool = Math.mulDiv(collateralOut, peggedFromCollateralPool, pegged);
            previewForLeveragedPool = collateralOut - previewForCollateralPool;
        } else {
            (previewForCollateralPool, previewForLeveragedPool) = IMinter_v3(MINTER).freeRedeemDryRun(
                peggedFromCollateralPool,
                peggedFromLeveragedPool
            );
            // Each pool's pegged is its own leg here. A leg that would be paid nothing is not taken, so a pool with
            // too little above its floor to be paid a wei does not stop the other pool's leg.
            if (previewForCollateralPool == 0) {
                peggedFromCollateralPool = 0;
            }
            if (previewForLeveragedPool == 0) {
                peggedFromLeveragedPool = 0;
            }
        }
        return (
            _capLiquidation(peggedFromCollateralPool, previewForCollateralPool, _STABILITY_POOL_COLLATERAL),
            _capLiquidation(peggedFromLeveragedPool, previewForLeveragedPool, _STABILITY_POOL_LEVERAGED)
        );
    }

    /// @dev One step of a rebalance: take the clamped legs `peggedFromCollateralPool` and `peggedFromLeveragedPool`
    ///      from the two pools, redeem them, and pay each pool - less the keeper's bounty ratio of each payment, within
    ///      the pool's share of the ceiling in `terms`, and the cut receiver's cut ratio of it. With
    ///      `leveragedPoolPaidInCollateral` both pools' pegged take the collateral route and the collateral is shared
    ///      between them in proportion to the pegged each gave up; without it the leveraged pool's pegged is converted
    ///      and the pool is paid in leveraged tokens.
    /// @return peggedLiquidated The pegged actually taken from the two pools.
    /// @return collateralPaid The collateral paid to the pools, after the bounty and the cut.
    /// @return leveragedPaid The leveraged tokens paid to the leveraged pool, after the bounty and the cut.
    function _liquidate(
        uint256 peggedFromCollateralPool,
        uint256 peggedFromLeveragedPool,
        bool leveragedPoolPaidInCollateral,
        RebalanceTerms memory terms
    ) private returns (uint256 peggedLiquidated, uint256 collateralPaid, uint256 leveragedPaid) {
        // The redeem and the payments run on what the sweeps actually took, never more pegged than is held, or a pool
        // would be left backing supply it no longer has.
        peggedFromCollateralPool = _sweepPegged(_STABILITY_POOL_COLLATERAL, peggedFromCollateralPool);
        peggedFromLeveragedPool = _sweepPegged(_STABILITY_POOL_LEVERAGED, peggedFromLeveragedPool);
        peggedLiquidated = peggedFromCollateralPool + peggedFromLeveragedPool;
        // slither-disable-next-line incorrect-equality
        if (peggedLiquidated == 0) {
            return (0, 0, 0);
        }

        IERC20(PEGGED_TOKEN).safeIncreaseAllowance(MINTER, peggedLiquidated);
        if (leveragedPoolPaidInCollateral) {
            // slither-disable-next-line unused-return no pegged is converted, so no leveraged is minted
            (uint256 collateralOut, ) = IMinter_v3(MINTER).freeRedeemPeggedToken(peggedLiquidated, 0, address(this));
            uint256 forCollateralPool = Math.mulDiv(collateralOut, peggedFromCollateralPool, peggedLiquidated);
            uint256 forLeveragedPool = collateralOut - forCollateralPool;
            collateralPaid = _payPool(
                _STABILITY_POOL_COLLATERAL,
                WRAPPED_COLLATERAL_TOKEN,
                peggedFromCollateralPool,
                forCollateralPool,
                forCollateralPool,
                terms
            );
            collateralPaid += _payPool(
                _STABILITY_POOL_LEVERAGED,
                WRAPPED_COLLATERAL_TOKEN,
                peggedFromLeveragedPool,
                forLeveragedPool,
                forLeveragedPool,
                terms
            );
        } else {
            // The collateral the leveraged pool's payment stands for, by which the ceiling measures it: what the pool's
            // pegged would redeem for by the collateral route, at the market the conversion is priced on - the
            // collateral its leveraged tokens are minted for. Read only where a ceiling applies.
            uint256 leveragedAsCollateral;
            if (terms.leveragedPoolBudget != type(uint256).max) {
                // slither-disable-next-line unused-return no pegged is converted, so no leveraged is minted
                (leveragedAsCollateral, ) = IMinter_v3(MINTER).freeRedeemDryRun(peggedFromLeveragedPool, 0);
            }
            (uint256 collateralOut, uint256 leveragedOut) = IMinter_v3(MINTER).freeRedeemPeggedToken(
                peggedFromCollateralPool,
                peggedFromLeveragedPool,
                address(this)
            );
            collateralPaid = _payPool(
                _STABILITY_POOL_COLLATERAL,
                WRAPPED_COLLATERAL_TOKEN,
                peggedFromCollateralPool,
                collateralOut,
                collateralOut,
                terms
            );
            leveragedPaid = _payPool(
                _STABILITY_POOL_LEVERAGED,
                LEVERAGED_TOKEN,
                peggedFromLeveragedPool,
                leveragedOut,
                leveragedAsCollateral,
                terms
            );
        }
    }

    /// @dev Sweep up to `pegged` of `pool`'s pegged into this manager, returning what was actually taken: a pool caps
    ///      the sweep at its `maxAssetLoss()`, the same cap its loss write-down applies, so it may hand back
    ///      less than asked.
    function _sweepPegged(address pool, uint256 pegged) private returns (uint256 taken) {
        // slither-disable-next-line incorrect-equality
        if (pegged == 0) {
            return 0;
        }
        uint256 peggedBefore = IERC20(PEGGED_TOKEN).balanceOf(address(this));
        ITokenHolder(pool).sweep(PEGGED_TOKEN, pegged, address(this));
        taken = IERC20(PEGGED_TOKEN).balanceOf(address(this)) - peggedBefore;
    }

    /// @dev Pay `pool` for the `pegged` it gave up, out of `proceeds` of `token`: the keeper its bounty ratio, the cut
    ///      receiver its cut ratio, the pool the rest - credited to its holders at once by `notifyLiquidation`, which
    ///      also writes the loss off their deposits. The bounty alone draws on the pool's budget in `terms`, its share
    ///      of the rebalance bounty ceiling in wrapped collateral, measured as the collateral the payment stands for:
    ///      `collateralRepresented` is the collateral `proceeds` is, or was minted for, so a bounty is worth its share
    ///      of it. The bounty is reduced to what the budget buys at that rate, and the budget falls by the worth of the
    ///      bounty paid, rounded up, for the pool's later legs. What the budget withholds stays with the pool.
    /// @return paid What the pool was paid, after the bounty and the cut.
    function _payPool(
        address pool,
        address token,
        uint256 pegged,
        uint256 proceeds,
        uint256 collateralRepresented,
        RebalanceTerms memory terms
    ) private returns (uint256 paid) {
        // slither-disable-next-line incorrect-equality
        if (pegged == 0) {
            return 0;
        }
        uint256 bounty = (proceeds * terms.bountyRatio) / 1 ether;
        uint256 cut = (proceeds * terms.cutRatio) / 1 ether;
        bool collateralPool = pool == _STABILITY_POOL_COLLATERAL;
        uint256 budget = collateralPool ? terms.collateralPoolBudget : terms.leveragedPoolBudget;
        // A payment that stands for less than a wei of collateral has no measure against the budget, and cannot exceed
        // it.
        if (budget != type(uint256).max && bounty > 0 && collateralRepresented > 0) {
            uint256 cap = Math.mulDiv(budget, proceeds, collateralRepresented);
            if (bounty > cap) {
                bounty = cap;
            }
            budget -= Math.mulDiv(bounty, collateralRepresented, proceeds, Math.Rounding.Ceil);
            if (collateralPool) {
                terms.collateralPoolBudget = budget;
            } else {
                terms.leveragedPoolBudget = budget;
            }
        }
        paid = proceeds - bounty - cut;
        IERC20(token).safeTransfer(terms.bountyReceiver, bounty);
        if (cut > 0) {
            IERC20(token).safeTransfer(terms.cutReceiver, cut);
        }
        IERC20(token).safeTransfer(pool, paid);
        IStabilityPool_v3(pool).notifyLiquidation(token, pegged, paid);
    }

    /// @dev Clamp a liquidation leg's pegged amount to what `pool` will honour, given the redeem's previewed `returned`
    ///      proceeds for that leg. Two bounds: `maxLiquidationReward` (the proceeds are distributed immediately as the
    ///      pool's reward and must not overflow the reward integral; scale the pegged down so the linear proceeds land
    ///      at the cap) and `maxAssetLoss` (a loss may take the pool only to its MIN floor). The pool enforces both
    ///      itself, later - its reward path can revert on overflow, its loss path caps inside `_capToFloor` - so
    ///      applying them here first sizes the sweep to what the pool accepts. Applied to the most a pool may give,
    ///      before the sizing (`_maxPeggedFrom`), and to each leg after it (`_clampLegs`).
    function _capLiquidation(uint256 pegged, uint256 returned, address pool) private view returns (uint256) {
        // slither-disable-next-line incorrect-equality avoids divide by 0
        if (pegged == 0) {
            return 0;
        }
        uint256 maxReward = IMultipleRewardAccumulator_v3(pool).maxLiquidationReward();
        if (returned > maxReward) {
            pegged = Math.mulDiv(pegged, maxReward, returned);
        }
        uint256 maxLoss = IStabilityPool_v3(pool).maxAssetLoss();
        if (pegged > maxLoss) {
            pegged = maxLoss;
        }
        return pegged;
    }

    function _harvestToPool(uint256 amount, address pool) private {
        if (amount > 0) {
            IERC20(WRAPPED_COLLATERAL_TOKEN).forceApprove(pool, amount);
            IMultipleRewardDistributor_v3(pool).depositReward(WRAPPED_COLLATERAL_TOKEN, amount);
            IERC20(WRAPPED_COLLATERAL_TOKEN).forceApprove(pool, 0);
        }
    }

    /// @dev Split a pool's `owed` into the NET to deposit this harvest and the GROSS it consumes (net + its skim). The
    /// net is the owed's residual share `owed × residualRatio`, capped at the pool's `maxDepositReward` (so
    /// `depositReward` cannot overflow the rate field); when capped, the net is `maxDepositReward` EXACTLY and the
    /// gross is grossed back up from it. A net below one reward period - where its rate `net / REWARD_PERIOD_LENGTH`
    /// floors to zero and would only sit in `queued` - streams nothing, leaving the whole owed to accumulate rather
    /// than transferring dust. A full cut (`residualRatio == 0`) streams nothing to the pool, so the net is zero and
    /// the whole owed is consumed (swept and skimmed).
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
            gross = owed; // the whole owed fits within `maxDepositReward`
        } else {
            net = cap; // capped: deposit exactly `maxDepositReward`, gross it back up for the skim
            gross = Math.mulDiv(cap, 1 ether, residualRatio);
        }
        if (net < IMultipleRewardDistributor_v3(pool).REWARD_PERIOD_LENGTH()) {
            return (0, 0); // sub-period net: the stream rate floors to zero, so defer the whole owed
        }
    }

    /// @inheritdoc IStabilityPoolManager_v2
    // slither-disable-next-line reentrancy-no-eth
    function harvest(address bountyReceiver, uint256 minBounty) external nonReentrant returns (uint256 harvested) {
        if (bountyReceiver == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(bountyReceiver);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        uint256 harvestableAmount = IMinter_v3(MINTER).harvestable();
        uint256 residualRatio = 1 ether - $.harvestBountyRatio - $.harvestCutRatio;

        // Allocate the NEW yield - harvestable beyond what is already owed to the pools and still sitting in the minter
        // - to the pools by CURRENT supply, GROSS (pre-skim), added to each pool's own `owed`. A pool's owed is its
        // own: a share deferred past the pool's `maxDepositReward` is never re-split to the other pool, so a pool that
        // had no deposit when it accrued never receives it. If the minter's excess has shrunk below what is owed (a
        // wrap-rate drop eroding it), write the owed down proportionally so it never claims more than the minter holds.
        uint256 toTreasuryGross;
        {
            uint256 owedBefore = $.owedCollateral + $.owedLeveraged;
            if (harvestableAmount < owedBefore) {
                // the minter's excess shrank below the total owed - write EACH pool's owed down by its OWN floored
                // share (symmetric with the new-yield split), so neither pool is handed the rounding remainder
                $.owedCollateral = Math.mulDiv($.owedCollateral, harvestableAmount, owedBefore);
                $.owedLeveraged = Math.mulDiv($.owedLeveraged, harvestableAmount, owedBefore);
            } else {
                uint256 newYield = harvestableAmount - owedBefore;
                (uint256 totalPoolSupply, uint256 collateralPoolSupply, uint256 leveragedPoolSupply) = _poolSupplies();
                if (totalPoolSupply > 0) {
                    // Floor BOTH shares; the split remainder (<= 1 wei) stays un-owed harvestable and is re-allocated
                    // next call by then-current supply - fair, since it is new yield never attributed to a pool, and
                    // so neither pool is handed the remainder as a systematic advantage.
                    $.owedCollateral += Math.mulDiv(newYield, collateralPoolSupply, totalPoolSupply);
                    $.owedLeveraged += Math.mulDiv(newYield, leveragedPoolSupply, totalPoolSupply);
                } else {
                    toTreasuryGross = newYield; // no deposits: the new yield goes to the treasury (no reward stream)
                }
            }
        }

        // Stream each pool's owed up to its `maxDepositReward`; the treasury takes its gross in full. The bounty and
        // cut are the exact ratio slices of the GROSS distributed this call - which equals what is swept from the
        // minter - so they are taken when the value reaches the pool, never on the deferred backlog, and a bounty
        // receiver's reward always matches the harvestable it consumed. The unprocessed owed and the sub-part flooring
        // remainder stay harvestable in the minter for a later call.
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
        uint256 cutAmount = Math.mulDiv(totalGross, $.harvestCutRatio, 1 ether);
        // The bounty ceiling: the caller is paid at most the ceiling, and the rest of the ratio's slice goes to the cut
        // receiver with the cut, so the pools' net and the harvest's total are as without one. A ceiling of zero is
        // none.
        {
            uint256 ceiling = $.harvestBountyCeiling;
            if (ceiling > 0 && bountyAmount > ceiling) {
                cutAmount += bountyAmount - ceiling;
                bountyAmount = ceiling;
            }
        }
        if (bountyAmount < minBounty) {
            revert InsufficientBounty(WRAPPED_COLLATERAL_TOKEN, bountyAmount, minBounty);
        }
        // The treasury (used only when no pool holds, so its gross is the whole gross) takes its OWN floored residual
        // share - like every other party, on its own base - so a flooring remainder is left unharvested rather than
        // handed to the treasury as a complement. mulDiv of a zero gross is zero, so no special case is needed.
        uint256 netTreasury = Math.mulDiv(toTreasuryGross, residualRatio, 1 ether);

        // Every party takes exactly its own floored share (the two exact fee floors, each pool's floored net, the
        // treasury's floored residual); the flooring remainder is left un-owed and unharvested, re-considered next call
        // by then-current supply - no party is ever handed another's shortfall.
        harvested = bountyAmount + cutAmount + netCollateral + netLeveraged + netTreasury;
        // Nothing fairly harvestable this call (every share floored or deferred to zero) - revert so the owed write-down
        // or increment above is rolled back rather than emitting Harvested(0) and sweeping nothing. Ordered after the
        // minBounty check, so a non-zero minBounty surfaces the more specific InsufficientBounty first.
        // slither-disable-next-line incorrect-equality
        if (harvested == 0) {
            revert NoHarvestable();
        }
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

        emit Harvested(harvested);
        // slither-disable-next-line unused-return
        _compoundRegistered();
    }
}
