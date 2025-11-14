"""Wake regression tests for Harbor contract size limits."""

from pytypes.script.harbor.HarborAutoDeployment import HarborAutoDeployment
from pytypes.script.harbor.HarborDeployment import HarborDeployment
from wake.testing import chain, default_chain

from tests.harbor_deployment_wake import HarborDeploymentWake


@chain.connect()
def test_can_deploy_40kb_contract():
    """Wake can deploy the slim 40KB HarborDeployment contract."""
    deployer = default_chain.accounts[0]

    HarborDeploymentWake.deploy_required_libraries(deployer)

    try:
        harbor = HarborDeployment.deploy(from_=deployer)
        print(f"✅ Successfully deployed 40KB HarborDeployment contract at {harbor.address}")
        print("✅ Wake CAN deploy contracts over 24KB!")
    except Exception as exc:
        print(f"❌ Failed to deploy 40KB HarborDeployment: {exc}")
        print("❌ Wake cannot deploy contracts over 24KB")
        assert False, f"Cannot deploy 40KB contract: {exc}"


@chain.connect()
def test_original_143kb_harbor_auto_deployment():
    """Pre-refactor 143KB version deploys when size limits are disabled."""
    deployer = default_chain.accounts[0]

    HarborDeploymentWake.deploy_required_libraries(deployer)

    print("\n" + "=" * 80)
    print("Testing ORIGINAL 143KB HarborAutoDeployment")
    print("=" * 80)

    harbor = HarborAutoDeployment.deploy(from_=deployer, gas_limit="max")

    assert harbor.address is not None

    print(
        "✅ SUCCESS! Original 143KB HarborAutoDeployment deployed at:",
        harbor.address,
    )
    print("✅ This confirms --disable-code-size-limit remains required in wake.toml")
    print("=" * 80)
