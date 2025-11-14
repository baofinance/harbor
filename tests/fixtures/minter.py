"""Minter deployment fixtures for Wake tests."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from pytypes.lib.baobase.src.MintableBurnableERC20_v1 import MintableBurnableERC20_v1
from pytypes.lib.baominter.src.minter.Minter_v1 import Minter_v1
from pytypes.lib.baominter.src.minter.ReservePool_v1 import ReservePool_v1
from pytypes.test.mocks.MockERC20 import MockERC20
from pytypes.test.mocks.MockWrappedPriceOracle import MockWrappedPriceOracle
from wake.testing import default_chain  # type: ignore[import]

from ..harbor_deployment_wake import HarborDeploymentWake


@dataclass(slots=True)
class MinterContext:
    """Aggregated handles for interacting with a deployed minter stack."""

    harbor: Any
    minter: Minter_v1
    pegged_token: MintableBurnableERC20_v1
    leveraged_token: MintableBurnableERC20_v1
    collateral_token: MockERC20
    reserve_pool: ReservePool_v1
    oracle: MockWrappedPriceOracle
    deployer: Any
    admin: Any
    treasury: Any
    fee_receiver: Any


def deploy_minter_environment() -> MinterContext:
    """Deploy Harbor and its minter dependencies, returning a reusable test context."""

    deployer = default_chain.accounts[0]
    treasury = default_chain.accounts[1]
    fee_receiver = default_chain.accounts[2]

    harbor = HarborDeploymentWake.deploy(deployer)
    harbor.useAdmin(deployer.address, from_=deployer)
    harbor.useTreasury(treasury.address, from_=deployer)
    harbor.useFeeReceiver(fee_receiver.address, from_=deployer)

    minter_tx = harbor.deployMinterFromConfig(from_=deployer)
    minter_tx.wait()
    minter_address = minter_tx.return_value

    finalize_tx = harbor.finalizeDeploymentOwnership(from_=deployer)
    finalize_tx.wait()

    minter = Minter_v1(minter_address)
    pegged_token = MintableBurnableERC20_v1(harbor.getPeggedToken())
    leveraged_token = MintableBurnableERC20_v1(harbor.getLeveragedToken())
    collateral_token = MockERC20(harbor.getCollateralToken())
    reserve_pool = ReservePool_v1(harbor.getReservePool())
    oracle = MockWrappedPriceOracle(harbor.getOracle())

    return MinterContext(
        harbor=harbor,
        minter=minter,
        pegged_token=pegged_token,
        leveraged_token=leveraged_token,
        collateral_token=collateral_token,
        reserve_pool=reserve_pool,
        oracle=oracle,
        deployer=deployer,
        admin=deployer,
        treasury=treasury,
        fee_receiver=fee_receiver,
    )
