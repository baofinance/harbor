// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleStorageV1
 * @notice Diamond storage pattern for Oracle contract
 */
library OracleStorageV1 {
    // Storage slot for oracle data
    bytes32 internal constant STORAGE_SLOT = keccak256("baofinance.oracle.storage.v1");

    struct Config {
        // how old the data read is allowed to be
        uint64 maxTimeDelay; // 64 bits
        // how far apart the two feeds can be
        uint64 maxTimeDifference; // 64 bits
    }

    struct HeartbeatData {
        // Dynamically calculated heartbeat
        uint32 calculatedHeartbeat; // 32 bits
        // Manually set heartbeat (if any)
        uint32 manualHeartbeat; // 32 bits
        // Number of updates tracked
        uint32 lastUpdateCount; // 32 bits
    }

    struct Layout {
        AggregatorV3Interface underlyingFeed;
        AggregatorV3Interface wrappedFeed;
        uint8 underlyingDecimals; // 8 bits
        uint8 wrappedDecimals; // 8 bits
        Config config;
        uint80 lastUnderlyingRound; // 80 bits
        uint80 lastWrappedRound; // 80 bits
        uint64 lastUpdateTimestamp; // 64 bits
        HeartbeatData underlyingHeartbeat;
        HeartbeatData wrappedHeartbeat;
        uint64[3] underlyingUpdateHistory;
        uint64[3] wrappedUpdateHistory;
    }

    /**
     * @dev Returns the storage layout
     */
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }
}
