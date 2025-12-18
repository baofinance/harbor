"""Pegged token deployment fixtures for Wake tests."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from pytypes.lib.baobase.src.MintableBurnableERC20_v1 import MintableBurnableERC20_v1
from wake.testing import default_chain  # type: ignore[import]

from ..harbor_deployment_wake import HarborDeploymentWake


@dataclass(slots=True)
class PeggedTokenContext:
    """Handles for interacting with the deployed pegged token."""

    harbor: Any
    pegged_token: MintableBurnableERC20_v1
    deployer: Any
    admin: Any
    fee_receiver: Any


def deploy_pegged_token_environment() -> PeggedTokenContext:
    """Deploy Harbor and its pegged token, returning a reusable test context."""

    deployer = default_chain.accounts[0]
    fee_receiver = default_chain.accounts[1]

    harbor = HarborDeploymentWake.deploy(deployer)
    harbor.useAdmin(deployer.address, from_=deployer)
    harbor.useFeeReceiver(fee_receiver.address, from_=deployer)

    pegged_tx = harbor.deployPeggedTokenFromConfig(from_=deployer)
    pegged_tx.wait()
    pegged_address = pegged_tx.return_value

    finalize_tx = harbor.finalizeDeploymentOwnership(from_=deployer)
    finalize_tx.wait()

    pegged_token = MintableBurnableERC20_v1(pegged_address)

    return PeggedTokenContext(
        harbor=harbor,
        pegged_token=pegged_token,
        deployer=deployer,
        admin=deployer,
        fee_receiver=fee_receiver,
    )
