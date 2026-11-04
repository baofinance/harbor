// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {btcMintersConfig} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {ethMintersConfig} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {eurMintersConfig} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {goldMintersConfig} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {mcapMintersConfig} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {silverMintersConfig} from "@harbor-script/src/Deploy_SILVER_Minter.sol";
import {usdMintersConfig} from "@harbor-script/src/Deploy_USD_Minter.sol";
import {Pauser, pausers} from "@harbor-script/src/Pausers.sol";

/// @notice Every peg production configures, each with its markets, from each peg's own list: fresh config contracts on
///         each call.
function allPegsConfig() returns (ConfigPeg[7] memory pegs, Config_MinterMarket[][7] memory marketsByPeg) {
    (pegs[0], marketsByPeg[0]) = btcMintersConfig();
    (pegs[1], marketsByPeg[1]) = ethMintersConfig();
    (pegs[2], marketsByPeg[2]) = eurMintersConfig();
    (pegs[3], marketsByPeg[3]) = goldMintersConfig();
    (pegs[4], marketsByPeg[4]) = mcapMintersConfig();
    (pegs[5], marketsByPeg[5]) = silverMintersConfig();
    (pegs[6], marketsByPeg[6]) = usdMintersConfig();
}

/// @notice Every market production configures, peg by peg: fresh config contracts on each call.
function allMintersConfig() returns (Config_MinterMarket[] memory markets) {
    (, Config_MinterMarket[][7] memory byPeg) = allPegsConfig();
    uint256 count;
    for (uint256 peg = 0; peg < byPeg.length; ++peg) {
        count += byPeg[peg].length;
    }
    markets = new Config_MinterMarket[](count);
    count = 0;
    for (uint256 peg = 0; peg < byPeg.length; ++peg) {
        for (uint256 i = 0; i < byPeg[peg].length; ++i) {
            markets[count++] = byPeg[peg][i];
        }
    }
}

/// @notice Whether the market of `minter` upgrades to v3 from a frozen read: whether the proxy runs a pauser on the fork
///         selected, one of those bao-base's deployment state for `network` records (`pausers`). A pause upgrades a
///         market's minter and pools to a pauser, which answers nothing, so what the upgrade needs from a frozen market
///         is read at the last block before the pause.
function isFrozen(address minter, string memory network) view returns (bool) {
    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address implementation = address(uint160(uint256(vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT))));
    Pauser[] memory list = pausers(network);
    for (uint256 i = 0; i < list.length; ++i) {
        if (list[i].implementation == implementation) {
            return true;
        }
    }
    return false;
}

/// @notice The peg production configures under `name`, with its markets: fresh config contracts on each call.
/// @dev Reverts if no peg has that name.
function pegNamed(string memory name) returns (ConfigPeg, Config_MinterMarket[] memory) {
    (ConfigPeg[7] memory pegs, Config_MinterMarket[][7] memory marketsByPeg) = allPegsConfig();
    for (uint256 i = 0; i < pegs.length; ++i) {
        if (LibString.eq(pegs[i].key(), name)) {
            return (pegs[i], marketsByPeg[i]);
        }
    }
    revert(string.concat("Peg not found: ", name));
}

/// @notice The markets a peg and a collateral name, as a deploy's `--peg` and `--collateral` name them: `*` for every
///         market of the peg, or one collateral's name. Naming no collateral is refused, where a deploy's filter gives
///         no markets: an upgrade has nothing else to do.
function marketsNamed(string memory peg, string memory collateral) returns (Config_MinterMarket[] memory) {
    if (bytes(collateral).length == 0) {
        revert(string.concat("No collateral named for peg: ", peg));
    }
    (, Config_MinterMarket[] memory markets) = pegNamed(peg);
    return MinterMarketConfigLib.parseCollateralFilter(markets, collateral);
}

/// @notice The markets an upgrade run names, in `UPGRADE_PEG` and `UPGRADE_COLLATERAL`: `script/upgrade` and the
///         rehearsal set them, so the script and every test of a run read the same names. Either unset is refused,
///         naming it.
/// @dev The environment, because `Deployer.run(string)` calls `build()` with no arguments and a test takes none.
function marketsToUpgrade() returns (Config_MinterMarket[] memory) {
    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    return marketsNamed(vm.envString("UPGRADE_PEG"), vm.envString("UPGRADE_COLLATERAL"));
}
