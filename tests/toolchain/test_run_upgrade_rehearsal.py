"""`script/verify/v3-upgrade/run-upgrade-rehearsal` rehearses the pegs named on one anvil session, one after another:
`--peg` takes one peg, several separated by commas, or `*` for every peg production configures, each the
`ConfigPeg_<peg>.sol` in `script/config/pegs`. A peg with no config there is refused by name. Each peg's records go to
`tmp/v3-upgrade/<peg>/`: the runner, and `check-upgraded-markets`, which it runs after each peg's upgrade, name that
directory to the campaign tests as RECORDS_DIR, and the check compares what they wrote there.

Hermetic: copies of the runners run in a made-up tree, with stubs for forge, `script/upgrade`, `cast` and `meld`
(`v3_upgrade_campaign`). The peg forms are checked with `--dry-run`, which prints what the run would cover and exits
before forking, upgrading or writing anything. A whole rehearsal runs under a pseudo-terminal, since the runner prompts
on the terminal before its anvil steps.
"""

import os
import pty
import re
import select
import signal
import subprocess
import time
from pathlib import Path

from .v3_upgrade_campaign import CAMPAIGN, logged, steps, stubbed, tree

RECORDS_COMPARED = "✅ PASS: each contract reads after the upgrade as it did before, or as expected"


def run(tmp_path: Path, *arguments: str) -> tuple[subprocess.CompletedProcess[str], Path]:
    """Run a copy of the runner from the tree, and return the tree's root."""
    root = tree(tmp_path)
    done = subprocess.run(
        [str(root / CAMPAIGN / "run-upgrade-rehearsal"), *arguments],
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
    environment, log = stubbed(tmp_path, root, stub_environment)
    runner = root / CAMPAIGN / "run-upgrade-rehearsal"

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
    return os.waitstatus_to_exitcode(status), output.decode(errors="replace"), root, logged(log)


def results(output: str) -> str:
    """The rehearsal's results, printed after every peg has run."""
    return output.split("rehearsal - results", 1)[1]


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
    """Every campaign step of a peg, the check's included, is given the peg's folder as RECORDS_DIR, and the check
    compares the expected after with the after there, finding that peg's market and no other."""
    status, output, root, lines = rehearse(tmp_path, "--peg", "BBB,AAA", "--collateral", "stETH")

    assert status == 0, output
    for peg in ("BBB", "AAA"):
        peg_steps = steps(lines, peg)
        assert len(peg_steps) == 8, peg_steps
        assert all(f" RECORDS_DIR=tmp/v3-upgrade/{peg} " in step for step in peg_steps), peg_steps
        compare = root / "tmp" / "v3-upgrade" / peg / "compare"
        for side in ("expected-after", "after"):
            assert [file.name for file in (compare / side / "pre").iterdir()] == [f"{peg}::stETH::minter.json"]
    assert results(output).count(RECORDS_COMPARED) == 2, output


def test_a_failed_check_of_one_peg_is_reported_and_the_next_peg_still_runs(tmp_path: Path) -> None:
    """A step of BBB's check fails: the rehearsal goes on to upgrade and check AAA, and its results fail BBB, naming
    the check's exit status, and pass AAA."""
    status, output, _, lines = rehearse(
        tmp_path, "--peg", "BBB,AAA", "--collateral", "stETH", stub_environment={"STUB_FAILING_PEG": "BBB"}
    )

    assert status == 1, output
    assert any(line.startswith("upgrade ") and "--peg AAA " in line for line in lines), lines
    assert any("MarketsExpectedAfter " in step for step in steps(lines, "AAA")), lines
    assert re.search(
        r"BBB::stETH - records in tmp/v3-upgrade/BBB/\s+❌ FAIL: check-upgraded-markets exited 1", results(output)
    ), output
    assert re.search(
        r"AAA::stETH - records in tmp/v3-upgrade/AAA/\s+" + re.escape(RECORDS_COMPARED), results(output)
    ), output
