"""`script/decode-safe-batch` names every address a batch carries from the state file beside the batch.

A batch is written under `deployments/<network>/batch/` - or `deployments/local/<network>/batch/` by a rehearsal -
and the deployments it names are recorded in `<salt prefix>.state.json` next to that directory, the salt prefix
being the batch's meta name, which the deployer writes. The decoder reads that file, not a fixed one, so a
rehearsal's batch is named from the rehearsal's state and a mainnet batch from mainnet's. An implementation is named
by its contract, source file, the proxy it serves - or "one-shot" for a contract recorded under `*`, an upgrader or a
frozen oracle - and its deploy time; a proxy by its key.

Hermetic: the batch, the state file and the artifacts the decoder reads selectors from are all written under the
test's own directory, so nothing here depends on a build or on a network.
"""

import json
import subprocess
from pathlib import Path

HARBOR = Path(__file__).resolve().parents[2]
DECODER = HARBOR / "script" / "decode-safe-batch"

MINTER_PROXY = "0xF42516EB885E737780EB864dd07cEc8628000919"
MINTER_V3 = "0x8456B26323214F263AB269B673fd2a110A0f4A98"
FROZEN_ORACLE = "0xf946DDD606bD17C6Ff2DBFcAB573ee8806d86C7a"

UPGRADE_TO_AND_CALL = "4f1ef286"
UPDATE_PRICE_ORACLE = "39d1fc82"


def word(hex_value: str) -> str:
    return hex_value.lower().removeprefix("0x").rjust(64, "0")


def upgrade_to_and_call(implementation: str) -> str:
    """`upgradeToAndCall(implementation, "")`: the address, the offset of the empty bytes, its length."""
    return "0x" + UPGRADE_TO_AND_CALL + word(implementation) + word("40") + word("0")


def update_price_oracle(oracle: str) -> str:
    return "0x" + UPDATE_PRICE_ORACLE + word(oracle)


def write_deployment(
    root: Path, network_dir: str, state_file: str | None = "harbor_v1", name: str | None = "harbor_v1"
) -> Path:
    """A deployments tree under `root`: the batch under `<network_dir>/batch/`, named `name` in its meta, and the
    state file `<state_file>.state.json` beside it - none where either is None."""
    deployment = root / "deployments" / network_dir
    batches = deployment / "batch"
    batches.mkdir(parents=True)
    state = {
        "implementations": {
            MINTER_V3: {
                "proxy": "BTC::stETH::minter",
                "contractSource": "@harbor/minter/Minter_v3.sol",
                "contractType": "Minter_v3",
                "deploymentTime": "2026-10-28T17:17:59Z",
            },
            FROZEN_ORACLE: {
                "proxy": "*",
                "contractSource": "@harbor-script/UpgradeMinter_v2_v3/FrozenPriceOracle.sol",
                "contractType": "FrozenPriceOracle",
                "deploymentTime": "2026-10-28T17:18:01Z",
            },
        },
        "proxies": {"BTC::stETH::minter": {"address": MINTER_PROXY}},
    }
    if state_file is not None:
        (deployment / f"{state_file}.state.json").write_text(json.dumps(state))
    batch = batches / "Upgrade_MarketsToV3_mainnet_BTC::stETH@harbor_multisig.json"
    meta = {"description": "BTC::stETH: upgrade"}
    if name is not None:
        meta["name"] = name
    batch.write_text(
        json.dumps(
            {
                "version": "1.0",
                "chainId": "1",
                "meta": meta,
                "transactions": [
                    {"to": MINTER_PROXY, "value": "0", "data": upgrade_to_and_call(MINTER_V3)},
                    {"to": MINTER_PROXY, "value": "0", "data": update_price_oracle(FROZEN_ORACLE)},
                ],
            }
        )
    )
    return batch


def write_artifacts(root: Path) -> Path:
    """The one artifact the decoder needs: the selectors of the two calls the batch makes."""
    artifacts = root / "artifacts" / "Calls.sol"
    artifacts.mkdir(parents=True)
    (artifacts / "Calls.json").write_text(
        json.dumps(
            {
                "methodIdentifiers": {
                    "upgradeToAndCall(address,bytes)": UPGRADE_TO_AND_CALL,
                    "updatePriceOracle(address)": UPDATE_PRICE_ORACLE,
                }
            }
        )
    )
    return root / "artifacts"


def decode(batch: Path, artifacts: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(DECODER), "-o", str(artifacts), str(batch)],
        cwd=HARBOR,
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )


def test_names_every_address_from_the_state_file_beside_the_batch(tmp_path: Path) -> None:
    batch = write_deployment(tmp_path, "local/mainnet")

    done = decode(batch, write_artifacts(tmp_path))

    assert done.returncode == 0, done.stderr
    assert f"to:       {MINTER_PROXY}  // BTC::stETH::minter (proxy)" in done.stdout
    assert (
        f"newImplementation: {MINTER_V3}  // Minter_v3 - @harbor/minter/Minter_v3.sol, "
        "impl for BTC::stETH::minter, deployed 2026-10-28T17:17:59Z" in done.stdout
    )
    assert (
        f"{FROZEN_ORACLE}  // FrozenPriceOracle - @harbor-script/UpgradeMinter_v2_v3/FrozenPriceOracle.sol, "
        "one-shot, deployed 2026-10-28T17:18:01Z" in done.stdout
    )
    assert "harbor_v1.state.json" in done.stderr


def test_a_batch_whose_salt_prefix_has_no_state_file_beside_it_is_refused(tmp_path: Path) -> None:
    batch = write_deployment(tmp_path, "mainnet", state_file="other_v1", name="harbor_v1")

    done = decode(batch, write_artifacts(tmp_path))

    assert done.returncode != 0
    assert str(batch.parent.parent / "harbor_v1.state.json") in done.stderr
    assert "no state file" in done.stderr


def test_a_batch_that_names_no_salt_prefix_is_refused(tmp_path: Path) -> None:
    batch = write_deployment(tmp_path, "mainnet", name=None)

    done = decode(batch, write_artifacts(tmp_path))

    assert done.returncode != 0
    assert str(batch) in done.stderr
    assert "names no salt prefix" in done.stderr
