#!/usr/bin/env bash
# filepath: ~/.local/bin/forge-memory-profile

set -e

MAX_TESTS=${MAX_TESTS:-0}
count=0

# Output file
OUTPUT_CSV="/tmp/forge-memory-profile.csv"
OUTPUT_TXT="/tmp/forge-memory-profile.txt"

echo "Profiling forge tests for memory usage..."
echo "This will take a while - running each test individually"
echo ""

# Create CSV header
echo "Contract,Test,Peak_RAM_MB,Peak_Swap_MB,Duration_s,Status" >"$OUTPUT_CSV"

# Helper to escape regex metacharacters for forge filters
escape_regex() {
  sed -e 's/[\\.*\[\]\^$+?(){}|]/\\&/g'
}

current_contract=""

while IFS= read -r line; do
  # Trim trailing carriage returns/spaces
  trimmed="${line%$'\r'}"

  case "$trimmed" in
    "")
      continue
      ;;
    "    "*)
      # Test line (four leading spaces)
      test_name="${trimmed#    }"
      if [[ -z "$current_contract" ]]; then
        continue
      fi
      if [[ ! $test_name =~ ^test_ ]]; then
        continue
      fi

      contract_regex=$(printf "%s" "$current_contract" | escape_regex)
      test_regex=$(printf "%s" "$test_name" | escape_regex)

      # echo "Running: $current_contract::$test_name"

      start_time=$(date +%s)
      start_mem=$(free -m | awk '/^Mem:/ {print $3}')
      start_swap=$(free -m | awk '/^Swap:/ {print $3}')

      if timeout 300 forge test --match-contract "^${contract_regex}$" --match-test "^${test_regex}$" >/dev/null 2>&1; then
        status="PASS"
      else
        exit_code=$?
        if [ $exit_code -eq 124 ]; then
          status="TIMEOUT"
        else
          status="FAIL"
        fi
      fi

      end_time=$(date +%s)
      end_mem=$(free -m | awk '/^Mem:/ {print $3}')
      end_swap=$(free -m | awk '/^Swap:/ {print $3}')

      duration=$((end_time - start_time))
      peak_mem=$((end_mem > start_mem ? end_mem - start_mem : 0))
      peak_swap=$((end_swap > start_swap ? end_swap - start_swap : 0))

      echo "$current_contract,$test_name,$peak_mem,$peak_swap,$duration,$status" >>"$OUTPUT_CSV"
      echo "$current_contract,$test_name,$peak_mem,$peak_swap,$duration,$status"

      sleep 1

      count=$((count + 1))
      if [[ $MAX_TESTS -gt 0 && $count -ge $MAX_TESTS ]]; then
        break
      fi
      ;;
    "  "*)
      # Contract line (two leading spaces)
      candidate="${trimmed#  }"
      if [[ -z "$candidate" ]]; then
        continue
      fi
      current_contract="$candidate"
      continue
      ;;
    *)
      # File path line – ignore
      continue
      ;;
  esac
done < <(forge test --list)

echo ""
echo "Profiling complete!"
echo "Results saved to: $OUTPUT_CSV"
echo ""
echo "Top 10 tests by RAM usage:"
sort -t',' -k3 -rn "$OUTPUT_CSV" | head -11 | column -t -s','

echo ""
echo "Top 10 tests by Swap usage:"
sort -t',' -k4 -rn "$OUTPUT_CSV" | head -11 | column -t -s','

echo ""
echo "Failed/Timeout tests:"
grep -E '(FAIL|TIMEOUT)$' "$OUTPUT_CSV" | column -t -s',' || echo "None"
