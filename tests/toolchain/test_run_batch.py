"""`script/run-batch` sends each call of a Safe batch file to anvil as its own transaction, from the owner of the first
call's target, in the file's order. It stops at the first call that fails, as a Safe stops the whole batch: the calls
after it are not sent.

Hermetic: `cast` is a stub on the PATH that records each command it is handed. It answers `owner()` with one address,
and fails the `cast send` to the target that STUB_FAILING_TARGET names, with a revert message on stderr.
"""

import json
import os
import stat
import subprocess
from pathlib import Path

HARBOR = Path(__file__).resolve().parents[2]
RUN_BATCH = HARBOR / "script" / "run-batch"

OWNER = "0x000000000000000000000000000000000000dEaD"
REVERT = "execution reverted: NotEnoughBalance"

CAST_STUB = f"""#!/usr/bin/env bash
echo "cast $*" >>"$STUB_LOG"
case "$1" in
  call) echo {OWNER} ;;
  send)
    if [[ "$2" == "${{STUB_FAILING_TARGET:-}}" ]]; then
      echo "Error: server returned an error response: error code 3: {REVERT}" >&2
      exit 1
    fi
    echo "status 1 (success)"
    ;;
esac
"""


def target(index: int) -> str:
    """The address of call `index`, counted from 1."""
    return f"0x{index:040x}"


def batch(tmp_path: Path, count: int) -> Path:
    """A batch file of `count` calls: call i goes to target(i), with data 0x<i> and value i."""
    file = tmp_path / "batch.json"
    transactions = [{"to": target(i), "data": f"0x{i:08x}", "value": str(i)} for i in range(1, count + 1)]
    file.write_text(json.dumps({"chainId": "1", "meta": {"description": "a test batch"}, "transactions": transactions}))
    return file


def run_batch(
    tmp_path: Path, batch_file: Path, failing_target: str = ""
) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    """Run `script/run-batch` on the file, and return what it did and each `cast send` the stub was handed."""
    stubs = tmp_path / "stubs"
    stubs.mkdir()
    cast = stubs / "cast"
    cast.write_text(CAST_STUB)
    cast.chmod(cast.stat().st_mode | stat.S_IXUSR)
    log = tmp_path / "stub.log"
    environment = {
        **os.environ,
        "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}",
        "STUB_LOG": str(log),
        "STUB_FAILING_TARGET": failing_target,
    }
    done = subprocess.run(
        [str(RUN_BATCH), str(batch_file)], capture_output=True, text=True, env=environment, check=False
    )
    lines = log.read_text().splitlines() if log.exists() else []
    return done, [line for line in lines if line.startswith("cast send ")]


def test_every_call_is_sent_in_order_from_the_owner_of_the_first_target(tmp_path: Path) -> None:
    """Each call goes to `cast send` once, in the file's order, with its own data and value, from `owner()` of the
    first call's target."""
    done, sends = run_batch(tmp_path, batch(tmp_path, 3))

    assert done.returncode == 0, done.stderr
    assert len(sends) == 3, sends
    for i, send in enumerate(sends, start=1):
        assert send.startswith(f"cast send {target(i)} 0x{i:08x} "), send
        assert f"--from {OWNER} --unlocked" in send, send
        assert f"--value {i} " in send, send


def test_a_failed_call_stops_the_batch(tmp_path: Path) -> None:
    """Call 2 of 3 fails: call 3 is not sent, the run exits 1, and it says where it stopped and how many calls it did
    not send."""
    done, sends = run_batch(tmp_path, batch(tmp_path, 3), failing_target=target(2))

    assert done.returncode == 1, done.stderr
    assert [send.split()[2] for send in sends] == [target(1), target(2)], sends
    assert "FAILED at call 2 of 3" in done.stderr, done.stderr
    assert "Not sent: 1" in done.stderr, done.stderr


def test_a_failed_call_is_sent_once_and_its_own_error_is_shown(tmp_path: Path) -> None:
    """The failed call is not sent a second time to show its error: the first attempt's own output is printed."""
    done, sends = run_batch(tmp_path, batch(tmp_path, 3), failing_target=target(2))

    assert [send.split()[2] for send in sends].count(target(2)) == 1, sends
    assert REVERT in done.stderr, done.stderr
