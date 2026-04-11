// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {ConfigTokenNames} from "script/config/ConfigTokenNames.sol";

/// @notice Config interface for stability pool deployment parameters.
interface IStabilityPoolMarketConfig {
    function stabilityPoolWithdrawalDelay() external pure returns (uint256);
    function stabilityPoolWithdrawalPeriod() external pure returns (uint256);
    function stabilityPoolEarlyWithdrawalFeeRatio() external pure returns (uint256);
    function minTotalSupply() external view returns (uint256);
}

/// @notice Harbor StabilityPool deployment logic.
/// @dev Each market has TWO stability pools: Collateral (wrapped collateral) and Leveraged (leveraged token).
/// @dev Both pools grant: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE to StabilityPoolManager.
abstract contract StabilityPool is HarborFactoryDeployer {
    string StabilityPoolCollateral = "stabilityPoolCollateral";
    string StabilityPoolLeveraged = "stabilityPoolLeveraged";

    // ========== STABILITY POOL DEPLOYMENT ==========

    /// @notice Deploy StabilityPool impl only, record in state.
    function deployStabilityPoolImplementation(
        string memory spType,
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig,
        address minter,
        address liquidationToken
    ) internal virtual returns (address impl) {
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);
        string memory spKey = string.concat(marketKey, "::", spType);
        console.log("    > %s", spKey);

        ConfigTokenNames names = ConfigTokenNames(address(marketConfig));
        bool isCollateral = keccak256(bytes(spType)) == keccak256("stabilityPoolCollateral");
        string memory tokenName = isCollateral ? names.spCollateralName() : names.spLeveragedName();
        string memory tokenSymbol = isCollateral ? names.spCollateralSymbol() : names.spLeveragedSymbol();

        IStabilityPoolMarketConfig cfg = IStabilityPoolMarketConfig(address(marketConfig));

        impl = address(
            new StabilityPool_v3(
                minter,
                liquidationToken,
                cfg.stabilityPoolWithdrawalDelay(),
                cfg.stabilityPoolWithdrawalPeriod(),
                cfg.minTotalSupply(),
                tokenName,
                tokenSymbol
            )
        );
        console.log("        Impl:   %s", impl);
        console.log("          Name:   %s", tokenName);
        console.log("          Symbol: %s", tokenSymbol);

        DeploymentState.recordImplementation(
            stateData,
            DeploymentTypes.ImplementationRecord({
                proxy: spKey,
                contractSource: "@harbor/minter/StabilityPool_v3.sol",
                contractType: "StabilityPool_v3",
                implementation: impl,
                deploymentTime: uint64(block.timestamp)
            })
        );
    }

    /// @notice Deploy StabilityPool impl+proxy, record in state.
    function deployStabilityPool(
        string memory spType,
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig,
        address minter,
        address liquidationToken
    ) internal returns (address proxy) {
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);
        string memory spKey = string.concat(marketKey, "::", spType);
        console.log("    > %s", spKey);

        address impl = deployStabilityPoolImplementation(spType, stateData, marketConfig, minter, liquidationToken);

        IStabilityPoolMarketConfig cfg = IStabilityPoolMarketConfig(address(marketConfig));
        bytes memory initData = abi.encodeCall(
            StabilityPool_v3.initialize,
            (owner(), cfg.stabilityPoolEarlyWithdrawalFeeRatio(), treasury())
        );

        proxy = _deployProxyViaStubAndRecord(stateData, spKey, impl, initData);
    }

    /// @notice Grant StabilityPool roles to StabilityPoolManager.
    function grantStabilityPoolRoles(
        string memory stabilityPoolKey,
        address stabilityPoolProxy,
        address stabilityPoolManager
    ) internal {
        StabilityPool_v3 pool = StabilityPool_v3(stabilityPoolProxy);
        uint256 roles = pool.REBALANCER_ROLE() | pool.REWARD_DEPOSITOR_ROLE();
        _grantRoles(
            stabilityPoolKey,
            stabilityPoolProxy,
            stabilityPoolManager,
            "stabilityPoolManager",
            roles,
            "REBALANCER | REWARD_DEPOSITOR"
        );
    }
}
