// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@solady/auth/Ownable.sol";
import { OwnableRoles } from "@solady/auth/OwnableRoles.sol";

import { IMintable, IBurnable, IBurnableFrom } from "src/minter/IMintable.sol";

// import { BaoAccessControl } from "src/common/BaoAccessControl.sol";

/// @title Bao Minter Leveraged Token
/// @notice A simple ERC20 token used as the leveraged token for a Bao Minter
/// @author rootminus0x1
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
contract LeveragedToken_v1 is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    OwnableRoles,
    ERC165Upgradeable,
    IMintable,
    IBurnable,
    IBurnableFrom
{
    using SafeERC20 for IERC20;
    uint256 public constant MINTER_ROLE = _ROLE_0;

    /// @notice initialise the UUPS proxy
    /// @param name The name of the ERC20 token
    /// @param symbol The symbol of the ERC20 token. This expected to reflect the collateral and pegged token symbols
    function initialize(address owner, string memory name, string memory symbol) public initializer {
        if (owner == address(0)) revert NewOwnerIsZeroAddress();
        _initializeOwner(owner);
        __UUPSUpgradeable_init();
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        __ERC165_init();
    }

    function _guardInitializeOwner() internal pure override(Ownable) returns (bool guard) {
        guard = true;
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// only DEFAULT_ADMIN_ROLE grantees can upgrade this contract.
    function _authorizeUpgrade(address) internal virtual override onlyOwner {}

    /// @notice Returns true if a given interface is supported.
    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IMintable).interfaceId ||
            interfaceId == type(IBurnableFrom).interfaceId ||
            interfaceId == type(IBurnable).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IERC20Metadata).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @notice Mints an amount of a token
    /// @param to The receiver of the new tokens.
    /// @param amount The amount of tokens minted.
    function mint(address to, uint256 amount) public override onlyRoles(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burns an amount of a token
    /// @param amount The amount of tokens burned. This amount must be owned by the caller.
    function burn(uint256 amount) public override onlyRoles(MINTER_ROLE) {
        _burn(_msgSender(), amount);
    }

    /// @notice Burns an amount of a token
    /// @param from The address of the owner of the tokens being burned.
    /// @param amount The amount of tokens burned. This amount must be owned `from`.
    function burnFrom(address from, uint256 amount) public override onlyRoles(MINTER_ROLE) {
        _burn(from, amount);
    }
}
