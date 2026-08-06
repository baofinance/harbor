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
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

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
    string private constant HARBOR_DEPLOYMENT_NAME = "Minter Contracts";

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
    // A market's infrastructure is three layers, each deployable on its own and each granting the roles it
    // owns. `deployMinterInfrastructure` is their composition, and is what production deploys.
    //
    //   deployMinterMarket           leveraged token, reserve pool, minter
    //   deployStabilityPoolsForMarket    the two pools, their reward tokens
    //   deployStabilityPoolManagerForMarket   the manager, genesis
    //
    // The layers are separable because each grants only roles it can: `grantMinterRoles` names the manager
    // and genesis as GRANTEES, and granting to a predicted CREATE3 address is valid whether or not anything
    // has been deployed there yet. `grantStabilityPoolRoles` is the exception — it reads `REBALANCER_ROLE()`
    // OFF the pool, so it needs the pool to exist, which is why it belongs to the pool layer rather than to
    // a shared role-granting step at the end.
    //
    // A test that needs only a minter calls only the first layer, instead of paying for pools and a manager
    // it never touches.

    /// @notice Deploy a market's full infrastructure: every layer, in order.
    /// @param state Deployment state (modified in place).
    /// @param market Market configuration.
    function deployMinterInfrastructure(DeploymentTypes.State memory state, Config_MinterMarket market) internal {
        string memory marketKey = MinterMarketConfigLib.salt(market);
        _reportMarket(marketKey);

        deployMinterMarket(state, market);
        deployStabilityPoolsForMarket(state, market);
        deployStabilityPoolManagerForMarket(state, market);

        _reportMarketComplete(marketKey);
    }

    /// @notice The minter and the two contracts it cannot exist without: its leveraged token and reserve pool.
    /// @dev Self-contained — it needs only the peg's pegged token, which is deployed once per peg above this.
    ///      Sufficient on its own for anything testing the minter in isolation.
    function deployMinterMarket(DeploymentTypes.State memory stateData, Config_MinterMarket market) internal {
        _deployLeveragedTokenWithRoles(stateData, market);
        deployReservePool(stateData, market);
        deployMinter(stateData, market);

        grantReservePoolRoles(market);
        grantMinterRoles(market);
    }

    /// @notice A market's two stability pools, their reward tokens, and the roles read off them.
    /// @dev Requires `deployMinterMarket` first: the pools take the minter and the leveraged token as
    ///      constructor arguments.
    function deployStabilityPoolsForMarket(
        DeploymentTypes.State memory stateData,
        Config_MinterMarket market
    ) internal {
        address minter = minterAddress(market);

        deployStabilityPool(
            StabilityPoolType.Collateral,
            stateData,
            market,
            minter,
            IHarborConfig(address(market)).wrappedCollateralToken()
        );

        deployStabilityPool(StabilityPoolType.Leveraged, stateData, market, minter, leveragedTokenAddress(market));

        _registerRewardTokens(market);

        grantStabilityPoolRoles(market, StabilityPoolType.Collateral);
        grantStabilityPoolRoles(market, StabilityPoolType.Leveraged);
    }

    /// @notice The manager that coordinates a market's two pools, and its genesis contract.
    /// @dev Requires both layers above: the manager takes the minter and both pools as constructor arguments.
    function deployStabilityPoolManagerForMarket(
        DeploymentTypes.State memory stateData,
        Config_MinterMarket market
    ) internal {
        deployStabilityPoolManager(stateData, market);
        deployGenesis(stateData, market);
    }

    function _registerRewardTokens(Config_MinterMarket market) internal {
        address spCollateral = stabilityPoolAddress(market, StabilityPoolType.Collateral);
        address spLeveraged = stabilityPoolAddress(market, StabilityPoolType.Leveraged);
        address wrappedCollateral = IHarborConfig(address(market)).wrappedCollateralToken();
        address leveragedToken = leveragedTokenAddress(market);

        // Collateral SP: wrappedCollateral (receives both harvest + rebalance rewards)
        IMultipleRewardDistributor(spCollateral).registerRewardToken(wrappedCollateral);

        // Leveraged SP: wrappedCollateral (harvest) + leveragedToken (rebalance)
        IMultipleRewardDistributor(spLeveraged).registerRewardToken(wrappedCollateral);
        IMultipleRewardDistributor(spLeveraged).registerRewardToken(leveragedToken);
    }

}
