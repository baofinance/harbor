// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {MarketActions} from "@harbor-test/harness/MarketActions.sol";
import {MarketAddresses} from "@harbor-test/harness/MarketAddresses.sol";
import {MarketReader} from "@harbor-test/harness/MarketReader.sol";
import {MarketRule, TreeRule} from "@harbor-test/harness/MarketRule.sol";

/// @notice A market a measurement can be run against, however it was stood up.
///
/// Graph generators kept re-deriving the same three steps - stand a market up, put a rule behind the minter,
/// measure it - and kept getting them slightly differently. Two bugs came out of that in a single session,
/// both silent. This is the seam those three steps live behind, so that a measurement holds only its own
/// loop and a run is `measurement + market + overrides`.
///
/// WHAT VARIES, and it is the whole reason this exists: where the market comes from (the local deploy chain,
/// or the DEPLOYED proxies on a pinned fork), what sits behind each proxy, which config it carries, and what
/// it is funded with. WHAT DOES NOT: the measurement loop, the columns, the file naming. One axis of
/// variation per run against a fixed measurement is the thing being bought.
abstract contract MarketUnderTest {
    // The well-known forge cheatcode address, referenced directly rather than inherited from a Test base so
    // this stays a mixin a market can be composed from.
    Vm private constant _vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @dev Everything a measurement needs to drive a market, gathered once by whoever stood it up.
    MarketAddresses internal market;

    /// @dev How to ASK this market its questions - see `MarketReader`. Chosen once, where the market is stood
    /// up and where what sits behind each proxy is decided, so it cannot disagree with the market it reads.
    MarketReader internal reader;

    /// @dev How to ACT on this market - see `MarketActions`. Set where the market is stood up, once its minter is
    /// known, so every measurement acts on the market through the one implementation. It places the market by a
    /// derived price, not by repeated steps towards one, because a sequence has to start somewhere exact for its rows
    /// to line up with another market's.
    MarketActions internal actions;

    /// @dev Stand the market up and fund its INITIAL CONDITIONS - the starting state every measurement is
    /// entitled to assume, so that two measurements of the same market are comparing the same thing. Funding
    /// BETWEEN steps belongs to the measurement instead: a sequence that tops a pool up mid-run is measuring
    /// something different from one that does not, and only the measurement knows which it means.
    ///
    /// THE SPLIT IS A PARAMETER RATHER THAN A HOOK, and that is deliberate. It is data flowing from the
    /// measurement into the market: the measurement is what decides how the genesis pegged is divided,
    /// because the division is part of what it means to measure. Declared as a virtual on this base it would
    /// sit on BOTH inheritance paths of every `measurement + market` run, so each leaf would have to override
    /// it purely to disambiguate - writing out a constant its siblings already write, saying nothing. Passed
    /// as an argument it is stated once, at the call site that chose it.
    ///
    /// @param collateralPoolShare Share of the genesis pegged deposited into the collateral stability pool,
    /// as a 1e18 fraction.
    /// @param leveragedPoolShare Share of the genesis pegged deposited into the leveraged stability pool, as
    /// a 1e18 fraction. The two need not sum to one: what is left over stays with the harness, an ordinary
    /// holder alongside the pools, which is what lets a conversion dilute the converter.
    /// @param runName What this run's files are called - the measurement's `context()`, which only it knows.
    /// The market records its provenance under it, so a run's provenance sits beside its data under the same
    /// name and no two runs write one file.
    function standUpMarket(
        uint256 collateralPoolShare,
        uint256 leveragedPoolShare,
        string memory runName
    ) internal virtual returns (MarketAddresses memory);

    /// @dev The ERC-1967 implementation slot, `keccak256("eip1967.proxy.implementation") - 1`.
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Writes down what is ACTUALLY behind every proxy in this market, so a run states its own
    /// provenance and a reader never has to take the harness's word for it.
    ///
    /// This exists because a market was measured for a week with the wrong implementations behind two of its
    /// proxies, and that was discovered only because one old contract happened to LACK a function the new one
    /// calls. Had the selector been present with a different meaning, the market would have produced numbers
    /// and they would have been plotted. Nothing else here distinguishes the market that was meant from one
    /// that merely ran.
    ///
    /// Each is recorded by WHAT IT IS - see `_whatAnswersAt` - and not by where it sits or what it hashes to,
    /// so the file changes when what a market is built from changes and at no other time. An implementation
    /// swapped on chain, a mock silently substituted by an inherited setup - each shows up as a row that does
    /// not match the last run's, in a file beside the data it produced. An address moved by a change to the
    /// test that deployed it, or the same source compiled with other settings, does not.
    ///
    /// Addresses that are not proxies say so, which is the honest answer for the etched oracle mock and for
    /// any token that was never behind one.
    function _recordMarketProvenance(string memory runName) internal {
        // Accumulated a row at a time rather than in one `string.concat`: eight rows and a header in a single
        // call puts more than the EVM's reachable stack depth in flight and the compiler refuses it.
        string memory out = string.concat("lineage,", reader.lineage(), ",\n");
        out = string.concat(out, "contract,code at the address,implementation\n");
        out = string.concat(out, _provenanceRow("minter", market.minter));
        out = string.concat(out, _provenanceRow("manager", market.manager));
        out = string.concat(out, _provenanceRow("collateralPool", market.collateralPool));
        out = string.concat(out, _provenanceRow("leveragedPool", market.leveragedPool));
        out = string.concat(out, _provenanceRow("pegged", market.pegged));
        out = string.concat(out, _provenanceRow("leveraged", market.leveraged));
        out = string.concat(out, _provenanceRow("wrappedCollateral", market.wrappedCollateral));
        out = string.concat(out, _provenanceRow("oracle", market.oracle));
        _vm.writeFile(string.concat("results/provenance", runName, ".csv"), out);
    }

    /// @dev BOTH the code at the address and the code behind it, and the first is not redundant. `vm.etch`
    /// replaces an address's CODE and leaves its storage, so an etched proxy still points at whatever
    /// implementation it held before - and a record that read only the slot would name the deployed contract
    /// while a mock was answering every call. The etched oracle is precisely that case. A genuine proxy is
    /// recorded as a proxy, so a row whose first column names anything else has been replaced, whatever its
    /// implementation pointer says.
    function _provenanceRow(string memory name, address proxy) private view returns (string memory) {
        address implementation = address(uint160(uint256(_vm.load(proxy, _IMPLEMENTATION_SLOT))));
        return
            string.concat(
                name,
                ",",
                _whatAnswersAt(proxy),
                ",",
                implementation == address(0) ? "(not-a-proxy)" : _whatAnswersAt(implementation),
                "\n"
            );
    }

    /// @dev The NAME of the contract whose code is at `target` when this tree built it, and the ADDRESS when it
    /// did not. Forge is asked which of the build's artifacts the code came from, which it can say for a
    /// contract with immutables or linked libraries and for a mock beside the contract it inherits from.
    ///
    /// Both halves are stable, which is the point. A name does not move when a test changes the address a
    /// contract is created at, nor when a build - the coverage run compiles with the optimizer off - turns the
    /// same source into different bytecode. Code no artifact matches was on chain at the pinned block, and
    /// there the block pins the address and the address pins the code.
    function _whatAnswersAt(address target) private view returns (string memory) {
        try _vm.getArtifactPathByDeployedCode(target.code) returns (string memory artifactPath) {
            // Forge answers with the artifact's file, `<out>/<source file>/<contract>.json`, under a root that
            // differs by machine and an output directory that differs by pass. The contract is its last part.
            string[] memory parts = _vm.split(artifactPath, "/");
            return _vm.replace(parts[parts.length - 1], ".json", "");
        } catch (bytes memory err) {
            if (
                keccak256(err) !=
                keccak256(
                    abi.encodeWithSignature(
                        "CheatcodeError(string)",
                        "vm.getArtifactPathByDeployedCode: no matching artifact found"
                    )
                )
            ) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            return _vm.toString(target);
        }
    }

    /// @dev Rebalance, reporting whether THE RULE UNDER TEST reverted it.
    ///
    /// This is not the tolerance that was rejected earlier and must not be read as it. That one caught
    /// `NoTokensToLiquidate`, which is an EMPTY POOL - a defect in how the market was set up, and rightly
    /// fixed by setting it up properly rather than by catching the symptom. This catches exactly one thing,
    /// `BelowMinimumCollateralRatio`, which a rule throws BY DESIGN where it declines to mint leveraged. That revert
    /// is not a failure of the measurement; it is the single behaviour the rule exists to exhibit, and a
    /// measurement that crashed on it could not report the one thing it was run to see. Anything else
    /// propagates unchanged.
    function _rebalanceUnlessTheRuleReverts(address keeper) internal returns (bool rebalanced) {
        _vm.startPrank(keeper);
        try IStabilityPoolManager(market.manager).rebalance(keeper, 0) {
            rebalanced = true;
        } catch (bytes memory err) {
            if (bytes4(err) != IMinter_v3.BelowMinimumCollateralRatio.selector) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
        }
        _vm.stopPrank();
    }

    /// @dev Is there a rebalance to perform? BOTH halves of the question: that the market wants one, and that
    /// a pool holds something to satisfy it with.
    ///
    /// `rebalanceable()` answers only the first - the ratio is above the peg and below the threshold - and knows
    /// nothing about the pools' balances. A loop taking it as the whole precondition eventually calls a
    /// rebalance with nothing to convert, which the DEPLOYED manager reports by reverting
    /// `NoTokensToLiquidate`. So the missing half of the predicate arrived as a crash, and the fix is to ask
    /// the whole question rather than to tolerate the answer.
    function _canRebalance() internal view returns (bool) {
        if (!IStabilityPoolManager(market.manager).rebalanceable()) {
            return false;
        }
        return
            IERC20(market.pegged).balanceOf(market.collateralPool) +
                IERC20(market.pegged).balanceOf(market.leveragedPool) >
            0;
    }

    /// @dev Reverts on a split that leaves NOBODY holding pegged outside the stability pools. Called by every
    /// market's `standUpMarket` before it funds anything.
    ///
    /// This is not tidiness, it is the difference between a measurement and a blind one. Below the peg the
    /// pegged claim is the entire collateral, divided by holding - so a pool holding every pegged token
    /// claims the whole market no matter how much of its own pegged a conversion has burned. Its position
    /// cannot fall, every value-retained column reads as conserved, and the measurement says nothing. A
    /// sequence that ran twelve rounds against a sole holder reported a flat result for exactly this reason,
    /// and the same market with a remainder outside the pools lost 88% of the position in ONE round.
    ///
    /// The leveraged side needs no such check: the genesis leveraged is minted to the harness and the pools
    /// take only pegged, so a holder outside them exists by construction.
    function _requireHoldersOutsidePools(uint256 collateralPoolShare, uint256 leveragedPoolShare) internal pure {
        require(
            collateralPoolShare + leveragedPoolShare < 1 ether,
            "MarketUnderTest: pool shares leave no pegged held outside the pools"
        );
    }

    /// @dev Names this market in every file it writes, via `context()`.
    function marketLabel() internal pure virtual returns (string memory);

    // ─── the rule under test ───

    /// @dev WHICH RULE this market runs: what goes behind the minter, which manager the market gets, and the
    /// label its files carry - one object, so a rule with two halves is installed whole or not at all (see
    /// `MarketRule`). The tree's own rule unless a run's constructor says otherwise: set ONCE, there, in the
    /// one line a run needs to say what it is, and read everywhere after.
    ///
    /// A field rather than a virtual, and the reason is the diamond. A rule offered as a MIXIN beside the market
    /// defines the same functions the market's base does, and the compiler then demands an override in every run
    /// purely to say which - the meaningless override this harness exists to be rid of. A field has one definer,
    /// and a run's constructor is the one place its rule is named - through `useRule`, never by assignment.
    MarketRule internal ruleUnderTest;

    constructor() {
        useRule(new TreeRule());
    }

    /// @dev Install the rule this run measures. Called from a run's constructor, before any fork exists.
    ///
    /// The rule is made PERSISTENT because both markets fork mainnet - the local one in `setUp`, the deployed
    /// one in `standUpMarket` - and selecting a fork replaces every account the test has not marked persistent.
    /// A rule object left unmarked is code-less by the time its label is first read, and the whole run reverts
    /// on the first call into it.
    function useRule(MarketRule rule) internal {
        ruleUnderTest = rule;
        _vm.makePersistent(address(rule));
    }

    /// @dev Names the rule in every file this market writes, beside the market's own label. Empty for the tree.
    function overrideLabel() internal view returns (string memory) {
        return ruleUnderTest.label();
    }
}
