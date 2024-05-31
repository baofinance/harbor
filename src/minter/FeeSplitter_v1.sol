// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import { IFeeSplitter } from "src/minter/IFeeSplitter.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import "forge-std/console.sol";

contract FeeSplitter_v1 is Initializable, UUPSUpgradeable, AccessControlDefaultAdminRulesUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    error ConfigDifferentSizes(uint beneficiaries, uint shares);

    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");
    uint32 private constant INVALID_TOTAL_SHARES = type(uint32).max;

    // structure containing the beneficiary and the number of shares allocated
    // occupies one slot
    struct Split {
        address beneficiary; //   0:160
        uint64 ratio; // 160: 64 = 224
    }

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.FeeSplitter
    struct FeeSplitterStorage {
        address rewardToken;
        uint32 totalShares; // the sum of the shares in splits (or uint32.max if it needs to be recalculated)
        // Split[] splits;
        EnumerableMap.AddressToUintMap splits; // beneficiary to split shares
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.FeeSplitter")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant FEE_SPLITTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

    // TODO: also the difference between external and public (apart from the auto generation of getters and setters)
    function _getFeeSplitterStorage() private pure returns (FeeSplitterStorage storage $) {
        assembly {
            $.slot := FEE_SPLITTER_STORAGE
        }
    }

    function initialize(
        address owner,
        address rewardToken,
        address[] calldata beneficiaries,
        uint16[] calldata shares
    ) public initializer {
        __AccessControlDefaultAdminRules_init(7 days, owner);
        __UUPSUpgradeable_init();
        __ERC165_init();
        console.log("bao.storage.FeeSplitter");
        console.logBytes32(
            keccak256(abi.encode(uint256(keccak256("bao.storage.FeeSplitter")) - 1)) & ~bytes32(uint256(0xff))
        );
        FeeSplitterStorage storage $ = _getFeeSplitterStorage();
        $.rewardToken = rewardToken;
        _updateBeneficiaries(beneficiaries, shares);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            //interfaceId == type(IFeeSpliter).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // TODO: add a abstract base class with checker functions
    // non-zero address, etc
    // that reverts with a standard error
    function updateBeneficiaries(
        address[] calldata beneficiaries,
        uint16[] calldata shares
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _updateBeneficiaries(beneficiaries, shares);
    }

    function setBeneficiary(address beneficiary, uint16 shares) private {
        FeeSplitterStorage storage $ = _getFeeSplitterStorage();
        $.splits.set(beneficiary, shares); // set or add
        _updateTotalShares($.splits.keys());
    }

    function removeBeneficiary(address beneficiary) public onlyRole(DEFAULT_ADMIN_ROLE) {
        FeeSplitterStorage storage $ = _getFeeSplitterStorage();
        $.splits.remove(beneficiary);
        _updateTotalShares($.splits.keys());
    }

    // TODO: make an interface for this function
    function claim() public onlyRole(CLAIMER_ROLE) {
        FeeSplitterStorage storage $ = _getFeeSplitterStorage();
        address rewardToken_ = $.rewardToken;
        address[] memory beneficiaryKeys = $.splits.keys();
        uint totalShares = $.totalShares;
        uint256 balance = IERC20(rewardToken_).balanceOf(address(this));
        for (uint i = 0; i < beneficiaryKeys.length; i++) {
            uint amount = ($.splits.get(beneficiaryKeys[i]) * balance) / totalShares;
            IERC20(rewardToken_).safeTransfer(beneficiaryKeys[i], amount);
        }
    }

    function _updateBeneficiaries(address[] calldata beneficiaries, uint16[] calldata shares) private {
        FeeSplitterStorage storage $ = _getFeeSplitterStorage();
        if (beneficiaries.length != shares.length) revert ConfigDifferentSizes(beneficiaries.length, shares.length);
        // empty all the existing beneficiaries
        // TODO: this is inefficient (I think)
        address[] memory beneficiaryKeys = $.splits.keys();
        for (uint i = 0; i < beneficiaryKeys.length; i++) $.splits.remove(beneficiaryKeys[i]);
        // add the new ones
        uint32 totalShares = 0;
        for (uint i = 0; i < beneficiaries.length; i++) {
            totalShares += uint32(shares[i]);
            $.splits.set(beneficiaries[i], shares[i]);
        }
        // calculate the total shares
        $.totalShares = totalShares;
    }

    function _updateTotalShares(address[] memory beneficiaries) private {
        FeeSplitterStorage storage $ = _getFeeSplitterStorage();
        uint32 totalShares = 0;
        for (uint i = 0; i < beneficiaries.length; i++) {
            totalShares += uint32($.splits.get(beneficiaries[i]));
        }
        $.totalShares = totalShares;
    }
}
