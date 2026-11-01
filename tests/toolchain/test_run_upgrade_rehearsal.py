"""`script/verify/v3-upgrade/run-upgrade-rehearsal` rehearses the pegs named on one anvil session, one after another:
`--peg` takes one peg, several separated by commas, or `*` for every peg production configures, each the
`ConfigPeg_<peg>.sol` in `script/config/pegs`. A peg with no config there is refused by name. Each peg's records go to
`tmp/v3-upgrade/<peg>/`.

Hermetic: a copy of the runner runs in a made-up tree holding only peg configs, with `--dry-run`, which prints what the
run would cover and exits before forking, upgrading or writing anything.
"""

import re
import shutil
import subprocess
from pathlib import Path

HARBOR = Path(__file__).resolve().parents[2]
RUNNER = HARBOR / "script" / "verify" / "v3-upgrade" / "run-upgrade-rehearsal"


def run(tmp_path: Path, *arguments: str) -> tuple[subprocess.CompletedProcess, Path]:
    """Run a copy of the runner from a tree whose peg configs are AAA and BBB, and return the tree's root."""
    root = tmp_path / "harbor"
    campaign = root / "script" / "verify" / "v3-upgrade"
    campaign.mkdir(parents=True)
    shutil.copy(RUNNER, campaign / "run-upgrade-rehearsal")
    pegs = root / "script" / "config" / "pegs"
    pegs.mkdir(parents=True)
    for name in ("ConfigPeg.sol", "ConfigPeg_AAA.sol", "ConfigPeg_BBB.sol"):
        (pegs / name).write_text("// a peg config\n")
    done = subprocess.run(
        [str(campaign / "run-upgrade-rehearsal"), *arguments],
        input="",
        capture_output=True,
        text=True,
        check=False,
    )
    return done, root


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
