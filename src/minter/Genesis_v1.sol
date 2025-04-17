// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {TokenHolder} from "@bao/TokenHolder.sol";
import {Token} from "@bao/Token.sol";

import {IMinter} from "@interfaces/IMinter.sol";
import {IGenesis} from "@interfaces/IGenesis.sol";

// TODO: add ERC165 supports Interface, e.g. ITokenHolder

/// @title Genesis
/// @author rootminus0x1 based on Aladdin's FX system
/// @notice Provides a mechanism for bootstrapping a 'minter' with initial collateral
/// The sequence is:
/// 1. users `deposit` collateral tokens, their share being recorded
/// 2. at some point the admin for this contract mints the pegged and leveraged tokens.
/// 3. once minting has occurred, the users can either
///     - withdraw the collateral they deposited for a fee
///     - claim their share of pegged and leveraged tokens, for free. They can, of course, redeem them for a fee.
/// TODO: check that the fee costs of withdrawing for a fee and claiming 50/50 split and redeeming them both
///     There is no advantage to withdrawing or claiming then redeeming as far as fees are concerned.
/// @dev uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract Genesis_v1 is Initializable, UUPSUpgradeable, ContextUpgradeable, BaoOwnable, TokenHolder, IGenesis {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                DATA
    //////////////////////////////////////////////////////////////*/

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.Genesis
    struct GenesisStorage {
        /// @notice The address of minter contract.
        address minter;
        /// @notice The address of collateral token.
        address collateralToken;
        /// @notice The address of peggedToken token.
        address peggedToken;
        /// @notice The address of leveragedToken token.
        address leveragedToken;
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

    // keccak256(abi.encode(uint256(keccak256("bao.storage.Genesis")) - 1)) & ~bytes32(uint256(0xff));
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
    function initialize(address owner_, address minter_) external initializer {
        // initialise all the state variables
        _initializeOwner(owner_);
        __Context_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        GenesisStorage storage $ = _getGenesisStorage();
        // balance tokens
        $.collateralToken = IMinter(minter_).collateralToken();
        $.peggedToken = IMinter(minter_).peggedToken();
        $.leveragedToken = IMinter(minter_).leveragedToken();
        $.minter = minter_;
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

    /// @inheritdoc IGenesis
    function collateralToken() external view returns (address token) {
        GenesisStorage storage $ = _getGenesisStorage();
        token = $.collateralToken;
    }

    /// @inheritdoc IGenesis
    function peggedToken() external view returns (address token) {
        GenesisStorage storage $ = _getGenesisStorage();
        token = $.peggedToken;
    }

    /// @inheritdoc IGenesis
    function leveragedToken() external view returns (address token) {
        GenesisStorage storage $ = _getGenesisStorage();
        token = $.leveragedToken;
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
        address collateralToken_ = $.collateralToken;
        address caller = _msgSender();
        collateralIn = Token.allOf(caller, collateralToken_, collateralIn);

        IERC20(collateralToken_).safeTransferFrom(caller, address(this), collateralIn);

        $.shares[receiver] += collateralIn;
    }

    /// @inheritdoc IGenesis
    function withdraw(
        address receiver,
        uint256 minCollateralOut
    ) external nonReentrant returns (uint256 collateralOut) {
        Token.ensureNonZeroAddress(receiver);
        GenesisStorage storage $ = _getGenesisStorage();
        if (!$.genesisEnded) {
            revert GenesisIsNotEnded();
        }
        address caller = _msgSender();
        // stop this early if the caller is asking for a higher min than is available
        uint256 share_ = $.shares[caller];
        if (share_ == 0) {
            revert Token.ZeroInputBalance($.collateralToken);
        }
        if (share_ < minCollateralOut) {
            revert InsufficientCollateral($.collateralToken);
        }
        address peggedToken_ = $.peggedToken;
        address leveragedToken_ = $.leveragedToken;

        (uint256 peggedAmount, uint256 leveragedAmount) = _mintable(
            share_,
            $.totalSharesAtGenesisEnd,
            $.totalPeggedAtGenesisEnd,
            $.totalLeveragedAtGenesisEnd
        );

        address minter_ = $.minter;
        // get the collateral back - minus the fees
        // we redeem the pegged first because that potentially reduces the fee for redeeming the leveraged
        // wake-disable-next-line reentrancy // we have nonReentrant on this function
        IERC20(peggedToken_).forceApprove(minter_, peggedAmount);
        // wake-disable-next-line reentrancy // minter is trusted and we have nonReentrant on this function
        collateralOut += IMinter(minter_).redeemPeggedToken(peggedAmount, receiver, 0);
        IERC20(leveragedToken_).forceApprove(minter_, leveragedAmount);
        collateralOut += IMinter(minter_).redeemLeveragedToken(leveragedAmount, receiver, 0);

        if (collateralOut < minCollateralOut) {
            revert InsufficientCollateral($.collateralToken);
        }
        $.shares[caller] = 0;
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
            revert Token.ZeroInputBalance($.collateralToken);
        }
        (uint256 peggedAmount, uint256 leveragedAmount) = _mintable(
            share_,
            $.totalSharesAtGenesisEnd,
            $.totalPeggedAtGenesisEnd,
            $.totalLeveragedAtGenesisEnd
        );

        // give the caller their share of the created tokens
        IERC20($.peggedToken).safeTransfer(receiver, peggedAmount);
        IERC20($.leveragedToken).safeTransfer(receiver, leveragedAmount);

        $.shares[caller] = 0;
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
            peggedAmount = (share * totalPeggedAmount) / totalShares;
            leveragedAmount = (share * totalLeveragedAmount) / totalShares;
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
        address collateralToken_ = $.collateralToken;
        uint256 totalCollateral = IERC20($.collateralToken).balanceOf(address(this));
        $.totalSharesAtGenesisEnd = totalCollateral;

        // mint the pegged and leveraged, using all (yes, including any /2 truncation) the collateral
        // there is a potential to offer a bonus to depositors here by transferring collateral manually
        // into this contract.
        uint256 halfCollateral = totalCollateral / 2;
        address minter_ = $.minter;
        // wake-disable-next-line reentrancy // nonReentrant on this function
        IERC20(collateralToken_).forceApprove(minter_, totalCollateral);
        // wake-disable-next-line reentrancy // minter is trusted and we have nonReentrant on this function
        $.totalPeggedAtGenesisEnd = IMinter(minter_).freeMintPeggedToken(halfCollateral, address(this));
        $.totalLeveragedAtGenesisEnd = IMinter(minter_).freeMintLeveragedToken(
            totalCollateral - halfCollateral,
            address(this)
        );
        // minted tokens can now be claimed by the depositor, or collateral withdrawn
        $.genesisEnded = true;
    }
}
