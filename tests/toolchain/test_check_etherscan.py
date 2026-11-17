"""`script/check-etherscan` writes a report of each contract's Etherscan verification, for the contracts a state file
records. By default (`--update`) it reads the previous report and asks Etherscan only about what that report does not
show verified: verification on Etherscan is permanent, so a ✓ stays true. `--all` asks about everything. The new
report replaces the previous one only when the whole run succeeds, and an Etherscan failure stops the run.

Hermetic: the check runs in a made-up tree, with stubs for `cast`, `forge` and `curl` on the PATH. The curl stub
answers as Etherscan does, from a map of the contracts it knows, and records each action and address it is asked
about.
"""

import json
import os
import re
import stat
import subprocess
from pathlib import Path

import pytest

HARBOR = Path(__file__).resolve().parents[2]
CHECK_ETHERSCAN = HARBOR / "script" / "check-etherscan"
EXPLORER = "https://etherscan.io"
NOT_VERIFIED = "Contract source code not verified"

# Answers as Etherscan's contract API does (replies measured on mainnet, 2026-11-12). A contract the map STUB_ETHERSCAN
# does not hold is answered as an account with no verified source. The reply to the action and address that
# STUB_REPLY_FOR names is STUB_REPLY; the request that STUB_CURL_FAILS_FOR names fails as curl does. The first
# STUB_RATE_LIMITED_TIMES requests that STUB_RATE_LIMITED_FOR names get Etherscan's rate-limit reply.
CURL_STUB = """#!/usr/bin/env bash
url="${*: -1}"
[[ "$url" =~ [?\\&]action=([a-z]+) ]] && action=${BASH_REMATCH[1]}
[[ "$url" =~ [?\\&]address=(0x[0-9a-fA-F]{40}) ]] && address=${BASH_REMATCH[1]}
echo "$action $address" >>"$STUB_LOG"
if [[ "$action $address" == "${STUB_CURL_FAILS_FOR:-}" ]]; then
  echo "curl: (6) Could not resolve host: api.etherscan.io" >&2
  exit 6
fi
if [[ "$action $address" == "${STUB_RATE_LIMITED_FOR:-}" ]] &&
  (($(grep -cxF "$action $address" "$STUB_LOG") <= STUB_RATE_LIMITED_TIMES)); then
  echo '{"status":"0","message":"NOTOK","result":"Max calls per sec rate limit reached (3/sec)"}'
  exit 0
fi
if [[ "$action $address" == "${STUB_REPLY_FOR:-}" ]]; then
  echo "$STUB_REPLY"
  exit 0
fi
contract=$(jq -c --arg a "${address,,}" '.[$a] // {"verified": false, "proxy": "0", "implementation": ""}' \\
  "$STUB_ETHERSCAN")
case "$action" in
  getabi)
    if [[ $(jq -r .verified <<<"$contract") == true ]]; then
      echo '{"status":"1","message":"OK","result":"[]"}'
    else
      echo '{"status":"0","message":"NOTOK","result":"Contract source code not verified"}'
    fi
    ;;
  getsourcecode)
    jq -c '{status: "1", message: "OK", result: [{
      ABI: (if .verified then "[]" else "Contract source code not verified" end),
      SourceCode: (if .verified then "contract C {}" else "" end),
      Proxy: .proxy, Implementation: .implementation}]}' <<<"$contract"
    ;;
esac
"""

CAST_STUB = """#!/usr/bin/env bash
case "$1" in
  chain-id) echo 1 ;;
esac
"""

# Records each wait instead of waiting.
SLEEP_STUB = """#!/usr/bin/env bash
echo "sleep $*" >>"$STUB_SLEEP_LOG"
"""

FORGE_STUB = """#!/usr/bin/env bash
echo '{"etherscan_api_key": "TESTKEY"}'
"""


def address(name: str) -> str:
    """A made-up address, distinct for each name, in upper case: the check compares addresses ignoring case."""
    return "0x" + name.encode().hex().rjust(40, "0").upper()


PA, IA = address("PA"), address("IA")  # proxy A and its implementation: verified, shown ✓ in the previous report
PB, IB = address("PB"), address("IB")  # proxy B: its Source was ✗ in the previous report
PC, IC_OLD, IC_NEW = address("PC"), address("IC_OLD"), address("IC_NEW")  # proxy C: upgraded since the report
PD, ID = address("PD"), address("ID")  # proxy D: new since the report; its implementation is not verified
PE = address("PE")  # proxy E: the state file records no implementation for it
R1, R2, R3 = address("R1"), address("R2"), address("R3")  # remaining: ✓ before, ✗ before, new since the report


def write_executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def state(proxies: dict[str, tuple[str, str | None]], remaining: list[str]) -> dict:
    """A state file: each proxy key to its address and implementation, and every implementation, the remaining ones
    included."""
    implementations = {
        implementation: {"proxy": key, "contractType": f"{key.split('::')[0]}_v1"}
        for key, (_, implementation) in proxies.items()
        if implementation
    }
    implementations.update({implementation: {"proxy": "old", "contractType": "Old_v1"} for implementation in remaining})
    return {
        "network": "mainnet",
        "proxies": {
            key: {"address": proxy, **({"implementation": implementation} if implementation else {})}
            for key, (proxy, implementation) in proxies.items()
        },
        "implementations": implementations,
    }


def tick(verified: bool, url: str) -> str:
    return f"[{'✓' if verified else '✗'}]({url})"


def proxy_row(key: str, proxy: str, implementation: str, ticks: str) -> str:
    """A proxy row as the report writes it; `ticks` gives Source, Impl Linked, Proxy Flag and Impl Verified."""
    code, checker = f"{EXPLORER}/address/{proxy}#code", f"{EXPLORER}/proxyContractChecker?a={proxy}"
    source, linked, flag, verified = (t == "✓" for t in ticks)
    return (
        f"| [{key}]({code}) | {tick(source, code)} | {tick(linked, checker)} | {tick(flag, checker)} "
        f"| {tick(verified, f'{EXPLORER}/address/{implementation}#code')} |"
    )


def remaining_row(implementation: str, verified: bool) -> str:
    code = f"{EXPLORER}/address/{implementation}#code"
    return f"| [old]({code}) | Old_v1 | {tick(verified, code)} |"


def report(proxy_rows: list[str], remaining_rows: list[str]) -> str:
    """A report as the check writes it."""
    lines = [
        "# Harbor Minter Verification Report",
        "",
        "- **Updated:** 2026-01-01 00:00:00 UTC",
        "",
        "## Proxies",
        "",
        "| Role | Source | Impl Linked | Proxy Flag | Impl Verified |",
        "|------|--------|-------------|------------|---------------|",
        *proxy_rows,
    ]
    if remaining_rows:
        lines += [
            "",
            "## Remaining Implementations",
            "",
            "| Role | Contract | Verified |",
            "|------|----------|----------|",
        ]
        lines += remaining_rows
    return "\n".join(lines) + "\n"


# The tree of the main test: proxies A to E and remaining implementations R1 to R3, with the previous report below.
STATE = state(
    {
        "A::minter": (PA, IA),
        "B::minter": (PB, IB),
        "C::minter": (PC, IC_NEW),
        "D::minter": (PD, ID),
        "E::pegged": (PE, None),
    },
    [IC_OLD, R1, R2, R3],
)
PREVIOUS = report(
    [
        proxy_row("A::minter", PA, IA, "✓✓✓✓"),
        proxy_row("B::minter", PB, IB, "✗✓✓✓"),
        proxy_row("C::minter", PC, IC_OLD, "✓✓✓✓"),
        f"| [E::pegged]({EXPLORER}/address/{PE}#code) | - | - | - | - |",
    ],
    [remaining_row(R1, True), remaining_row(R2, False)],
)
# What Etherscan knows now: everything is verified except D's implementation and R2.
VERIFIED_PROXY = {"verified": True, "proxy": "1"}
ETHERSCAN = {
    PA: {**VERIFIED_PROXY, "implementation": IA},
    PB: {**VERIFIED_PROXY, "implementation": IB},
    PC: {**VERIFIED_PROXY, "implementation": IC_NEW},
    PD: {**VERIFIED_PROXY, "implementation": ID},
    **{implementation: {"verified": True} for implementation in (IA, IB, IC_OLD, IC_NEW, R1, R3)},
}
# Every question the check can ask about STATE.
EVERY_QUERY = sorted(
    [f"{action} {proxy}" for proxy in (PA, PB, PC, PD) for action in ("getabi", "getsourcecode")]
    + [f"getabi {implementation}" for implementation in (IA, IB, IC_NEW, ID, IC_OLD, R1, R2, R3)]
)


def check(
    tmp_path: Path,
    *arguments: str,
    state_file: dict = STATE,
    previous: str | None = PREVIOUS,
    etherscan: dict = ETHERSCAN,
    stub_environment: dict[str, str] | None = None,
    pending: str | None = None,
) -> tuple[subprocess.CompletedProcess[str], Path, list[str]]:
    """Run the check on a tree holding the state file and, when given, the previous report and a pending report left
    by an earlier run; return what it did, the report's path and each query the curl stub was asked, sorted."""
    root = tmp_path / "harbor"
    (root / "src").mkdir(parents=True)
    (root / "foundry.toml").write_text("")
    mainnet = root / "deployments" / "mainnet"
    mainnet.mkdir(parents=True)
    (mainnet / "test.state.json").write_text(json.dumps(state_file))
    output = mainnet / "test.state.md"
    if previous is not None:
        output.write_text(previous)
    if pending is not None:
        output.with_name("test.state.md.pending").write_text(pending)
    stubs = tmp_path / "stubs"
    write_executable(stubs / "curl", CURL_STUB)
    write_executable(stubs / "cast", CAST_STUB)
    write_executable(stubs / "forge", FORGE_STUB)
    write_executable(stubs / "sleep", SLEEP_STUB)
    answers = tmp_path / "etherscan.json"
    answers.write_text(json.dumps({contract.lower(): answer for contract, answer in etherscan.items()}))
    log = tmp_path / "stub.log"
    environment = {
        **os.environ,
        "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}",
        "STUB_LOG": str(log),
        "STUB_SLEEP_LOG": str(tmp_path / "sleep.log"),
        "STUB_ETHERSCAN": str(answers),
        **(stub_environment or {}),
    }
    done = subprocess.run(
        [str(CHECK_ETHERSCAN), "--network", "mainnet", "--salt", "test", *arguments],
        cwd=root,
        capture_output=True,
        text=True,
        env=environment,
        check=False,
    )
    queries = sorted(log.read_text().splitlines()) if log.exists() else []
    return done, output, queries


def ticks(text: str, label: str) -> str:
    """The ✓ and ✗ of the report row whose first column is `label`, in column order."""
    rows = [line for line in text.splitlines() if line.startswith(f"| [{label}](")]
    assert len(rows) == 1, text
    return "".join(re.findall(r"\[(✓|✗)\]", rows[0]))


def remaining_ticks(text: str) -> dict[str, str]:
    """Each remaining implementation's address to its ✓ or ✗."""
    section = text.split("## Remaining Implementations", 1)[1]
    return {
        found.group(1): found.group(2)
        for found in re.finditer(
            r"^\| \[old\]\(\S+/address/(0x[0-9a-fA-F]{40})#code\) \| \S+ \| \[(✓|✗)\]", section, re.M
        )
    }


def test_update_asks_etherscan_only_about_what_the_previous_report_does_not_show_verified(tmp_path: Path) -> None:
    """The default run carries each ✓ of the previous report and asks about the rest: A's proxy columns and its
    implementation are carried; B's proxy is asked again for its ✗ Source and its implementation's ✓ is carried; C
    was upgraded, so its proxy and new implementation are asked about; D is new; E has no implementation to ask
    about. In the remaining table R1's ✓ is carried, R2's ✗ is asked again, R3 is new, and C's old implementation
    keeps the ✓ the proxy table showed for it. The report says when it was updated."""
    done, output, queries = check(tmp_path)

    assert done.returncode == 0, done.stdout + done.stderr
    assert queries == sorted(
        [f"getabi {PB}", f"getsourcecode {PB}"]
        + [f"getabi {PC}", f"getsourcecode {PC}", f"getabi {IC_NEW}"]
        + [f"getabi {PD}", f"getsourcecode {PD}", f"getabi {ID}"]
        + [f"getabi {R2}", f"getabi {R3}"]
    ), queries
    text = output.read_text()
    assert ticks(text, "A::minter") == "✓✓✓✓", text
    assert ticks(text, "B::minter") == "✓✓✓✓", text
    assert ticks(text, "C::minter") == "✓✓✓✓", text
    assert f"{EXPLORER}/address/{IC_NEW}#code" in text, text
    assert ticks(text, "D::minter") == "✓✓✓✗", text
    assert f"| [E::pegged]({EXPLORER}/address/{PE}#code) | - | - | - | - |" in text, text
    assert remaining_ticks(text) == {IC_OLD: "✓", R1: "✓", R2: "✗", R3: "✓"}, text
    assert re.search(r"^- \*\*Updated:\*\* \d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC$", text, re.M), text
    assert "Generated" not in text, text
    assert not output.with_name("test.state.md.pending").exists()


def test_a_report_that_shows_everything_verified_needs_no_etherscan_query(tmp_path: Path) -> None:
    """One proxy, all ✓ in the previous report for the same implementation: nothing is asked, and the row stays ✓."""
    done, output, queries = check(
        tmp_path,
        state_file=state({"A::minter": (PA, IA)}, []),
        previous=report([proxy_row("A::minter", PA, IA, "✓✓✓✓")], []),
    )

    assert done.returncode == 0, done.stdout + done.stderr
    assert queries == [], queries
    assert ticks(output.read_text(), "A::minter") == "✓✓✓✓", output.read_text()


def test_without_a_previous_report_update_asks_about_everything(tmp_path: Path) -> None:
    """The first run has no report to read: every contract is asked about, and the report is written."""
    done, output, queries = check(tmp_path, previous=None)

    assert done.returncode == 0, done.stdout + done.stderr
    assert queries == EVERY_QUERY, queries
    assert ticks(output.read_text(), "D::minter") == "✓✓✓✗", output.read_text()


def test_all_asks_about_everything_whatever_the_previous_report_shows(tmp_path: Path) -> None:
    """`--all` ignores the previous report: every contract is asked about, the ✓ ones included."""
    done, _, queries = check(tmp_path, "--all")

    assert done.returncode == 0, done.stdout + done.stderr
    assert queries == EVERY_QUERY, queries


def test_a_report_row_that_cannot_be_read_stops_the_run(tmp_path: Path) -> None:
    """A proxy row with two marks instead of four: the run stops before asking Etherscan anything, names the row,
    and leaves the previous report as it was."""
    unreadable = f"| [A::minter]({EXPLORER}/address/{PA}#code) | [✓]({EXPLORER}/address/{PA}#code) | [✓](x) |"
    previous = report([unreadable], [])
    done, output, queries = check(tmp_path, previous=previous)

    assert done.returncode == 1, done.stdout + done.stderr
    assert unreadable in done.stderr, done.stderr
    assert queries == [], queries
    assert output.read_text() == previous


def test_a_pending_report_from_an_earlier_run_is_removed_when_the_run_starts(tmp_path: Path) -> None:
    """An earlier run left a pending report; this run fails before writing its own. The earlier file is gone, and the
    run does not name it as its own."""
    unreadable = f"| [A::minter]({EXPLORER}/address/{PA}#code) | [✓](x) |"
    done, output, _ = check(tmp_path, previous=report([unreadable], []), pending="an earlier run's report\n")

    assert done.returncode == 1, done.stdout + done.stderr
    assert not output.with_name("test.state.md.pending").exists()
    assert "left for debugging" not in done.stderr, done.stderr


def waits(tmp_path: Path) -> list[str]:
    """Each wait the sleep stub was asked for."""
    log = tmp_path / "sleep.log"
    return log.read_text().splitlines() if log.exists() else []


def test_a_rate_limited_query_is_asked_again_a_second_later(tmp_path: Path) -> None:
    """Etherscan answers B's getabi twice with its rate-limit reply: the check waits a second before each new attempt,
    the third is answered, and the report shows B as the answer says."""
    done, output, queries = check(
        tmp_path, stub_environment={"STUB_RATE_LIMITED_FOR": f"getabi {PB}", "STUB_RATE_LIMITED_TIMES": "2"}
    )

    assert done.returncode == 0, done.stdout + done.stderr
    assert queries.count(f"getabi {PB}") == 3, queries
    assert waits(tmp_path) == ["sleep 1", "sleep 1"], waits(tmp_path)
    assert ticks(output.read_text(), "B::minter") == "✓✓✓✓", output.read_text()


def test_a_query_still_rate_limited_on_the_fifth_attempt_stops_the_run(tmp_path: Path) -> None:
    """Etherscan answers B's getabi with its rate-limit reply every time: the check asks five times, a second apart,
    then exits 1 with Etherscan's reply and the number of attempts, keeping the previous report."""
    done, output, queries = check(
        tmp_path, stub_environment={"STUB_RATE_LIMITED_FOR": f"getabi {PB}", "STUB_RATE_LIMITED_TIMES": "99"}
    )

    assert done.returncode == 1, done.stdout + done.stderr
    assert queries.count(f"getabi {PB}") == 5, queries
    assert waits(tmp_path) == ["sleep 1"] * 4, waits(tmp_path)
    assert f"getabi {PB}: status 0: Max calls per sec rate limit reached (3/sec), on each of 5 attempts" in done.stderr
    assert output.read_text() == PREVIOUS


INVALID_KEY = '{"status":"0","message":"NOTOK","result":"Invalid API Key (#err2)"}'


@pytest.mark.parametrize(
    ("fault", "query", "reply", "message"),
    [
        ("reply", f"getabi {PB}", INVALID_KEY, "Invalid API Key (#err2)"),
        ("reply", f"getsourcecode {PB}", INVALID_KEY, "Invalid API Key (#err2)"),
        ("reply", f"getabi {ID}", INVALID_KEY, "Invalid API Key (#err2)"),
        ("reply", f"getabi {R3}", INVALID_KEY, "Invalid API Key (#err2)"),
        ("reply", f"getsourcecode {PB}", '{"status":"1","message":"OK","result":[]}', "0 results"),
        ("reply", f"getabi {PB}", "<html>Bad Gateway</html>", "<html>Bad Gateway</html>"),
        ("curl", f"getabi {PB}", "", "Could not resolve host"),
    ],
    ids=[
        "proxy-getabi-error",
        "getsourcecode-error",
        "implementation-getabi-error",
        "remaining-getabi-error",
        "getsourcecode-no-result",
        "not-json",
        "request-failed",
    ],
)
def test_an_etherscan_failure_stops_the_run_and_keeps_the_previous_report(
    tmp_path: Path, fault: str, query: str, reply: str, message: str
) -> None:
    """A reply that is neither an answer nor "not verified", or a request that fails, is not shown as ✗: the run
    exits 1 naming the action, the address and what Etherscan or curl said. The previous report is kept, and the
    new one is left beside it for debugging."""
    environment = {"STUB_REPLY_FOR": query, "STUB_REPLY": reply} if fault == "reply" else {"STUB_CURL_FAILS_FOR": query}
    done, output, _ = check(tmp_path, stub_environment=environment)

    assert done.returncode == 1, done.stdout + done.stderr
    assert query in done.stderr, done.stderr
    assert message in done.stderr, done.stderr
    assert output.read_text() == PREVIOUS
    pending = output.with_name("test.state.md.pending")
    assert pending.exists()
    assert f".pending left for debugging at deployments/mainnet/{pending.name}" in done.stderr, done.stderr
