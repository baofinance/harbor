// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransientUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import { IRebalancePool } from "src/minter/IRebalancePool.sol";
import { ILiquidator } from "src/minter/ILiquidator.sol";
import { BaoAccessControl } from "src/common/BaoAccessControl.sol";

contract Liquidator_v1 is
    Initializable,
    UUPSUpgradeable,
    BaoAccessControl,
    ReentrancyGuardTransientUpgradeable,
    ILiquidator
{
    using SafeERC20 for IERC20;

    // keccak256(abi.encode(uint256(keccak256("bao.storage.Liquidator")) - 1)) & ~bytes32(uint256(0xff));
    // TODO:
    bytes32 private constant LIQUIDATOR_STORAGE = 0x0;
    /// @notice The role for liquidator.
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    /*************
     * Variables *
     *************/

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.Genesis
    struct LiquidatorStorage {
        /// @notice The address of rebalancePool contract.
        address rebalancePool;
        /// @notice the reward given to a successful liquidator
        address rewardToken;
        /// @notice the ampount of reward to be given to the liquidator caller
        uint96 rewardAmount; // decimals = 18
    }

    function _getLiquidatorStorage() private pure returns (LiquidatorStorage storage $) {
        assembly {
            $.slot := LIQUIDATOR_STORAGE
        }
    }

    function initialize(
        address owner,
        address rebalancePool,
        address rewardToken,
        uint256 rewardAmount
    ) public initializer {
        __BaoAccessControl_init(owner);
        __UUPSUpgradeable_init();

        if (!BaoAccessControl(rebalancePool).hasRole(LIQUIDATOR_ROLE, address(this)))
            revert NeedsRole(LIQUIDATOR_ROLE, address(this));

        LiquidatorStorage storage $ = _getLiquidatorStorage();
        $.rebalancePool = rebalancePool;
        $.rewardToken = rewardToken;
        $.rewardAmount = uint96(rewardAmount);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// @inheritdoc ILiquidator
    function assetToken() external view returns (address) {
        LiquidatorStorage storage $ = _getLiquidatorStorage();
        return IRebalancePool($.rebalancePool).assetToken();
    }

    // TODO: make this inherit TokenOwner to make recovery of owned tokens easier

    /// @inheritdoc ILiquidator
    function liquidate(
        address rewardReceiver,
        uint256 minLiquidation
    ) public virtual nonReentrant returns (uint256 liquidated) {
        LiquidatorStorage storage $ = _getLiquidatorStorage();
        address rebalancePool = $.rebalancePool;

        // wake-disable-next-line reentrancy // rebalancePool is trusted and reentrancy guard
        liquidated = IRebalancePool(rebalancePool).liquidate(minLiquidation);

        IERC20($.rewardToken).safeTransfer(rewardReceiver, $.rewardAmount);
    }
}
