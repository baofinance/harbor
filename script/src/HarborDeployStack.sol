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

    // ========== MAIN ENTRY POINT ==========

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
        _setSaltPrefix(saltPrefix);

        // Load or seed state
        DeploymentTypes.State memory state = _shouldPersistState()
            ? DeploymentState.load(_stateFileRead())
            : DeploymentState.fresh(saltPrefix, network);
        state.baoFactory = baoFactory();

        _reportRun(HARBOR_DEPLOYMENT_NAME, saltPrefix, network);

        if (deployPeg) {
            _reportSection(string.concat("Deploying ", peg.key(), " Pegged Token"));
            deployPeggedTokenWithRoles(state, peg, allMarkets);
        }

        for (uint256 i = 0; i < marketsToDeploy.length; i++) {
            deployMinterInfrastructure(state, marketsToDeploy[i]);
        }

        // Finalize: transfer ownerships and save state
        _reportSection("Transferring Ownerships");
        _transferAllOwnerships();
        _saveState(state);
        _reportRunComplete(HARBOR_DEPLOYMENT_NAME);
    }

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
