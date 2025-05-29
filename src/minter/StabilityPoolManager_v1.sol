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

import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

/// @title StabilityPoolManager
/// @author Based on original Liquidator and Harvester contracts
/// @notice Manages stability pools for liquidation and harvesting operations
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
contract StabilityPoolManager_v1 is
    Initializable,
    UUPSUpgradeable,
    BaoOwnableRoles,
    ERC165Upgradeable,
    ReentrancyGuardTransientUpgradeable,
    TokenHolder,
    IStabilityPoolManager
{
    using SafeERC20 for IERC20;

    /// @notice The role for liquidator.
    uint256 public constant LIQUIDATOR_ROLE = _ROLE_0;

    /// @notice The role for harvester.
    uint256 public constant HARVESTER_ROLE = _ROLE_1;

    /*************
     * Variables *
     *************/

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.StabilityPoolManager
    struct StabilityPoolManagerStorage {
        /// @notice The address of the minter contract
        address minter;
        /// @notice The address of the treasury (for fallback distribution)
        address treasury;
        /// @notice List of stability pools to manage
        address[] stabilityPools;
        /// @notice Mapping to check if a stability pool is registered
        mapping(address => bool) isStabilityPool;
        /// @notice The token used for bounties
        address bountyToken;
        /// @notice Fixed bounty amount
        uint256 bountyAmount;
        /// @notice Percentage-based bounty (as a ratio of the harvested amount)
        uint256 bountyRatio;
        /// @notice If true, use the minimum of fixed and percentage bounties; otherwise use maximum
        bool useMinBounty;
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.StabilityPoolManager")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant _STABILITYPOOL_MANAGER_STORAGE =
        0xf7b9d56d5f95eb31caba66756cf6f0b2d5c8f273df336044eab94218477ab900;

    function _getStabilityPoolManagerStorage() private pure returns (StabilityPoolManagerStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _STABILITYPOOL_MANAGER_STORAGE
        }
    }

    /// @notice In UUPS proxies the constructor sets immutables
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address minter_, address bountyToken_) {
        _disableInitializers();

        // Store the immutable addresses
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.minter = minter_;
        $.bountyToken = bountyToken_;
    }

    /// @notice Initialize the contract with starting configuration
    /// @param owner_ The owner address
    /// @param treasury_ The treasury address for fallback distributions
    /// @param initialPools Array of initial stability pools to add
    function initialize(address owner_, address treasury_, address[] memory initialPools) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __ERC165_init();
        __ReentrancyGuardTransient_init();

        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.treasury = treasury_;

        // Add initial stability pools
        for (uint i = 0; i < initialPools.length; i++) {
            _addStabilityPool(initialPools[i]);
        }

        // Set default bounty values
        $.bountyAmount = 0.1 ether;
        $.bountyRatio = 0.05 ether; // 5%
        $.useMinBounty = true;
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
    function stabilityPools() external view returns (address[] memory) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return $.stabilityPools;
    }

    /// @inheritdoc IStabilityPoolManager
    function hasStabilityPool(address stabilityPool) external view returns (bool) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return $.isStabilityPool[stabilityPool];
    }

    /// @inheritdoc IStabilityPoolManager
    function harvestable() external view returns (uint256) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return IMinter($.minter).harvestable();
    }

    /// @inheritdoc IStabilityPoolManager
    function bounty() external view returns (address token, uint256 amount, uint256 ratio, bool useMin) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return ($.bountyToken, $.bountyAmount, $.bountyRatio, $.useMinBounty);
    }

    /*************************
     * Admin Functions *
     *************************/

    /// @inheritdoc IStabilityPoolManager
    function addStabilityPool(address stabilityPool) external onlyOwner {
        _addStabilityPool(stabilityPool);
    }

    /// @inheritdoc IStabilityPoolManager
    function removeStabilityPool(address stabilityPool) external onlyOwner {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();

        if (!$.isStabilityPool[stabilityPool]) {
            revert StabilityPoolNotFound(stabilityPool);
        }

        // Find and remove from array
        uint256 length = $.stabilityPools.length;
        for (uint256 i = 0; i < length; i++) {
            if ($.stabilityPools[i] == stabilityPool) {
                // Move the last element to this position (if not already the last)
                if (i < length - 1) {
                    $.stabilityPools[i] = $.stabilityPools[length - 1];
                }
                // Remove the last element
                $.stabilityPools.pop();
                $.isStabilityPool[stabilityPool] = false;

                emit StabilityPoolRemoved(stabilityPool);
                return;
            }
        }
    }

    /// @inheritdoc IStabilityPoolManager
    function setBounty(uint256 amount, uint256 ratio, bool useMin) external onlyOwner {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.bountyAmount = amount;
        $.bountyRatio = ratio;
        $.useMinBounty = useMin;

        emit BountyUpdated($.bountyToken, amount, ratio, useMin);
    }

    /*************************
     * Core Functions *
     *************************/

    /// @inheritdoc IStabilityPoolManager
    function liquidate(
        address bountyReceiver,
        uint256 minLiquidation
    ) external nonReentrant onlyRoles(LIQUIDATOR_ROLE) returns (uint256 totalLiquidated) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();

        if ($.stabilityPools.length == 0) {
            revert NoStabilityPools();
        }

        // Calculate and send bounty
        uint256 bountyToSend = _calculateBounty(0); // No input amount for liquidation bounty
        IERC20($.bountyToken).safeTransfer(bountyReceiver, bountyToSend);

        // Try to liquidate from each pool until we reach the target
        uint256 remaining = minLiquidation;
        for (uint256 i = 0; i < $.stabilityPools.length; i++) {
            try IStabilityPool($.stabilityPools[i]).liquidate(remaining) returns (uint256 liquidated) {
                totalLiquidated += liquidated;

                emit LiquidationPerformed($.stabilityPools[i], liquidated);

                // If we've reached the minimum, we can stop
                if (totalLiquidated >= minLiquidation) {
                    break;
                }

                // Update remaining amount needed
                remaining = minLiquidation - totalLiquidated;
            } catch {
                // Skip failed liquidations
                continue;
            }
        }

        if (totalLiquidated < minLiquidation) {
            revert InsufficientLiquidation(totalLiquidated, minLiquidation);
        }

        return totalLiquidated;
    }

    /// @inheritdoc IStabilityPoolManager
    function harvest(
        address bountyReceiver,
        uint256 minBounty
    ) external nonReentrant onlyRoles(HARVESTER_ROLE) returns (uint256 harvestedAmount) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();

        // Check if there's anything to harvest
        harvestedAmount = IMinter($.minter).harvestable();
        if (harvestedAmount == 0) {
            revert NoHarvestable();
        }

        // Calculate bounty
        uint256 bountyAmount = _calculateBounty(harvestedAmount);
        if (bountyAmount < minBounty) {
            revert InsufficientBounty($.bountyToken, bountyAmount, minBounty);
        }

        // Perform the harvest
        uint256 beforeBalance = IERC20(IMinter($.minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(address(this));

        // Sweep from the minter to this contract
        ITokenHolder($.minter).sweep(IMinter($.minter).WRAPPED_COLLATERAL_TOKEN(), harvestedAmount, address(this));

        uint256 afterBalance = IERC20(IMinter($.minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(address(this));
        uint256 actuallyHarvested = afterBalance - beforeBalance;

        // Send bounty to the caller
        IERC20(IMinter($.minter).WRAPPED_COLLATERAL_TOKEN()).safeTransfer(bountyReceiver, bountyAmount);

        // Distribute the rest to stability pools
        uint256 amountForPools = actuallyHarvested - bountyAmount;
        _distributeHarvest(amountForPools);

        emit HarvestPerformed(actuallyHarvested, bountyAmount);
        return actuallyHarvested;
    }

    /*************************
     * Internal Functions *
     *************************/

    /// @dev Internal function to add a stability pool
    /// @param stabilityPool The address of the stability pool to add
    function _addStabilityPool(address stabilityPool) internal {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();

        // Validate the stability pool
        if (!_isValidStabilityPool(stabilityPool)) {
            revert InvalidStabilityPool(stabilityPool);
        }

        // Check if already added
        if ($.isStabilityPool[stabilityPool]) {
            revert StabilityPoolAlreadyAdded(stabilityPool);
        }

        // Add to list and mapping
        $.stabilityPools.push(stabilityPool);
        $.isStabilityPool[stabilityPool] = true;

        emit StabilityPoolAdded(stabilityPool);
    }

    /// @dev Validates if an address is a valid stability pool for this manager
    /// @param stabilityPool The address to validate
    /// @return valid True if the address is a valid stability pool
    function _isValidStabilityPool(address stabilityPool) internal view returns (bool valid) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();

        // Check if the address is a contract
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(stabilityPool)
        }
        if (codeSize == 0) return false;

        // Check if it implements the IStabilityPool interface
        try IStabilityPool(stabilityPool).MINTER() returns (address minter) {
            // Check if it's for the same minter
            return minter == $.minter;
        } catch {
            return false;
        }
    }

    /// @dev Calculates the bounty amount based on configured rules
    /// @param harvestedAmount The amount being harvested (0 for liquidations)
    /// @return bountyAmount The calculated bounty amount
    function _calculateBounty(uint256 harvestedAmount) internal view returns (uint256 bountyAmount) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();

        if (harvestedAmount == 0) {
            return $.bountyAmount; // Fixed bounty for liquidations
        }

        uint256 percentBounty = (harvestedAmount * $.bountyRatio) / 1 ether;

        if ($.useMinBounty) {
            return Math.min($.bountyAmount, percentBounty);
        } else {
            return Math.max($.bountyAmount, percentBounty);
        }
    }

    /// @dev Distributes harvested rewards to the registered stability pools
    /// @param amount Amount to distribute
    function _distributeHarvest(uint256 amount) internal {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        address wrappedCollateralToken = IMinter($.minter).WRAPPED_COLLATERAL_TOKEN();

        if ($.stabilityPools.length == 0) {
            // Send to treasury if no stability pools
            IERC20(wrappedCollateralToken).safeTransfer($.treasury, amount);
            return;
        }

        // Distribute evenly among pools
        uint256 amountPerPool = amount / $.stabilityPools.length;
        for (uint256 i = 0; i < $.stabilityPools.length; i++) {
            // For the last pool, transfer all remaining tokens to handle rounding
            uint256 poolAmount = i == $.stabilityPools.length - 1
                ? IERC20(wrappedCollateralToken).balanceOf(address(this))
                : amountPerPool;

            if (poolAmount > 0) {
                IERC20(wrappedCollateralToken).safeTransfer($.stabilityPools[i], poolAmount);

                // Notify the pool about the reward
                try IStabilityPool($.stabilityPools[i]).accumulateReward(wrappedCollateralToken, poolAmount) {} catch {}
            }
        }
    }

    /// @dev Override the TokenHolder check for sweeping
    function _checkSweeper() internal view override(TokenHolder) {
        _checkOwnerOrRoles(HARVESTER_ROLE);
    }
}
