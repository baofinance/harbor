// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransientUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import { OwnableRoles } from "@solady/auth/OwnableRoles.sol";

import { TokenOwner, ITokenOwner } from "../common/TokenOwner.sol";
import { IOwnable, IOwnableRoles } from "../interfaces/IOwnableRoles.sol";
import { IRebalancePool } from "./IRebalancePool.sol";
import { ILiquidator } from "./ILiquidator.sol";

contract Liquidator_v1 is
    Initializable,
    UUPSUpgradeable,
    OwnableRoles,
    ERC165Upgradeable,
    ReentrancyGuardTransientUpgradeable,
    TokenOwner,
    ILiquidator
{
    using SafeERC20 for IERC20;

    // keccak256(abi.encode(uint256(keccak256("bao.storage.Liquidator")) - 1)) & ~bytes32(uint256(0xff));
    // TODO:
    bytes32 private constant LIQUIDATOR_STORAGE = 0x0;
    /// @notice The role for liquidator.
    uint256 public constant LIQUIDATOR_ROLE = _ROLE_0;

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
        _initializeOwner(owner);
        __UUPSUpgradeable_init();
        __ERC165_init();

        if (!OwnableRoles(rebalancePool).hasAnyRole(address(this), LIQUIDATOR_ROLE))
            revert NeedsRole(address(this), LIQUIDATOR_ROLE);

        LiquidatorStorage storage $ = _getLiquidatorStorage();
        $.rebalancePool = rebalancePool;
        $.rewardToken = rewardToken;
        $.rewardAmount = uint96(rewardAmount);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal virtual override onlyOwner {}

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(ILiquidator).interfaceId ||
            interfaceId == type(IOwnable).interfaceId ||
            interfaceId == type(IOwnableRoles).interfaceId ||
            interfaceId == type(ITokenOwner).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc ILiquidator
    function assetToken() external view returns (address) {
        LiquidatorStorage storage $ = _getLiquidatorStorage();
        return IRebalancePool($.rebalancePool).assetToken();
    }

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
