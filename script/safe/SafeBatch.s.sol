// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {SafeBatchBase} from "script/safe/SafeBatchBase.s.sol";

/// @notice Safe batch contract with build()/run() pattern.
/// @dev Inherit from this contract and override `build()` to specify transactions.
///
/// Example:
/// ```solidity
/// contract MyBatch is SafeBatch {
///     function build() internal override {
///         string memory salt = _saltString("BTC", "fxUSD", "minter");
///         queue(salt, abi.encodeCall(IMinter.updateConfig, (cfg)), "updateConfig(130)");
///     }
/// }
/// ```
abstract contract SafeBatch is SafeBatchBase {
    /// @notice Override to define transactions.
    function build() internal virtual;

    /// @notice Main entry point. Run with: forge script <contract> --sig "run(string)" <salt>
    /// @param salt_ The salt prefix (e.g., "harbor_v1")
    function run(string memory salt_) public {
        _setSaltPrefix(salt_);
        build();
        console.log(_buildSafeJson(""));
    }
}
