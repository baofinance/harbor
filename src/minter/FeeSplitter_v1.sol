// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC165Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import { IFeeSplitter } from "src/minter/IFeeSplitter.sol";

import "forge-std/console.sol";

contract FeeSplitter_v1 is Initializable, UUPSUpgradeable, AccessControlDefaultAdminRulesUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");

    // structure containing the beneficiary and the number of shares allocated
    // occupies one slot
    struct Split {
        address beneficiary;
        uint32 shares;
    }

    /*
    beneficiaries in an enumerable map index => address

    reward tokens in an enumerable map, address => bytes32

    beneficiary index: 6 bits = 64 beneficiaries
    shares: 10 bits = 1000 values, so 0.1 percent precision, so either sum to 1000, or 100 or any value
    -> 16 reward tokens

    */

    // occupies split.length + 1 slots
    struct TokenRewardSplits {
        address token;
        uint32 totalShares;
        Split[] splits;
    }

    struct FeeSplitterStorage {
        mapping(address => TokenRewardSplits) rewardSplits;
        address[] tokens;
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.FeeSplitter")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant FEE_SPLITTER_STORAGE = 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00;

    // TODO: also the difference between external and public (apart from the auto generation of getters and setters)
    function _getFeeSplitterStorage() private pure returns (FeeSplitterStorage storage $) {
        assembly {
            $.slot := FEE_SPLITTER_STORAGE
        }
    }

    function initialize(address owner, string memory name, string memory symbol) public initializer {
        __AccessControlDefaultAdminRules_init(7 days, owner);
        __UUPSUpgradeable_init();
        __ERC165_init();
        console.log("bao.storage.FeeSplitter=%s");
        console.logBytes32(
            keccak256(abi.encode(uint256(keccak256("bao.storage.FeeSplitter")) - 1)) & ~bytes32(uint256(0xff))
        );
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
    function setToken(address token, address[] memory beneficiaries, uint256[] memory shares) public {
        FeeSplitterStorage storage $ = _getFeeSplitterStorage();
        //$.rewardSplits[token] = _makeTokenRewardSplits(beneficiaries, shares);
    }

    // TODO: make an interface for this function
    function claim() public onlyRole(CLAIMER_ROLE) {}
}
