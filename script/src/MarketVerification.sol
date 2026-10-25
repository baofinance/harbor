// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Token} from "@bao/Token.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {MarketAddresses} from "@harbor-script/src/MarketAddresses.sol";

/// @notice The check that a market's minter, pools and manager name its tokens and each other as its
///         `MarketAddresses` do, and that the tokens answer as ERC-20s.
/// @dev The contracts' constructors call no other contract, so each deploys whatever state the others are in. This
///      check stands in for theirs, once everything it reads exists: after a fresh deploy builds a market, and after
///      the upgrade deploys a market's new implementations, before its batch is saved. It also checks what no
///      constructor could without calling the minter: that each token is this market's.
abstract contract MarketVerification is HarborDeployer {
    /// @notice A contract of the market names an address other than the one the market's addresses hold.
    /// @param what The contract's salt key and the address it names, e.g. "BTC::stETH::stabilityPoolCollateral asset".
    error MarketAddressMismatch(string what, address expected, address found);

    /// @notice Refuse unless `minter`, `collateralPool`, `leveragedPool` and `manager` each name what `addresses`
    ///         hold for `config`'s market, and each of its tokens answers as an ERC-20.
    /// @dev The four are the market's proxies after a fresh deploy, or its new implementations in an upgrade: each
    ///      reads its addresses from its code, so an implementation answers alone.
    function verifyMarket(
        Config_MinterMarket config,
        MarketAddresses memory addresses,
        address minter,
        address collateralPool,
        address leveragedPool,
        address manager
    ) internal view {
        string memory minterName = minterKey(config);
        _requireAddress(
            minterName,
            " wrapped collateral",
            addresses.wrappedCollateral,
            IMinter_v3(minter).WRAPPED_COLLATERAL_TOKEN()
        );
        _requireAddress(minterName, " pegged token", addresses.pegged, IMinter_v3(minter).PEGGED_TOKEN());
        _requireAddress(minterName, " leveraged token", addresses.leveraged, IMinter_v3(minter).LEVERAGED_TOKEN());

        _verifyPool(stabilityPoolKey(config, StabilityPoolType.Collateral), addresses, collateralPool);
        _verifyPool(stabilityPoolKey(config, StabilityPoolType.Leveraged), addresses, leveragedPool);

        string memory managerName = stabilityPoolManagerKey(config);
        _requireAddress(managerName, " minter", addresses.minter, IStabilityPoolManager_v2(manager).MINTER());
        _requireAddress(
            managerName,
            " wrapped collateral",
            addresses.wrappedCollateral,
            IStabilityPoolManager_v2(manager).WRAPPED_COLLATERAL_TOKEN()
        );
        _requireAddress(
            managerName,
            " pegged token",
            addresses.pegged,
            IStabilityPoolManager_v2(manager).PEGGED_TOKEN()
        );
        _requireAddress(
            managerName,
            " leveraged token",
            addresses.leveraged,
            IStabilityPoolManager_v2(manager).LEVERAGED_TOKEN()
        );
        address[] memory pools = IStabilityPoolManager_v2(manager).stabilityPools();
        _requireAddress(managerName, " collateral pool", addresses.collateralPool, pools[0]);
        _requireAddress(managerName, " leveraged pool", addresses.leveragedPool, pools[1]);

        Token.sanityCheckERC20Token(addresses.wrappedCollateral);
        Token.sanityCheckERC20Token(addresses.pegged);
        Token.sanityCheckERC20Token(addresses.leveraged);
    }

    /// @dev The pool `pool`, named `poolName`, must name the market's minter, and its pegged token as its asset.
    function _verifyPool(string memory poolName, MarketAddresses memory addresses, address pool) private view {
        _requireAddress(poolName, " minter", addresses.minter, IStabilityPool_v3(pool).MINTER());
        _requireAddress(poolName, " asset", addresses.pegged, IStabilityPool_v3(pool).ASSET_TOKEN());
    }

    function _requireAddress(
        string memory contractName,
        string memory field,
        address expected,
        address found
    ) private pure {
        if (found != expected) {
            revert MarketAddressMismatch(string.concat(contractName, field), expected, found);
        }
    }
}
