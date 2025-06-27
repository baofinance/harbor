// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";

import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";

/// @title VotingEscrow
/// @author rootminus0x1
///         Modified from Aladdinn (https://github.com/AladdinDAO/aladdin-v3-contracts/blob/main/contracts/voting-escrow/VotingEscrow.vy)
///         Which was modified from Curve (https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/VotingEscrow.vy)
///         Added in functions from https://github.com/AladdinDAO/aladdin-v3-contracts/blob/main/contracts/voting-escrow/VotingEscrowHelper.sol
///         Made UUPS upgradeable with named storage
/// @notice Implements a system where governance tokens can be locked for a time period
///         in exchange for voting power (veToken).
/// @dev Voting power decays linearly with time. The maximum lock time is 4 years.
///
/// This is a faithful Solidity port of Curve's VotingEscrow Vyper contract.
/// Storage Pattern: Using ERC7201 namespaced storage slots to ensure that upgrades don't corrupt storage. This is more secure than the old storage gap approach.
/// Ownership Integration: Integrates with BAO's custom ownership model by inheriting from BaoOwnable, which provides a one-time ownership transfer pattern.
/// Upgradeability: Implements UUPS pattern using OpenZeppelin's contracts, with the _authorizeUpgrade function restricted to the BAO owner.
/// Code Differences:
/// Maintaining Solidity conventions while preserving Vyper logic
/// Replaced Vyper's nested array access with mapping[address][uint256] pattern
/// Using SafeCast for type conversion safety
/// Added additional view functions to improve useability
/// Compatible Interfaces:
/// Maintains exact function signatures from the Vyper original
/// Includes Aragon-compatible functions for DAO integration
/// Binary Search:
/// Implements the same binary search algorithm for finding checkpoint epochs
/// Uses 128 iterations to match Vyper implementation
/// Potential Issues:
/// Gas costs will be slightly higher than the Vyper original due to Solidity's storage access patterns
/// The Vyper original has extremely tightly packed storage which is harder to reproduce in Solidity
/// The checkpoint function is still gas-intensive due to the historical lookups
// slither-disable-start timestamp
// solhint-disable-next-line contract-name-camelcase
contract VotingEscrow_v1 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    BaoOwnableRoles,
    ITokenHolder,
    TokenHolder,
    IVotingEscrow
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    /***************************************************************************
     * Namespace Storage - ERC7201-based storage pattern for upgradeability
     **************************************************************************/

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.VotingEscrow")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _VOTING_ESCROW_STORAGE =
        0x8d4cdbcdf88ffd0d1c59297e12b94ebee7ae214c1a483d97ad100b0876812b00;

    struct VotingEscrowStorage {
        // Voting power tracking
        uint256 epoch;
        // Point structure for historical lookups
        mapping(uint256 => Point) pointHistory; // epoch -> point
        mapping(address => mapping(uint256 => Point)) userPointHistory; // user -> Point[user_epoch]
        mapping(address => uint256) userPointEpoch; // user -> epoch
        mapping(uint256 => int128) slopeChanges; // time -> slope change
        // contract security
        mapping(address => bool) isAllowedContract;
        // Token-related variables
        uint256 supply;
        mapping(address => LockedBalance) locked;
        // Aragon compatibility
        string name;
        string symbol;
        string version;
        bool transfersEnabled;
    }

    function _getStorage() private pure returns (VotingEscrowStorage storage $) {
        bytes32 position = _VOTING_ESCROW_STORAGE;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := position
        }
    }

    /***************************************************************************
     * Constants
     **************************************************************************/

    uint256 internal constant _MAXTIME = 4 * 365 days; // 4 years
    int128 internal constant _MAXTIME_I128 = 4 * 365 days; // 4 years

    uint256 public constant SMART_CONTRACT_MANAGER_ROLE = _ROLE_0;
    address public immutable token;
    uint8 public immutable decimals;

    /***************************************************************************
     * Struct Definitions
     **************************************************************************/

    /**
     * @notice Records a locked token balance and when it expires
     */
    struct LockedBalance {
        int128 amount; // Amount of token locked
        uint256 end; // When the lock expires
    }

    /***************************************************************************
     * Initialization
     **************************************************************************/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address token_) {
        _disableInitializers();
        token = token_;
        decimals = IERC20Metadata(token).decimals();
    }

    /**
     * @notice Initializes the contract with required parameters
     * @param _name Token name for Aragon compatibility
     * @param _symbol Token symbol for Aragon compatibility
     * @param _version Contract version for Aragon compatibility
     */
    function initialize(
        address owner_,
        string memory _name,
        string memory _symbol,
        string memory _version
    ) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __Context_init();
        __ReentrancyGuardTransient_init();

        VotingEscrowStorage storage $ = _getStorage();
        $.pointHistory[0] = Point(0, 0, block.timestamp, block.number);

        $.transfersEnabled = true;

        $.name = _name;
        $.symbol = _symbol;
        $.version = _version;
    }

    /***************************************************************************
     * protected mutator functions
     **************************************************************************/

    /**
     * @notice Required override for UUPS upgradeable pattern
     * @dev Only callable by owner
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /***************************************************************************
     * Internal Helpers
     **************************************************************************/

    modifier onlyAllowedContractOrEOA() {
        // Check if the caller is an EOA or has the required role
        if (
            // solhint-disable-next-line avoid-tx-origin
            msg.sender != tx.origin && // wake-disable-line tx-origin
            !hasAnyRole(msg.sender, SMART_CONTRACT_MANAGER_ROLE)
        ) {
            revert Unauthorized();
        }
        _;
    }

    /**
     * @dev Find the most recent point that is earlier than or equal to the timestamp
     * @param timestamp Timestamp to search for
     * @param startEpoch Start of the search range
     * @param endEpoch End of the search range
     */
    function _findPointEpoch(uint256 timestamp, uint256 startEpoch, uint256 endEpoch) internal view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();

        // Binary search
        uint256 min = startEpoch;
        uint256 max = endEpoch;

        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < 128; i++) {
            // 128 is enough for 128-bit numbers
            if (min >= max) {
                break;
            }
            uint256 mid = (min + max + 1) / 2;
            Point memory point = $.pointHistory[mid];
            if (point.ts <= timestamp) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }

        return min;
    }

    /**
     * @dev Calculate voting power at a specific timestamp based on a point
     * @param point The point to start calculation from
     * @param timestamp The timestamp at which to calculate voting power
     */
    function _supplyAt(Point memory point, uint256 timestamp) internal view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();

        Point memory lastPoint = Point(point.bias, point.slope, point.ts, point.blk);
        uint256 iTimestamp = (lastPoint.ts / 1 weeks) * 1 weeks;

        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < 255; i++) {
            iTimestamp += 1 weeks;
            int128 dSlope = 0;

            if (iTimestamp > timestamp) {
                iTimestamp = timestamp;
            } else {
                dSlope = $.slopeChanges[iTimestamp];
            }

            lastPoint.bias -= lastPoint.slope * int128(int256(iTimestamp - lastPoint.ts));
            if (iTimestamp == timestamp) {
                break;
            }
            lastPoint.slope += dSlope;
            lastPoint.ts = iTimestamp;
        }

        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }

        return uint256(int256(lastPoint.bias));
    }

    struct Param {
        Point u;
        int128 dslope;
    }

    /**
     * @dev Record global and per-user data to checkpoint
     * @param addr User's wallet address (0 for global checkpoint only)
     * @param oldLocked Pevious locked amount / end lock time for the user
     * @param newLocked New locked amount / end lock time for the user
     */
    // slither-disable-next-line cyclomatic-complexity
    function _checkpoint(address addr, LockedBalance memory oldLocked, LockedBalance memory newLocked) internal {
        VotingEscrowStorage storage $ = _getStorage();

        Param memory oldP;
        Param memory newP;

        oldP.u = Point(0, 0, 0, 0);
        newP.u = Point(0, 0, 0, 0);
        oldP.dslope = 0;
        newP.dslope = 0;
        uint256 epoch_ = $.epoch;

        if (addr != address(0)) {
            // Calculate slopes and biases for user points
            // Kept at zero when they have to
            if (oldLocked.end > block.timestamp && oldLocked.amount > 0) {
                oldP.u.slope = oldLocked.amount / _MAXTIME_I128;
                oldP.u.bias = oldP.u.slope * int128(int256(oldLocked.end - block.timestamp));
            }

            if (newLocked.end > block.timestamp && newLocked.amount > 0) {
                newP.u.slope = newLocked.amount / _MAXTIME_I128;
                newP.u.bias = newP.u.slope * int128(int256(newLocked.end - block.timestamp));
            }

            // Handle slope changes at lock expiry
            // Read values of scheduled changes in the slope
            // old_locked.end can be in the past and in the future
            // new_locked.end can ONLY by in the FUTURE unless everything expired: than zeros
            oldP.dslope = $.slopeChanges[oldLocked.end];
            if (newLocked.end != 0) {
                if (newLocked.end == oldLocked.end) {
                    newP.dslope = oldP.dslope;
                } else {
                    newP.dslope = $.slopeChanges[newLocked.end];
                }
            }
        }

        // Record checkpoint
        Point memory lastPoint = Point(0, 0, block.timestamp, block.number);
        if (epoch_ > 0) {
            lastPoint = $.pointHistory[epoch_];
        }
        uint256 lastCheckpoint = lastPoint.ts;
        // initial_last_point is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract
        // Initialize reference for extrapolation
        // note that we need to make a copy
        Point memory initialLastPoint = Point({
            bias: lastPoint.bias,
            slope: lastPoint.slope,
            ts: lastPoint.ts,
            blk: lastPoint.blk
        });

        uint256 blockSlope = 0; // dblock/dt
        if (block.timestamp > lastPoint.ts) {
            blockSlope = ((block.number - lastPoint.blk) * 1 ether) / (block.timestamp - lastPoint.ts);
        }
        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

        // Go over weeks to fill history and calculate what the current point is
        uint256 iTimestamp = (lastCheckpoint / 1 weeks) * 1 weeks;
        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < 255; i++) {
            // Hopefully it won't happen that this won't get used in 5 years!
            // If it does, users will be able to withdraw but vote weight will be broken
            iTimestamp += 1 weeks;
            int128 dslope = 0;

            if (iTimestamp > block.timestamp) {
                iTimestamp = block.timestamp;
            } else {
                dslope = $.slopeChanges[iTimestamp];
            }

            lastPoint.bias -= lastPoint.slope * int128(int256(iTimestamp - lastCheckpoint));
            lastPoint.slope += dslope;

            // Handle underflow
            if (lastPoint.bias < 0) // This can happen
            {
                lastPoint.bias = 0;
            }
            if (lastPoint.slope < 0) // This cannot happen - just in case
            {
                lastPoint.slope = 0;
            }

            lastCheckpoint = iTimestamp;
            lastPoint.ts = iTimestamp;
            lastPoint.blk = initialLastPoint.blk + (blockSlope * (iTimestamp - initialLastPoint.ts)) / 1 ether;

            epoch_ += 1;
            if (iTimestamp == block.timestamp) {
                lastPoint.blk = block.number;
                break;
            } else {
                $.pointHistory[epoch_] = lastPoint;
            }
        }

        $.epoch = epoch_;
        // Now point_history is filled until t=now

        // Now handle per-user history
        if (addr != address(0)) {
            // Update user point
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            lastPoint.slope += (newP.u.slope - oldP.u.slope);
            lastPoint.bias += (newP.u.bias - oldP.u.bias);

            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
        }

        // Record the changed point into history
        $.pointHistory[epoch_] = lastPoint;

        if (addr != address(0)) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            if (oldLocked.end > block.timestamp) {
                // old_dslope was <something> - u_old.slope, so we cancel that
                oldP.dslope += oldP.u.slope;
                if (newLocked.end == oldLocked.end) {
                    oldP.dslope -= newP.u.slope;
                }
                $.slopeChanges[oldLocked.end] = oldP.dslope;
            }

            if (newLocked.end > block.timestamp) {
                if (newLocked.end > oldLocked.end) {
                    newP.dslope -= newP.u.slope;
                    $.slopeChanges[newLocked.end] = newP.dslope;
                } // else: we recorded it already in old_dslope
            }

            // Update user epoch and history
            uint256 userEpoch = $.userPointEpoch[addr] + 1;
            $.userPointEpoch[addr] = userEpoch;

            newP.u.ts = block.timestamp;
            newP.u.blk = block.number;
            $.userPointHistory[addr][userEpoch] = newP.u;
        }
    }

    /***************************************************************************
     * Core Functions
     **************************************************************************/

    /**
     * @notice Deposit and lock tokens for a user
     * @param addr User address
     * @param value Amount to deposit
     * @param unlockTime Time when tokens unlock, 0 if unchanged
     * @param lockedBalance Previous locked balance
     * @param type_ Type of deposit (1: create lock, 2: increase amount, 3: extend time)
     */
    function _depositFor(
        address sender,
        address addr,
        uint256 value,
        uint256 unlockTime,
        LockedBalance memory lockedBalance,
        int128 type_
    ) internal {
        VotingEscrowStorage storage $ = _getStorage();

        LockedBalance memory _locked = LockedBalance(lockedBalance.amount, lockedBalance.end); // copy
        uint256 supplyBefore = $.supply;

        $.supply = supplyBefore + value;
        LockedBalance memory oldLocked = LockedBalance(_locked.amount, _locked.end); // copy

        // Adding to existing lock, or if a lock is expired - creating a new one
        _locked.amount += value.toInt256().toInt128();
        if (unlockTime != 0) {
            _locked.end = unlockTime;
        }
        $.locked[addr] = _locked;

        // Possibilities:
        // Both old_locked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // _locked.end > block.timestamp (always)
        _checkpoint(addr, oldLocked, _locked);

        if (value != 0) {
            IERC20(token).safeTransferFrom(sender, address(this), value);
        }

        emit IVotingEscrow.Deposit(addr, value, _locked.end, type_, block.timestamp);
        emit IVotingEscrow.Supply(supplyBefore, supplyBefore + value);
    }

    /**
     * @notice Record global data to checkpoint
     */
    function checkpoint() external {
        LockedBalance memory emptyLock = LockedBalance(0, 0);
        _checkpoint(address(0), emptyLock, emptyLock);
    }

    /**
     * @notice Deposit `value` tokens for `addr` and add to the lock
     * @dev Anyone (even a smart contract) can deposit for someone else, but
     *      cannot extend their locktime and deposit for a brand new user
     * @param addr User's wallet address
     * @param value Amount to add to user's lock
     */
    // solhint-disable-next-line func-name-mixedcase
    function deposit_for(address addr, uint256 value) external nonReentrant {
        VotingEscrowStorage storage $ = _getStorage();
        LockedBalance memory locked_ = $.locked[addr];

        if (value <= 0) {
            revert ValueNotPositive(value);
        }
        if (locked_.amount <= 0) {
            revert NothingIsLocked();
        }
        if (locked_.end <= block.timestamp) {
            revert LockExpired(block.timestamp, locked_.end);
        }

        _depositFor(_msgSender(), addr, value, 0, locked_, 0);
    }

    /**
     * @notice Deposit `value` tokens for `msg.sender` and lock until `unlockTime`
     * @param value Amount to deposit
     * @param unlockTime Epoch time when tokens unlock, rounded down to whole weeks
     */
    // solhint-disable-next-line func-name-mixedcase
    function create_lock(uint256 value, uint256 unlockTime) external nonReentrant onlyAllowedContractOrEOA {
        VotingEscrowStorage storage $ = _getStorage();

        unlockTime = (unlockTime / 1 weeks) * 1 weeks; // Locktime is rounded down to weeks
        LockedBalance memory locked_ = $.locked[msg.sender];

        if (value <= 0) {
            revert ValueNotPositive(value);
        }
        if (locked_.amount > 0) {
            revert AlreadyLockedAmount(locked_.amount, locked_.end);
        }
        if (unlockTime <= block.timestamp) {
            revert LockExpired(block.timestamp, unlockTime);
        }
        if (unlockTime > block.timestamp + _MAXTIME) {
            revert ExceededMaxLockTime(unlockTime, block.timestamp + _MAXTIME);
        }

        _depositFor(_msgSender(), _msgSender(), value, unlockTime, locked_, 1);
    }

    /**
     * @notice Deposit additional `value` tokens for `msg.sender`
     *         without modifying the unlock time
     * @param value Amount of tokens to deposit
     */
    // solhint-disable-next-line func-name-mixedcase
    function increase_amount(uint256 value) external nonReentrant onlyAllowedContractOrEOA {
        VotingEscrowStorage storage $ = _getStorage();

        LockedBalance memory locked_ = $.locked[msg.sender];

        if (value <= 0) {
            revert ValueNotPositive(value);
        }
        if (locked_.amount <= 0) {
            revert NothingIsLocked();
        }
        if (locked_.end <= block.timestamp) {
            revert LockExpired(block.timestamp, locked_.end);
        }
        _depositFor(_msgSender(), _msgSender(), value, 0, locked_, 2);
    }

    /**
     * @notice Extend the unlock time for `msg.sender` to `unlockTime`
     * @param unlockTime New epoch time for unlocking
     */
    // solhint-disable-next-line func-name-mixedcase
    function increase_unlock_time(uint256 unlockTime) external nonReentrant onlyAllowedContractOrEOA {
        VotingEscrowStorage storage $ = _getStorage();

        unlockTime = (unlockTime / 1 weeks) * 1 weeks; // Locktime is rounded down to weeks
        LockedBalance memory locked_ = $.locked[msg.sender];

        if (locked_.end <= block.timestamp) {
            revert LockExpired(block.timestamp, locked_.end);
        }
        if (locked_.amount <= 0) {
            revert NothingIsLocked();
        }
        if (unlockTime <= locked_.end) {
            revert LockCanOnlyIncrease(unlockTime, locked_.end);
        }
        if (unlockTime > block.timestamp + _MAXTIME) {
            revert ExceededMaxLockTime(unlockTime, block.timestamp + _MAXTIME);
        }

        _depositFor(_msgSender(), _msgSender(), 0, unlockTime, locked_, 3);
    }

    /**
     * @notice Withdraw all tokens for `msg.sender`
     * @dev Only possible if the lock has expired
     */
    function withdraw() external nonReentrant {
        VotingEscrowStorage storage $ = _getStorage();
        LockedBalance memory locked_ = $.locked[msg.sender];

        if (block.timestamp < locked_.end) {
            revert LockNotExpired(block.timestamp, locked_.end);
        }
        uint256 value = uint256(int256(locked_.amount));

        LockedBalance memory oldLocked = LockedBalance(locked_.amount, locked_.end);
        locked_.end = 0;
        locked_.amount = 0;
        $.locked[msg.sender] = locked_;

        uint256 supplyBefore = $.supply;
        $.supply = supplyBefore - value;

        // oldLocked can have either expired <= timestamp or zero end
        // locked_ has only 0 end
        // Both can have >= 0 amount
        _checkpoint(msg.sender, oldLocked, locked_);

        IERC20(token).safeTransfer(msg.sender, value);

        emit IVotingEscrow.Withdraw(msg.sender, value, block.timestamp);
        emit IVotingEscrow.Supply(supplyBefore, supplyBefore - value);
    }

    /***************************************************************************
     * Public View Functions - Voting Power
     **************************************************************************/

    function supply() external view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.supply;
    }

    /**
     * @notice Read the current locked balance of `addr`
     * @param addr Address to query
     * @return The locked balance
     */
    function locked(address addr) external view returns (LockedBalance memory) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.locked[addr];
    }

    function admin() external view returns (address) {
        return owner();
    }

    function controller() external view returns (address) {
        return owner();
    }

    function transfersEnabled() external view returns (bool) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.transfersEnabled;
    }

    function epoch() external view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.epoch;
    }

    // solhint-disable-next-line func-name-mixedcase
    function point_history(uint256 epoch_) external view returns (Point memory) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.pointHistory[epoch_];
    }

    // solhint-disable-next-line func-name-mixedcase
    function user_point_history(address addr, uint256 epoch_) external view returns (Point memory) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.userPointHistory[addr][epoch_];
    }

    // solhint-disable-next-line func-name-mixedcase
    function user_point_history__ts(address addr, uint256 epoch_) external view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.userPointHistory[addr][epoch_].ts;
    }

    // solhint-disable-next-line func-name-mixedcase
    function user_point_epoch(address addr) external view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.userPointEpoch[addr];
    }

    // solhint-disable-next-line func-name-mixedcase
    function slope_changes(uint256 week) external view returns (int128) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.slopeChanges[week];
    }

    function get_last_user_slope(address account) external view returns (int128) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.userPointHistory[account][$.userPointEpoch[account]].slope;
    }

    /**
     * @notice Calculate voting power for a specific timestamp
     * @param addr User address
     * @param ts Timestamp to query
     * @return User voting power
     */
    function _balanceOf(address addr, uint256 ts) internal view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();
        uint256 userEpoch = $.userPointEpoch[addr];

        if (userEpoch == 0) {
            return 0;
        } else {
            Point memory lastPoint = $.userPointHistory[addr][userEpoch];
            // Now handle the case when block.timestamp is earlier than user history
            if (ts < lastPoint.ts) {
                // Find the most recent user point before ts
                userEpoch = _findPointEpoch(ts, 1, userEpoch);
                lastPoint = $.userPointHistory[addr][userEpoch];
            }

            lastPoint.bias -= lastPoint.slope * int128(int256(ts - lastPoint.ts));
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }

            return uint256(int256(lastPoint.bias));
        }
    }

    /**
     * @notice Binary search to estimate timestamp for block number
     * @param _block Block to find
     * @param max_epoch Don't go beyond this epoch
     * @return Approximate timestamp for block
     */
    // solhint-disable-next-line func-name-mixedcase
    function find_block_epoch(uint256 _block, uint256 max_epoch) internal view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();

        // Binary search
        uint256 _min = 0;
        uint256 _max = max_epoch;

        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < 128; i++) {
            // Will be always enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if ($.pointHistory[_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    /**
     * @notice Get the timestamp for checkpoint `epoch` for `addr`
     * @param addr User wallet address
     * @param epoch_ User epoch number
     * @return Epoch time of the checkpoint
     */
    // solhint-disable-next-line func-name-mixedcase
    function user_point_historyTs(address addr, uint256 epoch_) external view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.userPointHistory[addr][epoch_].ts;
    }

    /**
     * @notice Get timestamp when `addr`'s lock finishes
     * @param addr User wallet
     * @return Epoch time of the lock end
     */
    // solhint-disable-next-line func-name-mixedcase
    function locked__end(address addr) external view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.locked[addr].end;
    }

    /**
     * @notice Calculate total voting power
     * @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
     * @return Total voting power
     */
    function totalSupply() external view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();
        Point memory lastPoint = $.pointHistory[$.epoch];
        return _supplyAt(lastPoint, block.timestamp);
    }

    /**
     * @notice Calculate total voting power at timestamp
     * @param t Time to calculate total voting power at
     * @return Total voting power
     */
    function totalSupply(uint256 t) external view returns (uint256) {
        VotingEscrowStorage storage $ = _getStorage();
        Point memory lastPoint = $.pointHistory[$.epoch];
        return _supplyAt(lastPoint, t);
    }

    /**
     * @notice Calculate total voting power at some point in the past
     * @param _block Block to calculate the total voting power at
     * @return Total voting power at `_block`
     */
    function totalSupplyAt(uint256 _block) external view returns (uint256) {
        if (_block > block.number) {
            revert("Block is in the future");
        }

        VotingEscrowStorage storage $ = _getStorage();
        uint256 _epoch = $.epoch;
        uint256 target_epoch = find_block_epoch(_block, _epoch);

        Point memory point = $.pointHistory[target_epoch];
        uint256 dt = 0;
        if (target_epoch < _epoch) {
            Point memory point_next = $.pointHistory[target_epoch + 1];
            if (point.blk != point_next.blk) {
                dt = ((_block - point.blk) * (point_next.ts - point.ts)) / (point_next.blk - point.blk);
            }
        } else {
            if (point.blk != block.number) {
                dt = ((_block - point.blk) * (block.timestamp - point.ts)) / (block.number - point.blk);
            }
        }
        // Now dt contains info on how far are we beyond point

        return _supplyAt(point, point.ts + dt);
    }

    /**
     * @notice Get the current voting power for `addr`
     * @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
     * @param addr User wallet address
     * @return User voting power
     */
    function balanceOf(address addr) external view returns (uint256) {
        return _balanceOf(addr, block.timestamp);
    }

    /**
     * @notice Get the voting power for `addr` at timestamp `t`
     * @param addr User wallet address
     * @param t Timestamp to query
     * @return User voting power
     */
    function balanceOf(address addr, uint256 t) external view returns (uint256) {
        return _balanceOf(addr, t);
    }

    /**
     * @notice Measure voting power of `addr` at block height `_block`
     * @dev Adheres to MiniMe `balanceOfAt` interface: https://github.com/Giveth/minime
     * @param addr User's wallet address
     * @param _block Block to calculate the voting power at
     * @return Voting power
     */
    function balanceOfAt(address addr, uint256 _block) external view returns (uint256) {
        // Copying and pasting totalSupply code because Vyper cannot pass by
        // reference yet
        if (_block > block.number) {
            revert("Block is in the future");
        }

        VotingEscrowStorage storage $ = _getStorage();

        // Binary search
        uint256 _min = 0;
        uint256 _max = $.userPointEpoch[addr];

        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < 128; i++) {
            // Will be always enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if ($.userPointHistory[addr][_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }

        Point memory upoint = $.userPointHistory[addr][_min];

        uint256 max_epoch = $.epoch;
        uint256 _epoch = find_block_epoch(_block, max_epoch);
        Point memory point_0 = $.pointHistory[_epoch];
        uint256 d_block = 0;
        uint256 d_t = 0;
        if (_epoch < max_epoch) {
            Point memory point_1 = $.pointHistory[_epoch + 1];
            d_block = point_1.blk - point_0.blk;
            d_t = point_1.ts - point_0.ts;
        } else {
            d_block = block.number - point_0.blk;
            d_t = block.timestamp - point_0.ts;
        }
        uint256 block_time = point_0.ts;
        if (d_block != 0) {
            block_time += (d_t * (_block - point_0.blk)) / d_block;
        }

        upoint.bias -= upoint.slope * int128(int256(block_time - upoint.ts));
        if (upoint.bias >= 0) {
            return uint256(int256(upoint.bias));
        } else {
            return 0;
        }
    }

    /**
     * @notice Get the most recently recorded rate of voting power decrease for `addr`
     * @param addr Address of the user
     * @return Value of the slope
     */
    function getLastUserSlope(address addr) external view returns (int128) {
        VotingEscrowStorage storage $ = _getStorage();
        uint256 uEpoch = $.userPointEpoch[addr];
        return $.userPointHistory[addr][uEpoch].slope;
    }

    /***************************************************************************
     * Public View Functions - Token Info for  Aragon compatibility
     **************************************************************************/

    function name() external view returns (string memory) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.name;
    }

    function symbol() external view returns (string memory) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.symbol;
    }

    function version() external view returns (string memory) {
        VotingEscrowStorage storage $ = _getStorage();
        return $.version;
    }
}

// slither-disable-end timestamp
