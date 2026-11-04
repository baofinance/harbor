#!/usr/bin/env bash
#
# etherscan-logs.sh - sourced by capture-holders and capture-logs beside it: every log of one contract over a block
# range, from Etherscan's `logs/getLogs` API.
#
# Why Etherscan (not cast logs): some RPC providers cap eth_getLogs at 10 blocks per call, which makes scanning
# millions of blocks impossible, and a scan that size uses up an RPC allowance. Etherscan's getLogs is not
# block-range limited (1000 records a page, paginated by block).
#
# etherscan_logs <address> <from-block> <to-block> [<topic0>]
#   Prints each log of the contract at <address> in [<from-block>, <to-block>] once, as one line of JSON with
#   Etherscan's own fields, in the order Etherscan returns them; with <topic0>, only the logs whose first topic it
#   is. A number field is hex, `0x0` for zero (Etherscan writes some zeros as a bare `0x`). Returns non-zero on a curl
#   or API failure; "No records found" is an empty result, not a failure. Needs ETHERSCAN_KEY.

ETHERSCAN_CHAIN_ID=1
ETHERSCAN_PAGE_SIZE=1000 # Etherscan's most records a page

# One getLogs response on stdin. Prints "COUNT LASTBLOCK" on line 1, then one line per log:
# "<transaction hash>:<log index>", a tab, and the log as JSON. Exits non-zero on a genuine API error.
_etherscan_parse_page() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("API returned non-JSON: " + raw[:200], file=sys.stderr)
    sys.exit(2)
status = str(d.get("status", "0"))
result = d.get("result")
if status != "1":
    msg = str(d.get("message", ""))
    if "No records" in msg or result == []:
        print("0 0")
        sys.exit(0)
    print("Etherscan error: %s %r" % (msg, result), file=sys.stderr)
    sys.exit(2)
# Etherscan writes zero as "0x" in some number fields, such as a block'"'"'s first log index.
for log in result:
    for field in ("blockNumber", "timeStamp", "gasPrice", "gasUsed", "logIndex", "transactionIndex"):
        if log.get(field) in ("", "0x"):
            log[field] = "0x0"
last = 0
for log in result:
    last = max(last, int(log["blockNumber"], 16))
print("%d %d" % (len(result), last))
for log in result:
    key = "%s:%d" % (log["transactionHash"], int(log["logIndex"], 16))
    print(key + "\t" + json.dumps(log, sort_keys=True, separators=(",", ":")))
'
}

# Every page of the logs, paginating by advancing fromBlock to the last block of a full page. Consecutive pages then
# share that block's logs, so each log line carries its key for etherscan_logs to drop the repeats.
_etherscan_pages() {
  local address="$1" from="$2" to="$3" topic0="${4:-}"
  local filter="" resp parsed meta count last
  if [[ -n "$topic0" ]]; then
    filter="&topic0=${topic0}"
  fi
  while true; do
    if ! resp=$(curl -s "https://api.etherscan.io/v2/api?chainid=${ETHERSCAN_CHAIN_ID}&module=logs&action=getLogs&address=${address}${filter}&fromBlock=${from}&toBlock=${to}&offset=${ETHERSCAN_PAGE_SIZE}&page=1&apikey=${ETHERSCAN_KEY}"); then
      echo "ERROR: curl failed for $address from $from" >&2
      return 1
    fi
    # The assignment's status is the pipeline's last command, the parser, which exits non-zero on an API error.
    if ! parsed=$(printf '%s' "$resp" | _etherscan_parse_page); then
      echo "ERROR: parsing Etherscan response for $address from $from" >&2
      return 1
    fi
    meta=$(printf '%s\n' "$parsed" | head -1)
    count=${meta%% *}
    last=${meta##* }
    printf '%s\n' "$parsed" | tail -n +2

    # Stop when the page was not full.
    if ((count < ETHERSCAN_PAGE_SIZE)); then
      break
    fi
    # A full page all in one block cannot advance.
    if ((last <= from)); then
      echo "ERROR: $address: a full page ($count logs) all in block $last - the scan cannot advance" >&2
      return 1
    fi
    from=$last
  done
}

etherscan_logs() {
  _etherscan_pages "$@" | awk -F'\t' '!seen[$1]++ { print $2 }'
  local statuses=("${PIPESTATUS[@]}")
  ((statuses[0] == 0 && statuses[1] == 0))
}
