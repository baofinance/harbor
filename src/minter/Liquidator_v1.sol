// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransientUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";
import { ILiquidator } from "src/minter/ILiquidator.sol";
import { AccessControl } from "src/common/AccessControl.sol";

contract Liquidator_v1 is
    Initializable,
    UUPSUpgradeable,
    AccessControl,
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
        /// @notice The address of minter contract.
        address minter;
        /// @notice The address of rebalancePool contract.
        address rebalancePool;
        /// @notice The collateralRatio the liquidation can start at
        uint96 rebalanceCollateralRatio;
        // @notice the token returned to the asset/peggedToken owner for the liquidated peggedTokens
        address returnToken;
        /// @notice The address of collateral token.
        address collateralToken;
        /// @notice The address of peggedToken token.
        address peggedToken;
        /// @notice The address of leveragedToken token.
        address leveragedToken;
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
        address minter,
        uint256 rebalanceCollateralRatio,
        address returnToken,
        address rewardToken,
        uint256 rewardAmount
    ) public initializer {
        __AccessControl_init(owner);
        __UUPSUpgradeable_init();

        if (!AccessControl(rebalancePool).hasRole(LIQUIDATOR_ROLE, address(this)))
            revert NeedsRole(LIQUIDATOR_ROLE, address(this));

        LiquidatorStorage storage $ = _getLiquidatorStorage();

        $.minter = minter;
        $.rebalancePool = rebalancePool;
        $.rebalanceCollateralRatio = uint96(rebalanceCollateralRatio);
        $.returnToken = returnToken;
        $.rewardToken = rewardToken;
        $.rewardAmount = uint96(rewardAmount);

        $.peggedToken = IMinter(minter).peggedToken();
        $.collateralToken = IMinter(minter).collateralToken();
        $.leveragedToken = IMinter(minter).leveragedToken();
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
    function collateralToken() external view returns (address) {
        LiquidatorStorage storage $ = _getLiquidatorStorage();
        return $.collateralToken;
    }

    /// @inheritdoc ILiquidator
    function assetToken() external view returns (address) {
        LiquidatorStorage storage $ = _getLiquidatorStorage();
        return $.peggedToken;
    }

    /// @inheritdoc ILiquidator
    function liquidate(address rewardReceiver) public virtual nonReentrant {
        LiquidatorStorage storage $ = _getLiquidatorStorage();

        address rebalancePool = $.rebalancePool;
        uint256 rebalanceCollateralRatio_ = $.rebalanceCollateralRatio;
        address minter = $.minter;
        address returnToken = $.returnToken;
        address collateralToken_ = $.collateralToken;
        address leveragedToken = $.leveragedToken;

        // depending on the token, determine the amount that needs to be liquidated
        uint256 peggedTokensToLiquidate;
        if (returnToken == collateralToken_) {
            peggedTokensToLiquidate = IMinter(minter).redeemPeggedForCollateralRatio(rebalanceCollateralRatio_);
        } else if (returnToken == leveragedToken) {
            peggedTokensToLiquidate = IMinter(minter).swapPeggedForleveragedForCollateralRatio(
                rebalanceCollateralRatio_
            );
        }

        uint256 peggedLiquidated = IRebalancePool(rebalancePool).liquidate(peggedTokensToLiquidate, minter);

        uint256 returnAmount;
        if (returnToken == collateralToken_) {
            returnAmount = IMinter(minter).redeemPeggedToken(peggedLiquidated, rebalancePool, 0);
        } else if (returnToken == leveragedToken) {
            returnAmount = IMinter(minter).freeSwapPeggedForLeveraged(peggedLiquidated, rebalancePool);
        }

        IRebalancePool(rebalancePool).accumulateReward(returnToken, returnAmount);

        // TODO: send the reward token to the receiver
    }
}
