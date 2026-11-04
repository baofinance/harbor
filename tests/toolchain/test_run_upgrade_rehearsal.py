"""`script/verify/v3-upgrade/run-upgrade-rehearsal` rehearses the pegs named on one anvil session, one after another:
`--peg` takes one peg, several separated by commas, or `*` for every peg production configures, each the
`ConfigPeg_<peg>.sol` in `script/config/pegs`. A peg with no config there is refused by name. Each peg's records go to
`tmp/v3-upgrade/<peg>/`: the runner names that directory to the capture tests as RECORDS_DIR, and compares what they
wrote there.

Hermetic: a copy of the runner runs in a made-up tree holding peg configs and a mainnet state file. The peg forms are
checked with `--dry-run`, which prints what the run would cover and exits before forking, upgrading or writing anything.
A whole rehearsal runs under a pseudo-terminal, since the runner prompts on the terminal before its anvil steps:
`script/verify/run-campaign-test`, `script/upgrade`, `cast` and `meld` are stubs that record what they are handed, and
the campaign-test stub writes the log forge would and the records the two capture tests write.
"""

import os
import pty
import re
import select
import shutil
import signal
import stat
import subprocess
import time
from pathlib import Path

HARBOR = Path(__file__).resolve().parents[2]
RUNNER = HARBOR / "script" / "verify" / "v3-upgrade" / "run-upgrade-rehearsal"

# Stands in for forge running one campaign test. It writes the step's log as forge would, and, for the two capture
# tests, what they write: a minter record per market under the directory RECORDS_DIR names - or under STUB_RECORDS_ROOT
# when set, as a capture test that ignores RECORDS_DIR writes. Without RECORDS_DIR it fails as the tests do, and the
# expected-after fails without the before and after records it reads.
CAMPAIGN_TEST_STUB = """#!/usr/bin/env bash
log="$2"
shift 2
contract=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --mc ]]; then
    contract=$2
  fi
  shift
done
echo "run-campaign-test $contract RECORDS_DIR=${RECORDS_DIR-unset} VERSION=${VERSION-unset} UPGRADE_PEG=$UPGRADE_PEG UPGRADE_COLLATERAL=$UPGRADE_COLLATERAL" >>"$STUB_LOG"
mkdir -p "$(dirname "$log")"
if [[ "$contract" == MarketsCapture || "$contract" == MarketsExpectedAfter ]]; then
  if [[ -z "${RECORDS_DIR:-}" ]]; then
    echo '[FAIL: vm.envString: environment variable "RECORDS_DIR" not found]' | tee "$log"
    exit 1
  fi
  root="${STUB_RECORDS_ROOT:-$RECORDS_DIR}"
  label="$UPGRADE_PEG::$UPGRADE_COLLATERAL::minter"
  if [[ "$contract" == MarketsCapture ]]; then
    mkdir -p "$root/$VERSION/pre"
    printf '{"peg": "%s", "collateral": "%s"}\\n' "$UPGRADE_PEG" "$UPGRADE_COLLATERAL" >"$root/$VERSION/pre/$label.json"
  else
    for version in before after; do
      [[ -f "$root/$version/pre/$label.json" ]] || {
        echo "[FAIL: vm.readFile: $root/$version/pre/$label.json: No such file or directory]" | tee "$log"
        exit 1
      }
    done
    mkdir -p "$root/expected-after/pre"
    cp "$root/before/pre/$label.json" "$root/expected-after/pre/$label.json"
  fi
fi
echo "Ran 1 test suite in 1.00s (1.00s CPU time): 1 tests passed, 0 failed, 0 skipped (1 total tests)" >"$log"
"""

# anvil's head, as the runner reads it: a block number, then that block's timestamp
CAST_STUB = """#!/usr/bin/env bash
echo "cast $*" >>"$STUB_LOG"
case "$1" in
  block-number) echo 100 ;;
  block) echo 1700000000 ;;
esac
"""

RECORDS_COMPARED = "✅ PASS: each contract reads after the upgrade as it did before, or as expected"


def write_executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def tree(tmp_path: Path) -> Path:
    """A tree holding a copy of the runner, the peg configs AAA and BBB, and a mainnet state file; its root."""
    root = tmp_path / "harbor"
    campaign = root / "script" / "verify" / "v3-upgrade"
    campaign.mkdir(parents=True)
    shutil.copy(RUNNER, campaign / "run-upgrade-rehearsal")
    pegs = root / "script" / "config" / "pegs"
    pegs.mkdir(parents=True)
    for name in ("ConfigPeg.sol", "ConfigPeg_AAA.sol", "ConfigPeg_BBB.sol"):
        (pegs / name).write_text("// a peg config\n")
    mainnet = root / "deployments" / "mainnet"
    mainnet.mkdir(parents=True)
    (mainnet / "harbor_v1.state.json").write_text("{}\n")
    return root


def run(tmp_path: Path, *arguments: str) -> tuple[subprocess.CompletedProcess, Path]:
    """Run a copy of the runner from the tree, and return the tree's root."""
    root = tree(tmp_path)
    done = subprocess.run(
        [str(root / "script" / "verify" / "v3-upgrade" / "run-upgrade-rehearsal"), *arguments],
        input="",
        capture_output=True,
        text=True,
        check=False,
    )
    return done, root


def rehearse(
    tmp_path: Path, *arguments: str, stub_environment: dict[str, str] | None = None
) -> tuple[int, str, Path, list[str]]:
    """Run a copy of the runner through a whole rehearsal under a pseudo-terminal, answering its one prompt, and return
    its exit status, everything it printed, the tree's root and each line the stubs logged."""
    root = tree(tmp_path)
    write_executable(root / "script" / "verify" / "run-campaign-test", CAMPAIGN_TEST_STUB)
    write_executable(root / "script" / "upgrade", '#!/usr/bin/env bash\necho "upgrade $*" >>"$STUB_LOG"\n')
    stubs = tmp_path / "stubs"
    write_executable(stubs / "cast", CAST_STUB)
    write_executable(stubs / "meld", '#!/usr/bin/env bash\necho "meld $*" >>"$STUB_LOG"\n')
    log = tmp_path / "stub.log"
    environment = {
        **os.environ,
        "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}",
        "STUB_LOG": str(log),
        **(stub_environment or {}),
    }
    runner = root / "script" / "verify" / "v3-upgrade" / "run-upgrade-rehearsal"

    pid, terminal = pty.fork()
    if pid == 0:
        try:
            os.execve(str(runner), [str(runner), *arguments], environment)
        finally:
            os._exit(127)
    output = b""
    answered = False
    deadline = time.monotonic() + 60
    while True:
        if time.monotonic() > deadline:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            raise AssertionError("the runner did not finish in 60s:\n" + output.decode(errors="replace"))
        readable, _, _ = select.select([terminal], [], [], 1)
        if not readable:
            continue
        try:
            chunk = os.read(terminal, 4096)
        except OSError:  # Linux: the read fails once the runner has exited and closed its side
            break
        if not chunk:  # macOS: end of file
            break
        output += chunk
        if not answered and b"Ready?" in output:
            os.write(terminal, b"y")
            answered = True
    os.close(terminal)
    _, status = os.waitpid(pid, 0)
    lines = log.read_text().splitlines() if log.exists() else []
    return os.waitstatus_to_exitcode(status), output.decode(errors="replace"), root, lines


def test_a_star_names_every_peg_configured_in_file_order(tmp_path: Path) -> None:
    done, root = run(tmp_path, "--peg", "*", "--collateral", "*", "--dry-run")

    assert done.returncode == 0, done.stderr
    assert re.search(r"Markets:\s+AAA::\*, BBB::\*", done.stdout), done.stdout
    assert re.search(r"Records:\s+tmp/v3-upgrade/<peg>/", done.stdout), done.stdout
    assert "Dry run" in done.stdout
    assert not (root / "tmp").exists()


def test_several_pegs_run_in_the_order_given(tmp_path: Path) -> None:
    done, _ = run(tmp_path, "--peg", "BBB,AAA", "--collateral", "stETH", "--dry-run")

    assert done.returncode == 0, done.stderr
    assert re.search(r"Markets:\s+BBB::stETH, AAA::stETH", done.stdout), done.stdout


def test_one_peg_still_names_its_markets(tmp_path: Path) -> None:
    done, _ = run(tmp_path, "--peg", "aaa", "--collateral", "*", "--dry-run")

    assert done.returncode == 0, done.stderr
    assert re.search(r"Markets:\s+AAA::\*\n", done.stdout), done.stdout


def test_a_peg_with_no_config_is_refused_by_name(tmp_path: Path) -> None:
    done, root = run(tmp_path, "--peg", "AAA,ZZZ", "--collateral", "*", "--dry-run")

    assert done.returncode == 1
    assert "ZZZ" in done.stderr and "script/config/pegs" in done.stderr, done.stderr
    assert not (root / "tmp").exists()


def test_each_pegs_records_are_written_to_and_compared_in_its_own_folder(tmp_path: Path) -> None:
    """Every campaign step of a peg is given the peg's folder as RECORDS_DIR, and the runner compares the expected
    after with the after there, finding that peg's market and no other."""
    status, output, root, lines = rehearse(tmp_path, "--peg", "BBB,AAA", "--collateral", "stETH")

    assert status == 0, output
    for peg in ("BBB", "AAA"):
        steps = [line for line in lines if line.startswith("run-campaign-test ") and f" UPGRADE_PEG={peg} " in line]
        assert len(steps) == 8, steps
        assert all(f" RECORDS_DIR=tmp/v3-upgrade/{peg} " in step for step in steps), steps
        compare = root / "tmp" / "v3-upgrade" / peg / "compare"
        for side in ("expected-after", "after"):
            assert [file.name for file in (compare / side / "pre").iterdir()] == [f"{peg}::stETH::minter.json"]
    assert output.count(RECORDS_COMPARED) == 2, output


def test_a_capture_that_leaves_no_records_in_the_pegs_folder_stops_the_run(tmp_path: Path) -> None:
    """A capture test that writes its records elsewhere leaves the peg's folder without them: the run stops there,
    naming the folder that does not exist, rather than reporting differences between folders that are not there."""
    status, output, _, _ = rehearse(
        tmp_path, "--peg", "AAA", "--collateral", "stETH", stub_environment={"STUB_RECORDS_ROOT": "tmp/v3-upgrade"}
    )

    assert status == 1, output
    assert "ERROR: tmp/v3-upgrade/AAA/expected-after does not exist" in output, output
    assert "differences printed above" not in output, output
