// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
/// @notice Harbor leveraged token deployment logic.
/// @dev Leveraged tokens are unique per market (e.g., hsFXUSD-BTC for BTC::fxUSD market).
abstract contract LeveragedToken is HarborFactoryDeployer {
    // ========== LEVERAGED TOKEN DEPLOYMENT ==========

    /// @notice Deploy a leveraged token and grant minter roles.
    function _deployLeveragedTokenWithRoles(
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig
    ) internal returns (address leveragedToken) {
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);

        string memory leveragedKey = string.concat(marketKey, "::leveraged");
        string memory tokenName = MinterMarketConfigLib.leveragedName(marketConfig);
        string memory tokenSymbol = MinterMarketConfigLib.leveragedSymbol(marketConfig);

        console.log("    > %s", leveragedKey);
        console.log("        Name:   %s", tokenName);
        console.log("        Symbol: %s", tokenSymbol);

        address impl = address(new MintableBurnableERC20_v1());
        console.log("        Impl:   %s", impl);

        bytes memory initData = abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner(), tokenName, tokenSymbol));

        leveragedToken = _deployProxyAndRecord(
            stateData,
            leveragedKey,
            impl,
            "@bao/MintableBurnableERC20_v1.sol",
            "MintableBurnableERC20_v1",
            initData
        );

        // Grant minter roles
        address minter = _predictAddress(marketKey, "minter");
        uint256 roles = IMintableRole(leveragedToken).MINTER_ROLE() | IBurnableRole(leveragedToken).BURNER_ROLE();
        _grantRoles(leveragedKey, leveragedToken, minter, marketKey, roles, "MINTER | BURNER");
    }
}
