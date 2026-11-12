#!/usr/bin/env bash
#
# campaign.sh - sourced by run-upgrade-rehearsal and check-upgraded-markets beside it, from the repository root: where
# the campaign's records go, the markets a run names, and the step that runs the campaign's tests.

# Each peg's records, and each step's log, go to $RECORDS_ROOT/<peg>/.
# shellcheck disable=SC2034 # read by the scripts that source this file
RECORDS_ROOT="tmp/v3-upgrade"
FORGE_VERBOSITY="${FORGE_VERBOSITY:--vv}"
PEG_CONFIGS="script/config/pegs"

# name_markets <peg> <collateral>
#   The markets that --peg <peg> and --collateral <collateral> name. Fills PEGS with the pegs, in the order given: one
#   peg, several separated by commas, or '*' for every peg production configures, each the ConfigPeg_<peg>.sol in
#   script/config/pegs, in file order. Sets MARKETS to each peg's market as <peg>::<collateral>, separated by commas.
#   An empty flag, or a peg with no config there, is refused by name, and the script exits.
name_markets() {
  local peg_flag="$1" collateral="$2" config name peg
  [[ -n "$peg_flag" ]] || {
    echo "ERROR: --peg required: a peg's name, several separated by commas, or '*' for every peg" >&2
    exit 1
  }
  [[ -n "$collateral" ]] || {
    echo "ERROR: --collateral required: a collateral's name, or '*' for every market of the peg" >&2
    exit 1
  }
  PEGS=()
  if [[ "$peg_flag" == "*" ]]; then
    for config in "$PEG_CONFIGS"/ConfigPeg_*.sol; do
      if [[ -f "$config" ]]; then
        name="$(basename "$config" .sol)"
        PEGS+=("${name#ConfigPeg_}")
      fi
    done
    [[ ${#PEGS[@]} -gt 0 ]] || {
      echo "ERROR: $PEG_CONFIGS holds no ConfigPeg_<peg>.sol" >&2
      exit 1
    }
  else
    local named_pegs
    IFS=',' read -ra named_pegs <<<"$peg_flag"
    for peg in "${named_pegs[@]}"; do
      PEGS+=("$(echo "$peg" | tr '[:lower:]' '[:upper:]')")
    done
  fi
  MARKETS=""
  for peg in "${PEGS[@]}"; do
    [[ -f "$PEG_CONFIGS/ConfigPeg_$peg.sol" ]] || {
      echo "ERROR: no peg '$peg': $PEG_CONFIGS has no ConfigPeg_$peg.sol" >&2
      exit 1
    }
    MARKETS+="${MARKETS:+, }$peg::$collateral"
  done
}

# campaign_test <records> <log> <contract> [<forge test argument>...]
#   Runs the campaign's tests matching <contract> with the given forge arguments, logging to <records>/<log>, which is
#   also where the capture tests write their records: RECORDS_DIR names it to them. A step forking mainnet does so from
#   inside its tests, and each fork takes the retries foundry.toml's mainnet entry carries - forge gives a fork a test
#   creates the entry's retries and not the command line's (foundry issue 18071) - with its requests paced by
#   run-campaign-test, as every campaign's are. A step against anvil is given --fork-url local, the fork its tests read.
#   Fails unless the tests actually ran - see script/verify/run-campaign-test.
campaign_test() {
  local records="$1" log="$2" contract="$3"
  shift 3
  RECORDS_DIR="$records" script/verify/run-campaign-test script/verify/v3-upgrade "$records/$log" --mc "$contract" "$@" \
    "$FORGE_VERBOSITY"
}
