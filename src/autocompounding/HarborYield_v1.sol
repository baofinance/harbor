// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {Token} from "@bao/Token.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";

import {IHarborYield} from "src/interfaces/IHarborYield.sol";
import {IAutoCompounder} from "src/interfaces/IAutoCompounder.sol";
import {ISwapper} from "src/interfaces/ISwapper.sol";
import {StringPacking_v1} from "src/minter/library/StringPacking_v1.sol";

/// @title HarborYield_v1
/// @notice Level 2 yield vault: one per peg. Manages multiple ERC4626 vaults (AutoCompounders,
///         wrapped collateral, equivalents) that share the same peg.
/// @dev Replaces both hyToken_v1 (compound/swap) and HarborAnchoredVault_v1 (weighted distribution).
///
///      Each managed vault has a weight. Deposits are routed to the vault the user specifies.
///      `redistribute()` moves holdings toward the target weight distribution. Permissionless.
///      `compound()` converts equivalent vault holdings into AC vault holdings via the swapper.
///
///      All assets are assumed pegged 1:1. totalAssets() = SUM(IERC4626(v).convertToAssets(balance)).
// solhint-disable-next-line contract-name-capwords
contract HarborYield_v1 is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ReentrancyGuardTransientUpgradeable,
    HarborOwnableRoles,
    TokenHolder,
    IHarborYield
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    error VaultNotRegistered(address token);
    error VaultNotActive(address vault);
    error VaultAlreadyRegistered(address vault);
    error ZeroShares();
    error ZeroWeight();
    error NothingToRedistribute();

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Role for triggering compound (equivalent → AC conversion via swapper).
    uint256 public constant COMPOUNDER_ROLE = _ROLE_0;

    /// @notice Role for triggering redistribution toward target weights.
    uint256 public constant REDISTRIBUTOR_ROLE = _ROLE_1;

    /*//////////////////////////////////////////////////////////////////////////
                                    IMMUTABLES
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_NAME_0;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_NAME_1;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_SYMBOL;

    /// @notice The swapper contract for token conversions (at a predictable proxy address).
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable SWAPPER; // solhint-disable-line immutable-vars-naming

    /*//////////////////////////////////////////////////////////////////////////
                                    STORAGE (ERC7201)
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:harbor.storage.HarborYield_v1
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("harbor.storage.HarborYield_v1")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _HARBOR_YIELD_STORAGE = 0xb05ebd6dfc4d62a678d881c33089de39bf9f2de81bf0c8c698a99ab10ff31300;

    struct ManagedVault {
        address vault; // ERC4626 vault (AutoCompounder, wstETH wrapper, fxSAVE wrapper, etc.)
        address asset; // the vault's underlying asset
        uint96 weight; // target distribution weight (arbitrary units, not BPS)
        bool active; // accepts new deposits
        bool isAutoCompounder; // true if vault implements IAutoCompounder
    }

    struct HarborYieldStorage {
        ManagedVault[] vaults;
        mapping(address => uint256) assetToVaultIndex; // asset => index+1 (0 = not registered)
        uint256 totalWeight; // sum of all vault weights (cached for gas)
    }

    function _getHarborYieldStorage() private pure returns (HarborYieldStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _HARBOR_YIELD_STORAGE
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTRUCTOR / INITIALIZER
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(string memory name_, string memory symbol_, address swapper_) {
        _disableInitializers();
        (_ERC20_NAME_0, _ERC20_NAME_1) = StringPacking_v1.pack64(name_);
        _ERC20_SYMBOL = StringPacking_v1.pack32(symbol_);
        Token.ensureNonZeroAddress(swapper_);
        // slither-disable-next-line missing-zero-check
        SWAPPER = swapper_;
    }

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
                                ADMIN: VAULT MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Register a new ERC4626 vault with a target weight.
    /// @param vault The ERC4626 vault address.
    /// @param weight Target distribution weight (arbitrary units, must be > 0).
    /// @param isAutoCompounder Whether the vault implements IAutoCompounder.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-events
    function addVault(address vault, uint96 weight, bool isAutoCompounder) external onlyOwner {
        if (weight == 0) {
            revert ZeroWeight();
        }
        Token.ensureContract(vault);
        address asset = IERC4626(vault).asset();

        HarborYieldStorage storage $ = _getHarborYieldStorage();
        if ($.assetToVaultIndex[asset] != 0) {
            revert VaultAlreadyRegistered(vault);
        }

        $.vaults.push(
            ManagedVault({vault: vault, asset: asset, weight: weight, active: true, isAutoCompounder: isAutoCompounder})
        );
        $.assetToVaultIndex[asset] = $.vaults.length; // 1-indexed
        $.totalWeight += weight;

        IERC20(asset).forceApprove(vault, type(uint256).max);

        emit VaultAdded(vault, asset, weight);
    }

    /// @notice Update a vault's target weight. Set to 0 to drain via redistribution.
    function setVaultWeight(address vault, uint96 weight) external onlyOwner {
        HarborYieldStorage storage $ = _getHarborYieldStorage();
        for (uint256 i = 0; i < $.vaults.length; i++) {
            if ($.vaults[i].vault == vault) {
                $.totalWeight = $.totalWeight - $.vaults[i].weight + weight;
                $.vaults[i].weight = weight;
                emit VaultWeightUpdated(vault, weight);
                return;
            }
        }
        revert VaultNotRegistered(vault);
    }

    /// @notice Deactivate a vault (stop accepting deposits, keep existing holdings).
    function deactivateVault(address vault) external onlyOwner {
        HarborYieldStorage storage $ = _getHarborYieldStorage();
        for (uint256 i = 0; i < $.vaults.length; i++) {
            if ($.vaults[i].vault == vault) {
                $.vaults[i].active = false;
                emit VaultDeactivated(vault);
                return;
            }
        }
        revert VaultNotRegistered(vault);
    }

    /// @notice Reactivate a previously deactivated vault.
    function activateVault(address vault) external onlyOwner {
        HarborYieldStorage storage $ = _getHarborYieldStorage();
        for (uint256 i = 0; i < $.vaults.length; i++) {
            if ($.vaults[i].vault == vault) {
                $.vaults[i].active = true;
                emit VaultActivated(vault);
                return;
            }
        }
        revert VaultNotRegistered(vault);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ERC20 METADATA (IMMUTABLE)
    //////////////////////////////////////////////////////////////////////////*/

    function name() public view override returns (string memory) {
        return StringPacking_v1.unpack64(_ERC20_NAME_0, _ERC20_NAME_1);
    }

    function symbol() public view override returns (string memory) {
        return StringPacking_v1.unpack64(_ERC20_SYMBOL, bytes32(0));
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CORE: TOTAL ASSETS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborYield
    function totalAssets() public view returns (uint256 total) {
        HarborYieldStorage storage $ = _getHarborYieldStorage();
        uint256 length = $.vaults.length;
        for (uint256 i = 0; i < length; i++) {
            // slither-disable-next-line calls-loop
            uint256 vaultShares = IERC20($.vaults[i].vault).balanceOf(address(this));
            if (vaultShares > 0) {
                // slither-disable-next-line calls-loop
                total += IERC4626($.vaults[i].vault).convertToAssets(vaultShares);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CORE: DEPOSIT
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborYield
    // slither-disable-next-line reentrancy-no-eth
    function deposit(address asset, uint256 amount, address receiver) external nonReentrant returns (uint256 shares) {
        amount = Token.allOf(msg.sender, asset, amount);

        HarborYieldStorage storage $ = _getHarborYieldStorage();
        uint256 idx = $.assetToVaultIndex[asset];
        if (idx == 0) {
            revert VaultNotRegistered(asset);
        }
        ManagedVault storage mv = $.vaults[idx - 1];
        if (!mv.active) {
            revert VaultNotActive(mv.vault);
        }

        uint256 assetsBefore = totalAssets();
        uint256 supplyBefore = totalSupply();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        // slither-disable-next-line unused-return
        IERC4626(mv.vault).deposit(amount, address(this));

        shares = Math.mulDiv(amount, supplyBefore + 1, assetsBefore + 1);
        if (shares == 0) {
            revert ZeroShares();
        }
        _mint(receiver, shares);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CORE: REDEEM
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborYield
    function redeem(uint256 shares, address receiver, address tokenOwner) external nonReentrant {
        if (msg.sender != tokenOwner) {
            _spendAllowance(tokenOwner, msg.sender, shares);
        }

        uint256 supply = totalSupply();
        _burn(tokenOwner, shares);

        HarborYieldStorage storage $ = _getHarborYieldStorage();
        uint256 length = $.vaults.length;
        for (uint256 i = 0; i < length; i++) {
            // slither-disable-next-line calls-loop
            uint256 vaultShares = IERC20($.vaults[i].vault).balanceOf(address(this));
            if (vaultShares > 0) {
                uint256 redeemAmount = Math.mulDiv(vaultShares, shares, supply);
                if (redeemAmount > 0) {
                    // slither-disable-next-line calls-loop,unused-return
                    IERC4626($.vaults[i].vault).redeem(redeemAmount, receiver, address(this));
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CORE: COMPOUND
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborYield
    // slither-disable-next-line reentrancy-events
    function compound(
        address fromVault,
        address toVault,
        uint256 vaultShareAmount,
        uint256 minAmountOut,
        bytes calldata swapData
    ) external nonReentrant onlyOwnerOrRoles(COMPOUNDER_ROLE) {
        // Redeem from the source equivalent vault to get its underlying asset
        uint256 assetAmount = IERC4626(fromVault).redeem(vaultShareAmount, address(this), address(this));

        // Swap the asset to the target vault's asset
        uint256 swappedAmount = _swapIfNeeded(
            IERC4626(fromVault).asset(),
            IERC4626(toVault).asset(),
            assetAmount,
            minAmountOut,
            swapData
        );

        // Deposit into the target vault (typically an AC)
        // slither-disable-next-line unused-return
        IERC4626(toVault).deposit(swappedAmount, address(this));

        emit Compounded(msg.sender, fromVault, toVault, assetAmount, swappedAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CORE: REDISTRIBUTE
    //////////////////////////////////////////////////////////////////////////*/

    struct RedistributeWork {
        uint256 sourceIdx;
        uint256 targetIdx;
        uint256 moveValue;
    }

    /// @inheritdoc IHarborYield
    // slither-disable-next-line reentrancy-events
    function redistribute(
        uint256 maxVaultSharesPerVault,
        uint256 minAmountOut,
        bytes calldata swapData
    ) external nonReentrant onlyOwnerOrRoles(REDISTRIBUTOR_ROLE) {
        HarborYieldStorage storage $ = _getHarborYieldStorage();
        uint256 tw = $.totalWeight;
        if (tw == 0) {
            revert NothingToRedistribute();
        }
        uint256 total = totalAssets();
        if (total == 0) {
            revert NothingToRedistribute();
        }

        // Find the most over/under-weight vaults
        RedistributeWork memory w;
        {
            uint256 maxExcess;
            uint256 maxDeficit;
            uint256 length = $.vaults.length;
            for (uint256 i = 0; i < length; i++) {
                // slither-disable-next-line calls-loop
                uint256 bal = IERC20($.vaults[i].vault).balanceOf(address(this));
                // slither-disable-next-line calls-loop
                uint256 cur = bal > 0 ? IERC4626($.vaults[i].vault).convertToAssets(bal) : 0;
                uint256 tgt = Math.mulDiv(total, $.vaults[i].weight, tw);
                if (cur > tgt) {
                    uint256 excess = cur - tgt;
                    if (excess > maxExcess) {
                        maxExcess = excess;
                        w.sourceIdx = i;
                    }
                } else {
                    uint256 deficit = tgt - cur;
                    if (deficit > maxDeficit) {
                        maxDeficit = deficit;
                        w.targetIdx = i;
                    }
                }
            }
            if (maxExcess == 0 || maxDeficit == 0) {
                revert NothingToRedistribute();
            }
            w.moveValue = maxExcess < maxDeficit ? maxExcess : maxDeficit;
        }

        // Redeem from source, cap shares
        address srcVault = $.vaults[w.sourceIdx].vault;
        address dstVault = $.vaults[w.targetIdx].vault;
        {
            uint256 srcShares = IERC4626(srcVault).convertToShares(w.moveValue);
            if (srcShares > maxVaultSharesPerVault) {
                srcShares = maxVaultSharesPerVault;
            }
            w.moveValue = IERC4626(srcVault).redeem(srcShares, address(this), address(this));
        }
        // Swap if needed, deposit to target
        uint256 deposited = _swapIfNeeded(
            $.vaults[w.sourceIdx].asset,
            $.vaults[w.targetIdx].asset,
            w.moveValue,
            minAmountOut,
            swapData
        );
        // slither-disable-next-line unused-return
        IERC4626(dstVault).deposit(deposited, address(this));
        emit Redistributed(msg.sender, srcVault, dstVault, w.moveValue, deposited);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Swap fromAsset -> toAsset via SWAPPER, or pass through if same asset.
    /// Called from both compound() and redistribute().
    function _swapIfNeeded(
        address fromAsset,
        address toAsset,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata swapData
    ) private returns (uint256 amountOut) {
        if (fromAsset == toAsset) {
            return amountIn;
        }
        IERC20(fromAsset).forceApprove(SWAPPER, amountIn);
        amountOut = ISwapper(SWAPPER).swap(fromAsset, toAsset, amountIn, minAmountOut, swapData);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                VIEW: VAULT INFO
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborYield
    function vaultCount() external view returns (uint256) {
        return _getHarborYieldStorage().vaults.length;
    }

    /// @inheritdoc IHarborYield
    function vaultAt(uint256 index) external view returns (address vault, address asset, bool active, uint96 weight) {
        ManagedVault storage mv = _getHarborYieldStorage().vaults[index];
        vault = mv.vault;
        asset = mv.asset;
        active = mv.active;
        weight = mv.weight;
    }

    /// @notice The cached total of all vault weights.
    function totalWeight() external view returns (uint256) {
        return _getHarborYieldStorage().totalWeight;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                SWEEP
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc TokenHolder
    function _checkSweeper() internal view override(TokenHolder) {
        _checkOwner();
    }
}
