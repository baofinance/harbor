// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {LibString} from "@solady/utils/LibString.sol";
import {PeggedToken} from "@harbor-script/src/contracts/PeggedToken.sol";
import {LeveragedToken} from "@harbor-script/src/contracts/LeveragedToken.sol";
import {Minter} from "@harbor-script/src/contracts/Minter.sol";
import {StabilityPool} from "@harbor-script/src/contracts/StabilityPool.sol";
import {StabilityPoolManager} from "@harbor-script/src/contracts/StabilityPoolManager.sol";
import {Genesis} from "@harbor-script/src/contracts/Genesis.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";

/// @notice The shared Harbor deploy stack: aggregates the per-contract deployers and exposes
///         `deployHarborForPeg`, which stands up a peg's full minter market (pegged/leveraged
///         tokens, minter, stability pools, SPM, genesis).
/// @dev Inherited by both the production `Deploy_<PEG>_mainnet` scripts and the `test/` setups
///      (via `Deploy_<PEG>_Minter`), so the real deploy code is exercised throughout the suite,
///      not only in a dedicated deploy test.
abstract contract HarborDeployStack is
    PeggedToken,
    LeveragedToken,
    Minter,
    StabilityPool,
    StabilityPoolManager,
    Genesis
{
    using LibString for string;

    /// @dev What this stack deploys, named once so the run's opening and closing lines cannot drift apart.
    /// @dev `internal` so a test-side subclass running a partial deploy reports under the same banner.
    string internal constant HARBOR_DEPLOYMENT_NAME = "Minter Contracts";

    // ========== MARKET LOOKUP ==========

    /// @notice Find a market config by collateral name.
    /// @param markets Array of market configurations.
    /// @param collateral Collateral name to find.
    /// @return The matching market config.
    /// @dev Reverts if not found.
    function findMarket(
        Config_MinterMarket[] memory markets,
        string memory collateral
    ) internal view returns (Config_MinterMarket) {
        bytes32 target = keccak256(bytes(collateral));
        for (uint256 i = 0; i < markets.length; i++) {
            if (keccak256(bytes(MinterMarketConfigLib.collateral(markets[i]))) == target) {
                return markets[i];
            }
        }
        revert(string.concat("Market not found for collateral: ", collateral));
    }

    /// @notice Parse collateral filter string into array of markets.
    /// @param allMarkets All configured markets.
    /// @param collateralFilter "*" for all, or single collateral name.
    /// @return Filtered array of markets.
    function parseCollateralFilter(
        Config_MinterMarket[] memory allMarkets,
        string memory collateralFilter
    ) internal view returns (Config_MinterMarket[] memory) {
        if (collateralFilter.eq("*")) {
            return allMarkets;
        }
        if (bytes(collateralFilter).length == 0) {
            return new Config_MinterMarket[](0);
        }
        Config_MinterMarket[] memory result = new Config_MinterMarket[](1);
        result[0] = findMarket(allMarkets, collateralFilter);
        return result;
    }

    // ========== THE DEPLOY RUN ==========

    /// @notice Deploy pegged token and/or markets for a peg.
    /// @param saltPrefix Salt prefix for CREATE3 deployment namespacing.
    /// @param peg Peg configuration.
    /// @param allMarkets All configured markets for this peg (used for role grants).
    /// @param network Network name (e.g., "mainnet").
    /// @param deployPeg Whether to deploy the pegged token.
    /// @param marketsToDeploy Markets to deploy (empty array = none).
    function deployHarborForPeg(
        string memory saltPrefix,
        ConfigPeg peg,
        Config_MinterMarket[] memory allMarkets,
        string memory network,
        bool deployPeg,
        Config_MinterMarket[] memory marketsToDeploy
    ) internal {
        _runDeploy(HARBOR_DEPLOYMENT_NAME, saltPrefix, network, peg, allMarkets, deployPeg, marketsToDeploy);
    }

    /// @notice Every deployment run, whatever it deploys, in four phases: create the state, deploy and
    ///         configure each contract, wire whatever could only be wired once both ends existed, then hand
    ///         ownership over.
    /// @dev NOT virtual, and deliberately so: the ORDER is the invariant here, and only the phases are
    ///      open. A run that could reorder these — or skip the last — would be a run that could leave
    ///      contracts owned by the deployer, or transfer ownership away before configuration finished.
    /// @param what Names the run in its opening and closing lines.
    function _runDeploy(
        string memory what,
        string memory saltPrefix,
        string memory network,
        ConfigPeg peg,
        Config_MinterMarket[] memory allMarkets,
        bool deployPeg,
        Config_MinterMarket[] memory marketsToDeploy
    ) internal {
        _setSaltPrefix(saltPrefix);

        DeploymentTypes.State memory state = _shouldPersistState()
            ? DeploymentState.load(_stateFileRead())
            : DeploymentState.fresh(saltPrefix, network);
        state.baoFactory = baoFactory();

        _reportRun(what, saltPrefix, network);

        _deployAndConfigure(state, peg, allMarkets, deployPeg, marketsToDeploy);
        _configureCrossDependencies(state, peg, marketsToDeploy);

        _reportSection("Transferring Ownerships");
        _transferAllOwnerships();
        _saveState(state);
        _reportRunComplete(what);
    }

    /// @notice Phase 2: deploy and configure the contracts this run owns.
    /// @dev The default is production's — the peg's pegged token, then every market's full infrastructure.
    ///      Override it to deploy less: a stack that needs only a minter calls a shorter prefix of the same
    ///      list. What an override cannot do is change what happens around it, which is the point.
    function _deployAndConfigure(
        DeploymentTypes.State memory state,
        ConfigPeg peg,
        Config_MinterMarket[] memory allMarkets,
        bool deployPeg,
        Config_MinterMarket[] memory marketsToDeploy
    ) internal virtual {
        if (deployPeg) {
            _reportSection(string.concat("Deploying ", peg.key(), " Pegged Token"));
            deployPeggedTokenWithRoles(state, peg, allMarkets);
        }

        for (uint256 i = 0; i < marketsToDeploy.length; i++) {
            deployMinterInfrastructure(state, marketsToDeploy[i]);
        }
    }

    /// @notice Phase 3: configure whatever could only be configured once BOTH contracts existed.
    /// @dev Empty by default — Harbor has no such pair today. The phase exists because phase 4 is the point
    ///      of no return: two contracts that must each verify the other can only do so while the deployer
    ///      still owns both, and this is the last moment that is true. Without somewhere to put such a call,
    ///      the alternative is to drop the verification, and that is not a trade worth forcing.
    function _configureCrossDependencies(
        DeploymentTypes.State memory,
        ConfigPeg,
        Config_MinterMarket[] memory
    ) internal virtual {}

    // ========== MINTER INFRASTRUCTURE DEPLOYMENT ==========
    //
    // Each contract's own deploy function deploys AND configures it — its setters, its reward tokens, the
    // roles it grants — so standing one up takes exactly one call and leaves nothing for a caller to
    // remember. `deployMinterInfrastructure` below is therefore just the market's contracts in dependency
    // order, and a caller wanting less calls a shorter prefix of the same list.
    //
    // The order is a real constraint in only one place. Every role grantee is a PREDICTED CREATE3 address
    // and granting to an address with no code is valid, so no contract has to wait for its grantees. What
    // does force order is a constructor that READS another contract: the minter reads its two tokens, and
    // each stability pool reads three token addresses off the minter (see `deployStabilityPool`).

    /// @notice Deploy a market's full infrastructure, in dependency order.
    /// @param state Deployment state (modified in place).
    /// @param market Market configuration.
    function deployMinterInfrastructure(DeploymentTypes.State memory state, Config_MinterMarket market) internal {
        string memory marketKey = MinterMarketConfigLib.salt(market);
        _reportMarket(marketKey);

        _deployLeveragedTokenWithRoles(state, market);
        deployReservePool(state, market);
        deployMinter(state, market);
        deployStabilityPool(StabilityPoolType.Collateral, state, market);
        deployStabilityPool(StabilityPoolType.Leveraged, state, market);
        deployStabilityPoolManager(state, market);
        deployGenesis(state, market);

        _reportMarketComplete(marketKey);
    }
}
