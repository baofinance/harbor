// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {MinterTokenShared} from "./MinterTokenShared.sol";
import {DeploymentState} from "../DeploymentState.sol";
import {DeploymentTypes} from "../DeploymentTypes.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Harbor leveraged token deployment logic.
/// @dev Leveraged tokens are unique per market (e.g., hsFXUSD-BTC for BTC::fxUSD market).
abstract contract LeveragedToken is MinterTokenShared {
    using LibString for string;

    // ========== LEVERAGED TOKEN DEPLOYMENT ==========

    /// @notice Deploy only the proxy for a leveraged token, pointing to an existing implementation.
    /// @dev Uses shared proxy deployment primitive; leveraged-specific part is the key/name/symbol.
    function deployLeveragedProxy(
        address baoFactoryAddr,
        string memory peg,
        string memory collateral,
        address implementation,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory leveragedKey = string.concat(peg, "::", collateral, "::leveraged");

        // Token name: "Harbor sail: variable leveraged long <COLLATERAL> against <PEG>"
        string memory tokenName = string.concat("Harbor sail: variable leveraged long ", collateral, " against ", peg);
        // Token symbol: "hs<COLLATERAL>-<PEG>"
        string memory tokenSymbol = string.concat("hs", collateral.upper(), "-", peg.upper());

        (proxy, proxyRecord) = _deployTokenProxy(
            baoFactoryAddr,
            leveragedKey,
            tokenName,
            tokenSymbol,
            DeploymentTypes.FragmentKind.MinterMarket,
            implementation,
            tokenOwner,
            systemSalt
        );
    }

    /// @notice Deploy a leveraged token (implementation + proxy) for a specific market.
    function deployLeveragedToken(
        address baoFactoryAddr,
        string memory peg,
        string memory collateral,
        address tokenOwner,
        string memory systemSalt
    )
        internal
        returns (
            address impl,
            address proxy,
            DeploymentTypes.ImplementationRecord memory implRecord,
            DeploymentTypes.ProxyRecord memory proxyRecord
        )
    {
        string memory leveragedKey = string.concat(peg, "::", collateral, "::leveraged");
        string memory tokenName = string.concat("Harbor sail: variable leveraged long ", collateral, " against ", peg);
        string memory tokenSymbol = string.concat("hs", collateral.upper(), "-", peg.upper());

        (impl, proxy, implRecord, proxyRecord) = _deployToken(
            baoFactoryAddr,
            leveragedKey,
            tokenName,
            tokenSymbol,
            DeploymentTypes.FragmentKind.MinterMarket,
            tokenOwner,
            systemSalt
        );
    }

    /// @notice Deploy a leveraged token, record in state, and grant minter roles.
    function deployLeveragedTokenWithRoles(
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig,
        address baoFactoryAddr,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address leveragedToken) {
        IMarketConfig market = IMarketConfig(address(marketConfig));
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);

        (
            ,
            address proxy,
            DeploymentTypes.ImplementationRecord memory implRecord,
            DeploymentTypes.ProxyRecord memory proxyRecord
        ) = deployLeveragedToken(baoFactoryAddr, market.peg(), market.collateral(), tokenOwner, systemSalt);

        DeploymentState.recordImplementation(stateData, implRecord);
        DeploymentState.recordProxy(stateData, proxyRecord);

        leveragedToken = proxy;
        _registerForOwnershipTransfer(proxy, _saltString(proxyRecord.id));

        console.log("      Roles:");
        _grantMinterRolesForMarketKey(leveragedToken, baoFactoryAddr, systemSalt, marketKey);
    }
}
