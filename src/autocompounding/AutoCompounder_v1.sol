// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HarborOwnable} from "@bao/HarborOwnable.sol";

import {IAutoCompounder} from "src/interfaces/IAutoCompounder.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardAccumulator_v3} from "src/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IMinter_v3} from "src/interfaces/IMinter_v3.sol";

/// @title AutoCompounder_v1
/// @notice Level 1 auto-compounder: non-rebasing ERC4626 vault wrapping a rebasing stability pool position.
/// @dev The ERC4626 asset is the SP token (rebasing ERC20). Share count is fixed on deposit; share price
///      moves as totalAssets changes from harvest rewards, compounding, and rebalance losses.
///      compound() claims wCOLn rewards, mints pegged tokens via the Minter (fee-capped), and redeposits to the SP.
///      totalAssets() includes the SP position plus unclaimed wCOLn valued via Minter dry run.
///      Works for both collateral and leveraged stability pools.
// solhint-disable-next-line contract-name-capwords
contract AutoCompounder_v1 is Initializable, UUPSUpgradeable, ERC4626Upgradeable, HarborOwnable, IERC5313, IAutoCompounder {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Thrown when compound() finds nothing to compound.
    error NothingToCompound();

    /// @dev Thrown when depositPeggedToken receives zero shares.
    error DepositPeggedTokenZeroShares();

    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when compound() successfully converts rewards to SP position.
    /// @param caller The address that triggered the compound.
    /// @param collateralClaimed The amount of wrapped collateral claimed from the SP.
    /// @param peggedMinted The amount of pegged tokens minted from the claimed collateral.
    event Compounded(address indexed caller, uint256 collateralClaimed, uint256 peggedMinted);

    /// @notice Emitted when compound() skips because fees exceed the cap.
    /// @param caller The address that triggered the compound.
    /// @param claimableCollateral The amount of wrapped collateral available but not claimed.
    event CompoundSkipped(address indexed caller, uint256 claimableCollateral);

    /// @notice Emitted when the max fee ratio is updated.
    /// @param newMaxFeeRatio The new max fee ratio (18 decimals).
    event MaxFeeRatioUpdated(uint256 newMaxFeeRatio);

    /*//////////////////////////////////////////////////////////////////////////
                                    IMMUTABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The stability pool this vault wraps.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable STABILITY_POOL; // solhint-disable-line immutable-vars-naming

    /// @notice The minter for this market.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER; // solhint-disable-line immutable-vars-naming

    /// @notice The wrapped collateral token (reward token from harvests).
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable WRAPPED_COLLATERAL; // solhint-disable-line immutable-vars-naming

    /// @notice The pegged token - the SP's underlying asset.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable PEGGED_TOKEN; // solhint-disable-line immutable-vars-naming

    /*//////////////////////////////////////////////////////////////////////////
                                    STORAGE (ERC7201)
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:harbor.storage.AutoCompounder_v1
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("harbor.storage.AutoCompounder_v1")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _AUTOCOMPOUNDER_STORAGE =
        0xaf31db2275af9d19e1d0340c8cbd037595d3c8505dede7df4950b3c168f87300;

    struct AutoCompounderStorage {
        /// @dev Maximum fee ratio for compound minting (18 decimals). e.g. 0.05 ether = 5%.
        uint256 maxFeeRatio;
    }

    function _getAutoCompounderStorage() private pure returns (AutoCompounderStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _AUTOCOMPOUNDER_STORAGE
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTRUCTOR / INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address stabilityPool_,
        address minter_
    ) ERC20Upgradeable() ERC4626Upgradeable() {
        _disableInitializers();
        STABILITY_POOL = stabilityPool_;
        MINTER = minter_;
        WRAPPED_COLLATERAL = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        PEGGED_TOKEN = IMinter(minter_).PEGGED_TOKEN();
        assert(IStabilityPool(stabilityPool_).ASSET_TOKEN() == PEGGED_TOKEN);
    }

    /// @notice Initialize the auto-compounder.
    /// @param deployerOwner_ The initial owner (typically the FactoryDeployer).
    /// @param pendingOwner_ The final owner (typically the Harbor multisig).
    /// @param maxFeeRatio_ The initial max fee ratio for compound minting (18 decimals).
    /// @param name_ The ERC20 name for the AC share token.
    /// @param symbol_ The ERC20 symbol for the AC share token.
    function initialize(
        address deployerOwner_,
        address pendingOwner_,
        uint256 maxFeeRatio_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
        __UUPSUpgradeable_init();
        __ERC4626_init(IERC20(STABILITY_POOL));
        __ERC20_init(name_, symbol_);
        _getAutoCompounderStorage().maxFeeRatio = maxFeeRatio_;

        // Permanent approvals for compound flow
        IERC20(PEGGED_TOKEN).approve(STABILITY_POOL, type(uint256).max);
        IERC20(WRAPPED_COLLATERAL).approve(MINTER, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                UUPS
    //////////////////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /*//////////////////////////////////////////////////////////////////////////
                                OWNERSHIP
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC5313
    function owner() public view override(HarborOwnable, IERC5313) returns (address owner_) {
        owner_ = HarborOwnable.owner();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Update the maximum fee ratio for compound minting.
    /// @param maxFeeRatio_ New max fee ratio (18 decimals). e.g. 0.05 ether = 5%.
    function setMaxFeeRatio(uint256 maxFeeRatio_) external onlyOwner {
        _getAutoCompounderStorage().maxFeeRatio = maxFeeRatio_;
        emit MaxFeeRatioUpdated(maxFeeRatio_);
    }

    /// @notice The current maximum fee ratio for compound minting.
    function maxFeeRatio() external view returns (uint256) {
        return _getAutoCompounderStorage().maxFeeRatio;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Total assets under management, in SP share units.
    /// @dev SP.balanceOf(this) + claimable wCOLn valued in pegged token terms via Minter dry run.
    function totalAssets() public view override returns (uint256) {
        uint256 spPosition = IERC20(STABILITY_POOL).balanceOf(address(this));
        uint256 claimableCollateral = IMultipleRewardAccumulator(STABILITY_POOL).claimable(address(this), WRAPPED_COLLATERAL);
        if (claimableCollateral == 0) {
            return spPosition;
        }
        // Use dry run with no fee cap to get price and rate, then value the claimable collateral.
        // price = underlying collateral price in peg terms (18 dec)
        // rate = wrapped-to-underlying rate (18 dec)
        // claimableValue = claimableCollateral * rate * price / 1e36
        (,,,, uint256 price, uint256 rate) =
            IMinter_v3(MINTER).mintPeggedTokenDryRun(claimableCollateral, type(uint256).max);
        uint256 claimableValue = claimableCollateral.mulDiv(rate, 1e18).mulDiv(price, 1e18);
        return spPosition + claimableValue;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                COMPOUND
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAutoCompounder
    function compound() external {
        uint256 claimable = IMultipleRewardAccumulator(STABILITY_POOL).claimable(address(this), WRAPPED_COLLATERAL);
        if (claimable == 0) {
            revert NothingToCompound();
        }

        uint256 maxFee = _getAutoCompounderStorage().maxFeeRatio;

        // Dry run to see how much can be profitably minted within the fee cap
        (,, uint256 collateralTaken,,,) = IMinter_v3(MINTER).mintPeggedTokenDryRun(claimable, maxFee);

        if (collateralTaken == 0) {
            // Fee too high - skip. wCOLn stays as unclaimed in SP, included in totalAssets via claimable().
            emit CompoundSkipped(msg.sender, claimable);
            return;
        }

        // Fractional claim: only take what can be profitably minted
        IMultipleRewardAccumulator_v3(STABILITY_POOL).claim(
            address(this), address(this), WRAPPED_COLLATERAL, collateralTaken
        );

        // Mint pegged tokens from the claimed collateral
        (uint256 minted,) = IMinter_v3(MINTER).mintPeggedToken(collateralTaken, address(this), 0, maxFee);

        // Deposit minted pegged tokens back into the SP
        IStabilityPool(STABILITY_POOL).deposit(minted, address(this), 0);

        emit Compounded(msg.sender, collateralTaken, minted);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CONVENIENCE DEPOSITS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAutoCompounder
    function depositPeggedToken(uint256 peggedAmount, address receiver) external returns (uint256 shares) {
        // Transfer pegged tokens from caller
        IERC20(PEGGED_TOKEN).safeTransferFrom(msg.sender, address(this), peggedAmount);

        // Deposit to SP - AC receives rebasing SP position
        uint256 spBalanceBefore = IERC20(STABILITY_POOL).balanceOf(address(this));
        IStabilityPool(STABILITY_POOL).deposit(peggedAmount, address(this), 0);
        uint256 spReceived = IERC20(STABILITY_POOL).balanceOf(address(this)) - spBalanceBefore;

        // Mint AC shares for the SP shares received
        shares = previewDeposit(spReceived);
        if (shares == 0) {
            revert DepositPeggedTokenZeroShares();
        }
        _mint(receiver, shares);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL OVERRIDES
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Deposit SP tokens from caller into the vault.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        IERC20(STABILITY_POOL).safeTransferFrom(caller, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Withdraw SP tokens from the vault to receiver.
    ///      Uses SP.transfer (not SP.withdraw) - the user receives the rebasing SP token directly.
    function _withdraw(address caller, address receiver, address tokenOwner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != tokenOwner) {
            _spendAllowance(tokenOwner, caller, shares);
        }
        _burn(tokenOwner, shares);
        IERC20(STABILITY_POOL).safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, tokenOwner, assets, shares);
    }

    /// @dev Decimals match the SP token (18).
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
