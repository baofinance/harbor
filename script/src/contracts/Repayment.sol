// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {Repayment_v1} from "@harbor/minter/Repayment_v1.sol";

/// @notice Harbor Repayment deployment logic: the contract that repays the holders of the rebalance dilution exploits
///         of 2026-10-16 from the markets' fees.
/// @dev One per incident, under its own key; the markets' fee receivers are pointed at it by the Safe batch that
///      compensates, not by this deployment.
abstract contract Repayment is HarborDeployer {
    /// @notice The salt key of the repayment contract for the exploits of 2026-10-16.
    function rebalanceDilutionRepaymentKey() public pure returns (string memory) {
        return "rebalanceDilutionRepayment";
    }

    /// @notice The predicted address of that contract.
    function rebalanceDilutionRepaymentAddress() public returns (address) {
        return _predictAddress(rebalanceDilutionRepaymentKey());
    }

    /// @notice Deploy Repayment_v1 impl only, record in state.
    /// @param token The token the debts are in: the wrapped collateral of the exploited markets.
    function deployRepaymentImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        address token
    ) internal virtual returns (address impl) {
        impl = address(new Repayment_v1(token));
        _reportImplementation(impl);

        _recordImplementation(stateData, key, "@harbor/minter/Repayment_v1.sol", "Repayment_v1", impl);
    }

    /// @notice Deploy a Repayment_v1 proxy under `key`, recorded in state, with its debts recorded and owned by the
    ///         run's owner once it accepts.
    /// @param token The token the debts are in.
    /// @param name_ The debt token's name, as wallets show it.
    /// @param symbol_ The debt token's symbol.
    /// @param accounts The accounts owed, each once.
    /// @param debts What each is owed, in `token`.
    function deployRepayment(
        DeploymentTypes.State memory stateData,
        string memory key,
        address token,
        string memory name_,
        string memory symbol_,
        address[] memory accounts,
        uint256[] memory debts
    ) internal returns (address proxy) {
        _reportContract(key);
        address impl = deployRepaymentImplementation(stateData, key, token);
        bytes memory initData = abi.encodeCall(
            Repayment_v1.initialize,
            (address(this), owner(), name_, symbol_, accounts, debts)
        );
        proxy = _deployProxyAndRecord(stateData, key, impl, initData);
    }
}
