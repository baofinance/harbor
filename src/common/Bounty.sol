// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {IBounty} from "src/interfaces/IBounty.sol";

/// @author rootminus0x1
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
abstract contract Bounty is Initializable, BaoOwnableRoles, ERC165Upgradeable, IBounty {
    /*************
     * Variables *
     *************/

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.Liquidator
    struct BountyStorage {
        /// @notice the amount of bounty to be given
        /// Either 'bountyAmount' or 'bountyRatio' which ever is the greater, or lesser, depending on 'useLower'
        uint96 bountyAmount; // absolute value, decimals = 18
        uint96 bountyRatio; // relative value, decimals = 18
        bool useLower;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.bounty")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _BOUNTY_STORAGE = 0x538a2fbe59f927c0e72a0c6b292feea8a04b00edae946a97d277ea844e1ee000;

    function _getBountyStorage() private pure returns (BountyStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _BOUNTY_STORAGE
        }
    }
    // solhint-disable-next-line func-name-mixedcase, private-vars-leading-underscore
    function __Bounty_init(address owner_) public initializer {
        _initializeOwner(owner_);
        __ERC165_init();
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(BaoOwnableRoles, ERC165Upgradeable) returns (bool) {
        return interfaceId == type(IBounty).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IBounty
    function setBounty(uint256 bountyAmount_, uint256 bountyRatio_, bool useLower_) public onlyOwner {
        BountyStorage storage $ = _getBountyStorage();
        $.bountyAmount = uint96(bountyAmount_);
        if (bountyRatio_ >= 1 ether) revert BountyRatioTooLarge(bountyRatio_, 1 ether);
        $.bountyRatio = uint96(bountyRatio_);
        $.useLower = useLower_;
    }

    /// @inheritdoc IBounty
    function bounty() external view returns (uint256 amount, uint256 ratio, bool useLower) {
        BountyStorage storage $ = _getBountyStorage();
        amount = $.bountyAmount;
        ratio = $.bountyRatio;
        useLower = $.useLower;
    }

    /// @inheritdoc IBounty
    function calcBounty(uint256 value) external pure returns (uint256 bounty_) {
        bounty_ = _calcBounty(value);
    }

    function _calcBounty(uint256 value) internal pure returns (uint256 bounty_) {
        BountyStorage memory local = _getBountyStorage();
        // calculate the ratio amount
        uint256 fromRatio = (value * local.bountyRatio) / 1 ether;
        uint256 fromAmount = Math.min(value, local.bountyAmount);
        bounty_ = local.useLower ? Math.min(fromRatio, fromAmount) : Math.max(fromRatio, fromAmount);
    }
}
