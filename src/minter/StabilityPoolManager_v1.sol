// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";
import {Token} from "@bao/Token.sol";

import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

/// @title StabilityPoolManager
/// @author Based on original Liquidator and Harvester contracts
/// @notice Manages stability pools for rebalancing and harvesting operations
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
contract StabilityPoolManager_v1 is
    Initializable,
    UUPSUpgradeable,
    BaoOwnableRoles,
    ERC165Upgradeable,
    ReentrancyGuardTransientUpgradeable,
    IStabilityPoolManager
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
    address private immutable STABILITY_POOL_COLLATERAL;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable STABILITY_POOL_LEVERAGED;

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.StabilityPoolManager
    struct StabilityPoolManagerStorage {
        /// @notice Fixed bounty amount for rebalancing
        uint256 rebalanceBountyRatio;
        uint256 rebalanceBountyToken;
        /// @notice The collateral ratio at which rebalancing should occur
        uint256 rebalanceThreshold;
        /// @notice Percentage-based bounty for harvesting (as a ratio of the harvested amount)
        uint256 harvestRatio;
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
        STABILITY_POOL_COLLATERAL = stabilityPoolCollateral;
        Token.ensureContract(stabilityPoolLeveraged);
        STABILITY_POOL_LEVERAGED = stabilityPoolLeveraged;
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
        pools[0] = STABILITY_POOL_COLLATERAL;
        pools[1] = STABILITY_POOL_LEVERAGED;
    }

    /// @inheritdoc IStabilityPoolManager
    function hasStabilityPool(address stabilityPool) external view returns (bool) {
        return (STABILITY_POOL_COLLATERAL == stabilityPool) || STABILITY_POOL_LEVERAGED == stabilityPool;
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
    function harvestBountyRatio() external view returns (uint256 harvestRatio) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        harvestRatio = $.harvestRatio;
    }

    function rebalanceBountyRatio() external view returns (uint256 rebalanceRatio) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        rebalanceRatio = $.rebalanceBountyRatio;
    }

    /// @notice Returns the collateral ratio at which rebalancing should occur
    /// @return The rebalance collateral ratio
    function rebalanceThreshold() external view returns (uint256) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return $.rebalanceThreshold;
    }

    /*************************
     * Admin Functions *
     *************************/

    /// @notice Updates the rebalance threshold collateral ratio
    /// @param newRatio The new rebalance threshold
    function setRebalanceThreshold(uint256 newRatio) external onlyOwner {
        if (newRatio < 1 ether) revert InvalidRebalanceThreshold(newRatio);
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.rebalanceThreshold = newRatio;

        emit RebalanceThresholdUpdated(newRatio);
    }

    /// @inheritdoc IStabilityPoolManager
    function setRebalanceBountyRatio(uint256 rebalanceRatio_) external onlyOwner {
        if (rebalanceRatio_ > 1 ether) {
            revert InvalidRebalanceBountyRatio(rebalanceRatio_);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.rebalanceBountyRatio = rebalanceRatio_;

        emit RebalanceBountyUpdated(rebalanceRatio_);
    }

    /// @inheritdoc IStabilityPoolManager
    function setHarvestBountyRatio(uint256 harvestRatio_) external onlyOwner {
        if (harvestRatio_ > 1 ether) {
            revert InvalidHarvestBountyRatio(harvestRatio_);
        }
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.harvestRatio = harvestRatio_;

        emit HarvestBountyUpdated(harvestRatio_);
    }

    /*************************
     * Core Functions *
     *************************/

    function _poolHoldings()
        private
        view
        returns (uint256 totalPoolHolding, uint256 poolHoldingCollateral, uint256 poolHoldingLeveraged)
    {
        poolHoldingCollateral = IERC20(PEGGED_TOKEN).balanceOf(STABILITY_POOL_COLLATERAL);
        poolHoldingLeveraged = IERC20(PEGGED_TOKEN).balanceOf(STABILITY_POOL_LEVERAGED);
        totalPoolHolding = poolHoldingCollateral + poolHoldingLeveraged;
    }

    /// @inheritdoc IStabilityPoolManager
    function rebalance(
        address bountyReceiver,
        uint256 minPeggedLiquidated
    ) external nonReentrant returns (uint256 peggedLiquidated) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        uint256 rebalanceThreshold_ = $.rebalanceThreshold;
        if (!_rebalanceable(IMinter(MINTER).collateralRatio(), rebalanceThreshold_)) {
            // it's an lower bound for non-rebalance mode
            revert CollateralRatioNotBelowRebalanceThreshold(IMinter(MINTER).collateralRatio(), rebalanceThreshold_);
        }

        // sum up the relative sizes of the stabilility pools - this is the pegged token holdings
        // note that these holdings are depleted by the liquidation process
        (uint256 totalPoolHolding, uint256 poolHoldingCollateral, uint256 poolHoldingLeveraged) = _poolHoldings();
        if (totalPoolHolding == 0) {
            revert NoTokensToLiquidate(PEGGED_TOKEN);
        }

        // get the amount to liquidate (double(ish) the anmount)
        uint256 peggedForCollateral = IMinter(MINTER).redeemPeggedForCollateralRatio(rebalanceThreshold_);
        uint256 peggedForLeveraged = IMinter(MINTER).swapPeggedForLeveragedForCollateralRatio(rebalanceThreshold_);

        // rescale to the pool holdings
        if (peggedForCollateral == 0) {
            peggedForLeveraged = totalPoolHolding;
        } else if (peggedForLeveraged == 0) {
            peggedForCollateral = totalPoolHolding;
        } else {
            // round up, just to be sure we are out of rebalance
            peggedForCollateral = Math.mulDiv(
                peggedForCollateral,
                poolHoldingCollateral,
                totalPoolHolding,
                Math.Rounding.Ceil
            );
            peggedForLeveraged = Math.mulDiv(
                peggedForLeveraged,
                poolHoldingLeveraged,
                totalPoolHolding,
                Math.Rounding.Ceil
            );
        }

        // can't liquidate more than the pools hold
        if (peggedForCollateral > poolHoldingCollateral) {
            peggedForCollateral = poolHoldingCollateral;
        }
        if (peggedForLeveraged > poolHoldingLeveraged) {
            peggedForLeveraged = poolHoldingLeveraged;
        }
        peggedLiquidated = peggedForCollateral + peggedForLeveraged;

        // make sure we're going to liquidate at least the minimum
        if (peggedLiquidated < minPeggedLiquidated) {
            revert InsufficientLiquidation(PEGGED_TOKEN, peggedLiquidated, minPeggedLiquidated);
        }

        // do the actual liquidation for each pool
        // * take the pegged tokens to be lqiudated
        // * liquidate them into the other token (collateral/leveraged)
        // * extract the feed and transfer to the fee receiver
        // * transfer the remainder to the stability pool, notifying it of that "reward"

        uint256 rebalanceBountyRatio_ = $.rebalanceBountyRatio;

        // allow the minter to burn my pegged tokens I've just swept up
        IERC20(PEGGED_TOKEN).safeIncreaseAllowance(MINTER, peggedLiquidated);

        // collateral return pool
        uint256 wrappedCollateralReturned = 0;
        if (peggedForCollateral > 0) {
            ITokenHolder(STABILITY_POOL_COLLATERAL).sweep(PEGGED_TOKEN, peggedForCollateral, address(this));
            wrappedCollateralReturned = IMinter(MINTER).freeRedeemPeggedToken(peggedForCollateral, address(this));

            // extract the bounty
            uint256 collateralBounty = (wrappedCollateralReturned * rebalanceBountyRatio_) / 1 ether;
            wrappedCollateralReturned -= collateralBounty;

            // transfer the amounts and update the stability pool accounts
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(bountyReceiver, collateralBounty);
            IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(STABILITY_POOL_COLLATERAL, wrappedCollateralReturned);
            IStabilityPool(STABILITY_POOL_COLLATERAL).accumulateReward(
                WRAPPED_COLLATERAL_TOKEN,
                wrappedCollateralReturned
            );
        }

        // leveraged return
        uint256 leveragedReturned = 0;
        if (peggedForLeveraged > 0) {
            ITokenHolder(STABILITY_POOL_LEVERAGED).sweep(PEGGED_TOKEN, peggedForLeveraged, address(this));
            leveragedReturned = IMinter(MINTER).freeSwapPeggedForLeveraged(peggedForLeveraged, address(this));

            // extract the bounty
            uint256 leveragedBounty = (leveragedReturned * rebalanceBountyRatio_) / 1 ether;
            leveragedReturned -= leveragedBounty;

            IERC20(LEVERAGED_TOKEN).safeTransfer(bountyReceiver, leveragedBounty);
            IERC20(LEVERAGED_TOKEN).safeTransfer(STABILITY_POOL_LEVERAGED, leveragedReturned);
            IStabilityPool(STABILITY_POOL_LEVERAGED).accumulateReward(LEVERAGED_TOKEN, leveragedReturned);
        }
        emit Rebalanced(peggedLiquidated, wrappedCollateralReturned, leveragedReturned);
    }

    function _harvestToPool(
        uint256 harvestableAmount,
        uint256 totalHolding,
        address pool,
        uint256 poolHolding
    ) private returns (uint256 harvestedAmount) {
        harvestedAmount = 0;
        if (poolHolding > 0) {
            // in the math we get truncation errors, but all that means is that dust is collected in the next harvest
            harvestedAmount = (harvestableAmount * poolHolding) / totalHolding;
            ITokenHolder(MINTER).sweep(WRAPPED_COLLATERAL_TOKEN, harvestedAmount, pool);
            IStabilityPool(pool).accumulateReward(WRAPPED_COLLATERAL_TOKEN, harvestedAmount);
        }
    }

    /// @inheritdoc IStabilityPoolManager
    function harvest(
        address bountyReceiver,
        uint256 minBounty
    ) external nonReentrant returns (uint256 harvestedAmount) {
        // Check if there's anything to harvest
        uint256 harvestableAmount = IMinter(MINTER).harvestable();
        if (harvestableAmount == 0) {
            revert NoHarvestable();
        }

        // Calculate bounty
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        uint256 bountyAmount = (harvestableAmount * $.harvestRatio) / 1 ether;
        if (bountyAmount < minBounty) {
            revert InsufficientBounty(WRAPPED_COLLATERAL_TOKEN, bountyAmount, minBounty);
        }
        // harvest the bounty
        ITokenHolder(MINTER).sweep(WRAPPED_COLLATERAL_TOKEN, bountyAmount, bountyReceiver);

        // keep a running total of the amount harvested
        uint256 actuallyHarvested = bountyAmount;
        harvestableAmount -= bountyAmount;

        // Calculate total pool balances (similar to Harvester_v1)
        (uint256 totalPoolHolding, uint256 poolHoldingCollateral, uint256 poolHoldingLeveraged) = _poolHoldings();

        // Distribute proportionally based on current holdings
        if (totalPoolHolding > 0) {
            actuallyHarvested += _harvestToPool(
                harvestableAmount,
                totalPoolHolding,
                STABILITY_POOL_COLLATERAL,
                poolHoldingCollateral
            );
            actuallyHarvested += _harvestToPool(
                harvestableAmount,
                totalPoolHolding,
                STABILITY_POOL_LEVERAGED,
                poolHoldingLeveraged
            );
        } else {
            // Send to treasury if no pools have a balance
            ITokenHolder(MINTER).sweep(WRAPPED_COLLATERAL_TOKEN, harvestableAmount, TREASURY);
        }

        emit Harvested(actuallyHarvested); //, bountyAmount);
        return actuallyHarvested;
    }
}
