// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HarborOwnable} from "@bao/HarborOwnable.sol";
import {Token} from "@bao/Token.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";

import {IHarborYield} from "src/interfaces/IHarborYield.sol";
import {StringPacking_v1} from "src/minter/library/StringPacking_v1.sol";

/// @title HarborYield_v1
/// @notice Level 2 yield vault: one per peg. Manages multiple ERC4626 vaults (AutoCompounders,
///         wrapped collateral, equivalents) that share the same peg.
/// @dev Users deposit peg-denominated assets (stETH, fxUSD, SP tokens). The vault deposits them
///      into the corresponding ERC4626 vault and holds the interest-bearing shares. The hyXXX share
///      represents a proportional claim on all held vault shares.
///
///      All assets are assumed pegged 1:1 to the same unit. totalAssets() sums
///      IERC4626(vault).convertToAssets(balance) across all managed vaults.
///
///      Withdrawal returns a proportional mix of all held vault assets.
// solhint-disable-next-line contract-name-capwords
contract HarborYield_v1 is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    HarborOwnable,
    TokenHolder,
    IERC5313,
    IHarborYield
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                    ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    error VaultNotRegistered(address asset);
    error VaultNotActive(address vault);
    error VaultAlreadyRegistered(address vault);
    error ZeroShares();

    /*//////////////////////////////////////////////////////////////////////////
                                    IMMUTABLES
    //////////////////////////////////////////////////////////////////////////*/

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

    /// @custom:storage-location erc7201:harbor.storage.HarborYield_v1
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("harbor.storage.HarborYield_v1")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _HARBOR_YIELD_STORAGE =
        0xb05ebd6dfc4d62a678d881c33089de39bf9f2de81bf0c8c698a99ab10ff31300;

    struct ManagedVault {
        address vault;    // ERC4626 vault (wstETH, fxSAVE, AutoCompounder, or adapter)
        address asset;    // the vault's underlying asset (stETH, fxUSD, hpETH.stETH)
        bool active;      // accepts new deposits
    }

    struct HarborYieldStorage {
        ManagedVault[] vaults;
        mapping(address => uint256) assetToVaultIndex; // asset address => index+1 (0 = not registered)
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
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20Upgradeable() {
        _disableInitializers();
        (_ERC20_NAME_0, _ERC20_NAME_1) = StringPacking_v1.pack64(name_);
        // slither-disable-next-line unused-return
        (_ERC20_SYMBOL,) = StringPacking_v1.pack64(symbol_);
    }

    /// @notice Initialize the HarborYield vault.
    /// @param deployerOwner_ The initial owner (typically the FactoryDeployer).
    /// @param pendingOwner_ The final owner (typically the Harbor multisig).
    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
        __UUPSUpgradeable_init();
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

    /// @notice Register a new ERC4626 vault to manage.
    /// @param vault The ERC4626 vault address.
    function addVault(address vault) external onlyOwner {
        Token.ensureContract(vault);
        address asset = IERC4626(vault).asset();

        HarborYieldStorage storage $ = _getHarborYieldStorage();
        if ($.assetToVaultIndex[asset] != 0) {
            revert VaultAlreadyRegistered(vault);
        }

        $.vaults.push(ManagedVault({vault: vault, asset: asset, active: true}));
        $.assetToVaultIndex[asset] = $.vaults.length; // 1-indexed

        // Permanent approval for deposits into this vault
        IERC20(asset).approve(vault, type(uint256).max);

        emit VaultAdded(vault, asset);
    }

    /// @notice Deactivate a vault (stop accepting deposits, keep existing holdings).
    /// @param vault The vault to deactivate.
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
    /// @param vault The vault to reactivate.
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
        for (uint256 i = 0; i < $.vaults.length; i++) {
            address vault = $.vaults[i].vault;
            uint256 vaultShares = IERC20(vault).balanceOf(address(this));
            if (vaultShares > 0) {
                total += IERC4626(vault).convertToAssets(vaultShares);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CORE: DEPOSIT
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborYield
    function deposit(address asset, uint256 amount, address receiver) external returns (uint256 shares) {
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

        // Snapshot totalAssets before deposit changes it
        uint256 assetsBefore = totalAssets();
        uint256 supplyBefore = totalSupply();

        // Transfer asset from caller and deposit into the ERC4626 vault
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC4626(mv.vault).deposit(amount, address(this));

        // Compute hyXXX shares at the pre-deposit exchange rate
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
    function redeem(uint256 shares, address receiver, address tokenOwner) external {
        if (msg.sender != tokenOwner) {
            _spendAllowance(tokenOwner, msg.sender, shares);
        }

        uint256 supply = totalSupply();
        _burn(tokenOwner, shares);

        // Redeem proportional vault shares from each managed vault
        HarborYieldStorage storage $ = _getHarborYieldStorage();
        for (uint256 i = 0; i < $.vaults.length; i++) {
            address vault = $.vaults[i].vault;
            uint256 vaultShares = IERC20(vault).balanceOf(address(this));
            if (vaultShares > 0) {
                uint256 redeemAmount = Math.mulDiv(vaultShares, shares, supply);
                if (redeemAmount > 0) {
                    IERC4626(vault).redeem(redeemAmount, receiver, address(this));
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                VIEW: VAULT INFO
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborYield
    function vaultCount() external view returns (uint256) {
        return _getHarborYieldStorage().vaults.length;
    }

    /// @inheritdoc IHarborYield
    function vaultAt(uint256 index) external view returns (address vault, address asset, bool active) {
        ManagedVault storage mv = _getHarborYieldStorage().vaults[index];
        vault = mv.vault;
        asset = mv.asset;
        active = mv.active;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                SWEEP
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc TokenHolder
    function _checkSweeper() internal view override(TokenHolder) {
        _checkOwner();
    }
}
