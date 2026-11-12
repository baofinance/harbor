"""`script/verify/v3-upgrade/check-upgraded-markets` checks the markets named once their upgrade has run on anvil: for
each peg, it captures each contract before the upgrade (on mainnet) and after it (on anvil), checks the storage the
upgrade copied, writes the record each contract is expected to have after, and compares the expected after with the
after. It reads from anvil the block it forked, whose later blocks hold the upgrade's events, and a time later than
its head, which both captures are warped to.

Hermetic: a copy of the runner runs in a made-up tree, with stubs for forge, `cast` and `meld` (`v3_upgrade_campaign`).
"""

import re
import subprocess
from pathlib import Path

from .v3_upgrade_campaign import CAMPAIGN, FORK_BLOCK, HEAD_TIMESTAMP, logged, steps, stubbed, tree

RECORDS_COMPARED = "✅ PASS: each contract reads after the upgrade as it did before, or as expected"
RECORDS_DIFFER = "❌ FAIL: the differences printed above are neither unchanged nor expected"


def check(
    tmp_path: Path, *arguments: str, stub_environment: dict[str, str] | None = None, root: Path | None = None
) -> tuple[subprocess.CompletedProcess[str], Path, list[str]]:
    """Run a copy of the check from a tree - `root` when given, a new one otherwise - and return what it did, the
    tree's root and each line the stubs logged."""
    root = root or tree(tmp_path)
    environment, log = stubbed(tmp_path, root, stub_environment)
    done = subprocess.run(
        [str(root / CAMPAIGN / "check-upgraded-markets"), *arguments],
        capture_output=True,
        text=True,
        env=environment,
        check=False,
    )
    return done, root, logged(log)


def result(output: str, market: str) -> str:
    """The result line the check prints for `market`."""
    found = re.search(re.escape(market) + r" - records in \S+\s+(.*)", output.split("the check - results", 1)[1])
    assert found, output
    return found.group(1)


def test_the_captures_share_a_time_after_anvils_head_and_the_events_are_read_from_its_fork_block(
    tmp_path: Path,
) -> None:
    """Both captures are warped to anvil's head time plus 12000 seconds; the expected after reads the upgrade's events
    from the block after anvil's fork block; the after capture and the storage copy fork anvil, and the before capture
    and the expected after fork mainnet themselves."""
    done, _, lines = check(tmp_path, "--peg", "AAA", "--collateral", "stETH")

    assert done.returncode == 0, done.stdout + done.stderr
    before, after, storage, expected = steps(lines, "AAA")
    start = f" START_TIMESTAMP={HEAD_TIMESTAMP + 12000} "
    assert before.startswith("run-campaign-test MarketsCapture ") and " VERSION=before " in before, before
    assert start in before and "--fork-url" not in before, before
    assert after.startswith("run-campaign-test MarketsCapture ") and " VERSION=after " in after, after
    assert start in after and "--fork-url local" in after, after
    assert storage.startswith("run-campaign-test MarketsStorageCopy ") and "--fork-url local" in storage, storage
    assert expected.startswith("run-campaign-test MarketsExpectedAfter "), expected
    assert start in expected and f" UPGRADE_FROM_BLOCK={FORK_BLOCK} " in expected, expected
    assert "--fork-url" not in expected, expected
    assert all(" RECORDS_DIR=tmp/v3-upgrade/AAA " in step for step in (before, after, storage, expected)), lines
    assert result(done.stdout, "AAA::stETH") == RECORDS_COMPARED, done.stdout


def test_a_difference_fails_its_peg_and_the_next_peg_is_still_compared(tmp_path: Path) -> None:
    """AAA's after differs from its expected after: AAA fails and the comparison is opened in meld, BBB is still
    checked and passes, and the check exits 1."""
    done, _, lines = check(
        tmp_path, "--peg", "AAA,BBB", "--collateral", "stETH", stub_environment={"STUB_AFTER_DIFFERS": "AAA"}
    )

    assert done.returncode == 1, done.stdout + done.stderr
    assert len(steps(lines, "BBB")) == 4, lines
    assert result(done.stdout, "AAA::stETH") == RECORDS_DIFFER, done.stdout
    assert result(done.stdout, "BBB::stETH") == RECORDS_COMPARED, done.stdout
    assert [line for line in lines if line.startswith("meld ")] == [
        "meld tmp/v3-upgrade/AAA/compare/expected-after tmp/v3-upgrade/AAA/compare/after"
    ], lines


def test_records_of_an_earlier_check_are_removed_and_other_logs_kept(tmp_path: Path) -> None:
    """An after record an earlier check left, which this check does not write, does not reach the comparison; the log
    of a rehearsal step the check does not run stays."""
    root = tree(tmp_path)
    records = root / "tmp" / "v3-upgrade" / "AAA"
    for side in ("after", "compare/after"):
        (records / side / "pre").mkdir(parents=True)
        (records / side / "pre" / "AAA::stETH::stale.json").write_text("{}\n")
    (records / "read-point.log").write_text("the read point's log\n")

    done, _, _ = check(tmp_path, "--peg", "AAA", "--collateral", "stETH", root=root)

    assert done.returncode == 0, done.stdout + done.stderr
    assert not (records / "compare" / "after" / "pre" / "AAA::stETH::stale.json").exists()
    assert (records / "read-point.log").read_text() == "the read point's log\n"


def test_a_failed_step_stops_the_check(tmp_path: Path) -> None:
    """AAA's after capture fails: no later step runs, for AAA or BBB, and the check exits with the step's status."""
    done, _, lines = check(
        tmp_path, "--peg", "AAA,BBB", "--collateral", "stETH", stub_environment={"STUB_FAILING_PEG": "AAA"}
    )

    assert done.returncode == 1, done.stdout + done.stderr
    assert [step.split()[1] for step in steps(lines, "AAA")] == ["MarketsCapture", "MarketsCapture"], lines
    assert steps(lines, "BBB") == [], lines
    assert "the check - results" not in done.stdout, done.stdout


def test_a_capture_that_leaves_no_records_stops_the_check_naming_the_folder(tmp_path: Path) -> None:
    """A capture test that writes its records elsewhere leaves the peg's folder without them: the check stops there,
    naming the folder that does not exist, rather than reporting differences between folders that are not there."""
    done, _, lines = check(
        tmp_path, "--peg", "AAA,BBB", "--collateral", "stETH", stub_environment={"STUB_RECORDS_ROOT": "tmp/v3-upgrade"}
    )

    assert done.returncode == 1, done.stdout + done.stderr
    assert "ERROR: tmp/v3-upgrade/AAA/expected-after does not exist" in done.stderr, done.stderr
    assert "differences printed above" not in done.stdout, done.stdout
    assert steps(lines, "BBB") == [], lines


def test_a_node_that_names_no_fork_block_is_refused(tmp_path: Path) -> None:
    """anvil_nodeInfo names no fork block: the check refuses, naming the field, before any step runs or any record is
    removed."""
    root = tree(tmp_path)
    record = root / "tmp" / "v3-upgrade" / "AAA" / "after" / "pre" / "AAA::stETH::minter.json"
    record.parent.mkdir(parents=True)
    record.write_text("{}\n")

    done, _, lines = check(
        tmp_path,
        "--peg",
        "AAA",
        "--collateral",
        "stETH",
        stub_environment={"STUB_NODE_INFO": '{"currentBlockNumber": "0x0", "forkConfig": {}}'},
        root=root,
    )

    assert done.returncode == 1, done.stdout + done.stderr
    assert "forkConfig.forkBlockNumber" in done.stderr, done.stderr
    assert not any(line.startswith("run-campaign-test ") for line in lines), lines
    assert record.exists()


def test_a_peg_with_no_config_is_refused_by_name(tmp_path: Path) -> None:
    """A peg with no ConfigPeg_<peg>.sol is refused, naming it and the folder, before anvil is read."""
    done, root, lines = check(tmp_path, "--peg", "AAA,ZZZ", "--collateral", "stETH")

    assert done.returncode == 1
    assert "ZZZ" in done.stderr and "script/config/pegs" in done.stderr, done.stderr
    assert lines == [], lines
    assert not (root / "tmp").exists()
