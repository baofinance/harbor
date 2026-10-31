"""`script/anvil` makes `deployments/local/mainnet/` a copy of `deployments/mainnet/` when it forks any block but the
factory's. A state file an earlier node left there records contracts the new node does not hold, and a run reading it
would be refused as a duplicate of its own deployments.

Hermetic: a copy of the script runs beside a made-up `deployments/` folder, which it finds relative to itself, and
`anvil` is a stub on PATH that records what it is handed instead of forking anything. A named block needs no lookup,
so `cast` is never run.
"""

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

HARBOR = Path(__file__).resolve().parents[2]
ANVIL_SCRIPT = HARBOR / "script" / "anvil"

MAINNET_FILE = {"saltPrefix": "harbor_v1", "writtenBy": "a mainnet run"}
EARLIER_LOCAL_FILE = {"saltPrefix": "harbor_v1", "writtenBy": "an earlier node"}
LOCAL_ONLY_FILE = {"saltPrefix": "pre1_3", "writtenBy": "an earlier node"}


def run(tmp_path: Path, answer: str, *arguments: str) -> tuple[subprocess.CompletedProcess, Path, list[str]]:
    """Run a copy of the script beside a deployments folder, answering its one prompt, and return the local state
    folder and each line the stub logged.

    mainnet holds one state file; local holds an older copy of it, a file of its own, and a batch folder.
    """
    root = tmp_path / "harbor"
    (root / "script").mkdir(parents=True)
    script = root / "script" / "anvil"
    shutil.copy(ANVIL_SCRIPT, script)
    mainnet = root / "deployments" / "mainnet"
    local = root / "deployments" / "local" / "mainnet"
    mainnet.mkdir(parents=True)
    (local / "batch").mkdir(parents=True)
    (mainnet / "harbor_v1.state.json").write_text(json.dumps(MAINNET_FILE))
    (local / "harbor_v1.state.json").write_text(json.dumps(EARLIER_LOCAL_FILE))
    (local / "pre1_3.state.json").write_text(json.dumps(LOCAL_ONLY_FILE))
    (local / "batch" / "Deploy.json").write_text("{}")

    stubs = tmp_path / "stubs"
    stubs.mkdir()
    stub = stubs / "anvil"
    stub.write_text('#!/usr/bin/env bash\necho "anvil $*" >> "$STUB_LOG"\n')
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)

    log = tmp_path / "stub.log"
    done = subprocess.run(
        [str(script), *arguments],
        input=answer,
        env={**os.environ, "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}", "STUB_LOG": str(log)},
        capture_output=True,
        text=True,
        check=False,
    )
    lines = log.read_text().splitlines() if log.exists() else []
    return done, local, lines


def state_files(local: Path) -> dict[str, dict]:
    return {file.name: json.loads(file.read_text()) for file in sorted(local.glob("*.json"))}


def test_a_fork_of_another_block_replaces_the_local_state_files_with_mainnets(tmp_path: Path) -> None:
    done, local, lines = run(tmp_path, "y", "--block", "rebalance-exploit")

    assert done.returncode == 0, done.stderr
    # mainnet's file replaces the older copy, the file mainnet has no counterpart of goes, and so do the batches
    assert state_files(local) == {"harbor_v1.state.json": MAINNET_FILE}
    assert not (local / "batch").exists()
    assert lines[0].startswith("anvil ") and "--fork-block-number" in lines[0]


def test_declining_leaves_the_local_state_files_as_they_were(tmp_path: Path) -> None:
    done, local, lines = run(tmp_path, "n", "--block", "rebalance-exploit")

    assert done.returncode == 0, done.stderr
    assert state_files(local) == {"harbor_v1.state.json": EARLIER_LOCAL_FILE, "pre1_3.state.json": LOCAL_ONLY_FILE}
    assert (local / "batch" / "Deploy.json").exists()
    assert lines[0].startswith("anvil ")


def test_a_fork_of_the_factory_block_deletes_the_local_state_files(tmp_path: Path) -> None:
    done, local, lines = run(tmp_path, "y", "--block", "factory")

    assert done.returncode == 0, done.stderr
    assert state_files(local) == {}
    assert not (local / "batch").exists()
    assert lines[0].startswith("anvil ")
