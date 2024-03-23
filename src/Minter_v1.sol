// SPDX-License-Identifier: Unlicense
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IMinter } from "./IMinter.sol";

/// @title
/// @author
/// @notice provides a base layer interface for minting and redeeming pegged and leveraged tokens
/// also provides information about the net asset values of the pegged and leveraged tokens
/// @dev uses UUPS proxy, erc7201 storage

/// @custom:oz-upgrades
contract Minter_v1 is Initializable, UUPSUpgradeable, OwnableUpgradeable, IMinter {
    /****************
     * storage
     */
    /// @custom:storage-location erc7201:bao.storage.Minter
    struct Storage {
        address collateralToken;
        address peggedToken;
        address leveragedToken;
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MINTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

    function _storage() private pure returns (Storage storage $) {
        assembly {
            $.slot := MINTER_STORAGE
        }
    }

    // UUPSUpgradeable

    function initialize(
        address owner,
        address collateralToken_,
        address peggedToken_,
        address leveragedToken_
    ) public initializer {
        __Ownable_init(owner);
        __UUPSUpgradeable_init();
        _storage().collateralToken = collateralToken_;
        _storage().peggedToken = peggedToken_;
        _storage().leveragedToken = leveragedToken_;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // stop the implementation being initialized to any version
        // https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
        _disableInitializers();
    }

    // only owners can upgrade this contract
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // External mutator functions

    /// @inheritdoc IMinter
    function mintPeggedToken(
        uint256 collateralIn,
        address recipient,
        uint256 minPTokenMinted
    ) external override returns (uint256 pTokenMinted) {
        if (collateralIn == type(uint256).max) {
            collateralIn = IERC20(_storage().collateralToken).balanceOf(_msgSender());
        }
    }

    /// @inheritdoc IMinter
    function mintLeveragedToken(
        uint256 collateralIn_,
        address recipient_,
        uint256 minXTokenMinted_
    ) external override returns (uint256 lTokenMinted, uint256 bonus) {}

    /// @inheritdoc IMinter
    function redeemPeggedToken(
        uint256 fTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external override returns (uint256 collateralOut, uint256 bonus) {}

    /// @inheritdoc IMinter
    function redeemLeveragedToken(
        uint256 leveragedTokenIn,
        address recipient,
        uint256 minCollateralOut
    ) external override returns (uint256 collateralOut) {}

    // External view functions

    /// @notice Return the address of the collateral (collateral) token
    function collateralToken() external view override returns (address) {
        return _storage().collateralToken;
    }

    /// @notice Return the address of the pegged token.
    function peggedToken() external view override returns (address) {
        return _storage().peggedToken;
    }

    /// @notice Return the address of the leveraged token.
    function leveragedToken() external view override returns (address) {
        return _storage().leveragedToken;
    }

    /// @notice Return the current collateral ratio of the pToken to the collateral token, multipled by 1e18.
    function collateralRatio() external view returns (uint256) {
        return 1; // TODO:
    }
}
