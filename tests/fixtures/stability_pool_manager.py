"""Stability pool manager deployment fixtures for Wake tests."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from pytypes.lib.baominter.src.minter.StabilityPool_v1 import StabilityPool_v1
from pytypes.lib.baominter.src.minter.StabilityPoolManager_v1 import StabilityPoolManager_v1
from wake.testing import default_chain  # type: ignore[import]

from .minter import MinterContext, deploy_minter_environment


@dataclass(slots=True)
class StabilityPoolManagerContext:
    """Aggregated handles for collateral + leveraged pools managed together."""

    minter: MinterContext
    collateral_pool: StabilityPool_v1
    leveraged_pool: StabilityPool_v1
    manager: StabilityPoolManager_v1
    reward_manager: Any
    reward_depositor: Any
    rebalancer: Any


def deploy_stability_pool_manager_environment() -> StabilityPoolManagerContext:
    """Deploy Harbor, stability pools, and the manager, returning a reusable context."""

    minter_ctx = deploy_minter_environment()
    harbor = minter_ctx.harbor
    deployer = minter_ctx.deployer

    reward_manager = default_chain.accounts[3]
    reward_depositor = default_chain.accounts[4]
    rebalancer = default_chain.accounts[5]

    harbor.useRewardManager(reward_manager.address, from_=deployer)
    harbor.useRewardDepositor(reward_depositor.address, from_=deployer)
    harbor.useRebalancer(rebalancer.address, from_=deployer)

    collateral_tx = harbor.deployStabilityPoolCollateralFromConfig(from_=deployer)
    collateral_tx.wait()
    collateral_pool = StabilityPool_v1(collateral_tx.return_value)

    leveraged_tx = harbor.deployStabilityPoolLeveragedFromConfig(from_=deployer)
    leveraged_tx.wait()
    leveraged_pool = StabilityPool_v1(leveraged_tx.return_value)

    manager_tx = harbor.deployStabilityPoolManagerFromConfig(from_=deployer)
    manager_tx.wait()
    manager = StabilityPoolManager_v1(manager_tx.return_value)

    finalize_tx = harbor.finalizeDeploymentOwnership(from_=deployer)
    finalize_tx.wait()

    return StabilityPoolManagerContext(
        minter=minter_ctx,
        collateral_pool=collateral_pool,
        leveraged_pool=leveraged_pool,
        manager=manager,
        reward_manager=reward_manager,
        reward_depositor=reward_depositor,
        rebalancer=rebalancer,
    )
