// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";

import {Minter_v2} from "@harbor/minter/Minter_v2.sol";
import {Minter_v3} from "@harbor/minter/Minter_v3.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice Upgrading a Minter from v2 to v3 works, and preserves everything the contract exposes.
/// @dev The PENDING upgrade: mainnet runs `Minter_v2` and `Minter_v3` is this repo's source, so this is the
///      step about to be performed rather than one already made. A v1→v2 test would only re-confirm history.
///
///      Reproducible by construction, which is what puts it in `test/`: the v2 minter is a fixture built
///      here, not real forked state. That is the correct input for proving upgrade MECHANICS — that the
///      proxy accepts the new implementation, that ownership and storage survive it, and that the contract
///      still works afterwards. Verifying the real upgrade SCRIPT against live data is `script/verify/`'s job.
contract MinterV2ToV3UpgradeTest is TestMinterSetUp {
    function setUp() public override {
        super.setUp();

        // The deploy above stands up a v3 minter. This suite upgrades FROM v2, so replace it with one — and
        // re-do the wiring the deploy did for an address that is no longer the minter under test.
        // `Minter_v2` is BaoOwnable: `initialize` names the FINAL owner and leaves the deployer holding it
        // temporarily, so the configuration below runs as this contract and `transferOwnership` completes the
        // handover at the end. Naming this contract here instead leaves nothing to transfer to.
        minter = UnsafeUpgrades.deployUUPSProxy(
            address(new Minter_v2(wrappedCollateralToken, peggedToken, leveragedToken, "burn(uint256)")),
            abi.encodeCall(Minter_v2.initialize, (owner()))
        );
        vm.label(minter, "minter(v2)");

        IMinter(minter).updateConfig(marketConfig.minterConfig());
        IMinter(minter).updateReservePool(reservePool);
        IMinter(minter).updateFeeReceiver(treasury());
        IMinter(minter).updatePriceOracle(priceOracle);

        zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        IBaoRoles(minter).grantRoles(zeroFee, zeroFeeRole);

        // The tokens grant mint/burn to the minter's address, and this is a different one.
        vm.startPrank(owner());
        IBaoRoles(leveragedToken).grantRoles(minter, minterRole | burnerRole);
        IBaoRoles(peggedToken).grantRoles(
            minter,
            IMintableRole(peggedToken).MINTER_ROLE() | IBurnableRole(peggedToken).BURNER_ROLE()
        );
        IBaoRoles(reservePool).grantRoles(minter, requesterRole);
        vm.stopPrank();

        IBaoOwnable(minter).transferOwnership(owner());
    }

    /// @dev The upgrade itself: a plain implementation swap. `Minter_v3.initialize` is `initializer` and the
    ///      proxy has already consumed that slot as v2, so there is no re-initialisation step — which is
    ///      precisely why the storage layouts have to line up on their own.
    function _upgradeToV3() private {
        address implementation = address(new Minter_v3(wrappedCollateralToken, peggedToken, leveragedToken));

        vm.startPrank(owner());
        UUPSUpgradeable(minter).upgradeToAndCall(implementation, "");
        vm.stopPrank();
    }

    /// @dev Everything the minter exposes that the upgrade must not disturb.
    struct MinterState {
        uint256 peggedTokenBalance;
        uint256 collateralTokenBalance;
        uint256 collateralRatio;
        uint256 leverageRatio;
        uint256 peggedTokenPrice;
        uint256 leveragedTokenPrice;
        address feeReceiver;
        address owner;
        bytes config;
    }

    function _readMinterState() private view returns (MinterState memory state) {
        state.peggedTokenBalance = IMinter(minter).peggedTokenBalance();
        state.collateralTokenBalance = IMinter(minter).collateralTokenBalance();
        state.collateralRatio = IMinter(minter).collateralRatio();
        state.leverageRatio = IMinter(minter).leverageRatio();
        state.peggedTokenPrice = IMinter(minter).peggedTokenPrice();
        state.leveragedTokenPrice = IMinter(minter).leveragedTokenPrice();
        state.feeReceiver = IMinter(minter).feeReceiver();
        state.owner = IBaoOwnable(minter).owner();
        // Encoded whole rather than field by field: the config nests dynamic arrays, and comparing the
        // encoding covers every one of them without a comparator that can fall behind the struct.
        state.config = abi.encode(IMinter(minter).config());
    }

    function _assertPreserved(MinterState memory before, string memory what) private view {
        MinterState memory afterUpgrade = _readMinterState();

        assertEq(afterUpgrade.peggedTokenBalance, before.peggedTokenBalance, string.concat(what, ": pegged"));
        assertEq(
            afterUpgrade.collateralTokenBalance,
            before.collateralTokenBalance,
            string.concat(what, ": collateral")
        );
        assertEq(afterUpgrade.collateralRatio, before.collateralRatio, string.concat(what, ": collateral ratio"));
        assertEq(afterUpgrade.leverageRatio, before.leverageRatio, string.concat(what, ": leverage ratio"));
        assertEq(afterUpgrade.peggedTokenPrice, before.peggedTokenPrice, string.concat(what, ": pegged price"));
        assertEq(
            afterUpgrade.leveragedTokenPrice,
            before.leveragedTokenPrice,
            string.concat(what, ": leveraged price")
        );
        assertEq(afterUpgrade.feeReceiver, before.feeReceiver, string.concat(what, ": fee receiver"));
        assertEq(afterUpgrade.owner, before.owner, string.concat(what, ": owner"));
        assertEq(afterUpgrade.config, before.config, string.concat(what, ": config"));
    }

    /// The fixture really is a v2 before the upgrade, and really is not afterwards. Without this the whole
    /// file could pass vacuously: an upgrade that silently did nothing leaves every comparison trivially equal.
    function test_theUpgradeActuallyReplacesTheImplementation() public {
        bytes32 implementationSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address before = address(uint160(uint256(vm.load(minter, implementationSlot))));

        _upgradeToV3();

        address afterUpgrade = address(uint160(uint256(vm.load(minter, implementationSlot))));
        assertNotEq(afterUpgrade, before, "the proxy points at a different implementation");
        assertGt(afterUpgrade.code.length, 0, "and that implementation exists");
    }

    /// An untouched minter upgrades cleanly and is usable afterwards.
    function test_upgradeFromV2_freshMinter() public {
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "no pegged before upgrade");
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "no collateral before upgrade");

        MinterState memory before = _readMinterState();
        _upgradeToV3();
        _assertPreserved(before, "fresh");

        setUp_collateral(1 ether, 0);
        assertGt(IMinter(minter).peggedTokenBalance(), 0, "minting works after the upgrade");
    }

    /// A minter holding both token positions keeps every balance and derived price across the upgrade.
    function test_upgradeFromV2_afterMint() public {
        setUp_collateral(5 ether, 5 ether);

        MinterState memory before = _readMinterState();
        _upgradeToV3();
        _assertPreserved(before, "after mint");

        setUp_collateral(1 ether, 1 ether);
        assertGt(IMinter(minter).peggedTokenBalance(), before.peggedTokenBalance, "more can be minted after");
    }

    /// A partially redeemed position survives too - the path that has written to storage twice.
    function test_upgradeFromV2_afterRedeem() public {
        setUp_collateral(5 ether, 5 ether);

        uint256 toRedeem = IERC20(peggedToken).balanceOf(zeroFee) / 4;
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, toRedeem);
        IMinter(minter).freeRedeemPeggedToken(toRedeem, 0, zeroFee);
        vm.stopPrank();

        MinterState memory before = _readMinterState();
        _upgradeToV3();
        _assertPreserved(before, "after redeem");

        uint256 more = IERC20(peggedToken).balanceOf(zeroFee) / 4;
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, more);
        IMinter(minter).freeRedeemPeggedToken(more, 0, zeroFee);
        vm.stopPrank();
        assertLt(IMinter(minter).peggedTokenBalance(), before.peggedTokenBalance, "redeeming works after");
    }

    /// The incentive config - the one piece of state that nests dynamic arrays - survives, and can still be
    /// changed afterwards, which is the operation `UpdateVolatility_*.s.sol` performs in production.
    function test_upgradeFromV2_configSurvivesAndRemainsSettable() public {
        setUp_config_free();
        vm.startPrank(owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();

        MinterState memory before = _readMinterState();
        _upgradeToV3();
        _assertPreserved(before, "config");

        setUp_config_flat();
        vm.startPrank(owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();
        _assertEqConfig(IMinter(minter).config(), config);
    }

    /// Mint, redeem across both token types, then upgrade - the state a live market would actually be in.
    function test_upgradeFromV2_mixedOperations() public {
        setUp_collateral(5 ether, 5 ether);

        uint256 toRedeem = IERC20(leveragedToken).balanceOf(zeroFee) / 3;
        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, toRedeem);
        IMinter(minter).freeRedeemLeveragedToken(toRedeem, zeroFee);
        vm.stopPrank();

        MinterState memory before = _readMinterState();
        _upgradeToV3();
        _assertPreserved(before, "mixed");
    }
}
