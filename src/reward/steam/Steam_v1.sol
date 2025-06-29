// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

import {ISTEAM} from "src/interfaces/ISTEAM.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";

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
// solhint-disable-next-line contract-name-camelcase
contract Steam_v1 is Initializable, UUPSUpgradeable, MintableBurnableERC20_v1, ISTEAM {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error AdminOnly();
    error MinterOnly();
    error ZeroAddress();
    error MinterAlreadySet();
    error TooSoon();
    error StartAfterEnd();
    error TooFarInFuture();
    error ExceedsAllowableMintAmount();
    error ZeroOrNonZeroAllowanceRequired();

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/
    // General constants
    uint256 private constant YEAR = 86400 * 365;

    // Supply parameters
    uint256 private constant RATE_REDUCTION_TIME = YEAR;
    uint256 private constant RATE_DENOMINATOR = 10 ** 18;
    uint256 private constant INFLATION_DELAY = 86400;

    /*//////////////////////////////////////////////////////////////
                          STORAGE NAMESPACES
    //////////////////////////////////////////////////////////////*/
    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.Steam
    struct SteamStorage {
        // Mining parameters
        int128 mining_epoch;
        uint256 start_epoch_time;
        uint256 rate;
        uint256 start_epoch_supply;
        // STEAM specific state
        address minter;
        address admin;
        uint256 INITIAL_RATE;
        uint256 RATE_REDUCTION_COEFFICIENT;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.Steam")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _STEAM_STORAGE = 0x4da127939a441a2c821984d24323d25bb0d4dcc01f200fd1e47125c8df2e5600;

    /// @notice Returns the storage for this contract
    function _getSteamStorage() private pure returns (SteamStorage storage $) {
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
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the Steam contract
    /// @param _init_supply Initial token supply
    /// @param _init_rate Initial emission rate
    /// @param _rate_reduction_coefficient Rate reduction coefficient
    /// @param _admin Admin address
    /// @param _name Token full name
    /// @param _symbol Token symbol
    function initialize(
        uint256 _init_supply,
        uint256 _init_rate,
        uint256 _rate_reduction_coefficient,
        address _admin,
        string calldata _name,
        string calldata _symbol
    ) external initializer {
        SteamStorage storage $ = _getSteamStorage();

        if ($.admin != address(0)) {
            revert AlreadyInitialized();
        }

        // Initialize MintableBurnableERC20_v1
        super.initialize(_admin, _name, _symbol);

        // Initialize STEAM-specific state
        $.admin = _admin;
        $.INITIAL_RATE = _init_rate;
        $.RATE_REDUCTION_COEFFICIENT = _rate_reduction_coefficient;
        $.start_epoch_time = block.timestamp;
        $.mining_epoch = -1;
        $.rate = 0;
        $.start_epoch_supply = _init_supply;

        // Mint initial supply to admin
        _mint(_admin, _init_supply);
    }

    /*//////////////////////////////////////////////////////////////
                            MINING PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update mining rate and supply at the start of the epoch
    /// @dev Any modifying mining call must also call this
    function _update_mining_parameters() internal {
        SteamStorage storage $ = _getSteamStorage();

        uint256 _rate = $.rate;
        uint256 _start_epoch_supply = $.start_epoch_supply;

        $.start_epoch_time += RATE_REDUCTION_TIME;
        $.mining_epoch += 1;

        if (_rate == 0) {
            _rate = $.INITIAL_RATE;
        } else {
            _start_epoch_supply += _rate * RATE_REDUCTION_TIME;
            $.start_epoch_supply = _start_epoch_supply;
            _rate = (_rate * RATE_DENOMINATOR) / $.RATE_REDUCTION_COEFFICIENT;
        }

        $.rate = _rate;

        emit UpdateMiningParameters(block.timestamp, _rate, _start_epoch_supply);
    }

    /// @notice Update mining rate and supply at the start of the epoch
    /// @dev Callable by any address, but only once per epoch
    ///      Total supply becomes slightly larger if this function is called late
    function update_mining_parameters() external {
        SteamStorage storage $ = _getSteamStorage();

        if (block.timestamp < $.start_epoch_time + RATE_REDUCTION_TIME) {
            revert TooSoon();
        }

        _update_mining_parameters();
    }

    /// @notice Get timestamp of the current mining epoch start
    ///         while simultaneously updating mining parameters
    /// @return Timestamp of the epoch
    function start_epoch_time_write() external returns (uint256) {
        SteamStorage storage $ = _getSteamStorage();

        uint256 _start_epoch_time = $.start_epoch_time;
        if (block.timestamp >= _start_epoch_time + RATE_REDUCTION_TIME) {
            _update_mining_parameters();
            return $.start_epoch_time;
        } else {
            return _start_epoch_time;
        }
    }

    /// @notice Get timestamp of the next mining epoch start
    ///         while simultaneously updating mining parameters
    /// @return Timestamp of the next epoch
    function future_epoch_time_write() external returns (uint256) {
        SteamStorage storage $ = _getSteamStorage();

        uint256 _start_epoch_time = $.start_epoch_time;
        if (block.timestamp >= _start_epoch_time + RATE_REDUCTION_TIME) {
            _update_mining_parameters();
            return $.start_epoch_time + RATE_REDUCTION_TIME;
        } else {
            return _start_epoch_time + RATE_REDUCTION_TIME;
        }
    }

    /// @notice Internal function to calculate available supply
    /// @return Current available supply
    function _available_supply() internal view returns (uint256) {
        SteamStorage storage $ = _getSteamStorage();
        return $.start_epoch_supply + (block.timestamp - $.start_epoch_time) * $.rate;
    }

    /// @notice Current number of tokens in existence (claimed or unclaimed)
    /// @return Available supply
    function available_supply() external view returns (uint256) {
        return _available_supply();
    }

    /// @notice How much supply is mintable from start timestamp till end timestamp
    /// @param start Start of the time interval (timestamp)
    /// @param end End of the time interval (timestamp)
    /// @return Tokens mintable from `start` till `end`
    function mintable_in_timeframe(uint256 start, uint256 end) external view returns (uint256) {
        SteamStorage storage $ = _getSteamStorage();

        if (start > end) {
            revert StartAfterEnd();
        }

        uint256 to_mint = 0;
        uint256 current_epoch_time = $.start_epoch_time;
        uint256 current_rate = $.rate;

        // Special case if end is in future (not yet minted) epoch
        if (end > current_epoch_time + RATE_REDUCTION_TIME) {
            current_epoch_time += RATE_REDUCTION_TIME;
            current_rate = (current_rate * RATE_DENOMINATOR) / $.RATE_REDUCTION_COEFFICIENT;
        }

        if (end > current_epoch_time + RATE_REDUCTION_TIME) {
            revert TooFarInFuture();
        }

        for (uint256 i = 0; i < 999; i++) {
            // Will not work in 1000 years, same as Curve!
            if (end >= current_epoch_time) {
                uint256 current_end = end;
                if (current_end > current_epoch_time + RATE_REDUCTION_TIME) {
                    current_end = current_epoch_time + RATE_REDUCTION_TIME;
                }

                uint256 current_start = start;
                if (current_start >= current_epoch_time + RATE_REDUCTION_TIME) {
                    break; // We should never get here but what if...
                } else if (current_start < current_epoch_time) {
                    current_start = current_epoch_time;
                }

                to_mint += current_rate * (current_end - current_start);

                if (start >= current_epoch_time) {
                    break;
                }
            }

            current_epoch_time -= RATE_REDUCTION_TIME;
            current_rate = (current_rate * $.RATE_REDUCTION_COEFFICIENT) / RATE_DENOMINATOR; // Double-division with rounding makes rate a bit less => good
            assert(current_rate <= $.INITIAL_RATE); // This should never happen
        }

        return to_mint;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    // /// @notice Set the minter address
    // /// @dev Only callable once, when minter has not yet been set
    // /// @param _minter Address of the minter
    // function set_minter(address _minter) external {
    //     SteamStorage storage $ = _getSteamStorage();

    //     if (msg.sender != $.admin) {
    //         revert AdminOnly();
    //     }

    //     if ($.minter != address(0)) {
    //         revert MinterAlreadySet();
    //     }

    //     $.minter = _minter;

    //     // Set up minter role in the MintableBurnableERC20_v1
    //     _grantRoles(_minter, MINTER_ROLE);

    //     emit SetMinter(_minter);
    // }

    // /// @notice Set the new admin.
    // /// @dev After all is set up, admin only can change the token name
    // /// @param _admin New admin address
    // function set_admin(address _admin) external {
    //     SteamStorage storage $ = _getSteamStorage();

    //     if (msg.sender != $.admin) {
    //         revert AdminOnly();
    //     }

    //     $.admin = _admin;

    //     // Update owner as well to maintain consistency
    //     // _transferOwnership(_admin);

    //     emit SetAdmin(_admin);
    // }

    // /// @notice Change the token name and symbol
    // /// @dev Only callable by the admin account
    // /// @param _name New token name
    // /// @param _symbol New token symbol
    // function set_name(string calldata _name, string calldata _symbol) external {
    //     SteamStorage storage $ = _getSteamStorage();

    //     if (msg.sender != $.admin) {
    //         revert AdminOnly();
    //     }

    //     // Need to reinitialize the parent contract to change name/symbol
    //     // Can't do this directly as initializer is locked, so we need custom logic
    //     _setNameAndSymbol(_name, _symbol);
    // }

    // /*//////////////////////////////////////////////////////////////
    //                         ERC20 OVERRIDES
    // //////////////////////////////////////////////////////////////*/
    // /// @notice Custom implementation to set name and symbol after initialization
    // /// @param _name New token name
    // /// @param _symbol New token symbol
    // function _setNameAndSymbol(string calldata _name, string calldata _symbol) internal {
    //     _name(); // Storage access to satisfy compiler warning
    //     _symbol(); // Storage access to satisfy compiler warning

    //     // Access name/symbol storage slots directly
    //     // This is the only way to modify these after initialization
    //     assembly {
    //         // Store name
    //         sstore(0x0, mload(add(_name.offset, 0x20)))

    //         // Store symbol
    //         sstore(0x1, mload(add(_symbol.offset, 0x20)))
    //     }
    // }

    // /// @notice Override the mint function to enforce STEAM-specific logic
    // /// @param _to The account that will receive the created tokens
    // /// @param _value The amount that will be created
    // /// @return success Boolean indicating success
    // function mint(address _to, uint256 _value) public override(MintableBurnableERC20_v1, IMintable) returns (bool) {
    //     SteamStorage storage $ = _getSteamStorage();

    //     if (msg.sender != $.minter) {
    //         revert MinterOnly();
    //     }

    //     if (_to == address(0)) {
    //         revert ZeroAddress();
    //     }

    //     if (block.timestamp >= $.start_epoch_time + RATE_REDUCTION_TIME) {
    //         _update_mining_parameters();
    //     }

    //     uint256 _total_supply = totalSupply() + _value;
    //     if (_total_supply > _available_supply()) {
    //         revert ExceedsAllowableMintAmount();
    //     }

    //     // Use parent mint
    //     super.mint(_to, _value);

    //     return true;
    // }

    /*//////////////////////////////////////////////////////////////
                        INTERFACE GETTERS
    //////////////////////////////////////////////////////////////*/
    /// @notice Get the mining epoch
    /// @return Current mining epoch
    function mining_epoch() external view returns (int128) {
        return _getSteamStorage().mining_epoch;
    }

    /// @notice Get the start epoch time
    /// @return Start epoch timestamp
    function start_epoch_time() external view returns (uint256) {
        return _getSteamStorage().start_epoch_time;
    }

    /// @notice Get the current emission rate
    /// @return Current rate
    function rate() external view returns (uint256) {
        return _getSteamStorage().rate;
    }

    /// @notice Get the initial rate
    /// @return Initial emission rate
    function INITIAL_RATE() external view returns (uint256) {
        return _getSteamStorage().INITIAL_RATE;
    }

    /// @notice Get the rate reduction coefficient
    /// @return Rate reduction coefficient
    function RATE_REDUCTION_COEFFICIENT() external view returns (uint256) {
        return _getSteamStorage().RATE_REDUCTION_COEFFICIENT;
    }

    /// @notice Get the minter address
    /// @return Minter address
    function minter() external view returns (address) {
        return _getSteamStorage().minter;
    }

    /// @notice Get the admin address
    /// @return Admin address
    function admin() external view returns (address) {
        return _getSteamStorage().admin;
    }

    // Implement necessary ERC165 interface checks
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ISTEAM).interfaceId || super.supportsInterface(interfaceId);
    }
}
