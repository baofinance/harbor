"""A made-up tree and stubs for the toolchain tests of the v3 upgrade campaign's two runners,
`script/verify/v3-upgrade/run-upgrade-rehearsal` and `script/verify/v3-upgrade/check-upgraded-markets`.

The tree holds copies of the two runners and `campaign.sh`, which both source, with the peg configs AAA and BBB and a
mainnet state file. `script/verify/run-campaign-test`, `script/upgrade`, `cast` and `meld` are stubs that record what
they are handed, and the campaign-test stub writes the log forge would and the records the two capture tests write.
"""

import os
import shutil
import stat
from pathlib import Path

HARBOR = Path(__file__).resolve().parents[2]
CAMPAIGN = Path("script") / "verify" / "v3-upgrade"
CAMPAIGN_FILES = ("run-upgrade-rehearsal", "check-upgraded-markets", "campaign.sh")

# Stands in for forge running one campaign test. It writes the step's log as forge would, and, for the two capture
# tests, what they write: a minter record per market under the directory RECORDS_DIR names - or under STUB_RECORDS_ROOT
# when set, as a capture test that ignores RECORDS_DIR writes. Without RECORDS_DIR it fails as the tests do, and the
# expected-after fails without the before and after records it reads. The after capture of the peg STUB_FAILING_PEG
# names fails; that of the peg STUB_AFTER_DIFFERS names writes a record the expected after does not hold.
CAMPAIGN_TEST_STUB = """#!/usr/bin/env bash
log="$2"
shift 2
arguments="$*"
contract=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --mc ]]; then
    contract=$2
  fi
  shift
done
echo "run-campaign-test $contract RECORDS_DIR=${RECORDS_DIR-unset} VERSION=${VERSION-unset} UPGRADE_PEG=$UPGRADE_PEG UPGRADE_COLLATERAL=$UPGRADE_COLLATERAL START_TIMESTAMP=${START_TIMESTAMP-unset} UPGRADE_FROM_BLOCK=${UPGRADE_FROM_BLOCK-unset} ARGUMENTS=$arguments" >>"$STUB_LOG"
mkdir -p "$(dirname "$log")"
if [[ "$contract" == MarketsCapture && "${VERSION-}" == after && "$UPGRADE_PEG" == "${STUB_FAILING_PEG:-}" ]]; then
  echo '[FAIL: the after capture failed]' | tee "$log"
  exit 1
fi
if [[ "$contract" == MarketsCapture || "$contract" == MarketsExpectedAfter ]]; then
  if [[ -z "${RECORDS_DIR:-}" ]]; then
    echo '[FAIL: vm.envString: environment variable "RECORDS_DIR" not found]' | tee "$log"
    exit 1
  fi
  root="${STUB_RECORDS_ROOT:-$RECORDS_DIR}"
  label="$UPGRADE_PEG::$UPGRADE_COLLATERAL::minter"
  if [[ "$contract" == MarketsCapture ]]; then
    mkdir -p "$root/$VERSION/pre"
    changed=false
    if [[ "$VERSION" == after && "$UPGRADE_PEG" == "${STUB_AFTER_DIFFERS:-}" ]]; then
      changed=true
    fi
    printf '{"peg": "%s", "collateral": "%s", "changed": %s}\\n' "$UPGRADE_PEG" "$UPGRADE_COLLATERAL" "$changed" \\
      >"$root/$VERSION/pre/$label.json"
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

FORK_BLOCK = 90
HEAD_BLOCK = 100
HEAD_TIMESTAMP = 1_700_000_000

# anvil as the runners read it: anvil_nodeInfo names the block it forked - or what STUB_NODE_INFO holds, when set - then
# the head's block number and timestamp.
CAST_STUB = f"""#!/usr/bin/env bash
echo "cast $*" >>"$STUB_LOG"
case "$1" in
  rpc)
    if [[ -n "${{STUB_NODE_INFO:-}}" ]]; then
      echo "$STUB_NODE_INFO"
    else
      echo '{{"currentBlockNumber": "0x64", "forkConfig": {{"forkBlockNumber": {FORK_BLOCK}}}}}'
    fi
    ;;
  block-number) echo {HEAD_BLOCK} ;;
  block) echo {HEAD_TIMESTAMP} ;;
esac
"""

# What a runner's environment must not carry in from the shell running the tests: each runner sets these itself, for
# each step that reads them, and the stub logs a step that is not given one as unset.
CAMPAIGN_VARIABLES = (
    "RECORDS_DIR",
    "VERSION",
    "UPGRADE_PEG",
    "UPGRADE_COLLATERAL",
    "START_TIMESTAMP",
    "UPGRADE_FROM_BLOCK",
)


def write_executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def tree(tmp_path: Path) -> Path:
    """A tree holding copies of the campaign's runners, the peg configs AAA and BBB, and a mainnet state file; its
    root."""
    root = tmp_path / "harbor"
    campaign = root / CAMPAIGN
    campaign.mkdir(parents=True)
    for name in CAMPAIGN_FILES:
        shutil.copy2(HARBOR / CAMPAIGN / name, campaign / name)
    pegs = root / "script" / "config" / "pegs"
    pegs.mkdir(parents=True)
    for name in ("ConfigPeg.sol", "ConfigPeg_AAA.sol", "ConfigPeg_BBB.sol"):
        (pegs / name).write_text("// a peg config\n")
    mainnet = root / "deployments" / "mainnet"
    mainnet.mkdir(parents=True)
    (mainnet / "harbor_v1.state.json").write_text("{}\n")
    return root


def stubbed(tmp_path: Path, root: Path, stub_environment: dict[str, str] | None = None) -> tuple[dict[str, str], Path]:
    """Put the stubs in the tree and on the PATH; return the environment to run a runner in, and the stubs' log."""
    write_executable(root / "script" / "verify" / "run-campaign-test", CAMPAIGN_TEST_STUB)
    write_executable(root / "script" / "upgrade", '#!/usr/bin/env bash\necho "upgrade $*" >>"$STUB_LOG"\n')
    stubs = tmp_path / "stubs"
    write_executable(stubs / "cast", CAST_STUB)
    write_executable(stubs / "meld", '#!/usr/bin/env bash\necho "meld $*" >>"$STUB_LOG"\n')
    log = tmp_path / "stub.log"
    environment = {name: value for name, value in os.environ.items() if name not in CAMPAIGN_VARIABLES}
    environment.update(
        {
            "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}",
            "STUB_LOG": str(log),
            **(stub_environment or {}),
        }
    )
    return environment, log


def logged(log: Path) -> list[str]:
    """Each line the stubs logged."""
    return log.read_text().splitlines() if log.exists() else []


def steps(lines: list[str], peg: str) -> list[str]:
    """The campaign steps the stubs logged for `peg`, in the order they ran."""
    return [line for line in lines if line.startswith("run-campaign-test ") and f" UPGRADE_PEG={peg} " in line]
