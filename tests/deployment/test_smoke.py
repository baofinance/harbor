# tests/test_deployment_smoke_wake.py
"""Simple smoke tests to verify HarborAutoDeployment structure in Wake.

These tests verify the deployment architecture works without triggering
complex auto-deploy logic. They test that the contracts can be instantiated
and basic methods can be called.
"""

from wake.testing import Address, chain, default_chain  # type: ignore[import]

from ..harbor_deployment_wake import HarborDeploymentWake

# ============================================================================
# Basic Structure Tests
# ============================================================================


@chain.connect()
def test_harbor_auto_deployment_can_deploy():
    """Test that HarborAutoDeployment contract can be deployed."""
    print("\n=== Test: HarborAutoDeployment Can Deploy ===\n")

    deployer = default_chain.accounts[0]

    # Deploy HarborAutoDeployment (libraries deployed automatically)
    print("Deploying HarborAutoDeployment with libraries...")
    harbor = HarborDeploymentWake.deploy(deployer)

    # Verify deployment
    print(f"   Harbor deployed at: {harbor.address}")
    assert harbor.address != Address.ZERO, "Harbor should be deployed"
    print("   [OK] Harbor deployed successfully")

    print("\n=== Test PASSED ===\n")


@chain.connect()
def test_harbor_has_method_works():
    """Test that has() method works on deployed HarborAutoDeployment."""
    print("\n=== Test: Harbor hasMinter() Method Works ===\n")

    deployer = default_chain.accounts[0]

    # Deploy HarborAutoDeployment (libraries deployed automatically)
    print("Deploying HarborAutoDeployment with libraries...")
    harbor = HarborDeploymentWake.deploy(deployer)

    # Test hasMinter() method - should return False for contracts not deployed
    print("Testing hasMinter() method...")
    has_minter = harbor.hasMinter()
    print(f"   has(MINTER): {has_minter}")
    assert not has_minter, "Minter should not exist yet"
    print("   [OK] hasMinter() method works correctly")

    print("\n=== Test PASSED ===\n")


@chain.connect()
def test_harbor_get_method_reverts_for_missing():
    """Test that get() method reverts for non-existent contracts (by design)."""
    print("\n=== Test: Harbor getMinter() Reverts for Missing Contracts ===\n")

    deployer = default_chain.accounts[0]

    # Deploy HarborAutoDeployment (libraries deployed automatically)
    print("Deploying HarborAutoDeployment with libraries...")
    harbor = HarborDeploymentWake.deploy(deployer)

    # Test getMinter() - SHOULD revert for non-existent contracts
    print("Testing getMinter() reverts for missing contract...")
    try:
        harbor.getMinter()
        # Should never reach here
        assert False, "getMinter() should have reverted for missing contract"
    except Exception as e:
        error_name = type(e).__name__
        print(f"   Correctly reverted with: {error_name}")
        assert "ContractNotFound" in error_name or "ContractNotFound" in str(e), (
            f"Expected ContractNotFound, got {error_name}"
        )
        print("   [OK] getMinter() correctly reverts for missing contracts")

    print("\n=== Test PASSED ===\n")


@chain.connect()
def test_harbor_keys_method_empty():
    """Test that keys() method returns empty array initially."""
    print("\n=== Test: Harbor keys() Returns Empty Initially ===\n")

    deployer = default_chain.accounts[0]

    # Deploy HarborAutoDeployment (libraries deployed automatically)
    print("Deploying HarborAutoDeployment with libraries...")
    harbor = HarborDeploymentWake.deploy(deployer)

    # Test keys() method - should return empty array
    print("Testing keys() method...")
    all_keys = harbor.keys()
    print(f"   keys(): {all_keys}")
    assert len(all_keys) == 0, "Keys should be empty initially"
    print("   [OK] keys() method returns empty array")

    print("\n=== Test PASSED ===\n")
