// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {MintableBurnableERC20_v2} from "@bao/MintableBurnableERC20_v2.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";
/// @notice Harbor leveraged token deployment logic.
/// @dev Leveraged tokens are unique per market (e.g., hsFXUSD-BTC for BTC::fxUSD market).
abstract contract LeveragedToken is HarborDeployer {
    // ========== LEVERAGED TOKEN DEPLOYMENT ==========

    /// @notice Deploy MintableBurnableERC20_v2 impl only (for leveraged token), record in state.
    function deployLeveragedTokenImplementation(
        DeploymentTypes.State memory stateData,
        string memory key
    ) internal virtual returns (address impl) {
        impl = address(new MintableBurnableERC20_v2());
        _reportImplementation(impl);

        _recordImplementation(stateData, key, "@bao/MintableBurnableERC20_v2.sol", "MintableBurnableERC20_v2", impl);
    }

    /// @notice Deploy a leveraged token and grant minter roles.
    function _deployLeveragedTokenWithRoles(
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig
    ) internal returns (address leveragedToken) {
        string memory key = leveragedTokenKey(marketConfig);
        string memory tokenName = ConfigTokenNames(address(marketConfig)).leveragedName();
        string memory tokenSymbol = ConfigTokenNames(address(marketConfig)).leveragedSymbol();

        _reportContract(key);
        _reportToken(tokenName, tokenSymbol);

        address impl = deployLeveragedTokenImplementation(stateData, key);

        bytes memory initData = abi.encodeCall(
            MintableBurnableERC20_v2.initialize,
            (address(this), owner(), tokenName, tokenSymbol)
        );

        leveragedToken = _deployProxyAndRecord(stateData, key, impl, initData);

        // Grant minter roles
        address minter = minterAddress(marketConfig);
        uint256 roles = IMintableRole(leveragedToken).MINTER_ROLE() | IBurnableRole(leveragedToken).BURNER_ROLE();
        _grantRoles(key, leveragedToken, minter, MinterMarketConfigLib.salt(marketConfig), roles, "MINTER | BURNER");
    }
}
