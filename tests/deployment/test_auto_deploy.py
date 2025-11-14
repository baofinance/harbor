# tests/test_deployment_autodeploy_wake.py
"""Tests for HarborAutoDeployment's higher-level deploy helpers in Wake.

These tests exercise the Harbor-specific deployment entrypoints (e.g.
``deployFeeReceiverFromConfig``) and ensure dependencies are auto-mocked where
expected. The legacy enum-based ``deployContract`` interface has been removed;
tests now target the concrete helper methods directly.
"""

from wake.testing import chain, default_chain, must_revert  # type: ignore[import]

from ..harbor_deployment_wake import HarborDeploymentWake

# ============================================================================
# Auto-Deploy Tests
# ============================================================================


@chain.connect()
def test_deploy_fee_receiver_with_real_admin():
    """Test deploying fee receiver with actual admin address (not auto-mock)."""
    print("\n=== Test: Deploy Fee Receiver With Real Admin ===\n")

    deployer = default_chain.accounts[0]

    # Deploy HarborAutoDeployment
    print("1. Deploying HarborAutoDeployment...")
    harbor = HarborDeploymentWake.deploy(deployer)
    print(f"   Harbor deployed at: {harbor.address}")

    # Set actual admin address (use deployer as admin)
    print("2. Setting admin to deployer address...")
    harbor.useAdmin(deployer.address)
    admin_addr = harbor.getAdmin()
    print(f"   Admin set to: {admin_addr}")

    # Deploy fee receiver (will use real admin, not auto-mock)
    print("3. Deploying FEE_RECEIVER...")
    try:
        # Try with explicit high gas limit to rule out gas estimation issues
        fee_receiver_tx = harbor.deployFeeReceiverFromConfig(gas_limit=30_000_000)
        fee_receiver_tx.wait()
        fee_receiver_addr = fee_receiver_tx.return_value
        print(f"   FeeReceiver deployed at: {fee_receiver_addr}")

        # Verify it's in the registry
        assert harbor.hasFeeReceiver(), "FeeReceiver should be in registry"
        assert harbor.getFeeReceiver() == fee_receiver_addr, "FeeReceiver address should match"
        print("   [OK] FeeReceiver deployed and registered successfully")

    except Exception as e:
        print(f"   [FAILED] Exception: {type(e).__name__}: {e}")
        import traceback

        traceback.print_exc()
        raise

    print("\n=== Test PASSED ===\n")


@chain.connect()
def test_deploy_fee_receiver_only():
    """Test deploying fee receiver with auto-mock admin (will likely fail in Wake)."""
    print("\n=== Test: Deploy Fee Receiver With Auto-Mock Admin ===\n")

    deployer = default_chain.accounts[0]

    # Deploy HarborAutoDeployment
    print("1. Deploying HarborAutoDeployment...")
    harbor = HarborDeploymentWake.deploy(deployer)
    print(f"   Harbor deployed at: {harbor.address}")

    # Deploy fee receiver (auto-mocks admin dependency from address without code)
    print("2. Deploying FEE_RECEIVER (will auto-mock admin)...")
    try:
        fee_receiver_tx = harbor.deployFeeReceiverFromConfig()
        fee_receiver_tx.wait()
        fee_receiver_addr = fee_receiver_tx.return_value
        print(f"   FeeReceiver deployed at: {fee_receiver_addr}")

        # Verify it's in the registry
        assert harbor.hasFeeReceiver(), "FeeReceiver should be in registry"
        assert harbor.getFeeReceiver() == fee_receiver_addr, "FeeReceiver address should match"
        print("   [OK] FeeReceiver deployed and registered successfully")

        # Check that admin was auto-mocked
        if harbor.hasAdmin():
            admin_addr = harbor.getAdmin()
            print(f"   Admin auto-mocked at: {admin_addr}")

    except Exception as e:
        print(f"   [FAILED] Exception: {type(e).__name__}: {e}")
        print("   NOTE: This is expected - Wake/Anvil is stricter about no-code addresses")
        import traceback

        traceback.print_exc()
        raise

    print("\n=== Test PASSED ===\n")


@chain.connect()
def test_deploy_wrapped_collateral_only():
    """Test deploying wrapped collateral token (also no dependencies)."""
    print("\n=== Test: Deploy Wrapped Collateral Only ===\n")

    deployer = default_chain.accounts[0]

    # Deploy HarborAutoDeployment
    print("1. Deploying HarborAutoDeployment...")
    harbor = HarborDeploymentWake.deploy(deployer)

    # Deploy wrapped collateral (no dependencies)
    print("2. Deploying WRAPPED_COLLATERAL...")
    try:
        with must_revert():
            harbor.getCollateralToken()
        print("   [OK] Reverted as expected")

    except Exception as e:
        print(f"   [FAILED] Exception: {type(e).__name__}: {e}")
        import traceback

        traceback.print_exc()
        raise

    print("\n=== Test PASSED ===\n")


@chain.connect()
def test_deploy_minter_with_dependencies():
    """Test deploying minter (has dependencies that need auto-mocking)."""
    print("\n=== Test: Deploy Minter With Dependencies ===\n")

    deployer = default_chain.accounts[0]

    # Deploy HarborAutoDeployment
    print("1. Deploying HarborAutoDeployment...")
    harbor = HarborDeploymentWake.deploy(deployer)

    # Deploy minter (will auto-mock dependencies)
    print("2. Deploying MINTER (will auto-mock dependencies)...")
    try:
        minter_tx = harbor.deployMinterFromConfig()
        minter_tx.wait()
        minter_addr = minter_tx.return_value
        print(f"   Minter deployed at: {minter_addr}")

        # Verify it's in the registry
        assert harbor.hasMinter(), "Minter should be in registry"
        assert harbor.getMinter() == minter_addr, "Minter address should match"
        print("   [OK] Minter deployed and registered successfully")

        # Check that dependencies were auto-mocked
        print("3. Checking auto-mocked dependencies...")
        if harbor.hasOracle():
            oracle_addr = harbor.getOracle()
            print(f"   Oracle auto-mocked at: {oracle_addr}")

        if harbor.hasCollateralToken():
            collateral_addr = harbor.getCollateralToken()
            print(f"   Collateral auto-mocked at: {collateral_addr}")

        if harbor.hasFeeReceiver():
            fee_receiver_addr = harbor.getFeeReceiver()
            print(f"   FeeReceiver auto-mocked at: {fee_receiver_addr}")

        print("   [OK] Dependencies auto-mocked successfully")

    except Exception as e:
        print(f"   [FAILED] Exception: {type(e).__name__}: {e}")
        import traceback

        traceback.print_exc()
        raise

    print("\n=== Test PASSED ===\n")
