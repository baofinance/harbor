// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;
import "forge-std/Test.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";

contract HistoricalTokensProbe is Test {
    uint256 constant FORK_BLOCK = 25272609; // preflight's CAPTURE_BLOCK
    string constant STATE = "deployments/mainnet/harbor_v1.state.json";

    function test_countHistoricalTokensAcrossAllPools() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        string memory s = vm.readFile(STATE);
        string[] memory keys = vm.parseJsonKeys(s, ".proxies");
        uint256 pools;
        uint256 totalHistorical;
        for (uint256 i = 0; i < keys.length; ++i) {
            bytes memory k = bytes(keys[i]);
            // match ::stabilityPoolCollateral or ::stabilityPoolLeveraged (both end in "Pool" + type)
            if (!_isSp(keys[i])) continue;
            address pool = vm.parseJsonAddress(s, string.concat(".proxies['", keys[i], "'].address"));
            uint256 h = IMultipleRewardDistributor(pool).historicalRewardTokens().length;
            uint256 a = IMultipleRewardDistributor(pool).activeRewardTokens().length;
            if (h > 0) {
                console2.log("HISTORICAL>0: %s active=%s historical=%s", keys[i], a, h);
            }
            totalHistorical += h;
            ++pools;
        }
        console2.log("pools=%s totalHistoricalTokens=%s", pools, totalHistorical);
        assertEq(pools, 22, "expected 22 pools");
    }
    function _isSp(string memory key) internal pure returns (bool) {
        return _ends(key, "::stabilityPoolCollateral") || _ends(key, "::stabilityPoolLeveraged");
    }
    function _ends(string memory v, string memory suf) internal pure returns (bool) {
        bytes memory vb = bytes(v);
        bytes memory sb = bytes(suf);
        if (vb.length < sb.length) return false;
        uint256 off = vb.length - sb.length;
        for (uint256 i = 0; i < sb.length; ++i) if (vb[off + i] != sb[i]) return false;
        return true;
    }
}
