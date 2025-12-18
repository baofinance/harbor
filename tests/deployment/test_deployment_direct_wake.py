# tests/test_deployment_direct_wake.py
"""Direct deployment tests to isolate deterministic proxy behavior.

These scenarios deploy contracts without using HarborDeployment's higher-level
helpers to confirm base proxy deployment logic continues to function.
"""

from pytypes.lib.baominter.src.minter.TokenDistributor_v1 import TokenDistributor_v1
from wake.testing import Address, chain, default_chain  # type: ignore[import]
from wake.testing.core import Abi  # type: ignore[import]

from ..harbor_deployment_wake import HarborDeploymentWake


@chain.connect()
def test_deploy_proxy_directly():
    """Test calling deployProxy() directly without using deployContract()."""
    print("\n=== Test: Call deployProxy() Directly ===\n")

    deployer_account = default_chain.accounts[0]

    # Deploy HarborDeployment
    print("1. Deploying HarborDeploymentWake...")
    harbor = HarborDeploymentWake.deploy(deployer_account)
    print(f"   Harbor at: {harbor.address}")

    # Set admin
    print("2. Setting admin...")
    harbor.useAdmin(deployer_account.address)
    admin = harbor.getAdmin()
    print(f"   Admin: {admin}")

    # Deploy TokenDistributor_v1 implementation
    print("3. Deploying TokenDistributor_v1 implementation...")
    impl = TokenDistributor_v1.deploy(from_=deployer_account)
    print(f"   Implementation at: {impl.address}")

    # Encode initialize call
    print("4. Encoding initialize call data...")
    init_data = Abi.encode_call(impl.initialize, [admin, "Test Fee Receiver"])
    print(f"   InitData: {init_data.hex()}")

    # Try calling deployProxy() directly
    print("5. Calling harbor.deployProxy() directly...")
    try:
        fee_receiver_tx = harbor.deployProxy(
            "fee-receiver",  # key - hardcoded for now
            impl.address,
            init_data,
            "fee-receiver-v1",  # saltString
            from_=deployer_account,
            gas_limit=30_000_000,
        )
        fee_receiver_tx.wait()
        fee_receiver_addr = fee_receiver_tx.return_value
        print(f"   FeeReceiver proxy deployed at: {fee_receiver_addr}")
        print("   [OK] Direct deployProxy call succeeded!")

    except Exception as e:
        print(f"   [FAILED] Exception: {type(e).__name__}: {e}")
        import traceback

        traceback.print_exc()
        raise

    print("\n=== Test PASSED ===\n")


@chain.connect()
def test_cheatcode_address_is_empty():
    cheatcode_addr = Address("0x7109709ECfa91a80626fF3989D68f67F5b1DD12D")
    code = default_chain.chain_interface.get_code(str(cheatcode_addr))
    print(f"Cheatcode address code length: {len(code)}")
    assert len(code) == 0, "Cheatcode address unexpectedly has code in Wake"
