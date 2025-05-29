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

    // Immutable variables (set in constructor)
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable BOUNTY_TOKEN;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable TREASURY;

    // Store up to 2 stability pools as immutable variables
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint8 private immutable STABILITY_POOL_COUNT;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable STABILITY_POOL_0;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable STABILITY_POOL_1;

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.StabilityPoolManager
    struct StabilityPoolManagerStorage {
        /// @notice Fixed bounty amount for rebalancing
        uint256 rebalanceAmount;
        /// @notice Percentage-based bounty for harvesting (as a ratio of the harvested amount)
        uint256 harvestRatio;
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
    constructor(address minter_, address treasury_, address[] memory stabilityPools_) {
        _disableInitializers();

        Token.ensureContract(minter_);
        // slither-disable-next-line missing-zero-check
        MINTER = minter_;

        address bountyToken = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        Token.ensureERC20Token(bountyToken);
        // slither-disable-next-line missing-zero-check
        BOUNTY_TOKEN = bountyToken;

        Token.ensureNonZeroAddress(treasury_);
        // slither-disable-next-line missing-zero-check
        TREASURY = treasury_;

        // Store stability pools
        require(stabilityPools_.length > 0, "No stability pools provided");
        require(stabilityPools_.length <= 2, "Too many stability pools");
        STABILITY_POOL_COUNT = uint8(stabilityPools_.length);

        // Validate and store the stability pools
        if (STABILITY_POOL_COUNT > 0) {
            Token.ensureContract(stabilityPools_[0]);
            _validateStabilityPool(stabilityPools_[0], minter_);
            STABILITY_POOL_0 = stabilityPools_[0];
        }

        if (STABILITY_POOL_COUNT > 1) {
            Token.ensureContract(stabilityPools_[1]);
            _validateStabilityPool(stabilityPools_[1], minter_);
            STABILITY_POOL_1 = stabilityPools_[1];
        }
    }

    /// @notice Initialize the contract with starting configuration
    /// @param owner_ The owner address
    function initialize(address owner_) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __ERC165_init();
        __ReentrancyGuardTransient_init();

        // Set default bounty values
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.rebalanceAmount = 0.1 ether;
        $.harvestRatio = 0.05 ether; // 5%
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

    /// @notice Helper function to validate a stability pool
    /// @param stabilityPool The address of the stability pool to validate
    /// @param minter_ The address of the minter contract
    function _validateStabilityPool(address stabilityPool, address minter_) private view {
        try IStabilityPool(stabilityPool).MINTER() returns (address poolMinter) {
            require(poolMinter == minter_, "Stability pool has wrong minter");
        } catch {
            revert InvalidStabilityPool(stabilityPool);
        }
    }

    /*************************
     * Public View Functions *
     *************************/

    /// @inheritdoc IStabilityPoolManager
    function stabilityPools() external view returns (address[] memory pools) {
        pools = new address[](STABILITY_POOL_COUNT);

        if (STABILITY_POOL_COUNT > 0) {
            pools[0] = STABILITY_POOL_0;
        }

        if (STABILITY_POOL_COUNT > 1) {
            pools[1] = STABILITY_POOL_1;
        }

        return pools;
    }

    /// @inheritdoc IStabilityPoolManager
    function hasStabilityPool(address stabilityPool) external view returns (bool) {
        if (STABILITY_POOL_COUNT > 0 && STABILITY_POOL_0 == stabilityPool) {
            return true;
        }

        if (STABILITY_POOL_COUNT > 1 && STABILITY_POOL_1 == stabilityPool) {
            return true;
        }

        return false;
    }

    /// @inheritdoc IStabilityPoolManager
    function harvestable() external view returns (uint256) {
        return IMinter(MINTER).harvestable();
    }

    /// @inheritdoc IStabilityPoolManager
    function rebalanceable() external view returns (bool) {
        // Check if any pools exist
        if (STABILITY_POOL_COUNT == 0) {
            return false;
        }

        // Check if collateral ratio is below the rebalance threshold
        uint256 currentCR = IMinter(MINTER).collateralRatio();
        uint256 rebalanceCR = IMinter(MINTER).rebalanceCollateralRatio();

        return currentCR < rebalanceCR;
    }

    /// @inheritdoc IStabilityPoolManager
    function bounty() external view returns (address token, uint256 rebalanceAmount, uint256 harvestRatio) {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        return (BOUNTY_TOKEN, $.rebalanceAmount, $.harvestRatio);
    }

    /*************************
     * Admin Functions *
     *************************/

    /// @inheritdoc IStabilityPoolManager
    function setRebalanceBounty(uint256 rebalanceAmount, uint256 harvestRatio) external onlyOwner {
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        $.rebalanceAmount = rebalanceAmount;
        $.harvestRatio = harvestRatio;

        emit BountyUpdated(BOUNTY_TOKEN, rebalanceAmount, harvestRatio);
    }

    /*************************
     * Core Functions *
     *************************/

    /// @inheritdoc IStabilityPoolManager
    function rebalance(
        address bountyReceiver,
        uint256 minLiquidation
    ) external nonReentrant onlyRoles(LIQUIDATOR_ROLE) returns (uint256 totalLiquidated) {
        if (STABILITY_POOL_COUNT == 0) {
            revert NoStabilityPools();
        }

        // Send bounty
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        IERC20(BOUNTY_TOKEN).safeTransfer(bountyReceiver, $.rebalanceAmount);

        // Try to liquidate from each pool until we reach the target
        totalLiquidated = 0;
        uint256 remaining = minLiquidation;

        // Try the first pool
        if (STABILITY_POOL_COUNT > 0) {
            try IStabilityPool(STABILITY_POOL_0).liquidate(remaining) returns (uint256 liquidated) {
                totalLiquidated += liquidated;
                emit LiquidationPerformed(STABILITY_POOL_0, liquidated);

                if (totalLiquidated >= minLiquidation) {
                    return totalLiquidated;
                }

                remaining = minLiquidation - totalLiquidated;
            } catch {
                // Skip failed liquidations
            }
        }

        // Try the second pool if needed and available
        if (STABILITY_POOL_COUNT > 1 && totalLiquidated < minLiquidation) {
            try IStabilityPool(STABILITY_POOL_1).liquidate(remaining) returns (uint256 liquidated) {
                totalLiquidated += liquidated;
                emit LiquidationPerformed(STABILITY_POOL_1, liquidated);
            } catch {
                // Skip failed liquidations
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
        // Check if there's anything to harvest
        harvestedAmount = IMinter(MINTER).harvestable();
        if (harvestedAmount == 0) {
            revert NoHarvestable();
        }

        // Calculate bounty
        StabilityPoolManagerStorage storage $ = _getStabilityPoolManagerStorage();
        uint256 bountyAmount = (harvestedAmount * $.harvestRatio) / 1 ether;
        if (bountyAmount < minBounty) {
            revert InsufficientBounty(BOUNTY_TOKEN, bountyAmount, minBounty);
        }

        // Perform the harvest
        uint256 beforeBalance = IERC20(BOUNTY_TOKEN).balanceOf(address(this));

        // Sweep from the minter to this contract
        ITokenHolder(MINTER).sweep(BOUNTY_TOKEN, harvestedAmount, address(this));

        uint256 afterBalance = IERC20(BOUNTY_TOKEN).balanceOf(address(this));
        uint256 actuallyHarvested = afterBalance - beforeBalance;

        // Send bounty to the caller
        IERC20(BOUNTY_TOKEN).safeTransfer(bountyReceiver, bountyAmount);

        // Distribute the rest to stability pools
        uint256 amountForPools = actuallyHarvested - bountyAmount;
        _distributeHarvest(amountForPools);

        emit HarvestPerformed(actuallyHarvested, bountyAmount);
        return actuallyHarvested;
    }

    /// @dev Distributes harvested rewards to the registered stability pools
    /// @param amount Amount to distribute
    function _distributeHarvest(uint256 amount) internal {
        address wrappedCollateralToken = BOUNTY_TOKEN;

        if (STABILITY_POOL_COUNT == 0) {
            // Send to treasury if no stability pools
            IERC20(wrappedCollateralToken).safeTransfer(TREASURY, amount);
            return;
        }

        // Calculate total pool balances (similar to Harvester_v1)
        uint256 totalBalance = 0;
        uint256 poolHolding_0 = 0;
        uint256 poolHolding_1 = 0;

        if (STABILITY_POOL_COUNT > 0) {
            poolHolding_0 = IERC20(wrappedCollateralToken).balanceOf(STABILITY_POOL_0);
            totalBalance += poolHolding_0;
        }

        if (STABILITY_POOL_COUNT > 1) {
            poolHolding_1 = IERC20(wrappedCollateralToken).balanceOf(STABILITY_POOL_1);
            totalBalance += poolHolding_1;
        }

        // Distribute proportionally based on current holdings
        if (totalBalance > 0) {
            if (poolHolding_0 > 0) {
                uint256 amountToSend = (amount * poolHolding_0) / totalBalance;
                IERC20(wrappedCollateralToken).safeTransfer(STABILITY_POOL_0, amountToSend);
                try IStabilityPool(STABILITY_POOL_0).accumulateReward(
                    wrappedCollateralToken,
                    amountToSend
                ) {} catch {}
            }

            if (poolHolding_1 > 0) {
                uint256 amountToSend = (amount * poolHolding_1) / totalBalance;
                IERC20(wrappedCollateralToken).safeTransfer(STABILITY_POOL_1, amountToSend);
                try IStabilityPool(STABILITY_POOL_1).accumulateReward(
                    wrappedCollateralToken,
                    amountToSend
                ) {} catch {}
            }
        } else {
            // Send to treasury if no pools have a balance
            IERC20(wrappedCollateralToken).safeTransfer(TREASURY, amount);
        }
    }

    /// @dev Override the TokenHolder check for sweeping
    function _checkSweeper() internal view override(TokenHolder) {
        _checkOwnerOrRoles(HARVESTER_ROLE);
    }
}
