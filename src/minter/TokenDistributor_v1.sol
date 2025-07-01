// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {Token} from "@bao/Token.sol";
import {TokenHolder} from "@bao/TokenHolder.sol";

import {ITokenDistributor} from "src/interfaces/ITokenDistributor.sol";

/// @notice Distributes tokens to addresses.
/// @author rootminus0x1
/// This contract
/// <ul>
/// <li>owns tokens via ERC20 transfers.
/// <li>maintains a list of tokens it knows about
/// <li>maintains a list of addresses and share amounts for each address
/// </ul>
/// When `distribute()` is called each known token is distributed to each address according to its share.
/// <br>
/// Note: all tokens are treated in the same way. If you need different distribution amounts for each address/token
/// pair, you need different TokenDistributor contracts. Each contract has a name that allows you to record its purpose,
/// for example, "fee distributor", "harvest distributor", etc.
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract TokenDistributor_v1 is
    ITokenDistributor,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    TokenHolder,
    BaoOwnableRoles
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ITokenDistributor
    uint256 public constant CLAIMER_ROLE = _ROLE_0;

    /// @notice Structure containing the recipient and the number of shares allocated to that recipient
    /// @dev Occupies one storage slot.
    struct Split {
        // who receives
        address recipient; //   0:160
        // the share of the total amount, as a ratio it is share / totalShares
        uint64 share; // 160: 64 = 224
    }

    // Share-with-proxy Storage
    // ------------------------
    /// @notice The contract state.
    /// Contains a list of token addresses and recipient addresses and recipient shares
    /// - a list of tokens
    /// - a list of {recipient, share} pairs
    ///
    /// @dev this is the share-with-proxy storage
    /// @custom:storage-location erc7201:bao.storage.TokenDistributor
    struct TokenDistributorStorage {
        // the name of the distributor - should be used to indicate the purpose of the distribution
        string name;
        // a list of tokens, all tokens get distributed in the same way via the list of {recipient, share}
        // this structure is optimised for distribution where the data is efficiently iterable, rather than set up where
        // linear searches are sometimes performed.
        EnumerableSet.AddressSet tokens;
        Split[] distribution;
        // storing totalShares instead of calculating it on the fly costs about the same for about 3 recipients
        // but scales much better
        uint totalShares; // solhint-disable-line explicit-types
    }

    /// @notice The storage hash for the shared-with-proxy storage
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.TokenDistributor")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _TOKEN_DISTRIBUTOR_STORAGE =
        0xd0775fa9e06b22c4332c4ba2f31eb3c883151d167c94d1d0a605e68bca1dbb00;

    function _getTokenDistributorStorage() private pure returns (TokenDistributorStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _TOKEN_DISTRIBUTOR_STORAGE
        }
    }

    /// @notice This is the de-fecto constructor
    /// @param owner_ The owner of the contract who is granted Role DEFAULT_ADMIN_ROLE
    /// @param name_ The name given to this distributor.
    function initialize(address owner_, string memory name_) public initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        TokenDistributorStorage storage $ = _getTokenDistributorStorage();
        $.name = name_;
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ITokenDistributor).interfaceId || super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                         PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ITokenDistributor
    function name() public view returns (string memory name_) {
        TokenDistributorStorage storage $ = _getTokenDistributorStorage();
        name_ = $.name;
    }

    /// @inheritdoc ITokenDistributor
    function tokens() public view returns (address[] memory tokens_) {
        TokenDistributorStorage storage $ = _getTokenDistributorStorage();
        tokens_ = $.tokens.values();
    }

    /// @inheritdoc ITokenDistributor
    function distribution()
        public
        view
        returns (
            address[] memory recipients,
            uint256[] memory shares,
            uint totalShares // solhint-disable-line explicit-types
        )
    {
        TokenDistributorStorage storage $ = _getTokenDistributorStorage();
        uint length = $.distribution.length; // solhint-disable-line explicit-types
        recipients = new address[](length);
        shares = new uint256[](length);
        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < length; i++) {
            recipients[i] = $.distribution[i].recipient;
            shares[i] = $.distribution[i].share;
        }
        totalShares = $.totalShares;
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ITokenDistributor
    function addToken(address token) public onlyOwner {
        TokenDistributorStorage storage $ = _getTokenDistributorStorage();
        Token.sanityCheckERC20Token(token);
        // slither-disable-next-line unused-return we don't care if the the token was already in the set
        $.tokens.add(token); // wake-disable-line unchecked-return-value //only adds if one is not already there
    }

    /// @inheritdoc ITokenDistributor
    function removeToken(address token) public onlyOwner {
        TokenDistributorStorage storage $ = _getTokenDistributorStorage();
        // slither-disable-next-line unused-return
        $.tokens.remove(token); // wake-disable-line unchecked-return-value //only removes if one is there
    }

    /// @inheritdoc ITokenDistributor
    function setDistribution(
        address[] calldata recipients,
        uint[] calldata shares // solhint-disable-line explicit-types
    ) public onlyOwner {
        if (recipients.length != shares.length) {
            revert RecipientsAndSharesDifferentSizes(recipients.length, shares.length);
        }
        TokenDistributorStorage storage $ = _getTokenDistributorStorage();
        uint totalShares = 0; // solhint-disable-line explicit-types

        // Overwrite existing elements
        uint existingLength = $.distribution.length; // solhint-disable-line explicit-types
        uint i; // solhint-disable-line explicit-types
        for (i = 0; i < recipients.length; i++) {
            Token.ensureNonZeroAddress(recipients[i]);
            uint256 share = shares[i];
            if (share > type(uint64).max) {
                revert ShareAmountIsTooHigh(recipients[i], share);
            }
            if (share == 0) {
                revert ShareAmountIsZero(recipients[i]);
            }
            // check for a zero share. If you want no shares don't include the recipient in recipients
            if (shares[i] == 0) {
                revert ShareAmountIsZero(recipients[i]);
            }
            // check for duplicates. There's no in memory mappings so we use brute force.
            // as there should be a small amount of recipients (< 10), this O(n^2) algorithm is acceptable
            // also because this function is rarely called, it's best to check for errors
            // solhint-disable-next-line explicit-types
            for (uint j = i + 1; j < recipients.length; j++) {
                if (recipients[i] == recipients[j]) {
                    revert DuplicateRecipient(recipients[i]);
                }
            }
            totalShares += shares[i];
            if (i < existingLength) {
                $.distribution[i] = Split(recipients[i], uint64(share));
            } else {
                $.distribution.push(Split(recipients[i], uint64(share)));
            }
        }
        $.totalShares = totalShares;

        // Remove any remaining old elements if the new array is shorter
        for (; i < existingLength; i++) {
            $.distribution.pop();
        }
    }

    /// @inheritdoc ITokenDistributor
    function addRecipient(address recipient, uint256 share) public onlyOwner {
        Token.ensureNonZeroAddress(recipient);

        if (share == 0) {
            revert ShareAmountIsZero(recipient);
        }
        if (share > type(uint64).max) {
            revert ShareAmountIsTooHigh(recipient, share);
        }
        TokenDistributorStorage storage $ = _getTokenDistributorStorage();
        // linear search is inefficient but OK for small numbers of recipients
        // it's not expected that this will be called very often
        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < $.distribution.length; i++) {
            if (recipient == $.distribution[i].recipient) {
                // existing recipient updated
                $.totalShares = $.totalShares + share - $.distribution[i].share;
                $.distribution[i].share = uint64(share);
                // we ensure that there are no duplicates elsewhere so we can return
                return;
            }
        }
        // if we get here, it's a new recipient
        $.totalShares += share;
        $.distribution.push(Split(recipient, uint64(share)));
    }

    /// @inheritdoc ITokenDistributor
    function removeRecipient(address recipient) public onlyOwner {
        TokenDistributorStorage storage $ = _getTokenDistributorStorage();
        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < $.distribution.length; i++) {
            // solhint-disable-line explicit-types
            if (recipient == $.distribution[i].recipient) {
                // existing recipient removed
                $.totalShares = $.totalShares - $.distribution[i].share;
                if (i < $.distribution.length - 1) {
                    // if it's in the middle,
                    // copy the last one over it
                    $.distribution[i] = $.distribution[$.distribution.length - 1];
                }
                // remove the last one
                $.distribution.pop();
            }
        }
    }

    // TODO: what protections, if any should be on this?
    // it is protected for now, as it is trivial to write a contract that
    // has an unprotected distribute function
    // has the correct role to call this function
    // @inheritdoc ITokenDistributor
    function distribute() public nonReentrant onlyOwnerOrRoles(CLAIMER_ROLE) {
        TokenDistributorStorage storage $ = _getTokenDistributorStorage();

        address[] memory tokens_ = $.tokens.values();
        Split[] memory dist = $.distribution;
        // TODO: check if it is more gas efficient to calculate total shares rather than store it
        uint totalShares = $.totalShares; // solhint-disable-line explicit-types

        // solhint-disable-next-line explicit-types
        for (uint t = 0; t < tokens_.length; t++) {
            // how much do we have
            // TODO: only transfer a minimum amount
            // TODO: only transfer at a given minimum frequency
            //slither-disable-next-line calls-loop
            uint256 ownership = IERC20(tokens_[t]).balanceOf(address(this));

            // solhint-disable-next-line explicit-types
            for (uint r = 0; r < dist.length; r++) {
                IERC20(tokens_[t]).safeTransfer(dist[r].recipient, (ownership * dist[r].share) / totalShares);
            }
        }
    }

    /// @inheritdoc TokenHolder
    function _sweep(address token, uint256 amount, address receiver) internal override(TokenHolder) {
        TokenDistributorStorage storage $ = _getTokenDistributorStorage();
        if ($.tokens.contains(token)) {
            revert TokenStillInUse(token);
        }
        super._sweep(token, amount, receiver);
    }
}
