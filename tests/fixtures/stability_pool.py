"""Stability pool deployment fixtures for Wake tests."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from pytypes.lib.baobase.src.interfaces.IBaoRoles import IBaoRoles
from pytypes.lib.baobase.src.MintableBurnableERC20_v1 import MintableBurnableERC20_v1
from pytypes.lib.baobase.src.TokenHolder import TokenHolder
from pytypes.lib.baominter.src.interfaces.IMultipleRewardAccumulator import IMultipleRewardAccumulator
from pytypes.lib.baominter.src.interfaces.IMultipleRewardDistributor import IMultipleRewardDistributor
from pytypes.lib.baominter.src.minter.StabilityPool_v1 import StabilityPool_v1
from pytypes.test.mocks.MockERC20 import MockERC20
from wake.development.core import Wei  # type: ignore[import]
from wake.testing import default_chain  # type: ignore[import]

from ..harbor_deployment_wake import HarborDeploymentWake

EARLY_WITHDRAWAL_FEE = Wei.from_ether(0.02)
MIN_TOTAL_SUPPLY = Wei.from_ether(1)
UINT256_MAX = (1 << 256) - 1
SECONDS_IN_DAY = 24 * 60 * 60


@dataclass(slots=True)
class StabilityPoolContext:
    """Aggregated handles for interacting with the deployed stability pool."""

    harbor: Any
    stability_pool: StabilityPool_v1
    pegged_token: MintableBurnableERC20_v1
    liquidation_token: MockERC20
    reward_accumulator: IMultipleRewardAccumulator
    reward_distributor: IMultipleRewardDistributor
    token_holder: TokenHolder
    deployer: Any
    owner: Any
    fee_recipient: Any
    fee_exempt: Any
    depositor: Any
    depositor_two: Any
    rebalancer: Any
    reward_depositor: Any


def deploy_stability_pool_environment() -> StabilityPoolContext:
    """Deploy Harbor and the stability pool, returning a rich test context."""

    deployer = default_chain.accounts[0]
    fee_exempt = default_chain.accounts[1]
    depositor = default_chain.accounts[2]
    depositor_two = default_chain.accounts[3]
    rebalancer = default_chain.accounts[4]
    reward_depositor = default_chain.accounts[5]
    fee_recipient = default_chain.accounts[6]
    reward_manager = default_chain.accounts[7]

    harbor = HarborDeploymentWake.deploy(deployer)
    harbor.useAdmin(deployer.address, from_=deployer)
    harbor.useFeeReceiver(fee_recipient.address, from_=deployer)
    harbor.useRebalancer(rebalancer.address, from_=deployer)
    harbor.useRewardDepositor(reward_depositor.address, from_=deployer)
    harbor.useRewardManager(reward_manager.address, from_=deployer)

    harbor.setStabilityPoolEarlyWithdrawalFee(EARLY_WITHDRAWAL_FEE, from_=deployer)

    stability_pool_tx = harbor.deployStabilityPoolCollateralFromConfig(from_=deployer)
    stability_pool_tx.wait()
    stability_pool_address = stability_pool_tx.return_value
    pegged_token_address = harbor.getPeggedToken()
    liquidation_token_address = harbor.getCollateralToken()

    finalize_tx = harbor.finalizeDeploymentOwnership(from_=deployer)
    finalize_tx.wait()
    transfers = finalize_tx.return_value
    assert transfers is not None
    assert transfers > 0

    stability_pool = StabilityPool_v2(stability_pool_address)
    pegged_token = MintableBurnableERC20_v1(pegged_token_address)
    liquidation_token = MockERC20(liquidation_token_address)
    reward_accumulator = IMultipleRewardAccumulator(stability_pool.address)
    reward_distributor = IMultipleRewardDistributor(stability_pool.address)
    token_holder = TokenHolder(stability_pool.address)

    grant_fee_exempt_tx = IBaoRoles(stability_pool.address).grantRoles(
        fee_exempt.address,
        stability_pool.EXEMPT_WITHDRAWAL_FEE_ROLE(),
        from_=deployer,
    )
    grant_fee_exempt_tx.wait()

    grant_minter_tx = IBaoRoles(pegged_token.address).grantRoles(
        deployer.address,
        pegged_token.MINTER_ROLE(),
        from_=deployer,
    )
    grant_minter_tx.wait()

    return StabilityPoolContext(
        harbor=harbor,
        stability_pool=stability_pool,
        pegged_token=pegged_token,
        liquidation_token=liquidation_token,
        reward_accumulator=reward_accumulator,
        reward_distributor=reward_distributor,
        token_holder=token_holder,
        deployer=deployer,
        owner=deployer,
        fee_recipient=fee_recipient,
        fee_exempt=fee_exempt,
        depositor=depositor,
        depositor_two=depositor_two,
        rebalancer=rebalancer,
        reward_depositor=reward_depositor,
    )
