// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Token} from "@bao/Token.sol";
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
    struct DoSomethingForBountyStorage {
        /// @notice the amount of bounty to be given
        /// Either 'bountyAmount' or 'bountyRatio' which ever is the greater, or lesser, depending on 'useLower'
        uint96 bountyAmount; // absolute value, decimals = 18
        uint96 bountyRatio; // relative value, decimals = 18
        bool useLower;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.dosomethingforbounty")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _DO_SOMETHING_FOR_BOUNTY_STORAGE =
        0x977542f90d83824dcd0ce4c1da9ed307590a2e8cbf8f54cf12b04a1969c89a00;

    function _getDoSomethingForBountyStorage() private pure returns (DoSomethingForBountyStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _DO_SOMETHING_FOR_BOUNTY_STORAGE
        }
    }

    // solhint-disable-next-line func-name-mixedcase
    function __DoSomethingForBountyStorage_init(
        address owner_,
        uint256 bountyAmount,
        uint256 bountyRatio,
        bool useLower
    ) public initializer {
        _initializeOwner(owner_);
        setBounty(bountyAmount, bountyRatio, useLower);
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
        DoSomethingForBountyStorage storage $ = _getDoSomethingForBountyStorage();
        $.bountyAmount = uint96(bountyAmount_);
        if (bountyRatio_ >= 1 ether) revert BountyRatioTooLarge(bountyRatio_, 1 ether);
        $.bountyRatio = uint96(bountyRatio_);
        $.useLower = useLower_;
    }

    /// @inheritdoc IBounty
    function bounty() external view returns (uint256 amount, uint256 ratio, bool useLower) {
        DoSomethingForBountyStorage storage $ = _getDoSomethingForBountyStorage();
        amount = $.bountyAmount;
        ratio = $.bountyRatio;
        useLower = $.useLower;
    }

    /// @inheritdoc IBounty
    function calcBounty(uint256 value) external pure returns (uint256 bounty_) {
        bounty_ = _calcBounty(value);
    }

    function _calcBounty(uint256 value) internal pure returns (uint256 bounty_) {
        DoSomethingForBountyStorage memory local = _getDoSomethingForBountyStorage();
        // calculate the ratio amount
        uint256 fromRatio = (value * local.bountyRatio) / 1 ether;
        uint256 fromAmount = Math.min(value, local.bountyAmount);
        bounty_ = local.useLower ? Math.min(fromRatio, fromAmount) : Math.max(fromRatio, fromAmount);
    }
}
