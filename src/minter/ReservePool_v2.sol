// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {TokenHolder_v2, ITokenHolder} from "@bao/TokenHolder_v2.sol";
import {IReservePool} from "@harbor/interfaces/IReservePool.sol";

/// @title Reserve Pool
/// @author rootminus0x1
/// @notice Holds ERC20 tokens for use in a reserve capacity for one or more Minters.
/// It hands out what the Minter contract asks for, token and amount, if it has it.
/// Anyone can load it up with tokens.
/// The owner can withdraw tokens.
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
/// @custom:oz-upgrades-from src/minter/ReservePool_v1.sol:ReservePool_v1
// solhint-disable-next-line contract-name-capwords
contract ReservePool_v2 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    IReservePool,
    TokenHolder_v2,
    HarborOwnableRoles
{
    using SafeERC20 for IERC20;

    uint256 public constant REQUESTER_ROLE = _ROLE_0;

    /// @param deployerOwner_ The initial owner, used by the deploy script to configure the contract.
    /// @param pendingOwner_ The address the deployer hands ownership to, within an hour of initialisation.
    function initialize(address deployerOwner_, address pendingOwner_) public initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
        __UUPSUpgradeable_init();
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

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IReservePool).interfaceId ||
            interfaceId == type(ITokenHolder).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @notice Transfers an `amountRequested` of a `token` to the `recipient`.
    /// If this contract does not have the `amountRequested` of the token, it transfers what it has.
    function requestBonus(
        address token,
        address recipient,
        uint256 amountRequested
    ) public override onlyRoles(REQUESTER_ROLE) returns (uint256 amountSent) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amountRequested > balance) {
            amountSent = balance;
        } else {
            amountSent = amountRequested;
        }
        emit RequestBonus(_msgSender(), token, recipient, amountRequested, amountSent);
        if (amountSent > 0) {
            IERC20(token).safeTransfer(recipient, amountSent);
        }
    }
}
