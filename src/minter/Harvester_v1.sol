// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {Token} from "@bao/Token.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";
import {IRebalancePool} from "src/interfaces/IRebalancePool.sol";
import {IHarvester} from "src/interfaces/IHarvester.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {Bounty, IBounty} from "src/common/Bounty.sol";

/// @author rootminus0x1
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract Harvester_v1 is Initializable, UUPSUpgradeable, ReentrancyGuardTransientUpgradeable, Bounty, IHarvester {
    using SafeERC20 for IERC20;

    /*************
     * Variables *
     *************/

    address public immutable MINTER;
    address public immutable BOUNTY_TOKEN;
    address public immutable HARVEST_RECEIVER;

    function initialize(address owner_) public initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __ERC165_init();
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address minter_, address harvestReceiver) {
        MINTER = minter_;
        Token.ensureContract(minter_);
        BOUNTY_TOKEN = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        Token.ensureERC20Token(BOUNTY_TOKEN);
        HARVEST_RECEIVER = harvestReceiver;
        Token.ensureContract(minter_);

        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IHarvester).interfaceId ||
            interfaceId == type(IBounty).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IHarvester
    function harvest(address bountyReceiver, uint256 minBounty) public virtual nonReentrant {
        uint256 totalHarvest = IMinter(MINTER).harvestable();
        uint256 bounty = _calcBounty(totalHarvest);

        // check if the caller thinks it's worthwhile
        if (bounty < minBounty) revert IHarvester.InsufficientBounty(BOUNTY_TOKEN, bounty, minBounty);

        // check if it's actually worthwhile
        if (totalHarvest - bounty > 0) {
            // send the bounty
            ITokenHolder(MINTER).sweep(BOUNTY_TOKEN, bounty, bountyReceiver);
            // now do the actual harvest
            ITokenHolder(MINTER).sweep(BOUNTY_TOKEN, totalHarvest - bounty, HARVEST_RECEIVER);
        }
    }
}
