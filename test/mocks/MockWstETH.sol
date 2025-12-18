// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";

/// @title Mock wstETH
/// @author rootminus0x1
/// @notice A simple ERC20 token that allows unprotected minting.
/// It is not a direct copy of wstETH but a re-implementation so that it can represent other candidate collateral tokens
/// in the Minter framework.
/// It is written as an upgradeable proxy so that features can be added or removed more easily for testing.
/// This does not, of course, preclude deploying variants of potential pegged tokens under different proxies.
/// The mint and burn functions are unprotected.
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
contract MockWstETH is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    OwnableUpgradeable,
    IMintable,
    IBurnable,
    IBurnableFrom
{
    using SafeERC20 for IERC20;

    /// @notice initialise the UUPS proxy
    function initialize(address owner) public initializer {
        __ERC20_init("Mock wstETH", "wstETH");
        __ERC20Permit_init("wstETH");
        __Ownable_init(owner);
        __UUPSUpgradeable_init();
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// only DEFAULT_ADMIN_ROLE grantees can upgrade this contract.
    function _authorizeUpgrade(address) internal virtual override onlyOwner {}

    /// @notice Mints an amount of a token
    /// @param to The receiver of the new tokens.
    /// @param amount The amount of tokens minted.
    function mint(address to, uint256 amount) public override {
        _mint(to, amount);
    }

    /// @notice Mints an amount of a token
    /// @param to The receiver of the new tokens.
    /// @param amount The amount of tokens minted.
    function unprotectedMint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    /// @notice Burns an amount of a token
    /// @param amount The amount of tokens burned. This amount must be owned by the caller.
    function burn(uint256 amount) public override {
        _burn(_msgSender(), amount);
    }

    /// @notice Burns an amount of a token
    /// @param from The address of the owner of the tokens being burned.
    /// @param amount The amount of tokens burned. This amount must be owned `from`.
    function burnFrom(address from, uint256 amount) public override {
        _burn(from, amount);
    }
}
