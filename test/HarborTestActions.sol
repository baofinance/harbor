// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @notice Shared harbor deployment-test setup helpers (no test-base dependency): a bag of utilities for standing up
/// pool state and running role-scoped operations against a deployed protocol.
abstract contract HarborTestActions {
    // the well-known forge/hevm cheatcode address: address(uint160(uint256(keccak256("hevm cheat code")))). Referenced
    // directly (not inherited from a Test base) so this stays a pure mixin.
    Vm private constant _vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @notice Put `implementation`'s runtime code at `target`, so calls to `target` run it.
    /// @dev The way to stand a mock in for a dependency this repo does not deploy but references by its predicted
    /// CREATE3 address. Install at the address the deploy's own resolver returns, so a key change moves the deploy
    /// and the mock together. Copies CODE, not storage: the implementation's constructor and field initialisers do
    /// NOT apply, so configure the installed mock through its setters afterwards.
    function installContractAt(address target, address implementation) internal {
        _vm.etch(target, implementation.code);
    }

    /// @notice Install a settable mock price oracle at `oracleAddress`, and return it for configuring.
    /// @param oracleAddress The market's oracle address, from the deploy's own `wrappedPriceOracleAddress` resolver.
    /// @dev Call AFTER the deploy. The price oracle is a separate deployment (harbor-price-aggregators), and the
    /// deploy wires the minter to its predicted address while that address is still codeless — exactly as production
    /// does. Installing beforehand would hide that path; installing after still beats the first read, because the
    /// deploy only ever stores the address, never calls it.
    function installMockPriceOracle(address oracleAddress) internal returns (address) {
        installContractAt(oracleAddress, address(new MockWrappedPriceOracle()));
        return oracleAddress;
    }

    /// @notice Hold `role` on `target` only for the wrapped call: grant it (as the target's owner) before the body,
    /// revoke it after - so the test never carries a standing role. Generalises the temporary-role pattern to any
    /// role-gated operation on an owned contract.
    modifier asRoles(address target, uint256 role) {
        address owner = IBaoOwnable(target).owner();
        _vm.startPrank(owner);
        IBaoRoles(target).grantRoles(address(this), role);
        _vm.stopPrank();
        _;
        _vm.startPrank(owner);
        IBaoRoles(target).revokeRoles(address(this), role);
        _vm.stopPrank();
    }

    /// @notice Bootstrap a minter's pool the way Genesis does: free-mint `collateralForPegged` worth of pegged and
    /// `collateralForLeveraged` worth of leveraged to `recipient` - the same `freeMint*` calls the Genesis contract
    /// makes. The starting collateral ratio follows the pegged:leveraged collateral split. The minter owner may
    /// free-mint (`onlyOwnerOrRoles`), so this acts as the owner - no ZERO_FEE_ROLE grant needed - and funds the owner
    /// from the mock collateral (deployment tests mock it, so no fork).
    function genesisMint(
        address minter,
        uint256 collateralForPegged,
        uint256 collateralForLeveraged,
        address recipient
    ) internal returns (uint256 peggedMinted, uint256 leveragedMinted) {
        address owner = IBaoOwnable(minter).owner();
        address wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();
        uint256 total = collateralForPegged + collateralForLeveraged;
        MockERC20(wrappedCollateral).mint(owner, total);
        _vm.startPrank(owner);
        IERC20(wrappedCollateral).approve(minter, total);
        if (collateralForPegged > 0) {
            peggedMinted = IMinter(minter).freeMintPeggedToken(collateralForPegged, recipient);
        }
        if (collateralForLeveraged > 0) {
            leveragedMinted = IMinter(minter).freeMintLeveragedToken(collateralForLeveraged, recipient);
        }
        _vm.stopPrank();
    }
}
