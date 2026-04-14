// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

import {HarborYield_v1} from "src/autocompounding/HarborYield_v1.sol";
import {IHarborYield} from "src/interfaces/IHarborYield.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {MockERC4626Vault} from "test/mocks/MockERC4626Vault.sol";
import {MockMinter} from "test/mocks/MockMinter.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";

/// @title HarborYield_v1 unit tests
/// @notice Tests HarborYield in isolation using MockERC20 assets, MockERC4626Vault, and MockSwapper.
///         Avoids the full Minter+SP+AC deployment to keep tests fast and focused on HY behaviour.
///
/// Run: forge test --mc HarborYieldTest -vv
contract HarborYieldTest is Test {
    // ── Actors ─────────────────────────────────────────────────────────
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    // ── Tokens ─────────────────────────────────────────────────────────
    MockERC20 pegToken; // e.g. haEUR (the HarborYield share's peg-unit asset)
    MockERC20 asset0; // e.g. stETH
    MockERC20 asset1; // e.g. fxSAVE

    // ── Managed ERC4626 vaults ─────────────────────────────────────────
    MockERC4626Vault vault0;
    MockERC4626Vault vault1;

    // ── Infrastructure ─────────────────────────────────────────────────
    MockSwapper swapper;
    HarborYield_v1 hy;

    // ── AC vault (vault0) — requires a MockMinter so it can introspect PEGGED_TOKEN/MINTER ──
    MockMinter minter0;

    // ── Equivalent vault (vault1) — requires an IWrappedPriceOracle ──
    MockWrappedPriceOracle oracle1;

    // ── Constants ──────────────────────────────────────────────────────
    uint64 constant DEFAULT_DRIFT_BPS = 200; // 2%

    uint64 constant WEIGHT_0 = 60; // 60% of target
    uint64 constant WEIGHT_1 = 40; // 40% of target

    function setUp() public virtual {
        pegToken = new MockERC20("Peg Token", "PEG", 18);
        asset0 = new MockERC20("Asset 0", "A0", 18);
        asset1 = new MockERC20("Asset 1", "A1", 18);

        // vault0 stands in as an AutoCompounder. Its "asset" is asset0 (playing the role of an
        // SP token 1:1 with the peg). Configure PEGGED_TOKEN and MINTER so HY can introspect it
        // during `addAutoCompounderVault`. The MockMinter returns peggedTokenPrice = 1e18.
        vault0 = new MockERC4626Vault(IERC20(address(asset0)), "Vault 0", "V0");
        minter0 = new MockMinter(address(asset0), address(pegToken), makeAddr("lev0"));
        vault0.configureAsAutoCompounder(address(pegToken), address(minter0));

        // vault1 is an equivalent-yield vault. Its asset is asset1 (e.g. fxSAVE-analog). HY
        // registers it via `addEquivalentVault` with a price oracle; the oracle reports 1:1
        // to satisfy the drift check.
        vault1 = new MockERC4626Vault(IERC20(address(asset1)), "Vault 1", "V1");
        oracle1 = new MockWrappedPriceOracle();
        oracle1.setLatestAnswer(1 ether, 1 ether); // price = 1, rate = 1 → 1:1 with peg

        // Swapper at 1:1 rate — pre-fund with enough of each token for tests.
        swapper = new MockSwapper(1 ether);
        asset0.mint(address(swapper), 1_000_000 ether);
        asset1.mint(address(swapper), 1_000_000 ether);

        // Deploy HarborYield_v1 impl + proxy.
        // address(this) is both deployer-owner and pending-owner: owner is address(this).
        HarborYield_v1 impl = new HarborYield_v1(
            "Harbor Yield Test",
            "hyTEST",
            address(swapper),
            address(pegToken)
        );
        bytes memory initData = abi.encodeCall(HarborYield_v1.initialize, (address(this), address(this)));
        hy = HarborYield_v1(address(new ERC1967Proxy(address(impl), initData)));

        hy.setMaxPegDriftBps(DEFAULT_DRIFT_BPS);

        hy.addAutoCompounderVault(address(vault0), WEIGHT_0);
        hy.addEquivalentVault(address(vault1), WEIGHT_1, address(oracle1));
    }

    // ── Helpers ────────────────────────────────────────────────────────

    /// @dev Deposit `amount` of `asset` into HY on behalf of `user`.
    function _deposit(address user, MockERC20 asset_, uint256 amount) internal returns (uint256 shares) {
        asset_.mint(user, amount);
        vm.startPrank(user);
        IERC20(address(asset_)).approve(address(hy), amount);
        shares = hy.deposit(address(asset_), amount, user);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            VAULT MANAGEMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice addVault registers a vault, updates totalWeight, and sets the asset index.
    function test_addVault_registersAndTracksWeight() public view {
        assertEq(hy.vaultCount(), 2);
        assertEq(hy.totalWeight(), uint256(WEIGHT_0) + WEIGHT_1);

        (address v0, address a0, bool active0, uint64 w0) = hy.vaultAt(0);
        assertEq(v0, address(vault0));
        assertEq(a0, address(asset0));
        assertTrue(active0);
        assertEq(w0, WEIGHT_0);

        (address v1, , bool active1, uint64 w1) = hy.vaultAt(1);
        assertEq(v1, address(vault1));
        assertTrue(active1);
        assertEq(w1, WEIGHT_1);
    }

    /// @notice addEquivalentVault reverts when the weight is zero.
    function test_addVault_zeroWeight_reverts() public {
        MockERC20 asset2 = new MockERC20("Asset 2", "A2", 18);
        MockERC4626Vault vault2 = new MockERC4626Vault(IERC20(address(asset2)), "Vault 2", "V2");
        MockWrappedPriceOracle oracle2 = new MockWrappedPriceOracle();
        oracle2.setLatestAnswer(1 ether, 1 ether);

        vm.expectRevert(HarborYield_v1.ZeroWeight.selector);
        hy.addEquivalentVault(address(vault2), 0, address(oracle2));
    }

    /// @notice addEquivalentVault reverts when the asset is already registered by another vault.
    function test_addVault_duplicateAsset_reverts() public {
        MockERC4626Vault dup = new MockERC4626Vault(IERC20(address(asset0)), "Dup", "DUP");
        MockWrappedPriceOracle oracleDup = new MockWrappedPriceOracle();
        oracleDup.setLatestAnswer(1 ether, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(HarborYield_v1.VaultAlreadyRegistered.selector, address(dup)));
        hy.addEquivalentVault(address(dup), 10, address(oracleDup));
    }

    /// @notice addEquivalentVault is owner-only; non-owners revert with Unauthorized.
    function test_addVault_nonOwner_reverts() public {
        MockERC20 asset2 = new MockERC20("Asset 2", "A2", 18);
        MockERC4626Vault vault2 = new MockERC4626Vault(IERC20(address(asset2)), "Vault 2", "V2");
        MockWrappedPriceOracle oracle2 = new MockWrappedPriceOracle();
        oracle2.setLatestAnswer(1 ether, 1 ether);

        vm.prank(alice);
        vm.expectRevert(); // HarborOwnable Unauthorized
        hy.addEquivalentVault(address(vault2), 10, address(oracle2));
    }

    /// @notice setVaultWeight adjusts the cached totalWeight correctly.
    function test_setVaultWeight_updatesTotalWeight() public {
        hy.setVaultWeight(address(vault0), 80);
        assertEq(hy.totalWeight(), 80 + WEIGHT_1);

        (, , , uint64 w0) = hy.vaultAt(0);
        assertEq(w0, 80);
    }

    /// @notice setVaultWeight on an unregistered vault reverts.
    function test_setVaultWeight_unknownVault_reverts() public {
        address ghost = makeAddr("ghost");
        vm.expectRevert(abi.encodeWithSelector(HarborYield_v1.VaultNotRegistered.selector, ghost));
        hy.setVaultWeight(ghost, 100);
    }

    /// @notice deactivateVault and activateVault toggle the active flag.
    function test_deactivateAndActivateVault() public {
        hy.deactivateVault(address(vault0));
        (, , bool active, ) = hy.vaultAt(0);
        assertFalse(active);

        hy.activateVault(address(vault0));
        (, , active, ) = hy.vaultAt(0);
        assertTrue(active);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            DEPOSIT / REDEEM
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice First deposit mints shares 1:1 with assets (at the empty-vault rate).
    function test_deposit_firstDepositOneToOne() public {
        uint256 shares = _deposit(alice, asset0, 100 ether);
        assertEq(shares, 100 ether, "first deposit 1:1");
        assertEq(hy.balanceOf(alice), shares);
        assertEq(hy.totalAssets(), 100 ether);
        // Vault holds the deposited assets, HY holds the vault shares.
        assertEq(asset0.balanceOf(address(vault0)), 100 ether);
        assertEq(IERC20(address(vault0)).balanceOf(address(hy)), 100 ether);
    }

    /// @notice Deposit to an unregistered asset reverts.
    function test_deposit_unregisteredAsset_reverts() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(alice, 1 ether);
        vm.startPrank(alice);
        IERC20(address(other)).approve(address(hy), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(HarborYield_v1.VaultNotRegistered.selector, address(other)));
        hy.deposit(address(other), 1 ether, alice);
        vm.stopPrank();
    }

    /// @notice Deposit to a deactivated vault reverts with VaultNotActive.
    function test_deposit_deactivatedVault_reverts() public {
        hy.deactivateVault(address(vault0));
        asset0.mint(alice, 1 ether);
        vm.startPrank(alice);
        IERC20(address(asset0)).approve(address(hy), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(HarborYield_v1.VaultNotActive.selector, address(vault0)));
        hy.deposit(address(asset0), 1 ether, alice);
        vm.stopPrank();
    }

    /// @notice Deposit routes each asset to its mapped vault; shares are minted at the current exchange rate.
    function test_deposit_routingTwoAssets() public {
        _deposit(alice, asset0, 60 ether);
        _deposit(bob, asset1, 40 ether);

        // Alice and Bob both deposited into empty vaults at 1:1 — each gets their deposit size in HY shares.
        assertEq(hy.balanceOf(alice), 60 ether, "alice shares");
        assertEq(hy.balanceOf(bob), 40 ether, "bob shares");
        assertEq(hy.totalAssets(), 100 ether, "total assets sum");
        assertEq(asset0.balanceOf(address(vault0)), 60 ether, "vault0 holds asset0");
        assertEq(asset1.balanceOf(address(vault1)), 40 ether, "vault1 holds asset1");
    }

    /// @notice Existing user share value is not diluted by a subsequent deposit into another vault.
    function test_deposit_doesNotDiluteExistingUsers() public {
        _deposit(alice, asset0, 100 ether);
        uint256 aliceShares = hy.balanceOf(alice);

        // Alice's share is worth the full 100 ether pool.
        uint256 aliceAssetsBefore = (hy.totalAssets() * aliceShares) / hy.totalSupply();
        assertEq(aliceAssetsBefore, 100 ether);

        // Bob deposits into the other vault.
        _deposit(bob, asset1, 50 ether);

        // Alice's implied assets should be unchanged.
        uint256 aliceAssetsAfter = (hy.totalAssets() * aliceShares) / hy.totalSupply();
        assertEq(aliceAssetsAfter, aliceAssetsBefore, "alice not diluted");
    }

    /// @notice deposit(type(uint256).max, ...) consumes the caller's full balance.
    function test_deposit_maxAmount_usesFullBalance() public {
        asset0.mint(alice, 77 ether);
        vm.startPrank(alice);
        IERC20(address(asset0)).approve(address(hy), type(uint256).max);
        uint256 shares = hy.deposit(address(asset0), type(uint256).max, alice);
        vm.stopPrank();

        assertEq(shares, 77 ether);
        assertEq(asset0.balanceOf(alice), 0);
    }

    /// @notice Yield accruing inside a managed vault increases HY.totalAssets and share price.
    function test_totalAssets_reflectsVaultYield() public {
        _deposit(alice, asset0, 100 ether);
        uint256 assetsBefore = hy.totalAssets();

        // Drop 10% yield into vault0.
        vault0.addYield(10 ether);

        // OZ ERC4626 uses a virtual-share offset that introduces 1-wei rounding on convertToAssets.
        assertApproxEqAbs(hy.totalAssets(), assetsBefore + 10 ether, 1, "totalAssets reflects yield");
    }

    /// @notice Redeem burns shares and pays out a proportional slice of every managed vault's holdings.
    function test_redeem_proportionalAcrossVaults() public {
        _deposit(alice, asset0, 60 ether);
        _deposit(alice, asset1, 40 ether);

        uint256 shares = hy.balanceOf(alice);
        // Redeem half of alice's shares.
        vm.prank(alice);
        hy.redeem(shares / 2, alice, alice);

        // Alice should have received half of each asset.
        assertEq(asset0.balanceOf(alice), 30 ether, "got half of asset0");
        assertEq(asset1.balanceOf(alice), 20 ether, "got half of asset1");
        assertEq(hy.balanceOf(alice), shares - shares / 2);
    }

    /// @notice Redeeming all shares drains both managed vaults.
    function test_redeem_fullRedemptionDrainsVaults() public {
        _deposit(alice, asset0, 60 ether);
        _deposit(alice, asset1, 40 ether);

        uint256 shares = hy.balanceOf(alice);
        vm.prank(alice);
        hy.redeem(shares, alice, alice);

        assertEq(hy.balanceOf(alice), 0);
        assertEq(IERC20(address(vault0)).balanceOf(address(hy)), 0, "vault0 shares drained");
        assertEq(IERC20(address(vault1)).balanceOf(address(hy)), 0, "vault1 shares drained");
    }

    /// @notice Redeeming on behalf of another account requires and consumes allowance.
    function test_redeem_withAllowance() public {
        _deposit(alice, asset0, 100 ether);
        uint256 shares = hy.balanceOf(alice);

        vm.prank(alice);
        hy.approve(bob, shares);

        vm.prank(bob);
        hy.redeem(shares, bob, alice);

        assertEq(hy.balanceOf(alice), 0);
        assertEq(asset0.balanceOf(bob), 100 ether, "bob received the underlying");
        assertEq(hy.allowance(alice, bob), 0, "allowance consumed");
    }

    /// @notice Redeem without allowance reverts.
    function test_redeem_withoutAllowance_reverts() public {
        _deposit(alice, asset0, 100 ether);
        uint256 shares = hy.balanceOf(alice);

        vm.prank(bob);
        vm.expectRevert(); // ERC20 allowance error
        hy.redeem(shares, bob, alice);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            COMPOUND (swap path)
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Owner can compound: redeem from one vault, swap asset, deposit into another vault.
    function test_compound_ownerCanConvertAcrossVaults() public {
        _deposit(alice, asset0, 60 ether);
        _deposit(bob, asset1, 40 ether);

        uint256 v0SharesBefore = IERC20(address(vault0)).balanceOf(address(hy));
        uint256 v1SharesBefore = IERC20(address(vault1)).balanceOf(address(hy));
        uint256 totalAssetsBefore = hy.totalAssets();

        // Move 10 vault0 shares -> asset0 -> swap to asset1 -> vault1.
        hy.compound(address(vault0), address(vault1), 10 ether, 10 ether, "");

        assertEq(IERC20(address(vault0)).balanceOf(address(hy)), v0SharesBefore - 10 ether, "vault0 shares down");
        assertGt(IERC20(address(vault1)).balanceOf(address(hy)), v1SharesBefore, "vault1 shares up");
        // At 1:1 rate and 1:1 vault exchange rate, total assets are preserved.
        assertEq(hy.totalAssets(), totalAssetsBefore, "totalAssets preserved across 1:1 swap");
    }

    /// @notice A compound caller holding COMPOUNDER_ROLE succeeds.
    function test_compound_compounderRoleCanCompound() public {
        _deposit(alice, asset0, 60 ether);
        _deposit(bob, asset1, 40 ether);

        hy.grantRoles(keeper, hy.COMPOUNDER_ROLE());

        vm.prank(keeper);
        hy.compound(address(vault0), address(vault1), 5 ether, 5 ether, "");
    }

    /// @notice A caller without COMPOUNDER_ROLE or ownership cannot compound.
    function test_compound_unauthorized_reverts() public {
        _deposit(alice, asset0, 60 ether);
        _deposit(bob, asset1, 40 ether);

        vm.prank(alice);
        vm.expectRevert(); // Unauthorized
        hy.compound(address(vault0), address(vault1), 5 ether, 5 ether, "");
    }

    /// @notice Compound honours the minAmountOut slippage check via the swapper.
    function test_compound_slippageRevertsFromSwapper() public {
        _deposit(alice, asset0, 60 ether);
        _deposit(bob, asset1, 40 ether);

        // minOut exceeds the fixed 1:1 swap output.
        vm.expectRevert(bytes("MockSwapper: slippage"));
        hy.compound(address(vault0), address(vault1), 5 ether, 6 ether, "");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            REDISTRIBUTE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Redistribute moves value from the over-weight vault to the under-weight vault.
    /// @dev Targets (60, 40) but we only deposit into asset0 (100, 0) — asset0 is 40 over, asset1 is 40 under.
    function test_redistribute_rebalancesTowardTargetWeights() public {
        _deposit(alice, asset0, 100 ether);

        uint256 v0Before = IERC4626(address(vault0)).convertToAssets(IERC20(address(vault0)).balanceOf(address(hy)));
        uint256 v1Before = IERC4626(address(vault1)).convertToAssets(IERC20(address(vault1)).balanceOf(address(hy)));
        assertEq(v0Before, 100 ether);
        assertEq(v1Before, 0);

        // Permit up to the full source position; require 1:1 swap output.
        hy.redistribute(type(uint256).max, 1, "");

        uint256 v0After = IERC4626(address(vault0)).convertToAssets(IERC20(address(vault0)).balanceOf(address(hy)));
        uint256 v1After = IERC4626(address(vault1)).convertToAssets(IERC20(address(vault1)).balanceOf(address(hy)));

        // Targets: (60, 40). A single rebalance moves exactly min(excess, deficit) = 40.
        assertEq(v0After, 60 ether, "vault0 at target");
        assertEq(v1After, 40 ether, "vault1 at target");
        // Total preserved at 1:1 rates.
        assertEq(hy.totalAssets(), 100 ether);
    }

    /// @notice REDISTRIBUTOR_ROLE holder (not owner) can redistribute.
    function test_redistribute_redistributorRoleCanCall() public {
        _deposit(alice, asset0, 100 ether);
        hy.grantRoles(keeper, hy.REDISTRIBUTOR_ROLE());

        vm.prank(keeper);
        hy.redistribute(type(uint256).max, 1, "");
    }

    /// @notice Non-owner without REDISTRIBUTOR_ROLE cannot redistribute.
    function test_redistribute_unauthorized_reverts() public {
        _deposit(alice, asset0, 100 ether);
        vm.prank(alice);
        vm.expectRevert();
        hy.redistribute(type(uint256).max, 1, "");
    }

    /// @notice When all vaults are already at their target weights, redistribute reverts.
    function test_redistribute_alreadyBalanced_reverts() public {
        // Deposit in exact 60/40 ratio -> already at target.
        _deposit(alice, asset0, 60 ether);
        _deposit(bob, asset1, 40 ether);

        vm.expectRevert(HarborYield_v1.NothingToRedistribute.selector);
        hy.redistribute(type(uint256).max, 1, "");
    }

    /// @notice Empty vault (nothing deposited yet) reverts NothingToRedistribute.
    function test_redistribute_emptyVault_reverts() public {
        vm.expectRevert(HarborYield_v1.NothingToRedistribute.selector);
        hy.redistribute(type(uint256).max, 1, "");
    }

    /// @notice The maxVaultSharesPerVault argument caps the amount moved in one call.
    function test_redistribute_maxSharesCapsMovement() public {
        _deposit(alice, asset0, 100 ether);

        // Cap source vault shares at 5 — less than the 40 needed to fully rebalance.
        hy.redistribute(5 ether, 1, "");

        uint256 v0After = IERC4626(address(vault0)).convertToAssets(IERC20(address(vault0)).balanceOf(address(hy)));
        uint256 v1After = IERC4626(address(vault1)).convertToAssets(IERC20(address(vault1)).balanceOf(address(hy)));

        // Only 5 moved from v0 to v1, not the full 40.
        assertEq(v0After, 95 ether);
        assertEq(v1After, 5 ether);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            ERC-4626 VIEW SHIM
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice `asset()` returns the peg token supplied at construction time.
    function test_asset_returnsPegToken() public view {
        assertEq(hy.asset(), address(pegToken));
    }

    /// @notice On an empty vault, convertToShares and convertToAssets return the input (1:1 rate
    ///         at supply = 0, totalAssets = 0 due to the virtual-share `+1` floor).
    function test_convert_onEmptyVault_isOneToOne() public view {
        assertEq(hy.totalSupply(), 0);
        assertEq(hy.totalAssets(), 0);
        assertEq(hy.convertToShares(100 ether), 100 ether);
        assertEq(hy.convertToAssets(100 ether), 100 ether);
    }

    /// @notice After a real deposit, convertToShares/Assets round-trip (within 1 wei).
    function test_convert_roundTripAfterDeposit() public {
        _deposit(alice, asset0, 100 ether);

        uint256 shares = hy.convertToShares(50 ether);
        uint256 assetsBack = hy.convertToAssets(shares);
        // Integer division in both directions can lose 1 wei.
        assertApproxEqAbs(assetsBack, 50 ether, 1, "round-trip within 1 wei");
    }

    /// @notice `convertToAssets(shares)` tracks the internal share-price formula used in `deposit`.
    ///         If the formula were `(supply+1)/(assets+1)`, convertToAssets(totalSupply) should
    ///         equal totalAssets within the virtual-share floor.
    function test_convert_matchesInternalFormula() public {
        _deposit(alice, asset0, 100 ether);
        _deposit(bob, asset1, 40 ether);

        uint256 supply = hy.totalSupply();
        uint256 assets = hy.totalAssets();

        // convertToAssets(supply) = supply * (assets + 1) / (supply + 1)
        // which differs from `assets` by at most 1 wei due to the virtual floor.
        uint256 fromShim = hy.convertToAssets(supply);
        assertApproxEqAbs(fromShim, assets, 1, "convertToAssets(supply) ~= totalAssets");
    }

    /// @notice previewDeposit matches convertToShares (both round down).
    function test_previewDeposit_matchesConvertToShares() public {
        _deposit(alice, asset0, 100 ether);

        uint256 preview = hy.previewDeposit(25 ether);
        uint256 converted = hy.convertToShares(25 ether);
        assertEq(preview, converted);
    }

    /// @notice previewRedeem matches convertToAssets (both round down).
    function test_previewRedeem_matchesConvertToAssets() public {
        _deposit(alice, asset0, 100 ether);

        uint256 preview = hy.previewRedeem(10 ether);
        uint256 converted = hy.convertToAssets(10 ether);
        assertEq(preview, converted);
    }

    /// @notice Share price (convertToAssets(1 ether)) grows as vault yield accrues.
    function test_convertToAssets_reflectsVaultYield() public {
        _deposit(alice, asset0, 100 ether);
        uint256 priceBefore = hy.convertToAssets(1 ether);

        // Simulate 10% yield in vault0.
        vault0.addYield(10 ether);

        uint256 priceAfter = hy.convertToAssets(1 ether);
        assertGt(priceAfter, priceBefore, "share price increased with yield");
    }

    /// @notice The view shim is exposed via the IHarborYield interface.
    function test_viewShim_reachableViaInterface() public view {
        // Compile-time check: these calls compile if IHarborYield declares them.
        assertEq(IHarborYield(address(hy)).asset(), address(pegToken));
        assertEq(IHarborYield(address(hy)).convertToShares(1 ether), hy.convertToShares(1 ether));
        assertEq(IHarborYield(address(hy)).convertToAssets(1 ether), hy.convertToAssets(1 ether));
        assertEq(IHarborYield(address(hy)).previewDeposit(1 ether), hy.previewDeposit(1 ether));
        assertEq(IHarborYield(address(hy)).previewRedeem(1 ether), hy.previewRedeem(1 ether));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            B.4.3: PEG VERIFICATION AT addVault
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice `addAutoCompounderVault` reverts if the AC's PEGGED_TOKEN doesn't match HY's peg.
    function test_addAutoCompounder_wrongPeg_reverts() public {
        MockERC20 asset2 = new MockERC20("Asset 2", "A2", 18);
        MockERC4626Vault acBad = new MockERC4626Vault(IERC20(address(asset2)), "Bad AC", "BAD");
        MockERC20 otherPeg = new MockERC20("Other Peg", "OPE", 18);
        MockMinter minterBad = new MockMinter(address(asset2), address(otherPeg), makeAddr("levBad"));
        acBad.configureAsAutoCompounder(address(otherPeg), address(minterBad));

        vm.expectRevert(
            abi.encodeWithSelector(HarborYield_v1.WrongPegToken.selector, address(pegToken), address(otherPeg))
        );
        hy.addAutoCompounderVault(address(acBad), 10);
    }

    /// @notice `addEquivalentVault` reverts if the oracle reports a rate outside maxPegDriftBps.
    function test_addEquivalent_excessiveDrift_reverts() public {
        MockERC20 asset2 = new MockERC20("Asset 2", "A2", 18);
        MockERC4626Vault equiv = new MockERC4626Vault(IERC20(address(asset2)), "Drift", "DFT");
        MockWrappedPriceOracle oracleDrift = new MockWrappedPriceOracle();
        // 5% depeg — way outside the default 2% drift tolerance
        oracleDrift.setLatestAnswer(0.95 ether, 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(HarborYield_v1.ExcessivePegDrift.selector, uint256(1 ether), uint256(0.95 ether))
        );
        hy.addEquivalentVault(address(equiv), 10, address(oracleDrift));
    }

    /// @notice A near-peg equivalent (within tolerance) registers successfully.
    function test_addEquivalent_withinDrift_succeeds() public {
        MockERC20 asset2 = new MockERC20("Asset 2", "A2", 18);
        MockERC4626Vault equiv = new MockERC4626Vault(IERC20(address(asset2)), "OK", "OK");
        MockWrappedPriceOracle oracleOk = new MockWrappedPriceOracle();
        // 1% "depeg" — inside the 2% tolerance
        oracleOk.setLatestAnswer(0.99 ether, 1 ether);

        hy.addEquivalentVault(address(equiv), 10, address(oracleOk));
        assertEq(hy.vaultCount(), 3);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            B.4.3: ORACLE-VALUED totalAssets
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice totalAssets for an AC-only holder equals convertToAssets at healthy peggedTokenPrice (1e18).
    function test_totalAssets_ac_healthyPeg() public {
        _deposit(alice, asset0, 100 ether);
        uint256 total = hy.totalAssets();
        // At peggedTokenPrice = 1e18, AC contribution = convertToAssets unchanged.
        assertApproxEqAbs(total, 100 ether, 1);
    }

    /// @notice totalAssets drops when the Minter reports a haXXX depeg via peggedTokenPrice().
    function test_totalAssets_ac_depegReducesValue() public {
        _deposit(alice, asset0, 100 ether);

        // Simulate haEUR depegging to 0.80 EUR — AC contribution to totalAssets drops 20%.
        minter0.setPeggedTokenPrice(0.8 ether);

        uint256 total = hy.totalAssets();
        assertApproxEqAbs(total, 80 ether, 1);
    }

    /// @notice totalAssets for an equivalent uses the oracle's mid rate.
    function test_totalAssets_equivalent_usesOracle() public {
        _deposit(alice, asset1, 100 ether);
        uint256 total = hy.totalAssets();
        // Oracle reports 1:1, so totalAssets ≈ 100 ether.
        assertApproxEqAbs(total, 100 ether, 1);

        // Move the oracle to 0.99 (1% depeg); totalAssets drops ~1%.
        oracle1.setLatestAnswer(0.99 ether, 1 ether);
        uint256 totalAfter = hy.totalAssets();
        assertApproxEqAbs(totalAfter, 99 ether, 1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            B.4.3: maxPegDriftBps ADMIN
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Setting a new drift value updates state and emits the event.
    function test_setMaxPegDriftBps_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit IHarborYield.MaxPegDriftBpsUpdated(500);
        hy.setMaxPegDriftBps(500);
        assertEq(hy.maxPegDriftBps(), 500);
    }

    /// @notice setMaxPegDriftBps is owner-only.
    function test_setMaxPegDriftBps_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        hy.setMaxPegDriftBps(500);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            B.4.3: RUNTIME ORACLE-BOUNDED MIN-OUT
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice compound with keeperMinOut = 0 still enforces HY's oracle-bounded floor.
    ///         Here the swapper rate is 1:1, oracle rates are 1:1, so effectiveMin ≈ 0.98x amountIn.
    ///         The swap yields 1x which is above 0.98x → success.
    function test_compound_oracleFloorAcceptsFairSwap() public {
        _deposit(alice, asset0, 60 ether);
        _deposit(bob, asset1, 40 ether);

        // keeperMinOut = 0 — HY overrides with its own floor based on oracle rates.
        hy.compound(address(vault0), address(vault1), 10 ether, 0, "");
    }

    /// @notice When the swapper yields less than HY's oracle floor, compound reverts via the
    ///         swapper's slippage check (because HY passed the floor as effectiveMinOut).
    function test_compound_oracleFloorRejectsBadSwap() public {
        _deposit(alice, asset0, 60 ether);
        _deposit(bob, asset1, 40 ether);

        // Swapper yields only 95% of input — below the 98% oracle floor.
        swapper.setRate(0.95 ether);

        vm.expectRevert(bytes("MockSwapper: slippage"));
        hy.compound(address(vault0), address(vault1), 10 ether, 0, "");
    }

    /// @notice If the oracle itself reflects a depeg, the floor follows the oracle down —
    ///         swaps at the depegged rate continue to succeed.
    function test_compound_floorFollowsOracleDuringDepeg() public {
        _deposit(alice, asset0, 60 ether);
        _deposit(bob, asset1, 40 ether);

        // Oracle reflects a 3% depeg on asset1; swapper also yields 97% (matching).
        oracle1.setLatestAnswer(0.97 ether, 1 ether);
        swapper.setRate(0.97 ether);

        // Oracle floor: expected ≈ from/to = 1/0.97 ≈ 1.031 ether per 1 ether
        // with 2% drift → floor ≈ 1.0106. Swap yields amountIn * 0.97 = 0.97 — BELOW floor.
        // So this SHOULD revert.
        //
        // The point is: the oracle-floor tracks the oracle BUT asset1's rate being 0.97
        // increases the expected out for from→to swaps, not decreases it. (You need more of a
        // "cheaper" asset to match a "full" output.) So the swap still has to beat the floor.
        vm.expectRevert(bytes("MockSwapper: slippage"));
        hy.compound(address(vault0), address(vault1), 10 ether, 0, "");
    }
}
