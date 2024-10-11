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
import { OwnableRoles } from "@solady/auth/OwnableRoles.sol";

import { ILeveragedToken, IERC165, IERC20Permit } from "./ILeveragedToken.sol";
import { IOwnable, IOwnableRoles } from "@bao/interfaces/IOwnableRoles.sol";
import { IMintable } from "@bao/interfaces/IMintable.sol";
import { IBurnable } from "@bao/interfaces/IBurnable.sol";
import { IBurnableFrom } from "@bao/interfaces/IBurnableFrom.sol";

/// @title Bao Minter Leveraged Token
/// @notice A simple ERC20 token used as the leveraged token for a Bao Minter
/// @author rootminus0x1
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract LeveragedToken_v1 is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    OwnableRoles,
    ERC165Upgradeable,
    /* ILeveragedToken */
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

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(ILeveragedToken).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IERC20Metadata).interfaceId ||
            interfaceId == type(IERC20Permit).interfaceId ||
            interfaceId == type(IOwnable).interfaceId ||
            interfaceId == type(IOwnableRoles).interfaceId ||
            interfaceId == type(IMintable).interfaceId ||
            interfaceId == type(IBurnable).interfaceId ||
            interfaceId == type(IBurnableFrom).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IMintable
    function mint(address to, uint256 amount) public override onlyRoles(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @inheritdoc IBurnable
    function burn(uint256 amount) public override onlyRoles(MINTER_ROLE) {
        _burn(_msgSender(), amount);
    }

    /// @inheritdoc IBurnableFrom
    function burnFrom(address from, uint256 amount) public override onlyRoles(MINTER_ROLE) {
        _burn(from, amount);
    }
}
