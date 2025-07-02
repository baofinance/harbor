// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {PermittableERC20_v1} from "@bao/PermittableERC20_v1.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";

import {ISTEAM} from "src/interfaces/ISTEAM.sol";

import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";

/// @title Steam (ERC20STEAM)
/// @author rootminus0x1 based on Curve Finance
/// @notice ERC20 with piecewise-linear mining supply.
/// @dev Based on the ERC-20 token standard as defined at
///      https://eips.ethereum.org/EIPS/eip-20
///
/// Original idea and credit:
/// Curve Finance's ERC20CRV
/// https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/ERC20CRV.vy
/// This contract is an almost-identical fork of Curve's contract
/// @custom:oz-upgrades
// slither-disable-start timestamp
// solhint-disable-next-line contract-name-camelcase
contract Steam_v1 is Initializable, UUPSUpgradeable, PermittableERC20_v1, ISTEAM, IMintableRole {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/
    // General constants
    uint256 private constant _YEAR = 365 days;

    // Supply parameters
    uint256 private constant _RATE_REDUCTION_TIME = _YEAR;
    uint256 private constant _RATE_DENOMINATOR = 1 ether;
    uint256 private constant _INFLATION_DELAY = 1 days;

    // STEAM specific state
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable INITIAL_RATE;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable RATE_REDUCTION_COEFFICIENT;

    uint256 public constant MINTER_ROLE = _ROLE_0;

    /*//////////////////////////////////////////////////////////////
                          STORAGE NAMESPACES
    //////////////////////////////////////////////////////////////*/
    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.Steam
    struct SteamStorage {
        // Mining parameters
        int128 miningEpoch;
        uint256 startEpochTime;
        uint256 rate;
        uint256 startEpochSupply;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.Steam")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _STEAM_STORAGE = 0x4da127939a441a2c821984d24323d25bb0d4dcc01f200fd1e47125c8df2e5600;

    /// @notice Returns the storage for this contract
    function _getSteamStorage() private pure returns (SteamStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _STEAM_STORAGE
        }
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTION
    //////////////////////////////////////////////////////////////*/
    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param initRate Initial emission rate
    /// @param rateReductionCoefficient Rate reduction coefficient
    constructor(uint256 initRate, uint256 rateReductionCoefficient) {
        _disableInitializers();
        INITIAL_RATE = initRate;
        RATE_REDUCTION_COEFFICIENT = rateReductionCoefficient;
    }

    /// @notice Initialize the Steam contract
    /// @param owner_ Admin address
    /// @param initSupply Initial token supply
    /// @param name_ Token full name
    /// @param symbol_ Token symbol
    function initialize(
        address owner_,
        uint256 initSupply,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        SteamStorage storage $ = _getSteamStorage();

        // Initialize PermittableERC20_v1
        PermittableERC20_v1.initialize(owner_, name_, symbol_);

        // Initialize STEAM-specific state
        $.startEpochTime = block.timestamp;
        $.miningEpoch = -1;
        $.rate = 0;
        $.startEpochSupply = initSupply;

        // Mint initial supply to admin
        _mint(owner_, initSupply);
    }

    // @dev remove protections. if you have a balance of them you can burn them
    function burn(uint256 value) external returns (bool) {
        super._burn(_msgSender(), value);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            MINING PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update mining rate and supply at the start of the epoch
    /// @dev Any modifying mining call must also call this
    function _updateMiningParameters() internal {
        SteamStorage storage $ = _getSteamStorage();

        uint256 rate_ = $.rate;
        uint256 startEpochSupply_ = $.startEpochSupply;

        $.startEpochTime += _RATE_REDUCTION_TIME;
        $.miningEpoch += 1;

        if (rate_ == 0) {
            rate_ = INITIAL_RATE;
        } else {
            startEpochSupply_ += rate_ * _RATE_REDUCTION_TIME;
            $.startEpochSupply = startEpochSupply_;
            rate_ = (rate_ * _RATE_DENOMINATOR) / RATE_REDUCTION_COEFFICIENT;
        }

        $.rate = rate_;

        emit UpdateMiningParameters(block.timestamp, rate_, startEpochSupply_);
    }

    /// @notice Update mining rate and supply at the start of the epoch
    /// @dev Callable by any address, but only once per epoch
    ///      Total supply becomes slightly larger if this function is called late
    // solhint-disable-next-line func-name-mixedcase
    function update_mining_parameters() external {
        SteamStorage storage $ = _getSteamStorage();

        if (block.timestamp < $.startEpochTime + _RATE_REDUCTION_TIME) {
            revert TooSoon();
        }

        _updateMiningParameters();
    }

    /// @notice Get timestamp of the current mining epoch start
    ///         while simultaneously updating mining parameters
    /// @return startEpochTime_ Timestamp of the epoch
    // solhint-disable-next-line func-name-mixedcase
    function start_epoch_time_write() external returns (uint256 startEpochTime_) {
        SteamStorage storage $ = _getSteamStorage();

        startEpochTime_ = $.startEpochTime;
        if (block.timestamp >= startEpochTime_ + _RATE_REDUCTION_TIME) {
            _updateMiningParameters();
            startEpochTime_ = $.startEpochTime;
        }
    }

    /// @notice Get timestamp of the next mining epoch start
    ///         while simultaneously updating mining parameters
    /// @return Timestamp of the next epoch
    // solhint-disable-next-line func-name-mixedcase
    function future_epoch_time_write() external returns (uint256) {
        SteamStorage storage $ = _getSteamStorage();

        uint256 startEpochTime_ = $.startEpochTime;
        if (block.timestamp >= startEpochTime_ + _RATE_REDUCTION_TIME) {
            _updateMiningParameters();
            return $.startEpochTime + _RATE_REDUCTION_TIME;
        } else {
            return startEpochTime_ + _RATE_REDUCTION_TIME;
        }
    }

    /// @notice Internal function to calculate available supply
    /// @return Current available supply
    function _availableSupply() internal view returns (uint256) {
        SteamStorage storage $ = _getSteamStorage();
        return $.startEpochSupply + (block.timestamp - $.startEpochTime) * $.rate;
    }

    /// @notice Current number of tokens in existence (claimed or unclaimed)
    /// @return Available supply
    // solhint-disable-next-line func-name-mixedcase
    function available_supply() external view returns (uint256) {
        return _availableSupply();
    }

    /// @notice How much supply is mintable from start timestamp till end timestamp
    /// @param start Start of the time interval (timestamp)
    /// @param end End of the time interval (timestamp)
    /// @return Tokens mintable from `start` till `end`
    // solhint-disable-next-line func-name-mixedcase
    function mintable_in_timeframe(uint256 start, uint256 end) external view returns (uint256) {
        SteamStorage storage $ = _getSteamStorage();

        if (start > end) {
            revert StartAfterEnd();
        }

        uint256 toMint = 0;
        uint256 currentEpochTime = $.startEpochTime;
        uint256 currentRate = $.rate;

        // Special case if end is in future (not yet minted) epoch
        if (end > currentEpochTime + _RATE_REDUCTION_TIME) {
            currentEpochTime += _RATE_REDUCTION_TIME;
            currentRate = (currentRate * _RATE_DENOMINATOR) / RATE_REDUCTION_COEFFICIENT;
        }

        if (end > currentEpochTime + _RATE_REDUCTION_TIME) {
            revert TooFarInFuture();
        }

        for (uint256 i = 0; i < 999; i++) {
            // Will not work in 1000 years, same as Curve!
            if (end >= currentEpochTime) {
                uint256 currentEnd = end;
                if (currentEnd > currentEpochTime + _RATE_REDUCTION_TIME) {
                    currentEnd = currentEpochTime + _RATE_REDUCTION_TIME;
                }

                uint256 currentStart = start;
                if (currentStart >= currentEpochTime + _RATE_REDUCTION_TIME) {
                    break; // We should never get here but what if...
                } else if (currentStart < currentEpochTime) {
                    currentStart = currentEpochTime;
                }

                toMint += currentRate * (currentEnd - currentStart);

                if (start >= currentEpochTime) {
                    break;
                }
            }

            currentEpochTime -= _RATE_REDUCTION_TIME;
            // slither-disable-next-line divide-before-multiply
            currentRate = (currentRate * RATE_REDUCTION_COEFFICIENT) / _RATE_DENOMINATOR; // Double-division with rounding makes rate a bit less => good
            assert(currentRate <= INITIAL_RATE); // This should never happen
        }

        return toMint;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice mints STEAM tokens
    /// @param to The account that will receive the created tokens
    /// @param value The amount that will be created
    /// @return success Boolean indicating success
    function mint(address to, uint256 value) external onlyRoles(MINTER_ROLE) returns (bool) {
        SteamStorage storage $ = _getSteamStorage();

        if (block.timestamp >= $.startEpochTime + _RATE_REDUCTION_TIME) {
            _updateMiningParameters();
        }

        uint256 totalSupply_ = totalSupply();
        uint256 availableSupply_ = _availableSupply();
        if (totalSupply_ + value > availableSupply_) {
            revert ExceedsAllowableMintAmount(value, totalSupply_, availableSupply_);
        }

        // Use parent mint
        super._mint(to, value);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERFACE GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISTEAM
    // solhint-disable-next-line func-name-mixedcase
    function mining_epoch() external view returns (int128) {
        return _getSteamStorage().miningEpoch;
    }

    /// @inheritdoc ISTEAM
    // solhint-disable-next-line func-name-mixedcase
    function start_epoch_time() external view returns (uint256) {
        return _getSteamStorage().startEpochTime;
    }

    /// @inheritdoc ISTEAM
    function rate() external view returns (uint256) {
        return _getSteamStorage().rate;
    }

    /// @inheritdoc ISTEAM
    function admin() external view returns (address) {
        return owner();
    }

    // Implement necessary ERC165 interface checks
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ISTEAM).interfaceId || super.supportsInterface(interfaceId);
    }
}

// slither-disable-end timestamp
