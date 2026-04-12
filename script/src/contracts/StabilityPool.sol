// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

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
        string memory spKey = _key(marketKey, spType);
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

        _recordImplementation(stateData, spKey, "@harbor/minter/StabilityPool_v3.sol", "StabilityPool_v3", impl);
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
        string memory spKey = _key(marketKey, spType);
        console.log("    > %s", spKey);

        address impl = deployStabilityPoolImplementation(spType, stateData, marketConfig, minter, liquidationToken);

        IStabilityPoolMarketConfig cfg = IStabilityPoolMarketConfig(address(marketConfig));
        bytes memory initData = abi.encodeCall(
            StabilityPool_v3.initialize,
            (address(this), owner(), cfg.stabilityPoolEarlyWithdrawalFeeRatio(), treasury())
        );

        proxy = _deployProxyAndRecord(stateData, spKey, impl, initData);
    }

    /// @notice Grant StabilityPool roles to StabilityPoolManager and AutoCompounder.
    /// @param marketKey The market salt key (e.g., "ETH::fxUSD").
    /// @param spType "stabilityPoolCollateral" or "stabilityPoolLeveraged".
    /// @param acType The matching AC type ("autoCompounderCollateral" or "autoCompounderLeveraged").
    function grantStabilityPoolRoles(string memory marketKey, string memory spType, string memory acType) internal {
        string memory spKey = _key(marketKey, spType);
        address sp = _predictAddress(spKey);

        // SPM gets REBALANCER + REWARD_DEPOSITOR
        address spm = _predictAddress(_key(marketKey, "stabilityPoolManager"));
        StabilityPool_v3 pool = StabilityPool_v3(sp);
        uint256 roles = pool.REBALANCER_ROLE() | pool.REWARD_DEPOSITOR_ROLE();
        _grantRoles(spKey, sp, spm, "stabilityPoolManager", roles, "REBALANCER | REWARD_DEPOSITOR");

        // AC gets EXEMPT_WITHDRAWAL_FEE
        address ac = _predictAddress(_key(marketKey, acType));
        _grantRoles(spKey, sp, ac, acType, pool.EXEMPT_WITHDRAWAL_FEE_ROLE(), "EXEMPT_WITHDRAWAL_FEE");
    }
}
