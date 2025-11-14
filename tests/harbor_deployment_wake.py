# tests/harbor_deployment_wake.py
"""Python wrapper for HarborAutoDeployment in Wake tests.

This wrapper encapsulates the deployment of required libraries (Config_v1 and all
deployer libraries) so that Wake tests have a clean API similar to Foundry tests.

Usage:
    from tests.harbor_deployment_wake import HarborDeploymentWake

    @chain.connect()
    def test_something():
        deployer = default_chain.accounts[0]
        harbor = HarborDeploymentWake.deploy(deployer)
        # Use harbor like normal HarborAutoDeployment
"""

import re
from pathlib import Path
from types import MappingProxyType
from typing import Any, cast

from pytypes.harbortemp.script.deployers.BaseStabilityPoolDeployer import BaseStabilityPoolDeployer
from pytypes.harbortemp.script.deployers.FeeReceiverDeployer import FeeReceiverDeployer
from pytypes.harbortemp.script.deployers.GenesisDeployer import GenesisDeployer
from pytypes.harbortemp.script.deployers.LeveragedTokenDeployer import LeveragedTokenDeployer

# Import all deployer libraries. Import ordering follows deployment order to keep
# console output grouped.
from pytypes.harbortemp.script.deployers.MinterDeployer import MinterDeployer
from pytypes.harbortemp.script.deployers.PeggedTokenDeployer import PeggedTokenDeployer
from pytypes.harbortemp.script.deployers.ReservePoolDeployer import ReservePoolDeployer
from pytypes.harbortemp.script.deployers.StabilityPoolCollateralDeployer import StabilityPoolCollateralDeployer
from pytypes.harbortemp.script.deployers.StabilityPoolLeveragedDeployer import StabilityPoolLeveragedDeployer
from pytypes.harbortemp.script.deployers.StabilityPoolManagerDeployer import StabilityPoolManagerDeployer
from pytypes.harbortemp.script.HarborAutoDeployment import HarborAutoDeployment
from pytypes.lib.baominter.src.minter.library.Config_v1 import Config_v1


def _load_harbor_key_classes():
    """Parse `HarborKeys.sol` so Python stays in sync with the contract source."""

    harbor_root = Path(__file__).resolve().parents[1] / "src" / "harbor"
    source_path = harbor_root / "HarborKeys.sol"
    pattern = re.compile(r'string\s+internal\s+constant\s+(\w+)\s*=\s*"([^"]+)"\s*;')

    if not source_path.exists():
        raise FileNotFoundError(f"HarborKeys source not found at {source_path}")

    section = None
    contracts: dict[str, str] = {}
    parameters: dict[str, str] = {}

    for line in source_path.read_text().splitlines():
        if "Contract Keys" in line:
            section = "contracts"
            continue
        if "Test-only contract keys" in line:
            section = "contracts"
            continue
        if "Parameter Keys" in line:
            section = "parameters"
            continue

        match = pattern.search(line)
        if not match:
            continue
        key, value = match.groups()
        if section == "contracts":
            contracts[key] = value
        elif section == "parameters":
            parameters[key] = value

    if not contracts or not parameters:
        raise ValueError("Failed to parse HarborKeys constants")

    def _build_class(name: str, values: dict[str, str]):
        namespace = {**values, "__slots__": ()}
        namespace["_mapping"] = MappingProxyType(values.copy())
        return type(name, (), namespace)

    return _build_class("Contracts", contracts), _build_class("Parameters", parameters)


class HarborDeploymentWake:
    """Wrapper for HarborAutoDeployment that handles library deployment.

    This class provides a clean interface for Wake tests by automatically deploying
    all required libraries (Config_v1 and deployer libraries) before deploying
    HarborAutoDeployment.

    In Foundry, libraries are auto-linked at compile time. In Wake, they must be
    manually deployed. This wrapper provides consistency across test frameworks.

    Example:
        deployer = default_chain.accounts[0]
        harbor = HarborDeploymentWake.deploy(deployer)
        minter_tx = harbor.deployMinterFromConfig()
        minter_tx.wait()
        minter = minter_tx.return_value
        assert harbor.getMinter() == minter
        assert harbor.hasMinter()
    """

    Contracts, Parameters = _load_harbor_key_classes()

    @staticmethod
    def deploy_required_libraries(deployer, *, verbose: bool = False):
        """Deploy Config_v1 and all Harbor deployer libraries.

        Wake requires explicit deployment for every linked library. This
        helper centralizes the sequence so tests can reuse it without
        duplicating boilerplate.
        """

        def _log(message: str):
            if verbose:
                print(message)

        _log("Deploying Config_v1 library...")
        Config_v1.deploy(from_=deployer)

        _log("Deploying deployer libraries...")
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

    @staticmethod
    def deploy(deployer):
        """Deploy HarborAutoDeployment with all required libraries.

        Args:
            deployer: The account to deploy from (typically default_chain.accounts[0])

        Returns:
            HarborAutoDeployment instance with all libraries deployed

        Example:
            deployer = default_chain.accounts[0]
            harbor = HarborDeploymentWake.deploy(deployer)
            minter_tx = harbor.deployMinterFromConfig()
            minter_tx.wait()
            minter = minter_tx.return_value
            assert harbor.getMinter() == minter
            assert harbor.hasMinter()
        """
        HarborDeploymentWake.deploy_required_libraries(deployer)

        # Deploy HarborAutoDeployment (44KB contract after library decomposition)
        harbor = cast(Any, HarborAutoDeployment.deploy(from_=deployer))

        return harbor

    @staticmethod
    def deploy_with_output(deployer):
        """Deploy with detailed output for debugging.

        Same as deploy() but prints deployment progress.
        Useful for debugging and seeing what's being deployed.
        """
        HarborDeploymentWake.deploy_required_libraries(deployer, verbose=True)

        print("Deploying HarborAutoDeployment...")
        harbor = cast(Any, HarborAutoDeployment.deploy(from_=deployer))
        print(f"HarborAutoDeployment deployed at: {harbor.address}")

        return harbor
