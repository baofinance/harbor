// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";

/// @notice The questions a measurement asks of a market, answered in the DIALECT of the versions actually
///         behind its proxies.
///
/// Every version difference met so far was handled on the spot and differently each time: a low-level
/// `staticcall` whose revert was read as zero, a `try/catch` on two named selectors, and twice nothing at all
/// - a market that simply crashed on a function one version had and the other did not. Three of those four
/// were invisible, and the worst was the tolerant one: reading ANY revert as a zero answers a broken market
/// with a plausible number instead of stopping.
///
/// So the differences live here, one subclass per lineage, and each answer is a POSITIVE statement about that
/// version rather than a guess recovered from a failure. A question a lineage genuinely cannot answer reverts
/// saying so, and names the lineage, rather than surfacing as a crash somewhere unrelated.
///
/// Which reader a market gets is decided once, where the market is stood up - beside the record of what is
/// behind each proxy - so it is a property of the market rather than a flag consulted later.
abstract contract MarketReader {
    /// @dev Names this lineage in the provenance record, so a run says which dialect it was read in.
    function lineage() public pure virtual returns (string memory);

    /// @dev A stability pool's ERC20 identity. Not every lineage's pool is an ERC20, which is exactly why
    /// this is asked of the reader and not of the pool.
    /// @param pool The pool proxy.
    /// @param isCollateralPool Which of the market's two pools it is - the only thing that distinguishes
    /// their names on a lineage that has to look them up rather than read them back.
    function poolName(address pool, bool isCollateralPool) public view virtual returns (string memory);

    function poolSymbol(address pool, bool isCollateralPool) public view virtual returns (string memory);
}

/// @notice The lineage DEPLOYED today: `Minter_v2` beside `StabilityPool_v2`, a pool from before v3's `name()` and
/// `symbol()`.
contract MarketReaderV2Lineage is MarketReader {
    /// @dev The market's configuration, which is where this lineage's pool names have to come from. Set once
    /// at construction: what this reader IS, not something it is told later.
    ConfigTokenNames private immutable _NAMES;

    constructor(ConfigTokenNames names) {
        _NAMES = names;
    }

    function lineage() public pure override returns (string memory) {
        return "v2";
    }

    /// @dev From the CONFIG, because this lineage's pool is not an ERC20 - `name()` and `symbol()` arrived
    /// with v3, where they are immutables carried in the implementation's own code. Asking the proxy reverts,
    /// which is how this was found.
    function poolName(address, bool isCollateralPool) public view override returns (string memory) {
        return isCollateralPool ? _NAMES.stabilityPoolCollateralName() : _NAMES.stabilityPoolLeveragedName();
    }

    function poolSymbol(address, bool isCollateralPool) public view override returns (string memory) {
        return isCollateralPool ? _NAMES.stabilityPoolCollateralSymbol() : _NAMES.stabilityPoolLeveragedSymbol();
    }
}

/// @notice The lineage in THIS TREE: `Minter_v3` (or a candidate derived from it) beside `StabilityPool_v3`.
contract MarketReaderV3Lineage is MarketReader {
    function lineage() public pure override returns (string memory) {
        return "v3";
    }

    function poolName(address pool, bool) public view override returns (string memory) {
        return IERC20Metadata(pool).name();
    }

    function poolSymbol(address pool, bool) public view override returns (string memory) {
        return IERC20Metadata(pool).symbol();
    }
}
