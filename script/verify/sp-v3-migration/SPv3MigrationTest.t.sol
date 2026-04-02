// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ForceMigrateAccumulator_v1} from "script/verify/sp-v3-migration/ForceMigrateAccumulator_v1.sol";
import {StabilityPool_v3} from "src/minter/StabilityPool_v3.sol";
import {console2 as console} from "forge-std/console2.sol";

/// @title SPv3MigrationTest
/// @notice Mainnet fork test that validates the full migration lifecycle:
///         snapshot → upgrade to ForceMigrateAccumulator_v1 → remediate → upgrade to StabilityPool_v3
///         Verifies all user-visible values are preserved and post-migration operations work.
///
/// Run: forge test --mc SPv3MigrationTest --fork-url mainnet -vv
contract SPv3MigrationTest is BaoTest, HarborFactoryDeployer {
    // ── Addresses ───────────────────────────────────────────────────────────

    address spc; // collateral stability pool (ETH::fxUSD)
    address minter;
    address wrappedCollateral;
    address peg;
    address proxyOwner;

    // ── Per-holder snapshot ─────────────────────────────────────────────────

    struct HolderState {
        address holder;
        uint256 balance;
        uint256 claimableCollateral;
        uint256 claimedCollateral;
    }

    HolderState[] pre;

    // ── Holders for ETH::fxUSD::stabilityPoolCollateral ─────────────────────
    // Source: Etherscan tokentx API query (doc/migration-sp-v3-holders.md)

    function _holders() internal pure returns (address[] memory h) {
        h = new address[](24);
        h[0] = 0x13F210c8bAf5f5DBAFf3E917E2e5A49E73BBAF12;
        h[1] = 0x1a9152528AEFbcD9E5df4E0770f4F510e7056913;
        h[2] = 0x31632636D664895f1BD9D03f5F7c162A2A6980EB;
        h[3] = 0x3dFc49e5112005179Da613BdE5973229082dAc35;
        h[4] = 0x4382916A88b6EEd40530ef47deD0D402563dDACa;
        h[5] = 0x4dAf8ce9D729ca4F121381ec4B22123627C1C004;
        h[6] = 0x50b3Bf1B3119afc37A25c841c06C1BDD05Da1Fab;
        h[7] = 0x742fC5146d7Ff18291E3B7499811AD87015Fc7E4;
        h[8] = 0x7F14A89F5333A334C0EA3B5AAA7Dc2c8E1C72de6;
        h[9] = 0x81253f3Fc43D5e399610beE4D7a235826A7663b8;
        h[10] = 0x8b7698945dBCedF33F5e8d9E62B1Af8101318575;
        h[11] = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
        h[12] = 0x9db1D99D1C79A3A2C0123fcd0abB13d9B7c75657;
        h[13] = 0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e;
        h[14] = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;
        h[15] = 0xbA26035B9CD76cdA5b767A966b8A3392E476Fc0F;
        h[16] = 0xc16A44D0759ec03c677E97eF020a2345d4dC27Fb;
        h[17] = 0xDC1330EF8dc913C39bd29F9523418eEEacEf03D6;
        h[18] = 0xdd9c0BB1102D45357bEC81BbdffBb615D64C0ff9;
        h[19] = 0xE39165aDE355988EFb24dA4f2403971101134CAB;
        h[20] = 0xeEbF37253066532aFeB3FAcb4F2a411703353A83;
        h[21] = 0xef5E7606769400DC667DDC520C911D84405e61b7;
        h[22] = 0xF7e64540f42094497E2De0F06232992b03942898;
        h[23] = 0xf7e9CAaaEEb6cC9657E1Dd490F044114AecC31B2;
    }

    // ── Setup ───────────────────────────────────────────────────────────────

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        _setSaltPrefix("harbor_v1");
        spc = _predictAddress(_key("ETH", "fxUSD", "stabilityPoolCollateral"));
        minter = _predictAddress(_key("ETH", "fxUSD", "minter"));
        peg = _predictAddress(_key("ETH", "pegged"));
        wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();
        proxyOwner = IBaoOwnable(spc).owner();

        _snapshotAll();
        _runMigration();
    }

    function _snapshotAll() internal {
        address[] memory holders = _holders();
        for (uint256 i = 0; i < holders.length; i++) {
            pre.push(
                HolderState({
                    holder: holders[i],
                    balance: IStabilityPool(spc).assetBalanceOf(holders[i]),
                    claimableCollateral: IMultipleRewardAccumulator(spc).claimable(holders[i], wrappedCollateral),
                    claimedCollateral: IMultipleRewardAccumulator(spc).claimed(holders[i], wrappedCollateral)
                })
            );
        }
    }

    function _runMigration() internal {
        // Capture reward tokens BEFORE upgrading (pauser fallback reverts all other calls)
        address[] memory tokens = IMultipleRewardDistributor(spc).activeRewardTokens();
        address[] memory holders = _holders();

        // 1. Upgrade to migration contract
        vm.prank(proxyOwner);
        UUPSUpgradeable(spc).upgradeToAndCall(address(new ForceMigrateAccumulator_v1()), "");

        ForceMigrateAccumulator_v1 mig = ForceMigrateAccumulator_v1(spc);

        // 2. Snapshot pre-remediation balances
        uint256[][] memory preOld = new uint256[][](holders.length);
        uint256[][] memory preNew = new uint256[][](holders.length);
        for (uint256 i = 0; i < holders.length; i++) {
            preOld[i] = new uint256[](tokens.length);
            preNew[i] = new uint256[](tokens.length);
            for (uint256 j = 0; j < tokens.length; j++) {
                (preOld[i][j], preNew[i][j]) = mig.balances(holders[i], tokens[j]);
            }
        }

        // 3. Remediate: copy V1 → V2 for all holders
        vm.prank(proxyOwner);
        mig.remediate(tokens, holders);

        // 4. Verify post-remediation for each case
        for (uint256 i = 0; i < holders.length; i++) {
            for (uint256 j = 0; j < tokens.length; j++) {
                (uint256 postOld, uint256 postNew) = mig.balances(holders[i], tokens[j]);
                string memory label = string.concat(vm.toString(holders[i]), " token ", vm.toString(j));

                // old slot is never modified by remediate
                assertEq(postOld, preOld[i][j], string.concat("old unchanged: ", label));

                if (preNew[i][j] != 0) {
                    // already migrated: new unchanged (remediate skipped this user)
                    assertEq(postNew, preNew[i][j], string.concat("already migrated, new unchanged: ", label));
                } else if (preOld[i][j] != 0) {
                    // was unmigrated: new == old (remediate copied)
                    assertEq(postNew, preOld[i][j], string.concat("migrated, new == old: ", label));
                } else {
                    // no data: both still zero
                    assertEq(postNew, 0, string.concat("no data, new still 0: ", label));
                }
            }
        }

        // 5. Upgrade to v3
        vm.prank(proxyOwner);
        UUPSUpgradeable(spc).upgradeToAndCall(
            address(
                new StabilityPool_v3(
                    minter,
                    wrappedCollateral,
                    3600,
                    90000,
                    1 ether,
                    "Harbor SP: haETH-fxUSD collateral",
                    "spETH-FXUSD-C"
                )
            ),
            ""
        );
    }

    // ── Tests: State Preservation ───────────────────────────────────────────

    function test_balancesPreserved() public view {
        for (uint256 i = 0; i < pre.length; i++) {
            assertEq(
                IStabilityPool(spc).assetBalanceOf(pre[i].holder),
                pre[i].balance,
                string.concat("balance: ", vm.toString(pre[i].holder))
            );
        }
    }

    function test_claimablePreserved() public view {
        for (uint256 i = 0; i < pre.length; i++) {
            assertEq(
                IMultipleRewardAccumulator(spc).claimable(pre[i].holder, wrappedCollateral),
                pre[i].claimableCollateral,
                string.concat("claimable: ", vm.toString(pre[i].holder))
            );
        }
    }

    function test_claimedPreserved() public view {
        for (uint256 i = 0; i < pre.length; i++) {
            assertEq(
                IMultipleRewardAccumulator(spc).claimed(pre[i].holder, wrappedCollateral),
                pre[i].claimedCollateral,
                string.concat("claimed: ", vm.toString(pre[i].holder))
            );
        }
    }

    function test_totalSupplyPreserved() public view {
        uint256 total = 0;
        for (uint256 i = 0; i < pre.length; i++) {
            total += pre[i].balance;
        }
        assertApproxEqAbs(IStabilityPool(spc).totalAssetSupply(), total, pre.length, "totalSupply ~ sum of balances");
    }

    // ── Tests: Post-Migration Operations ────────────────────────────────────

    function test_deposit() public {
        address newUser = makeAddr("newUser");
        uint256 amount = 1 ether;
        deal(peg, newUser, amount);
        vm.startPrank(newUser);
        IERC20(peg).approve(spc, amount);
        IStabilityPool(spc).deposit(amount, newUser, 0);
        vm.stopPrank();
        assertEq(IStabilityPool(spc).assetBalanceOf(newUser), amount, "deposit works on v3");
    }

    function test_claim() public {
        for (uint256 i = 0; i < pre.length; i++) {
            if (pre[i].claimableCollateral == 0) continue;
            uint256 balBefore = IERC20(wrappedCollateral).balanceOf(pre[i].holder);
            vm.prank(pre[i].holder);
            IMultipleRewardAccumulator(spc).claim();
            uint256 received = IERC20(wrappedCollateral).balanceOf(pre[i].holder) - balBefore;
            assertEq(received, pre[i].claimableCollateral, string.concat("claim: ", vm.toString(pre[i].holder)));
            break; // test one holder
        }
    }

    function test_transfer() public {
        // Find a holder with balance
        for (uint256 i = 0; i < pre.length; i++) {
            if (pre[i].balance == 0) continue;
            address from = pre[i].holder;
            address to = makeAddr("recipient");
            uint256 amount = pre[i].balance / 10;

            vm.prank(from);
            StabilityPool_v3(spc).transfer(to, amount);

            assertEq(StabilityPool_v3(spc).balanceOf(to), amount, "recipient balance");
            assertEq(StabilityPool_v3(spc).balanceOf(from), pre[i].balance - amount, "sender balance");
            break;
        }
    }

    function test_erc20Metadata() public view {
        StabilityPool_v3 sp3 = StabilityPool_v3(spc);
        assertEq(bytes(sp3.name()).length > 0, true, "name not empty");
        assertEq(bytes(sp3.symbol()).length > 0, true, "symbol not empty");
        assertEq(sp3.decimals(), 18, "decimals");
        console.log("  name:    %s", sp3.name());
        console.log("  symbol:  %s", sp3.symbol());
    }
}
