// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HarborOwnable} from "@bao/HarborOwnable.sol";
import {Token} from "@bao/Token.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";

import {IAutoCompounder} from "src/interfaces/IAutoCompounder.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardAccumulator_v3} from "src/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IMinter_v3} from "src/interfaces/IMinter_v3.sol";
import {ERC20MetadataLib_v1} from "src/util/ERC20MetadataLib_v1.sol";

/// @title AutoCompounder_v1
/// @notice Level 1 auto-compounder: non-rebasing ERC4626 vault wrapping a rebasing stability pool position.
/// @dev The ERC4626 asset is the SP token (rebasing ERC20). Share count is fixed on deposit; share price
///      moves as totalAssets changes from harvest rewards, compounding, and rebalance losses.
///      compound() claims wrapped collateral rewards, mints pegged tokens via the Minter (fee-capped),
///      and redeposits to the SP.
///      totalAssets() includes the SP position plus unclaimed wrapped collateral valued via Minter dry run.
///      Works for both collateral and leveraged stability pools.
// solhint-disable-next-line contract-name-capwords
contract AutoCompounder_v1 is
    Initializable,
    UUPSUpgradeable,
    ERC4626Upgradeable,
    ReentrancyGuardTransientUpgradeable,
    HarborOwnable,
    TokenHolder,
    IAutoCompounder
{
    using SafeERC20 for IERC20;

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

    /// @notice Emitted on every compound() call.
    /// @param caller The address that triggered the compound.
    /// @param claimableCollateral The total amount of wrapped collateral available before compound.
    /// @param collateralClaimed The amount of wrapped collateral claimed (0 if skipped due to fees).
    /// @param peggedMinted The amount of pegged tokens minted (0 if skipped due to fees).
    event Compounded(
        address indexed caller,
        uint256 claimableCollateral,
        uint256 collateralClaimed,
        uint256 peggedMinted
    );

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

    /// @dev ERC20 name stored as two bytes32 (up to 64 characters)
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_NAME_0;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_NAME_1;

    /// @dev ERC20 symbol stored as bytes32 (up to 32 characters)
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_SYMBOL;

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
    constructor(address stabilityPool_, address minter_, string memory name_, string memory symbol_) {
        _disableInitializers();
        Token.ensureNonZeroAddress(stabilityPool_);
        Token.ensureNonZeroAddress(minter_);
        // slither-disable-next-line missing-zero-check
        STABILITY_POOL = stabilityPool_;
        // slither-disable-next-line missing-zero-check
        MINTER = minter_;
        WRAPPED_COLLATERAL = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        PEGGED_TOKEN = IMinter(minter_).PEGGED_TOKEN();
        assert(IStabilityPool(stabilityPool_).ASSET_TOKEN() == PEGGED_TOKEN);
        (_ERC20_NAME_0, _ERC20_NAME_1) = ERC20MetadataLib_v1.packName(name_);
        _ERC20_SYMBOL = ERC20MetadataLib_v1.packSymbol(symbol_);
    }

    /// @notice Initialize the auto-compounder.
    /// @param deployerOwner_ The initial owner (typically the FactoryDeployer).
    /// @param pendingOwner_ The final owner (typically the Harbor multisig).
    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        __ERC20_init("", "");
        __ERC4626_init(IERC20(STABILITY_POOL));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                UUPS
    //////////////////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

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

    /// @notice Set permanent token approvals for the compound flow.
    /// @dev Called by the deployer after proxy creation. Approves the SP to spend pegged tokens
    ///      and the Minter to spend wrapped collateral.
    function approveCompoundTokens() external onlyOwner {
        IERC20(PEGGED_TOKEN).forceApprove(STABILITY_POOL, type(uint256).max);
        IERC20(WRAPPED_COLLATERAL).forceApprove(MINTER, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ERC20 METADATA (IMMUTABLE)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice ERC20 name, packed into constructor immutables.
    function name() public view override(ERC20Upgradeable, IERC20Metadata) returns (string memory) {
        return ERC20MetadataLib_v1.unpackName(_ERC20_NAME_0, _ERC20_NAME_1);
    }

    /// @notice ERC20 symbol, packed into constructor immutables.
    function symbol() public view override(ERC20Upgradeable, IERC20Metadata) returns (string memory) {
        return ERC20MetadataLib_v1.unpackSymbol(_ERC20_SYMBOL);
    }

    /// @dev Decimals match the SP token (18).
    function decimals() public pure override(ERC4626Upgradeable) returns (uint8) {
        return 18;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Total assets under management, in SP share units.
    /// @dev SP.balanceOf(this) + claimable wrapped collateral valued in pegged token terms via Minter dry run.
    function totalAssets() public view override returns (uint256) {
        uint256 spPosition = IERC20(STABILITY_POOL).balanceOf(address(this));
        uint256 claimableCollateral = IMultipleRewardAccumulator(STABILITY_POOL).claimable(
            address(this),
            WRAPPED_COLLATERAL
        );
        if (claimableCollateral == 0) {
            return spPosition;
        }
        // Use dry run with no fee cap to get price and rate, then value the claimable collateral.
        // price = underlying collateral price in peg terms (18 dec)
        // rate = wrapped-to-underlying rate (18 dec)
        // claimableValue = claimableCollateral * rate * price / 1e36
        // slither-disable-next-line unused-return
        (, , , , uint256 price, uint256 rate) = IMinter_v3(MINTER).mintPeggedTokenDryRun(
            claimableCollateral,
            type(uint256).max
        );
        return spPosition + Math.mulDiv(claimableCollateral, price * rate, 1e36);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                COMPOUND
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAutoCompounder
    function compound() external nonReentrant {
        uint256 claimable = IMultipleRewardAccumulator(STABILITY_POOL).claimable(address(this), WRAPPED_COLLATERAL);
        if (claimable == 0) {
            revert NothingToCompound();
        }

        uint256 maxFee = _getAutoCompounderStorage().maxFeeRatio;

        // Dry run to see how much can be profitably minted within the fee cap
        // slither-disable-next-line unused-return
        (, , uint256 collateralTaken, , , ) = IMinter_v3(MINTER).mintPeggedTokenDryRun(claimable, maxFee);

        if (collateralTaken == 0) {
            // Fee too high - skip. Wrapped collateral stays as unclaimed in SP,
            // included in totalAssets via claimable().
            emit Compounded(msg.sender, claimable, 0, 0);
            return;
        }

        // Fractional claim: only take what can be profitably minted
        IMultipleRewardAccumulator_v3(STABILITY_POOL).claim(
            address(this),
            address(this),
            WRAPPED_COLLATERAL,
            collateralTaken
        );

        // Mint pegged tokens from the claimed collateral
        // slither-disable-next-line unused-return
        (uint256 minted, ) = IMinter_v3(MINTER).mintPeggedToken(collateralTaken, address(this), 0, maxFee);

        // Deposit minted pegged tokens back into the SP
        // slither-disable-next-line unused-return
        IStabilityPool(STABILITY_POOL).deposit(minted, address(this), 0);

        emit Compounded(msg.sender, claimable, collateralTaken, minted);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CONVENIENCE DEPOSITS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAutoCompounder
    // slither-disable-next-line reentrancy-no-eth
    function depositPeggedToken(uint256 peggedAmount, address receiver) external nonReentrant returns (uint256 shares) {
        peggedAmount = Token.allOf(msg.sender, PEGGED_TOKEN, peggedAmount);

        // Snapshot exchange rate BEFORE the SP deposit changes totalAssets
        uint256 assetsBefore = totalAssets();
        uint256 supplyBefore = totalSupply();

        // Transfer pegged tokens from caller, deposit to SP
        IERC20(PEGGED_TOKEN).safeTransferFrom(msg.sender, address(this), peggedAmount);
        uint256 spBalanceBefore = IERC20(STABILITY_POOL).balanceOf(address(this));
        // slither-disable-next-line unused-return
        IStabilityPool(STABILITY_POOL).deposit(peggedAmount, address(this), 0);
        uint256 spReceived = IERC20(STABILITY_POOL).balanceOf(address(this)) - spBalanceBefore;

        // Compute shares at the pre-deposit exchange rate (matches ERC4626._convertToShares)
        shares = Math.mulDiv(spReceived, supplyBefore + 1, assetsBefore + 1);
        // slither-disable-next-line incorrect-equality
        if (shares == 0) {
            revert DepositPeggedTokenZeroShares();
        }
        _mint(receiver, shares);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                SWEEP
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc TokenHolder
    function _checkSweeper() internal view override(TokenHolder) {
        _checkOwner();
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
    function _withdraw(
        address caller,
        address receiver,
        address tokenOwner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != tokenOwner) {
            _spendAllowance(tokenOwner, caller, shares);
        }
        _burn(tokenOwner, shares);
        IERC20(STABILITY_POOL).safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, tokenOwner, assets, shares);
    }
}
