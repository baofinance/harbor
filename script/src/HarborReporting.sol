// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {Deployer} from "@bao-script/deployment/Deployer.sol";

/// @notice Harbor's share of the deploy's running commentary — the lines an operator watching a harbor
///         deploy sees go past that bao-base could not have written.
/// @dev Separated from the deployment logic it describes so that test coverage measures the two apart.
///      Under `forge test` a deploy is silent, so every message body here is unreachable and every
///      `_shouldReport` branch is one-sided; left in with the deployment code those permanently-uncovered
///      lines mask the coverage of the code that actually deploys things.
///
///      The predicate (`_shouldReport`) and the generic vocabulary (`_reportRun`, `_reportSection`,
///      `_reportContract`, `_reportImplementation`, `_reportProxy`, `_reportDetail`,
///      `_reportOwnershipTransfer`) live on bao-base's `DeployReporting`, because their nouns are
///      bao-base's — salt keys, implementations, proxies, ownership transfers. Only harbor's own
///      vocabulary is here. That split is what makes a deploy silent end to end: bao-base reports on its
///      own account and a consumer cannot reach inside it, so the predicate is shared rather than
///      reimplemented.
abstract contract HarborReporting is Deployer {
    /// @notice The market whose contracts follow.
    function _reportMarket(string memory marketKey) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("");
        console.log("  > Market: %s", marketKey);
    }

    /// @notice A token's name and symbol, under the contract that owns them.
    function _reportToken(string memory name, string memory symbol) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("          Name:   %s", name);
        console.log("          Symbol: %s", symbol);
    }

    /// @notice The named market's contracts are all deployed and wired.
    /// @param marketKey The same value given to `_reportMarket`, so the two lines bracket the market by
    ///        name — which matters when several markets deploy in one run and the completions interleave
    ///        with the contracts of the next.
    function _reportMarketComplete(string memory marketKey) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("    [%s complete]", marketKey);
    }

    /// @notice A role grant the deployer performed itself.
    function _reportRoleGrant(
        string memory granterLabel,
        string memory granteeLabel,
        string memory roleDescription
    ) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("      %s: %s role -> %s", granterLabel, roleDescription, granteeLabel);
    }

    /// @notice A role grant the deployer cannot perform, for the multisig to execute.
    /// @dev Not commentary — this is the operator's deliverable, and the one message here whose loss in a
    ///      script run would be a defect rather than a tidier console. It is still silent under
    ///      `forge test`: a test using the deploy as a fixture has no operator to instruct. A test that is
    ///      ABOUT the deploy turns reporting on.
    function _reportManualRoleGrant(
        string memory granterLabel,
        address target,
        address grantee,
        string memory granteeLabel,
        uint256 roles,
        string memory roleDescription
    ) internal view virtual {
        if (!_shouldReport()) {
            return;
        }
        console.log("      %s: %s role -> %s (MANUAL TX REQUIRED)", granterLabel, roleDescription, granteeLabel);
        console.log("          To:    %s", target);
        console.log("          Call:  grantRoles(%s, %s)", grantee, roles);
    }
}
