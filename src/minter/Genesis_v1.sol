// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {TokenHolder} from "@bao/TokenHolder.sol";
import {Token} from "@bao/Token.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

// TODO: add ERC165 supports Interface, e.g. ITokenHolder

/// @title Genesis
/// @author rootminus0x1 based on Aladdin's FX system
/// @notice Provides a mechanism for bootstrapping a 'minter' with initial collateral
/// The sequence is:
/// 1. users `deposit` collateral tokens, their share being recorded by them holding a Genesis token
/// 2. at some point the admin for this contract mints the pegged and leveraged tokens.
/// 3. once minting has occurred, the users can either
///     - withdraw the collateral they deposited for a fee
///     - claim their share of pegged and leveraged tokens, for free. They can, of course, redeem them for a fee.
/// TODO: check that the fee costs of withdrawing for a fee and claiming 50/50 split and redeeming them both
///     There is no advantage to withdrawing or claiming then redeeming as far as fees are concerned.
/// @dev uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract Genesis_v1 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    BaoOwnable,
    TokenHolder,
    IGenesis
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                DATA
    //////////////////////////////////////////////////////////////*/

    // Immutable variables
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable PEGGED_TOKEN;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable WRAPPED_COLLATERAL_TOKEN;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable LEVERAGED_TOKEN;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable STABILITY_POOL_COLLATERAL;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable STABILITY_POOL_LEVERAGED;

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.Genesis
    struct GenesisStorage {
        /// @notice Mapping from user address to pool shares.
        mapping(address => uint256) shares;
        /// @notice The total amount of pool shares at the time the genesis ends.
        uint256 totalSharesAtGenesisEnd;
        /// @notice The total amount of pegged at the time the genesis ends.
        uint256 totalPeggedAtGenesisEnd;
        /// @notice The total amount of leveraged at the time the genesis ends.
        uint256 totalLeveragedAtGenesisEnd;
        /// @notice Whether the genesis stage has ended and withdrawing collateral or claiming pegged/leveraged can start.
        bool genesisEnded;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.Genesis")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _GENESIS_STORAGE = 0x0664bd1ecb0513904298180c56323018f000c9153e463401931cf3813b7eb300;

    /// @notice Returns the storage for this contract
    function _getGenesisStorage() private pure returns (GenesisStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _GENESIS_STORAGE
        }
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice In UUPS proxies construction is performed by a function
    function initialize(address owner_) external initializer {
        // initialise all the state variables
        _initializeOwner(owner_);
        __Context_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        emit GenesisBegins();
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address minter_) {
        Token.ensureContract(minter_);
        // slither-disable-next-line missing-zero-check
        MINTER = minter_;
        // slither-disable-next-line missing-zero-check
        WRAPPED_COLLATERAL_TOKEN = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        // slither-disable-next-line missing-zero-check
        PEGGED_TOKEN = IMinter(minter_).PEGGED_TOKEN();
        // slither-disable-next-line missing-zero-check
        LEVERAGED_TOKEN = IMinter(minter_).LEVERAGED_TOKEN();

        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /*//////////////////////////////////////////////////////////////
                        PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGenesis
    function balanceOf(address depositor) external view returns (uint256 share_) {
        GenesisStorage storage $ = _getGenesisStorage();
        share_ = $.shares[depositor];
    }

    /// @inheritdoc IGenesis
    function claimable(address depositor) external view returns (uint256 peggedAmount, uint256 leveragedAmount) {
        GenesisStorage storage $ = _getGenesisStorage();
        if (!$.genesisEnded) {
            revert GenesisIsNotEnded();
        }
        (peggedAmount, leveragedAmount) = _mintable(
            $.shares[depositor],
            $.totalSharesAtGenesisEnd,
            $.totalPeggedAtGenesisEnd,
            $.totalLeveragedAtGenesisEnd
        );
    }

    /// @inheritdoc IGenesis
    function genesisIsEnded() external view returns (bool ended) {
        GenesisStorage storage $ = _getGenesisStorage();
        ended = $.genesisEnded;
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGenesis
    function deposit(uint256 collateralIn, address receiver) external {
        Token.ensureNonZeroAddress(receiver);
        GenesisStorage storage $ = _getGenesisStorage();
        if ($.genesisEnded) {
            revert GenesisIsEnded();
        }
        address caller = _msgSender();
        collateralIn = Token.allOf(caller, WRAPPED_COLLATERAL_TOKEN, collateralIn);

        IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransferFrom(caller, address(this), collateralIn);

        $.shares[receiver] += collateralIn;

        emit Deposit(caller, receiver, collateralIn);
    }

    /// @inheritdoc IGenesis
    function withdraw(uint256 amount, address receiver) external nonReentrant returns (uint256 collateralOut) {
        if (amount == 0) {
            revert Token.ZeroInputBalance(address(this));
        }
        Token.ensureNonZeroAddress(receiver);
        GenesisStorage storage $ = _getGenesisStorage();
        if ($.genesisEnded) {
            revert GenesisIsEnded();
        }
        address caller = _msgSender();
        uint256 callerShares = $.shares[caller];

        if (amount == type(uint256).max) {
            // withdraw all shares
            amount = callerShares;
        } else if (amount > callerShares) {
            revert IERC20Errors.ERC20InsufficientBalance(caller, callerShares, amount);
        }

        // remove the amount from the share
        $.shares[caller] = callerShares - amount;

        // transfer the amount out
        IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(receiver, amount);
        collateralOut = amount;

        emit Withdraw(caller, receiver, amount);
    }

    /// @inheritdoc IGenesis
    function claim(address receiver) external {
        Token.ensureNonZeroAddress(receiver);
        GenesisStorage storage $ = _getGenesisStorage();
        if (!$.genesisEnded) {
            revert GenesisIsNotEnded();
        }
        address caller = _msgSender();
        uint256 share_ = $.shares[caller];
        if (share_ == 0) {
            revert Token.ZeroInputBalance(WRAPPED_COLLATERAL_TOKEN);
        }
        (uint256 peggedAmount, uint256 leveragedAmount) = _mintable(
            share_,
            $.totalSharesAtGenesisEnd,
            $.totalPeggedAtGenesisEnd,
            $.totalLeveragedAtGenesisEnd
        );

        // give the caller their share of the created tokens
        IERC20(PEGGED_TOKEN).safeTransfer(receiver, peggedAmount);
        IERC20(LEVERAGED_TOKEN).safeTransfer(receiver, leveragedAmount);

        $.shares[caller] = 0;

        emit Claim(caller, receiver, peggedAmount, leveragedAmount);
    }

    /*//////////////////////////////////////////////////////////////
                          PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _mintable(
        uint256 share,
        uint256 totalShares,
        uint256 totalPeggedAmount,
        uint256 totalLeveragedAmount
    ) private pure returns (uint256 peggedAmount, uint256 leveragedAmount) {
        if (totalShares > 0) {
            // count out the caller's share
            peggedAmount = Math.mulDiv(share, totalPeggedAmount, totalShares);
            leveragedAmount = Math.mulDiv(share, totalLeveragedAmount, totalShares);
        } else {
            // if there are no shares, then the caller gets nothing
            peggedAmount = 0;
            leveragedAmount = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                      PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGenesis
    function endGenesis() external onlyOwner nonReentrant {
        GenesisStorage storage $ = _getGenesisStorage();
        if ($.genesisEnded) {
            revert GenesisIsEnded();
        }
        // record the total shares now so all further share calculations are based on this number
        uint256 totalCollateral = IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(address(this));
        $.totalSharesAtGenesisEnd = totalCollateral;

        // mint the pegged and leveraged, using all (yes, including any /2 truncation) the collateral
        // there is a potential to offer a bonus to depositors here by transferring collateral manually
        // into this contract.
        uint256 peggedAmount = totalCollateral / 2;
        uint256 leveragedAmount = totalCollateral - peggedAmount;
        // wake-disable-next-line reentrancy // nonReentrant on this function
        IERC20(WRAPPED_COLLATERAL_TOKEN).safeIncreaseAllowance(MINTER, totalCollateral);
        // wake-disable-next-line reentrancy // minter is trusted and we have nonReentrant on this function
        if (peggedAmount > 0) {
            $.totalPeggedAtGenesisEnd = IMinter(MINTER).freeMintPeggedToken(peggedAmount, address(this));
        }
        if (leveragedAmount > 0) {
            $.totalLeveragedAtGenesisEnd = IMinter(MINTER).freeMintLeveragedToken(leveragedAmount, address(this));
        }
        // minted tokens can now be claimed by the depositor, or collateral withdrawn
        $.genesisEnded = true;

        emit GenesisEnds();
    }
}
