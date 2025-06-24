// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title VotingEscrow
 * @author Modified from Curve (https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/VotingEscrow.vy)
 * @notice Implements a system where governance tokens can be locked for a time period
 *         in exchange for voting power (veToken).
 * @dev Voting power decays linearly with time. The maximum lock time is 4 years.
 *      This is a faithful Solidity port of Curve's VotingEscrow Vyper contract.
 */
contract VotingEscrow is Initializable, UUPSUpgradeable, BaoOwnable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    /***************************************************************************
     * Namespace Storage - ERC7201-based storage pattern for upgradeability
     **************************************************************************/

    // keccak256("VotingEscrow.Storage") - 1
    bytes32 private constant _VOTING_ESCROW_STORAGE_LOCATION =
        0x8d8a99a3577e8a383fc91b0385c6deb89d9ebb840c5e898538462bd33ddb96a1;

    struct VotingEscrowStorage {
        // Point structure for historical lookups
        mapping(uint256 => Point) pointHistory; // epoch -> point
        mapping(address => Point[1000000000]) userPointHistory; // user -> Point[user_epoch]
        mapping(address => uint256) userPointEpoch; // user -> epoch
        mapping(uint256 => int128) slopeChanges; // time -> slope change
        // Token-related variables
        address token;
        uint256 supply;
        mapping(address => LockedBalance) locked;
        // Voting power tracking
        uint256 epoch;
        // Aragon compatibility
        string name;
        string symbol;
        string version;
        uint8 decimals;
        address controller;
        bool transfersEnabled;
        // For smart wallet checker
        address smartWalletChecker;
        address futureSmartWalletChecker;
    }

    function _getStorage() private pure returns (VotingEscrowStorage storage s) {
        bytes32 position = _VOTING_ESCROW_STORAGE_LOCATION;
        assembly {
            s.slot := position
        }
    }

    /***************************************************************************
     * Constants
     **************************************************************************/

    uint256 internal constant WEEK = 7 * 86400; // all future times are rounded by week
    uint256 internal constant MAXTIME = 4 * 365 * 86400; // 4 years
    int128 internal constant MAXTIME_I128 = 4 * 365 * 86400; // 4 years
    uint256 internal constant MULTIPLIER = 1e18;

    /***************************************************************************
     * Struct Definitions
     **************************************************************************/

    /**
     * @notice Point structure records bias and slope at a given timestamp
     * @dev Used for voting power calculation and historical tracking
     */
    struct Point {
        int128 bias; // Voting power at time.ts
        int128 slope; // Voting power rate of decay (dweight / dt)
        uint256 ts; // Timestamp
        uint256 blk; // Block
    }

    /**
     * @notice Records a locked token balance and when it expires
     */
    struct LockedBalance {
        int128 amount; // Amount of token locked
        uint256 end; // When the lock expires
    }

    /***************************************************************************
     * Events
     **************************************************************************/

    event CommitOwnership(address admin);
    event ApplyOwnership(address admin);

    event Deposit(address indexed provider, uint256 value, uint256 indexed locktime, int128 type_, uint256 ts);

    event Withdraw(address indexed provider, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);

    /***************************************************************************
     * Initialization
     **************************************************************************/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with required parameters
     * @param tokenAddr Address of the ERC20 token that will be locked
     * @param _name Token name for Aragon compatibility
     * @param _symbol Token symbol for Aragon compatibility
     * @param _version Contract version for Aragon compatibility
     */
    function initialize(
        address tokenAddr,
        string memory _name,
        string memory _symbol,
        string memory _version
    ) external initializer {
        __UUPSUpgradeable_init();
        _initializeOwner(msg.sender);

        VotingEscrowStorage storage s = _getStorage();
        s.token = tokenAddr;
        s.pointHistory[0].blk = block.number;
        s.pointHistory[0].ts = block.timestamp;
        s.controller = msg.sender;
        s.transfersEnabled = true;

        uint8 _decimals = IERC20Metadata(tokenAddr).decimals();
        require(_decimals <= 255, "Decimals exceeds uint8");

        s.name = _name;
        s.symbol = _symbol;
        s.version = _version;
        s.decimals = _decimals;
    }

    /***************************************************************************
     * Admin Functions
     **************************************************************************/

    /**
     * @notice Change smart wallet checker contract address
     * @dev Only callable by owner
     * @param addr New smart wallet checker address
     */
    function commitSmartWalletChecker(address addr) external onlyOwner {
        VotingEscrowStorage storage s = _getStorage();
        s.futureSmartWalletChecker = addr;
    }

    /**
     * @notice Apply pending smart wallet checker
     * @dev Only callable by owner
     */
    function applySmartWalletChecker() external onlyOwner {
        VotingEscrowStorage storage s = _getStorage();
        s.smartWalletChecker = s.futureSmartWalletChecker;
    }

    /**
     * @notice Required override for UUPS upgradeable pattern
     * @dev Only callable by owner
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /***************************************************************************
     * Internal Helpers
     **************************************************************************/

    /**
     * @dev Check if the call is from a whitelisted smart contract, revert if not
     * @param addr Address to check
     */
    function _assertNotContract(address addr) internal view {
        if (addr != tx.origin) {
            VotingEscrowStorage storage s = _getStorage();
            address checker = s.smartWalletChecker;
            if (checker != address(0)) {
                if (ISmartWalletChecker(checker).check(addr)) {
                    return;
                }
            }
            revert("Smart contract depositors not allowed");
        }
    }

    /**
     * @dev Find the most recent point that is earlier than or equal to the timestamp
     * @param timestamp Timestamp to search for
     * @param startEpoch Start of the search range
     * @param endEpoch End of the search range
     */
    function _findPointEpoch(uint256 timestamp, uint256 startEpoch, uint256 endEpoch) internal view returns (uint256) {
        VotingEscrowStorage storage s = _getStorage();

        // Binary search
        uint256 min = startEpoch;
        uint256 max = endEpoch;

        for (uint i = 0; i < 128; i++) {
            // 128 is enough for 128-bit numbers
            if (min >= max) {
                break;
            }
            uint256 mid = (min + max + 1) / 2;
            Point memory point = s.pointHistory[mid];
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
        VotingEscrowStorage storage s = _getStorage();

        Point memory lastPoint = point;
        uint256 t_i = (lastPoint.ts / WEEK) * WEEK;

        for (uint i = 0; i < 255; i++) {
            t_i += WEEK;
            int128 dSlope = 0;

            if (t_i > timestamp) {
                t_i = timestamp;
            } else {
                dSlope = s.slopeChanges[t_i];
            }

            lastPoint.bias -= lastPoint.slope * int128(int256(t_i - lastPoint.ts));
            if (t_i == timestamp) {
                break;
            }
            lastPoint.slope += dSlope;
            lastPoint.ts = t_i;
        }

        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }

        return uint256(int256(lastPoint.bias));
    }

    /**
     * @dev Record global and per-user data checkpoints
     * @param addr User address (0 for global checkpoint only)
     * @param oldLocked Previous locked amount/end
     * @param newLocked New locked amount/end
     */
    function _checkpoint(address addr, LockedBalance memory oldLocked, LockedBalance memory newLocked) internal {
        VotingEscrowStorage storage s = _getStorage();

        Point memory uOld = Point(0, 0, 0, 0);
        Point memory uNew = Point(0, 0, 0, 0);
        int128 oldDslope = 0;
        int128 newDslope = 0;
        uint256 _epoch = s.epoch;

        if (addr != address(0)) {
            // Calculate slopes and biases for user points
            if (oldLocked.end > block.timestamp && oldLocked.amount > 0) {
                uOld.slope = oldLocked.amount / MAXTIME_I128;
                uOld.bias = uOld.slope * int128(int256(oldLocked.end - block.timestamp));
            }

            if (newLocked.end > block.timestamp && newLocked.amount > 0) {
                uNew.slope = newLocked.amount / MAXTIME_I128;
                uNew.bias = uNew.slope * int128(int256(newLocked.end - block.timestamp));
            }

            // Handle slope changes at lock expiry
            oldDslope = s.slopeChanges[oldLocked.end];
            if (newLocked.end != 0) {
                if (newLocked.end == oldLocked.end) {
                    newDslope = oldDslope;
                } else {
                    newDslope = s.slopeChanges[newLocked.end];
                }
            }
        }

        // Record checkpoint
        Point memory lastPoint = Point(0, 0, block.timestamp, block.number);
        if (_epoch > 0) {
            lastPoint = s.pointHistory[_epoch];
        }

        uint256 lastCheckpoint = lastPoint.ts;

        // Initialize reference for extrapolation
        Point memory initialLastPoint = Point({
            bias: lastPoint.bias,
            slope: lastPoint.slope,
            ts: lastPoint.ts,
            blk: lastPoint.blk
        });

        uint256 blockSlope = 0;
        if (block.timestamp > lastPoint.ts) {
            blockSlope = (MULTIPLIER * (block.number - lastPoint.blk)) / (block.timestamp - lastPoint.ts);
        }

        // Go over weeks to fill history and calculate what the current point is
        uint256 t_i = (lastCheckpoint / WEEK) * WEEK;
        for (uint i = 0; i < 255; i++) {
            t_i += WEEK;
            int128 dslope = 0;

            if (t_i > block.timestamp) {
                t_i = block.timestamp;
            } else {
                dslope = s.slopeChanges[t_i];
            }

            lastPoint.bias -= lastPoint.slope * int128(int256(t_i - lastCheckpoint));
            lastPoint.slope += dslope;

            // Handle underflow
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }

            lastCheckpoint = t_i;
            lastPoint.ts = t_i;
            lastPoint.blk = initialLastPoint.blk + (blockSlope * (t_i - initialLastPoint.ts)) / MULTIPLIER;

            _epoch += 1;
            if (t_i == block.timestamp) {
                lastPoint.blk = block.number;
                break;
            } else {
                s.pointHistory[_epoch] = lastPoint;
            }
        }

        s.epoch = _epoch;

        // Now handle per-user history
        if (addr != address(0)) {
            // Update user point
            lastPoint.slope += (uNew.slope - uOld.slope);
            lastPoint.bias += (uNew.bias - uOld.bias);

            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
        }

        // Record the final point
        s.pointHistory[_epoch] = lastPoint;

        if (addr != address(0)) {
            // Schedule slope changes
            if (oldLocked.end > block.timestamp) {
                oldDslope += uOld.slope;
                if (newLocked.end == oldLocked.end) {
                    oldDslope -= uNew.slope;
                }
                s.slopeChanges[oldLocked.end] = oldDslope;
            }

            if (newLocked.end > block.timestamp) {
                if (newLocked.end > oldLocked.end) {
                    newDslope -= uNew.slope;
                    s.slopeChanges[newLocked.end] = newDslope;
                }
            }

            // Update user epoch and history
            uint256 userEpoch = s.userPointEpoch[addr] + 1;
            s.userPointEpoch[addr] = userEpoch;

            uNew.ts = block.timestamp;
            uNew.blk = block.number;
            s.userPointHistory[addr][userEpoch] = uNew;
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
        address addr,
        uint256 value,
        uint256 unlockTime,
        LockedBalance memory lockedBalance,
        int128 type_
    ) internal {
        VotingEscrowStorage storage s = _getStorage();
        uint256 supplyBefore = s.supply;
        s.supply = supplyBefore + value;

        LockedBalance memory oldLocked = lockedBalance;

        // Adding to existing lock, or if a lock is expired - creating a new one
        lockedBalance.amount += value.toInt128();
        if (unlockTime != 0) {
            lockedBalance.end = unlockTime;
        }
        s.locked[addr] = lockedBalance;

        // Checkpoint
        _checkpoint(addr, oldLocked, lockedBalance);

        if (value != 0) {
            IERC20(s.token).safeTransferFrom(msg.sender, address(this), value);
        }

        emit Deposit(addr, value, lockedBalance.end, type_, block.timestamp);
        emit Supply(supplyBefore, supplyBefore + value);
    }

    /**
     * @notice Record global data to checkpoint
     */
    function checkpoint() external {
        VotingEscrowStorage storage s = _getStorage();
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
    function depositFor(address addr, uint256 value) external {
        VotingEscrowStorage storage s = _getStorage();
        LockedBalance memory locked_ = s.locked[addr];

        require(value > 0, "Value must be positive");
        require(locked_.amount > 0, "No existing lock found");
        require(locked_.end > block.timestamp, "Cannot add to expired lock");

        _depositFor(addr, value, 0, locked_, 0);
    }

    /**
     * @notice Deposit `value` tokens for `msg.sender` and lock until `unlockTime`
     * @param value Amount to deposit
     * @param unlockTime Epoch time when tokens unlock, rounded down to whole weeks
     */
    function createLock(uint256 value, uint256 unlockTime) external {
        VotingEscrowStorage storage s = _getStorage();
        _assertNotContract(msg.sender);

        unlockTime = (unlockTime / WEEK) * WEEK; // Locktime is rounded down to weeks
        LockedBalance memory locked_ = s.locked[msg.sender];

        require(value > 0, "Value must be positive");
        require(locked_.amount == 0, "Withdraw old tokens first");
        require(unlockTime > block.timestamp, "Can only lock until future time");
        require(unlockTime <= block.timestamp + MAXTIME, "Voting lock can be 4 years max");

        _depositFor(msg.sender, value, unlockTime, locked_, 1);
    }

    /**
     * @notice Deposit additional `value` tokens for `msg.sender`
     *         without modifying the unlock time
     * @param value Amount of tokens to deposit
     */
    function increaseAmount(uint256 value) external {
        VotingEscrowStorage storage s = _getStorage();
        _assertNotContract(msg.sender);

        LockedBalance memory locked_ = s.locked[msg.sender];

        require(value > 0, "Value must be positive");
        require(locked_.amount > 0, "No existing lock found");
        require(locked_.end > block.timestamp, "Cannot add to expired lock");

        _depositFor(msg.sender, value, 0, locked_, 2);
    }

    /**
     * @notice Extend the unlock time for `msg.sender` to `unlockTime`
     * @param unlockTime New epoch time for unlocking
     */
    function increaseUnlockTime(uint256 unlockTime) external {
        VotingEscrowStorage storage s = _getStorage();
        _assertNotContract(msg.sender);

        unlockTime = (unlockTime / WEEK) * WEEK; // Locktime is rounded down to weeks
        LockedBalance memory locked_ = s.locked[msg.sender];

        require(locked_.end > block.timestamp, "Lock expired");
        require(locked_.amount > 0, "Nothing is locked");
        require(unlockTime > locked_.end, "Can only increase lock duration");
        require(unlockTime <= block.timestamp + MAXTIME, "Voting lock can be 4 years max");

        _depositFor(msg.sender, 0, unlockTime, locked_, 3);
    }

    /**
     * @notice Withdraw all tokens for `msg.sender`
     * @dev Only possible if the lock has expired
     */
    function withdraw() external {
        VotingEscrowStorage storage s = _getStorage();
        LockedBalance memory locked_ = s.locked[msg.sender];

        require(block.timestamp >= locked_.end, "The lock has not expired");
        uint256 value = uint256(int256(locked_.amount));

        LockedBalance memory oldLocked = locked_;
        locked_.end = 0;
        locked_.amount = 0;
        s.locked[msg.sender] = locked_;

        uint256 supplyBefore = s.supply;
        s.supply = supplyBefore - value;

        // oldLocked can have either expired <= timestamp or zero end
        // locked_ has only 0 end
        // Both can have >= 0 amount
        _checkpoint(msg.sender, oldLocked, locked_);

        IERC20(s.token).safeTransfer(msg.sender, value);

        emit Withdraw(msg.sender, value, block.timestamp);
        emit Supply(supplyBefore, supplyBefore - value);
    }

    /***************************************************************************
     * View Functions - Voting Power
     **************************************************************************/

    /**
     * @notice Calculate voting power for a specific timestamp
     * @param addr User address
     * @param ts Timestamp to query
     * @return User voting power
     */
    function _balanceOfAt(address addr, uint256 ts) internal view returns (uint256) {
        VotingEscrowStorage storage s = _getStorage();
        uint256 userEpoch = s.userPointEpoch[addr];

        if (userEpoch == 0) {
            return 0;
        } else {
            Point memory lastPoint = s.userPointHistory[addr][userEpoch];
            // Now handle the case when block.timestamp is earlier than user history
            if (ts < lastPoint.ts) {
                // Find the most recent user point before ts
                userEpoch = _findPointEpoch(ts, 1, userEpoch);
                lastPoint = s.userPointHistory[addr][userEpoch];
            }

            lastPoint.bias -= lastPoint.slope * int128(int256(ts - lastPoint.ts));
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }

            return uint256(int256(lastPoint.bias));
        }
    }

    /**
     * @notice Get the timestamp for checkpoint `epoch` for `addr`
     * @param addr User wallet address
     * @param epoch User epoch number
     * @return Epoch time of the checkpoint
     */
    function userPointHistoryTs(address addr, uint256 epoch) external view returns (uint256) {
        VotingEscrowStorage storage s = _getStorage();
        return s.userPointHistory[addr][epoch].ts;
    }

    /**
     * @notice Get timestamp when `addr`'s lock finishes
     * @param addr User wallet
     * @return Epoch time of the lock end
     */
    function lockedEnd(address addr) external view returns (uint256) {
        VotingEscrowStorage storage s = _getStorage();
        return s.locked[addr].end;
    }

    /**
     * @notice Calculate total voting power at specific timestamp
     * @param t Timestamp to query
     * @return Total voting power
     */
    function totalSupplyAt(uint256 t) external view returns (uint256) {
        VotingEscrowStorage storage s = _getStorage();
        uint256 _epoch = s.epoch;
        uint256 targetEpoch = _findPointEpoch(t, 0, _epoch);

        Point memory point = s.pointHistory[targetEpoch];
        uint256 dt = 0;

        if (targetEpoch < _epoch) {
            Point memory pointNext = s.pointHistory[targetEpoch + 1];
            if (point.blk != pointNext.blk) {
                dt = ((t - point.ts) * (pointNext.blk - point.blk)) / (pointNext.ts - point.ts);
            }
        } else if (point.blk != block.number && point.ts != block.timestamp) {
            dt = ((t - point.ts) * (block.number - point.blk)) / (block.timestamp - point.ts);
        }

        // Now dt contains info on how far are we beyond point
        return _supplyAt(point, t);
    }

    /**
     * @notice Calculate total voting power
     * @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
     * @return Total voting power
     */
    function totalSupply() external view returns (uint256) {
        VotingEscrowStorage storage s = _getStorage();
        Point memory lastPoint = s.pointHistory[s.epoch];
        return _supplyAt(lastPoint, block.timestamp);
    }

    /**
     * @notice Calculate total voting power at timestamp
     * @param t Time to calculate total voting power at
     * @return Total voting power
     */
    function totalSupply(uint256 t) external view returns (uint256) {
        VotingEscrowStorage storage s = _getStorage();
        Point memory lastPoint = s.pointHistory[s.epoch];
        return _supplyAt(lastPoint, t);
    }

    /**
     * @notice Get the current voting power for `addr`
     * @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
     * @param addr User wallet address
     * @return User voting power
     */
    function balanceOf(address addr) external view returns (uint256) {
        return _balanceOfAt(addr, block.timestamp);
    }

    /**
     * @notice Get the voting power for `addr` at timestamp `t`
     * @param addr User wallet address
     * @param t Timestamp to query
     * @return User voting power
     */
    function balanceOf(address addr, uint256 t) external view returns (uint256) {
        return _balanceOfAt(addr, t);
    }

    /**
     * @notice Get the most recently recorded rate of voting power decrease for `addr`
     * @param addr Address of the user
     * @return Value of the slope
     */
    function getLastUserSlope(address addr) external view returns (int128) {
        VotingEscrowStorage storage s = _getStorage();
        uint256 uEpoch = s.userPointEpoch[addr];
        return s.userPointHistory[addr][uEpoch].slope;
    }

    /**
     * @notice Read the current locked balance of `addr`
     * @param addr Address to query
     * @return The locked balance
     */
    function locked(address addr) external view returns (LockedBalance memory) {
        VotingEscrowStorage storage s = _getStorage();
        return s.locked[addr];
    }

    /***************************************************************************
     * View Functions - Token Info (Aragon compatibility)
     **************************************************************************/

    function token() external view returns (address) {
        VotingEscrowStorage storage s = _getStorage();
        return s.token;
    }

    function name() external view returns (string memory) {
        VotingEscrowStorage storage s = _getStorage();
        return s.name;
    }

    function symbol() external view returns (string memory) {
        VotingEscrowStorage storage s = _getStorage();
        return s.symbol;
    }

    function version() external view returns (string memory) {
        VotingEscrowStorage storage s = _getStorage();
        return s.version;
    }

    function decimals() external view returns (uint8) {
        VotingEscrowStorage storage s = _getStorage();
        return s.decimals;
    }

    /***************************************************************************
     * Utility Functions
     **************************************************************************/

    /**
     * @notice Change controller address (Aragon compatibility)
     * @dev Only callable by controller
     * @param _newController New controller address
     */
    function changeController(address _newController) external {
        VotingEscrowStorage storage s = _getStorage();
        require(msg.sender == s.controller, "Only controller can change controller");
        s.controller = _newController;
    }
}

/**
 * @notice Interface for checking if an address is a smart contract wallet
 */
interface ISmartWalletChecker {
    function check(address addr) external returns (bool);
}

/**
 * @notice Interface for ERC20 metadata functions
 */
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}
