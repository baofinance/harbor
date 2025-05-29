// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";
import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {ILiquidator} from "src/interfaces/ILiquidator.sol";

/// @author rootminus0x1
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract Liquidator_v1 is
    Initializable,
    UUPSUpgradeable,
    BaoOwnableRoles,
    ERC165Upgradeable,
    ReentrancyGuardTransientUpgradeable,
    TokenHolder,
    ILiquidator
{
    using SafeERC20 for IERC20;

    /// @notice The role for liquidator.
    uint256 public constant LIQUIDATOR_ROLE = _ROLE_0;

    /*************
     * Variables *
     *************/

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.Liquidator
    struct LiquidatorStorage {
        /// @notice The address of stabilityPool contract.
        address stabilityPool;
        /// @notice the reward given to a successful liquidator
        address rewardToken;
        /// @notice the ampount of reward to be given to the liquidator caller
        uint96 rewardAmount; // decimals = 18
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.Liquidator")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant _LIQUIDATOR_STORAGE = 0xba08515d98ad1a2775d4a7609c4d903f99de8974de45068f40eaa9f5802a7a00;

    function _getLiquidatorStorage() private pure returns (LiquidatorStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _LIQUIDATOR_STORAGE
        }
    }

    function initialize(address owner_, address stabilityPool_, address rewardToken) public initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __ERC165_init();

        // TODO:
        // if (!BaoOwnableRoles(stabilityPool).hasAnyRole(address(this), LIQUIDATOR_ROLE))
        //     revert NeedsRole(address(this), LIQUIDATOR_ROLE);

        LiquidatorStorage storage $ = _getLiquidatorStorage();
        $.stabilityPool = stabilityPool_;
        $.rewardToken = rewardToken;
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaoOwnableRoles, ERC165Upgradeable) returns (bool) {
        return
            interfaceId == type(ILiquidator).interfaceId ||
            interfaceId == type(ITokenHolder).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // @inheritdoc ILiquidator
    function stabilityPool() external view returns (address) {
        LiquidatorStorage storage $ = _getLiquidatorStorage();
        return $.stabilityPool;
    }

    /// @inheritdoc ILiquidator
    function reward() external view returns (address token, uint256 amount) {
        LiquidatorStorage storage $ = _getLiquidatorStorage();
        return ($.rewardToken, $.rewardAmount);
    }

    function setReward(address rewardToken, uint256 rewardAmount) external {
        LiquidatorStorage storage $ = _getLiquidatorStorage();
        $.rewardToken = rewardToken;
        $.rewardAmount = uint96(rewardAmount);
    }

    /// @inheritdoc ILiquidator
    function liquidate(
        address rewardReceiver,
        uint256 minLiquidation
    ) public virtual nonReentrant returns (uint256 liquidated) {
        LiquidatorStorage storage $ = _getLiquidatorStorage();
        // send the reward - do this first because it is the cheapest to do
        IERC20($.rewardToken).safeTransfer(rewardReceiver, $.rewardAmount);

        // do the actual liquidation
        // TODO: bring more from stability pools
        // wake-disable-next-line reentrancy // stabilityPool is trusted and reentrancy guard
        liquidated = IStabilityPool($.stabilityPool).liquidate(minLiquidation);
    }
}
