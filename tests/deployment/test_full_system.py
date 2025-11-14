# tests/test_harbor_deployment_wake.py
"""Test HarborAutoDeployment works in Wake after decomposition."""

from typing import Any, cast

from pytypes.lib.baominter.src.minter.library.Config_v1 import Config_v1
from pytypes.script.harbor.deployers.BaseStabilityPoolDeployer import BaseStabilityPoolDeployer
from pytypes.script.harbor.deployers.FeeReceiverDeployer import FeeReceiverDeployer
from pytypes.script.harbor.deployers.GenesisDeployer import GenesisDeployer
from pytypes.script.harbor.deployers.LeveragedTokenDeployer import LeveragedTokenDeployer

# Import deployer libraries (needed because they're over 24KB and must be
# explicitly deployed)
from pytypes.script.harbor.deployers.MinterDeployer import MinterDeployer
from pytypes.script.harbor.deployers.PeggedTokenDeployer import PeggedTokenDeployer
from pytypes.script.harbor.deployers.ReservePoolDeployer import ReservePoolDeployer
from pytypes.script.harbor.deployers.StabilityPoolCollateralDeployer import StabilityPoolCollateralDeployer
from pytypes.script.harbor.deployers.StabilityPoolLeveragedDeployer import StabilityPoolLeveragedDeployer
from pytypes.script.harbor.deployers.StabilityPoolManagerDeployer import StabilityPoolManagerDeployer
from pytypes.test.HarborAutoDeployment import HarborAutoDeployment
from wake.testing import *  # type: ignore[import]


@chain.connect()
def test_harbor_auto_deployment_basic():
    """Test that HarborAutoDeployment can be deployed in Wake after refactoring."""
    deployer = default_chain.accounts[0]

    # Deploy Config_v1 library (required by Minter_v1)
    Config_v1.deploy(from_=deployer)

    # Deploy all deployer libraries (HarborAutoDeployment depends on them)
    # These include oversized libraries (MinterDeployer: 29KB,
    # BaseStabilityPoolDeployer: 26KB) which now work thanks to
    # --disable-code-size-limit in wake.toml.
    FeeReceiverDeployer.deploy(from_=deployer)
    PeggedTokenDeployer.deploy(from_=deployer)
    LeveragedTokenDeployer.deploy(from_=deployer)
    ReservePoolDeployer.deploy(from_=deployer)
    MinterDeployer.deploy(from_=deployer)  # 29KB - needs --disable-code-size-limit
    BaseStabilityPoolDeployer.deploy(from_=deployer)
    # 26KB deployment only succeeds with --disable-code-size-limit
    StabilityPoolCollateralDeployer.deploy(from_=deployer)
    StabilityPoolLeveragedDeployer.deploy(from_=deployer)
    StabilityPoolManagerDeployer.deploy(from_=deployer)
    GenesisDeployer.deploy(from_=deployer)

    # Deploy HarborAutoDeployment. The original 143KB contract would hang
    # before refactoring; library decomposition plus
    # --disable-code-size-limit makes it work at 44KB.
    harbor = cast(Any, HarborAutoDeployment.deploy(from_=deployer))

    # Verify the massive contract deployed successfully
    assert harbor.address != Address("0x0000000000000000000000000000000000000000")

    print(f"✅ SUCCESS! HarborAutoDeployment (44KB) deployed at: {harbor.address}")
    print("✅ Previously this 143KB contract would hang Wake completely!")
    print("✅ Refactored from 143KB → 44KB using library decomposition")
    print("✅ Deployed with --disable-code-size-limit in wake.toml")


@chain.connect()
def test_harbor_full_system():
    """Test full Harbor system deployment in Wake."""
    deployer = default_chain.accounts[0]

    # Deploy Config_v1 library
    Config_v1.deploy(from_=deployer)

    # Deploy all deployer libraries
    FeeReceiverDeployer.deploy(from_=deployer)
    PeggedTokenDeployer.deploy(from_=deployer)
    LeveragedTokenDeployer.deploy(from_=deployer)
    ReservePoolDeployer.deploy(from_=deployer)
    MinterDeployer.deploy(from_=deployer)
    BaseStabilityPoolDeployer.deploy(from_=deployer)
    StabilityPoolCollateralDeployer.deploy(from_=deployer)
    StabilityPoolLeveragedDeployer.deploy(from_=deployer)
    StabilityPoolManagerDeployer.deploy(from_=deployer)
    GenesisDeployer.deploy(from_=deployer)

    # Deploy HarborAutoDeployment (44KB)
    harbor = cast(Any, HarborAutoDeployment.deploy(from_=deployer))

    # Deploy minter (auto-deploys all dependencies)
    minter_tx = harbor.deployMinterFromConfig()
    minter_tx.wait()
    minter_addr = minter_tx.return_value

    # Verify deployment
    assert minter_addr != Address("0x0000000000000000000000000000000000000000")
    assert harbor.hasMinter()

    # Verify auto-deployed dependencies
    assert harbor.hasAdmin()
    assert harbor.hasOracle()
    assert harbor.hasCollateralToken()
    assert harbor.hasPeggedToken()
    assert harbor.hasLeveragedToken()
    assert harbor.hasReservePool()
    assert harbor.hasFeeReceiver()

    print("✅ Full Harbor system deployed successfully!")
    print(f"✅ Minter deployed at: {minter_addr}")
