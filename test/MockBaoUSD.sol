// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IMintable, IBurnable } from "src/minter/IMintable.sol";

/// @title Mock Bao USD
/// @author rootminus0x1
/// @notice A simple ERC20 token that optionally allows unprotected minting.
/// It does not support burning from any address only from msgSender() as per the real BaoUSD.
/// It is not a direct copy of BaoUSD but a re-implementation so that it can represent other candidate pegged tokens
/// in the Minter framework.
/// It is written as an upgradeable proxy so that features can be added or removed more easily for testing.
/// This does not, of course, preclude deploying variants of potential pegged tokens under different proxies.
/// There are two mint functions, both with the same parameters:
/// - mint: the standard ERC20 form that is protected - only minters can call it
/// - unprotectedMint: an unprotected one that anyone can call. This is for easily minting yourself some tokens for testing purposes.
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
contract MockBaoUSD is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    IMintable,
    IBurnable
{
    using SafeERC20 for IERC20;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice initialise the UUPS proxy
    function initialize(address owner) public initializer {
        __Ownable_init(owner);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ERC20_init("Mock BaoUSD", "BaoUSD");
        __ERC20Permit_init("BaoUSD");
        __ERC165_init();
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// only DEFAULT_ADMIN_ROLE grantees can upgrade this contract.
    function _authorizeUpgrade(address) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @notice Mints an amount of a token
    /// @param to The receiver of the new tokens.
    /// @param amount The amount of tokens minted.
    function mint(address to, uint256 amount) public override onlyRole(MINTER_ROLE) {
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
    function burn(uint256 amount) public override onlyRole(MINTER_ROLE) {
        _burn(_msgSender(), amount);
    }

    /// @notice Adds a minter
    /// @param minter_ The address of the new minter.
    function addMinter(address minter_) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, minter_);
    }
}
