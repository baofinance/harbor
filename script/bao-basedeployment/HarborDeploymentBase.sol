// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {DeploymentState} from "./DeploymentState.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {MinterMarketConfigLib, Config_MinterMarket} from "script/config/ConfigBase.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Base contract for Harbor deployment orchestration.
/// @dev Provides orchestration for deploying markets from config contracts.
/// @dev Scripts that inherit this should use DeploymentState via composition.
abstract contract HarborDeploymentBase {
    using MinterMarketConfigLib for Config_MinterMarket;

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Deploy a minter market from config.
    /// @param state The deployment state.
    /// @param config The market configuration contract.
    /// @return Updated deployment state.
    function deployMinterMarket(
        DeploymentTypes.State memory state,
        Config_MinterMarket config
    ) internal view returns (DeploymentTypes.State memory) {
        string memory marketSalt = config.salt();
        console.log("\n=== Deploying Minter Market: %s ===", marketSalt);

        // Use predictAddress to get proxy addresses without deployment order dependencies
        // Example pattern:
        //
        // string memory peggedKey = config.peggedKey();  // e.g., "fxUSD"
        // string memory leveragedKey = _qualifyKey(marketSalt, "leveraged");
        // string memory minterKey = _qualifyKey(marketSalt, "minter");
        //
        // address peggedToken = predictAddress(peggedKey, SYSTEM_SALT_STRING());
        // address leveragedToken = predictAddress(leveragedKey, SYSTEM_SALT_STRING());
        // address wrappedCollateral = config.wrappedCollateralToken();
        //
        // 1. Deploy Minter
        //    Minter_v1 minterImpl = new Minter_v1(
        //      wrappedCollateral,
        //      peggedToken,
        //      leveragedToken,
        //      config.peggedBurnSignature()
        //    );
        //    deployProxy(
        //      0,  // value
        //      minterKey,
        //      SYSTEM_SALT_STRING(),
        //      address(minterImpl),
        //      abi.encodeCall(Minter_v1.initialize, (config.owner())),
        //      "Minter_v1",
        //      type(Minter_v1).creationCode,
        //      _deployer()
        //    );
        //    recordImplementation(...);
        //    recordProxy(...);
        //
        // 2. Deploy Leveraged Token
        //    MintableBurnableERC20_v1 leveragedImpl = new MintableBurnableERC20_v1();
        //    deployProxy(...);
        //    recordImplementation(...);
        //    recordProxy(...);
        //
        // 3. Deploy StabilityPools (collateral and leveraged)
        //    address minter = predictAddress(minterKey, SYSTEM_SALT_STRING());
        //    StabilityPool_v1 spCollateralImpl = new StabilityPool_v1(
        //      minter,
        //      wrappedCollateral,  // liquidation token
        //      config.earlyWithdrawalFee(),
        //      config.feeAddress(),
        //      config.withdrawalStartDelay(),
        //      config.withdrawalEndWindow(),
        //      config.minTotalSupply()
        //    );
        //    deployProxy(...);
        //
        // 4. Deploy StabilityPoolManager
        //    address spCollateral = predictAddress(...);
        //    address spLeveraged = predictAddress(...);
        //    StabilityPoolManager_v1 spmImpl = new StabilityPoolManager_v1(
        //      minter,
        //      config.treasury(),
        //      spCollateral,
        //      spLeveraged
        //    );
        //    deployProxy(...);
        //
        // 5. Grant roles (these operate on already-deployed proxies)
        //    IBaoRoles(peggedToken).grantRoles(minter, MINTER_ROLE | BURNER_ROLE);
        //    IBaoRoles(leveragedToken).grantRoles(minter, MINTER_ROLE | BURNER_ROLE);
        //    IBaoRoles(spCollateral).grantRoles(spm, REBALANCER_ROLE | REWARD_DEPOSITOR_ROLE);
        //    etc.
        //
        // 6. Set addresses on minter
        //    Minter_v1(minter).updatePriceOracle(config.priceOracle());
        //    Minter_v1(minter).updateFeeReceiver(config.feeReceiver());
        //    etc.
        //
        // 7. Optional: Run smoke tests
        //    if (_shouldRunSmokeTests()) {
        //      _runSmokeTestForMarket(state, config);
        //    }

        console.log("Market %s deployment complete (skeleton - awaiting Phase 2 config completion)", marketSalt);
        return state;
    }

    /// @notice Generate a qualified key for a contract within a market.
    /// @param marketSalt The market salt (e.g., "BTC::stETH").
    /// @param role The contract role (e.g., "minter", "stabilityPoolCollateral").
    /// @return The qualified key (e.g., "BTC::stETH::minter").
    function _qualifyKey(string memory marketSalt, string memory role) internal pure returns (string memory) {
        return string.concat(marketSalt, "::", role);
    }

    /// @notice Parse a fragment descriptor from market and role.
    /// @param marketSalt The market salt (e.g., "BTC::stETH").
    /// @param role The contract role (e.g., "minter").
    /// @return Fragment descriptor for the contract.
    function _parseFragment(string memory marketSalt, string memory role)
        internal
        pure
        returns (DeploymentTypes.FragmentDescriptor memory)
    {
        return DeploymentTypes.FragmentDescriptor({
            kind: DeploymentTypes.FragmentKind.ContractRole,
            key: _qualifyKey(marketSalt, role)
        });
    }

    /// @notice Hook to determine if smoke tests should run.
    /// @dev Override in test harness or concrete scripts. Default: false.
    /// @return True if smoke tests should be executed.
    function _shouldRunSmokeTests() internal view virtual returns (bool) {
        return false;
    }

    /// @notice Hook to run smoke tests for a deployed market.
    /// @dev Override in test harness or concrete scripts. Default: no-op.
    /// @param state The deployment state.
    /// @param config The market configuration.
    function _runSmokeTestForMarket(DeploymentTypes.State memory state, Config_MinterMarket config)
        internal
        view
        virtual
    {
        // Default: no smoke tests
        // Can be overridden to check:
        // - All addresses non-zero
        // - Roles correctly assigned
        // - View functions return expected values
    }
}
