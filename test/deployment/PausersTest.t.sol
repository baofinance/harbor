// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {allMintersConfig, isFrozen} from "@harbor-script/src/AllMintersConfig.sol";
import {Pauser, PauserNotDeployed, pauserNamed, pausers} from "@harbor-script/src/Pausers.sol";
import {FROZEN_MARKETS_CAPTURE} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";

/// @notice The pausers bao-base has deployed, read from its deployment state, and what makes a market frozen: its minter
///         running one of them.
contract PausersTest is Test {
    function pauserNamedFromOutside(string memory network, string memory contractType) external view returns (address) {
        return pauserNamed(network, contractType);
    }

    /// bao-base's mainnet deployment state records the pauser that paused the markets, BaoPauser_v1, and `pausers` lists
    /// it and nothing that is not a pauser.
    function test_pausers_listsEveryPauserBaoBaseDeployed() public view {
        Pauser[] memory list = pausers("mainnet");
        assertGt(list.length, 0, "at least one pauser");
        bool hasBaoPauser;
        for (uint256 i = 0; i < list.length; ++i) {
            assertTrue(
                LibString.indexOf(list[i].contractType, "Pauser_v") != LibString.NOT_FOUND,
                string.concat(list[i].contractType, ": a pauser, by name")
            );
            assertNotEq(list[i].implementation, address(0), string.concat(list[i].contractType, ": at an address"));
            hasBaoPauser = hasBaoPauser || LibString.eq(list[i].contractType, "BaoPauser_v1");
        }
        assertTrue(hasBaoPauser, "BaoPauser_v1, which paused the markets");
    }

    /// A pauser the state does not record is refused by name, with its network.
    function test_pauserNamed_refusesAPauserNotDeployed() public {
        vm.expectRevert(abi.encodeWithSelector(PauserNotDeployed.selector, "mainnet", "NoSuchPauser_v1"));
        this.pauserNamedFromOutside("mainnet", "NoSuchPauser_v1");
    }

    /// At the block after the capture's, where the pause took effect, every market of the six paused pegs reads frozen,
    /// its minter running BaoPauser_v1, and no USD market does: eleven markets, as the pause's Safe batch named them.
    function test_isFrozen_readsThePauserOnTheElevenAndNotUSD() public {
        vm.createSelectFork("mainnet", HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE) + 1);
        HarborDeployRun live = new HarborDeployRun(
            address(0),
            address(0),
            "harbor_v1",
            "mainnet",
            HarborDeployRun.Cut.Whole
        );
        address baoPauser = pauserNamed("mainnet", "BaoPauser_v1");
        Config_MinterMarket[] memory markets = allMintersConfig();
        uint256 frozen;
        for (uint256 i = 0; i < markets.length; ++i) {
            string memory market = MinterMarketConfigLib.salt(markets[i]);
            address minter = live.minterAddress(markets[i]);
            bool isUSD = LibString.eq(MinterMarketConfigLib.peg(markets[i]), "USD");
            address runs = address(uint160(uint256(vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT))));
            assertEq(runs == baoPauser, !isUSD, string.concat(market, ": its minter runs BaoPauser_v1"));
            assertEq(isFrozen(minter, "mainnet"), !isUSD, string.concat(market, ": frozen"));
            frozen += isUSD ? 0 : 1;
        }
        assertEq(frozen, 11, "the markets the pause froze");
    }
}
