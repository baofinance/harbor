// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {Token} from "@bao/Token.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";

import {IHarborYield} from "@harbor/interfaces/IHarborYield.sol";
import {IAutoCompounder} from "@harbor/interfaces/IAutoCompounder.sol";
import {ISwapper} from "@harbor/interfaces/ISwapper.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {ERC20MetadataLib_v1} from "@harbor/util/ERC20MetadataLib_v1.sol";

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
    ERC20,
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

    /// @notice An AutoCompounder vault's `PEGGED_TOKEN` does not match this HarborYield's peg
    ///         token. The caller is trying to register an AC from the wrong market.
    error WrongPegToken(address expected, address actual);

    /// @notice A vault's asset does not value 1:1 against the peg token within the allowed
    ///         drift. Either a config error (wrong asset) or a market depeg in progress.
    error ExcessivePegDrift(uint256 expected, uint256 actual);

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

    /// @notice The peg token (e.g. haEUR) that values the HarborYield share in peg units.
    ///         HY is not ERC-4626 — it holds multiple assets — but `asset()` returns this token
    ///         for interop with aggregators and price feeds. Also serves as the peg-identity
    ///         reference for `addVault` — AC vaults are checked against this via
    ///         `IAutoCompounder.PEGGED_TOKEN()`, and equivalent vaults are checked via the
    ///         swapper's value preview against this token.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable _PEG_TOKEN;

    /*//////////////////////////////////////////////////////////////////////////
                                    STORAGE (ERC7201)
    //////////////////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:harbor.storage.HarborYield_v1
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("harbor.storage.HarborYield_v1")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _HARBOR_YIELD_STORAGE = 0xb05ebd6dfc4d62a678d881c33089de39bf9f2de81bf0c8c698a99ab10ff31300;

    struct ManagedVault {
        address vault; // ERC4626 vault (AutoCompounder, wstETH wrapper, fxSAVE wrapper, etc.)
        uint64 weight; // target distribution weight (arbitrary units) — packs into slot with vault + bools
        bool active; // accepts new deposits
        bool isAutoCompounder; // true if vault implements IAutoCompounder
    }

    struct HarborYieldStorage {
        ManagedVault[] vaults;
        mapping(address => uint256) assetToVaultIndex; // asset => index+1 (0 = not registered)
        uint256 totalWeight; // sum of all vault weights (cached for gas)
        uint64 maxPegDriftBps; // max deviation from 1:1 for equivalent vaults, in bps (10000 = 100%)
        mapping(address => address) vaultValuationOracle; // sparse: equivalents only; AC vaults use default address(0)
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
    constructor(string memory name_, string memory symbol_, address swapper_, address pegToken_) {
        _disableInitializers();
        (_ERC20_NAME_0, _ERC20_NAME_1) = ERC20MetadataLib_v1.packName(name_);
        _ERC20_SYMBOL = ERC20MetadataLib_v1.packSymbol(symbol_);
        Token.ensureNonZeroAddress(swapper_);
        Token.ensureNonZeroAddress(pegToken_);
        // slither-disable-next-line missing-zero-check
        SWAPPER = swapper_;
        // slither-disable-next-line missing-zero-check
        _PEG_TOKEN = pegToken_;
    }

    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        // Solady ERC20 has no init hook — name/symbol are resolved via virtual overrides
        // backed by ERC20MetadataLib_v1 immutables in the constructor. Permit is built in.
    }

    /*//////////////////////////////////////////////////////////////////////////
                                UUPS
    //////////////////////////////////////////////////////////////////////////*/

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /*//////////////////////////////////////////////////////////////////////////
                                ADMIN: VAULT MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Register an AutoCompounder vault. Verifies the AC's underlying pegged token
    ///         matches this HarborYield's peg token by introspecting `IAutoCompounder.PEGGED_TOKEN()`.
    ///         No oracle required — ACs hold the peg token directly via their underlying SP.
    /// @param vault The AutoCompounder vault address.
    /// @param weight Target distribution weight (arbitrary units, must be > 0).
    // slither-disable-next-line reentrancy-no-eth,reentrancy-events
    function addAutoCompounderVault(address vault, uint64 weight) external onlyOwner {
        Token.ensureContract(vault);
        address acPegged = IAutoCompounder(vault).PEGGED_TOKEN();
        if (acPegged != _PEG_TOKEN) {
            revert WrongPegToken(_PEG_TOKEN, acPegged);
        }
        _addVault(vault, weight, true, address(0));
    }

    /// @notice Register an equivalent-yield ERC4626 vault with a required peg-value oracle.
    ///         The oracle's current mid-rate must be within `maxPegDriftBps` of 1:1 with the
    ///         peg token, or registration reverts. The oracle is stored per-vault and used by
    ///         `totalAssets` for valuation and by `compound`/`redistribute` for the runtime
    ///         oracle-bounded swap floor.
    /// @param vault The equivalent-yield ERC4626 vault.
    /// @param weight Target distribution weight.
    /// @param valuationOracle IWrappedPriceOracle providing (price, rate) for the vault's
    ///                        asset vs the peg token.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-events
    function addEquivalentVault(address vault, uint64 weight, address valuationOracle) external onlyOwner {
        Token.ensureContract(vault);
        Token.ensureContract(valuationOracle);

        // Check that the oracle currently reports a rate close to 1:1. This catches wrong-class
        // assets (oracle rate obviously not ~1e18) and currently-depegged assets (oracle rate
        // > maxPegDriftBps away from 1e18).
        uint256 rate = _oracleRatePegUnits(valuationOracle);
        _requirePegDriftWithin(1 ether, rate);

        _addVault(vault, weight, false, valuationOracle);
    }

    /// @dev Shared bookkeeping for both addVault variants. Both callers have already verified
    ///      the vault-class-specific peg check before reaching here.
    function _addVault(address vault, uint64 weight, bool isAutoCompounder, address valuationOracle) private {
        if (weight == 0) {
            revert ZeroWeight();
        }
        address vaultAsset = IERC4626(vault).asset();

        HarborYieldStorage storage $ = _getHarborYieldStorage();
        if ($.assetToVaultIndex[vaultAsset] != 0) {
            revert VaultAlreadyRegistered(vault);
        }

        $.vaults.push(ManagedVault({vault: vault, weight: weight, active: true, isAutoCompounder: isAutoCompounder}));
        $.assetToVaultIndex[vaultAsset] = $.vaults.length; // 1-indexed
        $.totalWeight += weight;
        if (valuationOracle != address(0)) {
            $.vaultValuationOracle[vault] = valuationOracle;
        }

        IERC20(vaultAsset).forceApprove(vault, type(uint256).max);

        emit VaultAdded(vault, vaultAsset, weight);
    }

    /// @notice Update the maximum peg drift allowed for equivalent-vault registration and
    ///         rebalance swaps, in basis points (e.g., 200 = 2%).
    /// @dev Setting to 0 forces exact 1:1 parity, which will break for any real equivalent;
    ///      intended for deactivation / emergency freeze only.
    function setMaxPegDriftBps(uint64 newMaxPegDriftBps) external onlyOwner {
        _getHarborYieldStorage().maxPegDriftBps = newMaxPegDriftBps;
        emit MaxPegDriftBpsUpdated(newMaxPegDriftBps);
    }

    /// @notice The current maximum peg drift in basis points.
    function maxPegDriftBps() external view returns (uint64) {
        return _getHarborYieldStorage().maxPegDriftBps;
    }

    /// @notice Update a vault's target weight. Set to 0 to drain via redistribution.
    function setVaultWeight(address vault, uint64 weight) external onlyOwner {
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
        return ERC20MetadataLib_v1.unpackName(_ERC20_NAME_0, _ERC20_NAME_1);
    }

    function symbol() public view override returns (string memory) {
        return ERC20MetadataLib_v1.unpackSymbol(_ERC20_SYMBOL);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ERC-4626 VIEW SHIM
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The peg token that values HarborYield shares.
    /// @dev HarborYield is not a standard ERC-4626 vault (it holds multiple assets with
    ///      proportional redemption). This view exists for interop with aggregators, portfolio
    ///      trackers, and price feeds that expect an ERC-4626-style `asset()` getter. The
    ///      mutation surface (`deposit(asset, amount, receiver)`, `redeem`) is intentionally
    ///      non-standard.
    function asset() public view returns (address) {
        return _PEG_TOKEN;
    }

    /// @inheritdoc IHarborYield
    function totalAssets() public view returns (uint256 total) {
        HarborYieldStorage storage $ = _getHarborYieldStorage();
        uint256 length = $.vaults.length;
        for (uint256 i = 0; i < length; i++) {
            address vault = $.vaults[i].vault;
            // slither-disable-next-line calls-loop
            uint256 vaultShares = IERC20(vault).balanceOf(address(this));
            // Zero-balance skip: `== 0` is an exact guard, not a comparison used to drive
            // financial logic — we just avoid the follow-on convertToAssets/oracle calls when
            // there's nothing to value.
            // slither-disable-next-line incorrect-equality
            if (vaultShares == 0) {
                continue;
            }
            // slither-disable-next-line calls-loop
            uint256 vaultAssets = IERC4626(vault).convertToAssets(vaultShares);
            // slither-disable-next-line calls-loop
            total += Math.mulDiv(vaultAssets, _fairRateInPegUnits(vault), 1 ether);
        }
    }

    /// @notice Convert an assets amount (in peg units) to HarborYield share units, rounded down.
    /// @dev Matches the internal formula used in `deposit`: `shares * (supply + 1) / (assets + 1)`.
    ///      For interop only; the actual `deposit(asset, amount, receiver)` path uses the
    ///      vault-specific asset, not the peg token.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + 1, totalAssets() + 1);
    }

    /// @notice Convert a HarborYield share amount to assets in peg units, rounded down.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + 1, totalSupply() + 1);
    }

    /// @notice Preview the shares that would be minted by depositing `assets` peg units.
    /// @dev HY has no deposit entrypoint that takes the peg token directly; this preview
    ///      reflects the economic conversion rate, not a concrete deposit path.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Preview the assets (in peg units) that `shares` would redeem for at the current rate.
    /// @dev HY's actual `redeem` pays out a proportional mix of every managed vault's holdings,
    ///      not peg tokens. This preview reflects the share price in peg units for valuation only.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CORE: DEPOSIT
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborYield
    // slither-disable-next-line reentrancy-no-eth
    function deposit(address asset_, uint256 amount, address receiver) external nonReentrant returns (uint256 shares) {
        amount = Token.allOf(msg.sender, asset_, amount);

        HarborYieldStorage storage $ = _getHarborYieldStorage();
        uint256 idx = $.assetToVaultIndex[asset_];
        if (idx == 0) {
            revert VaultNotRegistered(asset_);
        }
        ManagedVault storage mv = $.vaults[idx - 1];
        if (!mv.active) {
            revert VaultNotActive(mv.vault);
        }

        uint256 assetsBefore = totalAssets();
        uint256 supplyBefore = totalSupply();

        IERC20(asset_).safeTransferFrom(msg.sender, address(this), amount);
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
    // Guarded by `nonReentrant` and role-gated to COMPOUNDER_ROLE / owner. The external redeem
    // on line 431 is followed by a storage read (_effectiveMinOut reads maxPegDriftBps via the
    // ERC7201 slot), which slither classifies as a "state write" because of the assembly slot
    // binding — it's a pointer load, not a mutation. No attacker-controlled state transition
    // spans the call.
    // slither-disable-next-line reentrancy-events,reentrancy-no-eth,reentrancy-benign
    function compound(
        address fromVault,
        address toVault,
        uint256 vaultShareAmount,
        uint256 minAmountOut,
        bytes calldata swapData
    ) external nonReentrant onlyOwnerOrRoles(COMPOUNDER_ROLE) {
        // Redeem from the source vault to get its underlying asset
        uint256 assetAmount = IERC4626(fromVault).redeem(vaultShareAmount, address(this), address(this));

        // Apply HY's oracle-bounded floor on top of the keeper's minAmountOut. If the keeper
        // is lazy or compromised and passes a low minAmountOut, HY's own floor kicks in.
        uint256 effectiveMin = _effectiveMinOut(fromVault, toVault, assetAmount, minAmountOut);

        // Swap the asset to the target vault's asset
        uint256 swappedAmount = _swapIfNeeded(
            IERC4626(fromVault).asset(),
            IERC4626(toVault).asset(),
            assetAmount,
            effectiveMin,
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
    // Guarded by `nonReentrant` and role-gated to REDISTRIBUTOR_ROLE / owner. The external
    // redeem on line 520 is followed by a storage read (_effectiveMinOut reads maxPegDriftBps
    // via the ERC7201 slot), which slither classifies as a "state write" because of the
    // assembly slot binding — it's a pointer load, not a mutation. No attacker-controlled
    // state transition spans the call.
    // slither-disable-next-line reentrancy-events,reentrancy-no-eth,reentrancy-benign
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

        // Apply HY's oracle-bounded floor on top of the keeper's minAmountOut.
        uint256 effectiveMin = _effectiveMinOut(srcVault, dstVault, w.moveValue, minAmountOut);

        // Swap if needed, deposit to target
        uint256 deposited = _swapIfNeeded(
            IERC4626(srcVault).asset(),
            IERC4626(dstVault).asset(),
            w.moveValue,
            effectiveMin,
            swapData
        );
        // slither-disable-next-line unused-return
        IERC4626(dstVault).deposit(deposited, address(this));
        emit Redistributed(msg.sender, srcVault, dstVault, w.moveValue, deposited);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL: PEG VALUATION
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Return the current fair rate (peg units per 1 asset unit, 18 decimals) for a
    ///      registered vault.
    ///
    ///      The sparse `vaultValuationOracle` mapping is the branch discriminator:
    ///        - `address(0)` → AC vault. Read `peggedTokenPrice()` from the vault's Minter
    ///          (normally 1e18, lower during a peg-token depeg). No oracle lookup for the
    ///          asset side because an AC's asset is the SP token, which is 1:1 with the peg
    ///          token (haXXX) via the pool.
    ///        - non-zero → equivalent vault. Read the registered `IWrappedPriceOracle` and
    ///          combine min/max price and rate into a single mid value.
    function _fairRateInPegUnits(address vault) private view returns (uint256) {
        address oracle = _getHarborYieldStorage().vaultValuationOracle[vault];
        if (oracle == address(0)) {
            // Called from totalAssets()'s per-vault loop. Targets are owner-gated at registration
            // (addAutoCompounderVault), vault count is small by design, and the Minter is a
            // trusted Harbor contract — so the calls-loop DoS risk does not apply here.
            // slither-disable-next-line calls-loop
            address minter = IAutoCompounder(vault).MINTER();
            // slither-disable-next-line calls-loop
            return IMinter(minter).peggedTokenPrice();
        }
        return _oracleRatePegUnits(oracle);
    }

    /// @dev Return the mid-rate reported by an IWrappedPriceOracle, expressed as
    ///      "peg units per 1 asset unit" in 18 decimals: `mid(price) * mid(rate) / 1e18`.
    function _oracleRatePegUnits(address oracle) private view returns (uint256) {
        // Called transitively from totalAssets()'s per-vault loop. The oracle is owner-vetted
        // at addEquivalentVault (_requirePegDriftWithin is called on it), vault count is small,
        // and the oracle is a trusted Harbor-registered contract — so the calls-loop DoS risk
        // does not apply here.
        // slither-disable-next-line calls-loop
        (uint256 minP, uint256 maxP, uint256 minR, uint256 maxR) = IWrappedPriceOracle(oracle).latestAnswer();
        uint256 price = (minP + maxP) / 2;
        uint256 rate = (minR + maxR) / 2;
        return Math.mulDiv(price, rate, 1 ether);
    }

    /// @dev Revert if `actual` is not within `maxPegDriftBps` of `expected`. Symmetric
    ///      range check used by `addEquivalentVault` to assert the oracle currently reports
    ///      a rate close to 1:1 with the peg token.
    function _requirePegDriftWithin(uint256 expected, uint256 actual) private view {
        uint256 tolerance = Math.mulDiv(expected, _getHarborYieldStorage().maxPegDriftBps, 10_000);
        if (actual < expected - tolerance || actual > expected + tolerance) {
            revert ExcessivePegDrift(expected, actual);
        }
    }

    /// @dev Compute the oracle-bounded minimum acceptable output for a swap from one managed
    ///      vault's asset into another's. The returned value is `max(keeperMinOut, oracleFloor)`,
    ///      so a compromised keeper passing `keeperMinOut = 0` still gets HY's own floor.
    function _effectiveMinOut(
        address fromVault,
        address toVault,
        uint256 amountIn,
        uint256 keeperMinOut
    ) private view returns (uint256) {
        uint256 fromRate = _fairRateInPegUnits(fromVault);
        uint256 toRate = _fairRateInPegUnits(toVault);
        uint256 expectedOut = Math.mulDiv(amountIn, fromRate, toRate);
        uint256 oracleFloor = Math.mulDiv(expectedOut, 10_000 - _getHarborYieldStorage().maxPegDriftBps, 10_000);
        return keeperMinOut > oracleFloor ? keeperMinOut : oracleFloor;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL: SWAPPER
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
    function vaultAt(uint256 index) external view returns (address vault, address asset_, bool active, uint64 weight) {
        ManagedVault storage mv = _getHarborYieldStorage().vaults[index];
        vault = mv.vault;
        // slither-disable-next-line calls-loop
        asset_ = IERC4626(mv.vault).asset();
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
