// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";

/// @notice A rule under test, as ONE object: what goes behind the minter, which manager the market gets, and the
///         label the run's files carry.
///
/// A rule can have two halves. `MinterLeverageCap` refuses to sell leverage below its floor, and only a manager
/// that knows so routes a rebalance around the refusal instead of reverting inside it; a run that installed the
/// minter and forgot the manager would measure a rule nobody proposed - which happened, once, before this
/// existed. Holding both halves in one object makes that impossible to do by accident.
///
/// It is an OBJECT rather than a mixin for a reason found the hard way: a mixin beside a market defines the same
/// functions the market's base does, and Solidity then demands an override in every run purely to say which -
/// the diamond, with the meaningless overrides that come with it. An object has one definer. A run names its
/// rule in one line, in its constructor. And every rule has an external surface, so a layer outside Solidity
/// can compose the same runs from the same pieces.
abstract contract MarketRule {
    /// @notice The suffix the run's files carry, after the market's own. Empty for the tree.
    function label() public view virtual returns (string memory);

    /// @notice The minter implementation to put behind the market's minter proxy, built FROM the immutables the
    ///         market already carries - the addresses are handed over, so a rule cannot re-point a market at other
    ///         tokens. Zero leaves the market on the minter it has.
    function buildMinter(
        address wrappedCollateralToken,
        address peggedToken,
        address leveragedToken
    ) public virtual returns (address);

    /// @notice The manager implementation for the market, built from the minter and pools it already has - the
    ///         same handing-over, for the same reason. This tree's manager unless the rule sizes a rebalance
    ///         differently.
    function buildManager(
        address minter,
        address collateralPool,
        address leveragedPool
    ) public virtual returns (address) {
        return address(new StabilityPoolManager_v2(minter, collateralPool, leveragedPool));
    }
}

/// @notice The rule as it stands in this tree: the minter the market came with, this tree's manager, no label.
contract TreeRule is MarketRule {
    function label() public pure override returns (string memory) {
        return "";
    }

    function buildMinter(address, address, address) public pure override returns (address) {
        return address(0);
    }
}
