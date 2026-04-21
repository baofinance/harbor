// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626} from "@solady/tokens/ERC4626.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HarborOwnable} from "@bao/HarborOwnable.sol";
import {Token} from "@bao/Token.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";

import {IAutoCompounder} from "@harbor/interfaces/IAutoCompounder.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {IYieldManager} from "@harbor/interfaces/IYieldManager.sol";
import {ERC20MetadataLib_v1} from "@harbor/util/ERC20MetadataLib_v1.sol";

/// @title AutoCompounder_v1
/// @notice Level 1 auto-compounder: non-rebasing ERC4626 vault wrapping a rebasing stability pool position.
/// @dev The ERC4626 asset is the SP token (rebasing ERC20). Share count is fixed on deposit; share price
///      moves as totalAssets changes from harvest rewards, compounding, and rebalance losses.
///      compound() claims all wrapped collateral rewards, mints pegged tokens via the Minter (fee-capped),
///      and redeposits to the SP. Any residual wCOLn that cannot be profitably minted (fee too high or
///      minPegged not met) is routed to YIELD_MANAGER.distribute() if a yield manager is registered.
///      totalAssets() includes the SP position plus unclaimed wrapped collateral valued via Minter dry run.
///      Works for both collateral and leveraged stability pools.
// solhint-disable-next-line contract-name-capwords
contract AutoCompounder_v1 is
    Initializable,
    UUPSUpgradeable,
    ERC4626,
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

    /// @dev Thrown when neither a yield manager nor a local maxFeeRatio is provided.
    ///      Exactly one must be set: a yield manager that supplies mintMaxFeeRatio() dynamically,
    ///      or a non-zero maxFeeRatio constant for standalone use.
    error MaxFeeRatioSourceRequired();

    /// @dev Thrown when both a yield manager and a non-zero maxFeeRatio are provided.
    ///      Exactly one must be set: yield manager (dynamic) xor maxFeeRatio constant (standalone).
    error MaxFeeRatioSourceConflict();

    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every compound() call.
    /// @param caller The address that triggered the compound.
    /// @param collateralTotal Total wrapped collateral processed (claimed from SP + any pre-existing balance).
    /// @param peggedMinted Amount of pegged tokens minted and redeposited to the SP (0 if minting failed/skipped).
    /// @param residual Amount of wrapped collateral routed to YIELD_MANAGER.distribute() (0 if none).
    event Compounded(address indexed caller, uint256 collateralTotal, uint256 peggedMinted, uint256 residual);

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Upper-bound gas estimate for a compound() execution, used to compute the
    ///         Yearn-style minimum pegged output floor. Sized conservatively at 500k to
    ///         cover Minter mintPeggedToken (~125k), SP claim and deposit, and overhead.
    uint256 private constant MAX_COMPOUND_GAS = 500_000;

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

    /// @notice The yield manager (HarborYield) this AC is registered in.
    ///         Mutually exclusive with MAX_FEE_RATIO: exactly one of YIELD_MANAGER or MAX_FEE_RATIO
    ///         must be non-zero (enforced in constructor).
    ///         When set: compound() reads mintMaxFeeRatio() from here (portfolio-wide policy), routes
    ///         residual wCOLn via distribute(), and calls snapshotPerformance() after each compound.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable YIELD_MANAGER; // solhint-disable-line immutable-vars-naming

    /// @notice Maximum Minter fee ratio for standalone ACs (18 decimals, e.g. 0.05 ether = 5%).
    ///         Mutually exclusive with YIELD_MANAGER: exactly one must be non-zero.
    ///         Set at construction; linked to the Minter's fee tier configuration.
    ///         Zero when YIELD_MANAGER is set — mintMaxFeeRatio() is read from there instead.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable MAX_FEE_RATIO; // solhint-disable-line immutable-vars-naming

    /// @notice Oracle providing the peg reference asset price in ETH (IWrappedPriceOracle).
    ///         Required: used every compound() to compute the Yearn-style gas floor:
    ///         minPeggedOut = block.basefee × MAX_COMPOUND_GAS × maxUnderlyingPrice / 1e18
    ///         For the haETH peg a trivial constant oracle returning 1e18 is sufficient.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable PEG_ORACLE; // solhint-disable-line immutable-vars-naming

    /// @dev ERC20 name stored as two bytes32 (up to 64 characters)
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_NAME_0;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_NAME_1;

    /// @dev ERC20 symbol stored as bytes32 (up to 32 characters)
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_SYMBOL;

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTRUCTOR / INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param yieldManager_ HarborYield address, or address(0) for standalone. Mutually exclusive with maxFeeRatio_.
    /// @param maxFeeRatio_ Local fee cap (18 dec), or 0 when yieldManager_ is set. Mutually exclusive with yieldManager_.
    /// @param pegOracle_ Required IWrappedPriceOracle for the gas floor calculation.
    constructor(
        address stabilityPool_,
        address minter_,
        address yieldManager_,
        uint256 maxFeeRatio_,
        address pegOracle_,
        string memory name_,
        string memory symbol_
    ) {
        _disableInitializers();
        Token.ensureNonZeroAddress(stabilityPool_);
        Token.ensureNonZeroAddress(minter_);
        Token.ensureNonZeroAddress(pegOracle_);
        // Exactly one of {yieldManager, maxFeeRatio} must be set.
        if (yieldManager_ == address(0) && maxFeeRatio_ == 0) {
            revert MaxFeeRatioSourceRequired();
        }
        if (yieldManager_ != address(0) && maxFeeRatio_ != 0) {
            revert MaxFeeRatioSourceConflict();
        }
        // slither-disable-next-line missing-zero-check
        STABILITY_POOL = stabilityPool_;
        // slither-disable-next-line missing-zero-check
        MINTER = minter_;
        WRAPPED_COLLATERAL = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        PEGGED_TOKEN = IMinter(minter_).PEGGED_TOKEN();
        assert(IStabilityPool(stabilityPool_).ASSET_TOKEN() == PEGGED_TOKEN);
        // slither-disable-next-line missing-zero-check
        YIELD_MANAGER = yieldManager_;
        MAX_FEE_RATIO = maxFeeRatio_;
        // slither-disable-next-line missing-zero-check
        PEG_ORACLE = pegOracle_;
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
    }

    /*//////////////////////////////////////////////////////////////////////////
                                UUPS
    //////////////////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /*//////////////////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Set permanent token approvals for the compound flow.
    /// @dev Called by the deployer after proxy creation. Approves the SP to spend pegged tokens
    ///      and the Minter to spend wrapped collateral.
    function approveCompoundTokens() external onlyOwner {
        IERC20(PEGGED_TOKEN).forceApprove(STABILITY_POOL, type(uint256).max);
        IERC20(WRAPPED_COLLATERAL).forceApprove(MINTER, type(uint256).max);
    }

    /// @notice The effective maximum fee ratio for compound minting.
    ///         For yield-manager ACs reads dynamically from YIELD_MANAGER (portfolio-wide policy).
    ///         For standalone ACs returns the immutable MAX_FEE_RATIO set at construction.
    function mintMaxFeeRatio() external view returns (uint256) {
        if (YIELD_MANAGER != address(0)) {
            return IYieldManager(YIELD_MANAGER).mintMaxFeeRatio();
        }
        return MAX_FEE_RATIO;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ERC20 / ERC4626 METADATA
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The ERC4626 asset — the underlying rebasing StabilityPool share token.
    function asset() public view override returns (address) {
        return STABILITY_POOL;
    }

    /// @notice ERC20 name, packed into constructor immutables.
    function name() public view override returns (string memory) {
        return ERC20MetadataLib_v1.unpackName(_ERC20_NAME_0, _ERC20_NAME_1);
    }

    /// @notice ERC20 symbol, packed into constructor immutables.
    function symbol() public view override returns (string memory) {
        return ERC20MetadataLib_v1.unpackSymbol(_ERC20_SYMBOL);
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
        // Claim all active reward tokens from SP to this contract (includes WRAPPED_COLLATERAL).
        IMultipleRewardAccumulator(STABILITY_POOL).claim();

        // Total available: just claimed + any pre-existing balance (e.g. residual from a prior standalone compound).
        uint256 total = IERC20(WRAPPED_COLLATERAL).balanceOf(address(this));
        if (total == 0) {
            revert NothingToCompound();
        }

        // Yearn-style gas floor: skip minting when gas cost exceeds the pegged output value.
        // minPeggedOut = block.basefee × MAX_COMPOUND_GAS × (peg units per ETH) / 1e18
        // Use maxUnderlyingPrice (conservative): higher price → higher floor → fewer unprofitable calls.
        // slither-disable-next-line unused-return
        (, uint256 maxPegPerEth, ,) = IWrappedPriceOracle(PEG_ORACLE).latestAnswer();
        uint256 minPegged = Math.mulDiv(block.basefee, MAX_COMPOUND_GAS * maxPegPerEth, 1e18);

        // Fee cap: yield manager knows the opportunity cost of alternative DEX paths;
        // standalone ACs use the immutable set at construction.
        uint256 maxFee = YIELD_MANAGER != address(0)
            ? IYieldManager(YIELD_MANAGER).mintMaxFeeRatio()
            : MAX_FEE_RATIO;

        // Mint pegged tokens from claimed collateral. mintPeggedToken reverts if minPegged cannot
        // be met, or returns (0, 0) if the fee exceeds maxFee (when minPegged == 0, but here
        // minPegged > 0 so any failure reverts). Catch all failures and route wCOLn instead.
        uint256 peggedMinted;
        uint256 residual;
        try IMinter_v3(MINTER).mintPeggedToken(total, address(this), minPegged, maxFee)
            returns (uint256 peggedOut, uint256 collateralUsed) {
            if (peggedOut > 0) {
                // Deposit minted pegged tokens back into the SP.
                // slither-disable-next-line unused-return
                IStabilityPool(STABILITY_POOL).deposit(peggedOut, address(this), 0);
                peggedMinted = peggedOut;
            }
            residual = total - collateralUsed;
        } catch {
            residual = total;
        }

        // Route residual wCOLn to the yield manager for alternative conversion.
        if (residual > 0 && YIELD_MANAGER != address(0)) {
            IERC20(WRAPPED_COLLATERAL).safeTransfer(YIELD_MANAGER, residual);
            IYieldManager(YIELD_MANAGER).distribute(WRAPPED_COLLATERAL, residual);
        }

        // Ask the yield manager to snapshot all vault rates now that state has changed.
        if (YIELD_MANAGER != address(0)) {
            IYieldManager(YIELD_MANAGER).snapshotPerformance();
        }

        emit Compounded(msg.sender, total, peggedMinted, residual);
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
}
