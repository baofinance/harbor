// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {HarborOwnable} from "@bao/HarborOwnable.sol";
import {IRewardAlias} from "src/interfaces/IRewardAlias.sol";

/// @title RewardAlias
/// @notice A minimal UUPS-upgradeable contract that identifies itself as an alias for an underlying reward token.
/// @dev Deploy via BaoFactory (CREATE3) at a predictable address.
///      The reward system detects aliases via IRewardAlias.underlying() during registration.
///      The alias address is used for integral tracking; the underlying is used for token transfers.
// solhint-disable-next-line contract-name-capwords
contract RewardAlias is Initializable, UUPSUpgradeable, HarborOwnable, IERC5313, IRewardAlias {
    /// @notice The underlying reward token this alias represents.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable override underlying;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address underlying_) {
        _disableInitializers();
        underlying = underlying_;
    }

    /// @notice Initialize ownership.
    /// @param deployerOwner_ The initial (temporary) owner — typically the FactoryDeployer contract.
    /// @param pendingOwner_ The final owner — typically the Harbor multisig.
    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
        __UUPSUpgradeable_init();
    }

    /// @inheritdoc IERC5313
    function owner() public view override(HarborOwnable, IERC5313) returns (address owner_) {
        owner_ = HarborOwnable.owner();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC5313).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Authorize upgrades — only owner can upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
