"""`script/anvil` forks mainnet at a block named by `--block`, and makes `deployments/local/mainnet/` a copy of
`deployments/mainnet/` when it forks any block but the factory's. A state file an earlier node left there records
contracts the new node does not hold, and a run reading it would be refused as a duplicate of its own deployments.

A day starts at 06:00 local time. `--block today` is the last block before the start of today, so every run on a
day forks the same block; `yesterday` and `today-N` count days back from it, and a plain date is 06:00 on that date.
A value with a time keeps its time.

Hermetic: a copy of the script runs beside a made-up `deployments/` folder, which it finds relative to itself, and
`anvil` and `cast` are stubs on PATH that record what they are handed instead of forking or looking anything up.
A named block needs no lookup, so `cast` is run only for a day or a time, when its stub answers one fixed block.
"""

import json
import os
import shutil
import stat
import subprocess
from datetime import datetime, time, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

HARBOR = Path(__file__).resolve().parents[2]
ANVIL_SCRIPT = HARBOR / "script" / "anvil"

MAINNET_FILE = {"saltPrefix": "harbor_v1", "writtenBy": "a mainnet run"}
EARLIER_LOCAL_FILE = {"saltPrefix": "harbor_v1", "writtenBy": "an earlier node"}
LOCAL_ONLY_FILE = {"saltPrefix": "pre1_3", "writtenBy": "an earlier node"}

# The block the `cast find-block` stub answers for any time
FOUND_BLOCK = 26309019
DAY_STARTS_AT = time(6)


def run(
    tmp_path: Path, answer: str, *arguments: str, zone: str | None = None
) -> tuple[subprocess.CompletedProcess, Path, list[str]]:
    """Run a copy of the script beside a deployments folder, answering its one prompt, and return the local state
    folder and each line the stubs logged. `zone` sets the local time zone the script runs in.

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
    for name, body in (("anvil", ""), ("cast", f"echo {FOUND_BLOCK}\n")):
        stub = stubs / name
        stub.write_text(f'#!/usr/bin/env bash\necho "{name} $*" >> "$STUB_LOG"\n{body}')
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)

    log = tmp_path / "stub.log"
    environment = {**os.environ, "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}", "STUB_LOG": str(log)}
    if zone is not None:
        environment["TZ"] = zone
    done = subprocess.run(
        [str(script), *arguments],
        input=answer,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    lines = log.read_text().splitlines() if log.exists() else []
    return done, local, lines


def state_files(local: Path) -> dict[str, dict]:
    return {file.name: json.loads(file.read_text()) for file in sorted(local.glob("*.json"))}


def zone_where_the_hour_is_now(hour: int) -> str:
    """A zone in which the local time is now in the given hour. The Etc/GMT zones keep no summer time and span every
    whole-hour offset from -12 to +14, so one of them is at any hour at any moment. (Their sign is inverted: Etc/GMT-9
    is nine hours ahead of UTC.)"""
    offset = (hour - datetime.now(timezone.utc).hour) % 24
    if offset > 14:
        offset -= 24
    return "Etc/GMT" if offset == 0 else f"Etc/GMT{-offset:+d}"


def start_of_day(zone: str, day: datetime.date) -> int:
    """The second at which a day began in a zone, as the script hands it to `cast find-block`."""
    return int(datetime.combine(day, DAY_STARTS_AT, tzinfo=ZoneInfo(zone)).timestamp())


def found_block_from(lines: list[str], second: int) -> None:
    """Assert that the script looked up the block before `second` and forked at the block the lookup answered."""
    assert lines == [f"cast find-block {second} --rpc-url mainnet", *lines[1:]]
    assert len(lines) == 2 and lines[1].startswith("anvil ") and f"--fork-block-number {FOUND_BLOCK}" in lines[1]


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


def test_today_is_the_last_block_before_six_this_morning(tmp_path: Path) -> None:
    # In a zone where it is now midday, today began at 06:00 on today's date there
    zone = zone_where_the_hour_is_now(12)
    done, _, lines = run(tmp_path, "y", "--block", "today", zone=zone)

    assert done.returncode == 0, done.stderr
    found_block_from(lines, start_of_day(zone, datetime.now(ZoneInfo(zone)).date()))


def test_before_six_in_the_morning_today_is_the_day_that_began_yesterday(tmp_path: Path) -> None:
    # In a zone where it is now 03:00, the day that began at 06:00 yesterday is still today
    zone = zone_where_the_hour_is_now(3)
    done, _, lines = run(tmp_path, "y", "--block", "today", zone=zone)

    assert done.returncode == 0, done.stderr
    found_block_from(lines, start_of_day(zone, datetime.now(ZoneInfo(zone)).date() - timedelta(days=1)))


def test_yesterday_and_today_minus_n_count_days_back_from_today(tmp_path: Path) -> None:
    zone = zone_where_the_hour_is_now(12)
    today = datetime.now(ZoneInfo(zone)).date()

    for spec, days_back in (("yesterday", 1), ("today-1", 1), ("today-7", 7)):
        done, _, lines = run(tmp_path / spec, "y", "--block", spec, zone=zone)

        assert done.returncode == 0, done.stderr
        found_block_from(lines, start_of_day(zone, today - timedelta(days=days_back)))


def test_a_plain_date_starts_at_six_in_the_morning_local_time(tmp_path: Path) -> None:
    # London keeps summer time in July, so 06:00 there is 05:00 UTC: the time is local, not UTC
    for spec in ("2026-07-04", "4-Jul-2026", "Jul-4-2026"):
        done, _, lines = run(tmp_path / spec, "y", "--block", spec, zone="Europe/London")

        assert done.returncode == 0, done.stderr
        found_block_from(lines, start_of_day("Europe/London", datetime(2026, 7, 4).date()))
        assert f"Forking mainnet at block {FOUND_BLOCK}, the last block before 2026-07-04 06:00 +0100" in done.stdout


def test_before_a_date_forks_the_block_before_the_last_block_before_it(tmp_path: Path) -> None:
    done, _, lines = run(tmp_path, "y", "--block", "4-Jul-2026", "--before", zone="Europe/London")

    assert done.returncode == 0, done.stderr
    assert f"--fork-block-number {FOUND_BLOCK - 1}" in lines[1]
    assert (
        f"Forking mainnet at block {FOUND_BLOCK - 1}, the block before {FOUND_BLOCK}, "
        "the last block before 2026-07-04 06:00 +0100" in done.stdout
    )


def test_a_time_keeps_its_time(tmp_path: Path) -> None:
    done, _, lines = run(tmp_path, "y", "--block", "2025-12-01T12:00:00Z", zone="Europe/London")

    assert done.returncode == 0, done.stderr
    found_block_from(lines, int(datetime(2025, 12, 1, 12, tzinfo=timezone.utc).timestamp()))


def test_a_time_in_the_future_is_refused(tmp_path: Path) -> None:
    done, _, lines = run(tmp_path, "y", "--block", "2099-01-01", zone="Europe/London")

    assert done.returncode == 1
    assert "2099-01-01 06:00 +0000" in done.stderr and "future" in done.stderr
    assert lines == []


def test_a_value_that_is_not_a_block_day_date_or_time_is_refused(tmp_path: Path) -> None:
    done, _, lines = run(tmp_path, "y", "--block", "someday", zone="Europe/London")

    assert done.returncode == 1
    assert "'someday'" in done.stderr
    assert lines == []
