"""`script/run-script --local` prepares a local anvil fork so that a deploy run can go through to its broadcast.

A local run sends from anvil's default account. BaoFactory deploys only for its owner or an operator, and only its
owner can set an operator, so the run sets one first, sending as the owner: anvil needs no key for that. A local run
also sends legacy transactions, which need no fee estimate: the estimate fails on a fork of an old block.

None of this may reach a real network, where the owner is a multisig and the fees are real.

Hermetic: `cast` and `forge` are stubs on PATH that record what they are handed, and the run's folder is the test's
own, so nothing here depends on a node or on a build.
"""

import os
import re
import stat
import subprocess
from pathlib import Path

HARBOR = Path(__file__).resolve().parents[2]
RUN_SCRIPT = HARBOR / "script" / "run-script"
BAO_BASE = HARBOR / "lib" / "bao-base"

SCRIPT_NAME = "Deploy_EUR_mainnet"
SET_OPERATOR = "setOperator(address,uint256)"
ANVIL_SENDER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
# FactoryDeployer.OPERATOR_ALLOWANCE_MARGIN: a run is refused unless more than this is left of its allowance
OPERATOR_ALLOWANCE_MARGIN_SECONDS = 24 * 60 * 60


def source_address(path: Path, pattern: str) -> str:
    match = re.search(pattern, path.read_text())
    assert match, f"{pattern} not found in {path}"
    return match.group(1)


FACTORY = source_address(
    BAO_BASE / "script" / "deployment" / "FactoryDeployer.sol",
    r"function baoFactory\(\)[^{]*\{(?:\s*//[^\n]*)*\s*return (0x[0-9a-fA-F]{40});",
)
FACTORY_OWNER = source_address(
    BAO_BASE / "lib" / "bao-factory" / "src" / "BaoFactory_v1.sol",
    r"_OWNER = (0x[0-9a-fA-F]{40});",
)


def write_stub(directory: Path, name: str, body: str) -> None:
    stub = directory / name
    stub.write_text(f'#!/usr/bin/env bash\necho "{name} $*" >> "$STUB_LOG"\n{body}\n')
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)


def run(
    tmp_path: Path, *arguments: str, cast_send_exit: int = 0
) -> tuple[subprocess.CompletedProcess, list[list[str]]]:
    """Run the script from a folder holding only what it checks for, and return each command the stubs were handed."""
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    write_stub(stubs, "forge", "")
    write_stub(
        stubs,
        "cast",
        f"""case "$1" in
  chain-id) echo 1 ;;
  send) exit {cast_send_exit} ;;
esac""",
    )
    project = tmp_path / "project"
    (project / "script").mkdir(parents=True)
    (project / "foundry.toml").touch()
    (project / "script" / f"{SCRIPT_NAME}.s.sol").touch()

    log = tmp_path / "stub.log"
    done = subprocess.run(
        [str(RUN_SCRIPT), SCRIPT_NAME, "--network", "mainnet", "--salt", "pre1_3", *arguments],
        cwd=project,
        env={**os.environ, "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}", "STUB_LOG": str(log)},
        capture_output=True,
        text=True,
        check=False,
    )
    commands = [line.split() for line in log.read_text().splitlines()]
    return done, commands


def position(commands: list[list[str]], first_words: list[str]) -> int:
    """Index of the first command starting with these words, or -1."""
    for index, command in enumerate(commands):
        if command[: len(first_words)] == first_words:
            return index
    return -1


def value_of(command: list[str], flag: str) -> str:
    return command[command.index(flag) + 1]


def test_a_local_run_makes_its_sender_an_operator_as_the_factory_owner_before_forge_runs(tmp_path: Path) -> None:
    done, commands = run(tmp_path, "--local", "--broadcast")

    assert done.returncode == 0, done.stderr
    send = position(commands, ["cast", "send"])
    assert send != -1, commands
    command = commands[send]
    assert value_of(command, "--from") == FACTORY_OWNER
    assert "--unlocked" in command
    assert value_of(command, "--rpc-url") == "local"
    arguments = command[command.index(FACTORY) :]
    assert arguments[1:3] == [SET_OPERATOR, ANVIL_SENDER]
    # The allowance is what the deploy's own check accepts, and that check refuses exactly the margin
    assert int(arguments[3]) > OPERATOR_ALLOWANCE_MARGIN_SECONDS
    # The owner has its gas before it sends, and the operator is set before forge deploys
    assert position(commands, ["cast", "rpc", "anvil_setBalance", FACTORY_OWNER]) < send
    assert send < position(commands, ["forge", "script"])


def test_a_local_run_sends_legacy_transactions(tmp_path: Path) -> None:
    done, commands = run(tmp_path, "--local", "--broadcast")

    assert done.returncode == 0, done.stderr
    assert "--legacy" in commands[position(commands, ["cast", "send"])]
    assert "--legacy" in commands[position(commands, ["forge", "script"])]


def test_a_local_run_with_an_account_sets_no_operator(tmp_path: Path) -> None:
    # The sender is then the keystore account, whose address only forge resolves: FactoryDeployer's own check speaks
    # for it, and its broadcast is still a legacy transaction.
    done, commands = run(tmp_path, "--local", "--broadcast", "--account", "deployer")

    assert done.returncode == 0, done.stderr
    assert position(commands, ["cast", "send"]) == -1
    assert "--legacy" in commands[position(commands, ["forge", "script"])]


def test_a_run_on_a_network_sends_as_the_account_and_leaves_the_factory_alone(tmp_path: Path) -> None:
    done, commands = run(tmp_path, "--broadcast", "--account", "deployer")

    assert done.returncode == 0, done.stderr
    assert position(commands, ["cast", "send"]) == -1
    assert position(commands, ["cast", "rpc"]) == -1
    assert "--legacy" not in commands[position(commands, ["forge", "script"])]


def test_a_refused_operator_stops_the_run_before_forge(tmp_path: Path) -> None:
    done, commands = run(tmp_path, "--local", "--broadcast", cast_send_exit=1)

    assert done.returncode != 0
    assert position(commands, ["cast", "send"]) != -1
    assert position(commands, ["forge", "script"]) == -1
