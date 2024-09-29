// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { TokenOwner } from "src/common/TokenOwner.sol";

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
contract Genesis_v1 is Initializable, UUPSUpgradeable, ContextUpgradeable, TokenOwner {
    using SafeERC20 for IERC20;

    ////////////
    // Events //
    ////////////

    /// @notice Emitted when the status of `genesisClaimable` is updated.
    event ClaimingEnabledUpdated(bool status);

    ////////////
    // Errors //
    ////////////

    /// @dev Thrown when an attempt to withdraw both pegged and leveraged token.
    error GenesisIsNotEnded();

    /// @dev Thrown when the amount of collateral token is not enough.
    error InsufficientCollateral(address token);

    /// @dev Thrown when deposit after the genesis process has ended.
    error GenesisIsEnded();

    /// @dev Thrown when withdraw before initialization.
    error ClaimingIsNotEnabled();

    ///////////////
    // Variables //
    ///////////////

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
        /// @notice The total amount of pool shares.
        uint256 totalShares;
        bool genesisEnded;
        /// @notice Whether claiming the pegged and leveraged tokens is enabled.
        bool claimingEnabled;
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

    //////////////////
    // Construction //
    //////////////////

    /// @notice In UUPS proxies construction is performed by a function
    function initialize(address owner, address minter_) external initializer {
        // initialise all the state variables
        _initializeOwner(owner);
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

    //////////////////////////////
    // Public Mutator Functions //
    //////////////////////////////

    /// @notice Deposit collateral token to this contract.
    /// @param collateralIn The amount of token to deposit.
    /// @param receiver The address of pool share recipient.
    function deposit(uint256 collateralIn, address receiver) external {
        GenesisStorage storage $ = _getGenesisStorage();
        if ($.genesisEnded) revert GenesisIsEnded();

        IERC20($.collateralToken).safeTransferFrom(_msgSender(), address(this), collateralIn);
        $.shares[receiver] += collateralIn;
        $.totalShares += collateralIn;
    }

    /// @notice Withdraw some collateral from this contract, for a fee, after genesis has ended.
    /// @param recipient The address of collateral token recipient.
    /// @param minCollateralOut The minimum amount of collateral token should receive.
    /// @return collateralOut The amount of collateral token received.
    function withdraw(
        address recipient,
        uint256 minCollateralOut
    ) external nonReentrant returns (uint256 collateralOut) {
        GenesisStorage storage $ = _getGenesisStorage();

        (uint256 peggedAmount, uint256 leveragedAmount) = _withdraw($);

        address minter_ = $.minter;
        // we redeem the leveraged first because that potentially reduces the fee for redeeming the pegged
        // wake-disable-next-line reentrancy // minter is trusted
        collateralOut += IMinter(minter_).redeemLeveragedToken(leveragedAmount, recipient, 0);
        collateralOut += IMinter(minter_).redeemPeggedToken(peggedAmount, recipient, 0);

        if (collateralOut < minCollateralOut) revert InsufficientCollateral($.collateralToken);
    }

    /// @notice Withdraw fxUSD/fToken and xToken from this contract.
    /// @param receiver The address of token recipient.
    function claim(address receiver) external {
        GenesisStorage storage $ = _getGenesisStorage();
        if (!$.claimingEnabled) revert ClaimingIsNotEnabled();

        (uint256 peggedAmount, uint256 leveragedAmount) = _withdraw($);

        IERC20($.peggedToken).safeTransfer(receiver, peggedAmount);
        IERC20($.leveragedToken).safeTransfer(receiver, leveragedAmount);
    }

    function _withdraw(GenesisStorage storage $) private returns (uint256 peggedAmount, uint256 leveragedAmount) {
        if (!$.genesisEnded) revert GenesisIsNotEnded();
        uint256 share_ = $.shares[_msgSender()];
        $.shares[_msgSender()] = 0;
        uint256 totalShares_ = $.totalShares;
        uint256 totalPeggedToken = IERC20($.peggedToken).balanceOf(address(this));
        uint256 totalLeveragedToken = IERC20($.leveragedToken).balanceOf(address(this));
        peggedAmount = (share_ * totalPeggedToken) / totalShares_;
        leveragedAmount = (share_ * totalLeveragedToken) / totalShares_;
    }

    //////////////////////////
    // Restricted Functions //
    //////////////////////////

    /// @notice Initialize minter with the collateral in this contract.
    function endGenesis() external onlyOwner nonReentrant {
        GenesisStorage storage $ = _getGenesisStorage();
        if ($.genesisEnded) revert GenesisIsEnded();

        uint256 totalCollateral = IERC20($.collateralToken).balanceOf(address(this));
        uint256 peggedCollateral = totalCollateral / 2;
        address minter_ = $.minter;
        // wake-disable-next-line reentrancy // minter is trusted
        IMinter(minter_).freeMintPeggedToken(peggedCollateral, address(this));
        IMinter(minter_).freeMintLeveragedToken(totalCollateral - peggedCollateral, address(this));

        $.genesisEnded = true;
    }

    /// @notice Change the status of `fxWithdrawalEnabled`.
    function updateClaimingEnabled(bool newValue) external onlyOwner {
        GenesisStorage storage $ = _getGenesisStorage();
        $.claimingEnabled = newValue;

        emit ClaimingEnabledUpdated(newValue);
    }
}
