// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
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

    /// @notice Move a market to `targetCollateralRatio` by choosing the wrap rate and letting the collateral price
    /// absorb the difference. Returns the price it derived.
    ///
    /// @dev The rate is the independent variable, and the price the derived one, for a reason that decides what this
    /// helper can reach at all: the recognised backing is `min(record, held x rate)`, and the price does not appear in
    /// that comparison. So only the rate selects which branch the market is on, and a price-driven move is
    /// structurally incapable of reaching the impaired branch — at any collateral ratio, however wide the sweep.
    ///
    /// Setting the rate first is what makes the derivation closed-form: the backing settles before the price is
    /// computed from it, so there is nothing to iterate towards. The reverse direction is closed-form too
    /// (`rate = ratio x pegged / (held x price)`) but is only valid if the resulting rate keeps the market on the
    /// impaired branch, so it assumes a branch and must then check it.
    ///
    /// Preconditions and the achieved ratio are enforced with `require` rather than an assertion, because this stays a
    /// mixin with no test-base dependency. Feasibility of the derived price is the caller's to judge and is why the
    /// price is returned: a suite that declares its own collateral-price range asserts against it on the way out,
    /// rather than passing that range down through a parameter this mixin could not name or a field it would have to
    /// remember between calls.
    ///
    /// @param minter The market to move.
    /// @param oracle The market's mock price oracle.
    /// @param targetCollateralRatio The collateral ratio the market should sit at, 1e18-scaled.
    /// @param wrapRate The wrapped-to-underlying rate, used directly as the oracle rate.
    function setCollateralRatioByRate(
        address minter,
        address oracle,
        uint256 targetCollateralRatio,
        uint256 wrapRate
    ) internal returns (uint256 collateralPrice) {
        // The rate first: the recognised backing depends on it, and not on the price it is read at.
        (uint256 priceBefore, , , ) = IWrappedPriceOracle(oracle).latestAnswer();
        MockWrappedPriceOracle(oracle).setLatestAnswer(priceBefore, wrapRate);

        uint256 backing = IMinter(minter).collateralTokenBalance(); // recognised: min(record, held x rate)
        uint256 peggedBalance = IMinter(minter).peggedTokenBalance();
        require(backing > 0, "a market with no recognised backing has no collateral ratio to target");
        require(peggedBalance > 0, "a market with no anchor issued has no collateral ratio to target");

        // collateralRatio is backing x price / peggedBalance, so the price that lands on the target inverts it
        collateralPrice = Math.mulDiv(targetCollateralRatio, peggedBalance, backing);
        MockWrappedPriceOracle(oracle).setLatestAnswer(collateralPrice, wrapRate);

        // The derived price floors, contributing at most `backing / peggedBalance` to the ratio it produces, and the
        // ratio's own division floors by at most one - so the achieved ratio sits within that of the target.
        uint256 tolerance = Math.ceilDiv(backing, peggedBalance) + 1;
        uint256 achieved = IMinter(minter).collateralRatio();
        require(
            achieved + tolerance >= targetCollateralRatio && achieved <= targetCollateralRatio + tolerance,
            "the derived price does not put the market at the requested collateral ratio"
        );
    }

}
