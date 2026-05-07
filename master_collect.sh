#!/usr/bin/env bash
# ============================================================
# master_collect.sh
#
# What it does:
#   1. Reads your 165 hosts from hosts.txt
#   2. For each host (in parallel):
#      a. SCPs collect.sh to the remote server /tmp/
#      b. SSHs in and runs it as sudo
#      c. Pulls the resulting CSV back to csv_output/<hostname>.csv
#
# Usage: ./master_collect.sh
# ============================================================

# --- Configuration ---
HOSTS_FILE="./hosts.txt"            # your list of 165 hosts
COLLECT_SCRIPT="./collect.sh"       # the vendor script on YOUR jump server
EXPECT_SCRIPT="./run_collect.exp"   # must be in same directory
OUTPUT_DIR="./csv_output"           # where per-host CSVs will be saved
PARALLEL_JOBS=15                    # how many hosts to hit simultaneously
LOG_FILE="./failed_hosts.log"       # failed hosts get logged here

# --- Setup ---
mkdir -p "$OUTPUT_DIR"
> "$LOG_FILE"

# Sanity checks
if [[ ! -f "$HOSTS_FILE" ]]; then
    echo "ERROR: hosts.txt not found — add your 165 hosts to it"
    exit 1
fi

if [[ ! -f "$COLLECT_SCRIPT" ]]; then
    echo "ERROR: collect.sh not found — place the vendor script in this directory"
    exit 1
fi

if [[ ! -f "$EXPECT_SCRIPT" ]]; then
    echo "ERROR: run_collect.exp not found — must be in same directory as this script"
    exit 1
fi

if ! command -v expect &>/dev/null; then
    echo "ERROR: 'expect' is not installed. Run: sudo yum install -y expect"
    exit 1
fi

# --- Read credentials once at the start ---
read -rp  "IPA Username: " IPA_USER
read -rsp "IPA Password: " IPA_PASS
echo ""

if [[ -z "$IPA_USER" || -z "$IPA_PASS" ]]; then
    echo "ERROR: Username or password cannot be empty"
    exit 1
fi

# -----------------------------------------------
# Worker function — runs once per host
# -----------------------------------------------
run_on_host() {
    local host="$1"
    local outfile="${OUTPUT_DIR}/${host}.csv"

    expect "$EXPECT_SCRIPT" \
        "$host" \
        "$IPA_USER" \
        "$IPA_PASS" \
        "$COLLECT_SCRIPT" \
        "$outfile" \
        2>> "$LOG_FILE"

    local rc=$?

    if [[ $rc -ne 0 || ! -s "$outfile" ]]; then
        echo "[FAIL] $host"
        echo "$host" >> "$LOG_FILE"
    else
        echo "[OK]   $host — $(wc -l < "$outfile") rows"
    fi
}

export -f run_on_host
export IPA_USER IPA_PASS COLLECT_SCRIPT EXPECT_SCRIPT OUTPUT_DIR LOG_FILE

# -----------------------------------------------
# Main — parallel execution across all hosts
# -----------------------------------------------
TOTAL_HOSTS=$(grep -v '^\s*#' "$HOSTS_FILE" | grep -v '^\s*$' | wc -l)

echo ""
echo "============================================="
echo " Mass Collection Starting"
echo "============================================="
echo "  Vendor script : $COLLECT_SCRIPT"
echo "  Total hosts   : $TOTAL_HOSTS"
echo "  Parallel jobs : $PARALLEL_JOBS"
echo "  Output dir    : $OUTPUT_DIR"
echo "  Started       : $(date)"
echo "============================================="
echo ""

grep -v '^\s*#' "$HOSTS_FILE" | grep -v '^\s*$' | \
    xargs -P "$PARALLEL_JOBS" -I{} bash -c 'run_on_host "$@"' _ {}

# -----------------------------------------------
# Summary
# -----------------------------------------------
FAILED_COUNT=$(sort -u "$LOG_FILE" | grep -v '^\s*$' | wc -l)
SUCCESS_COUNT=$(ls "$OUTPUT_DIR"/*.csv 2>/dev/null | wc -l)

echo ""
echo "============================================="
echo " Done!"
echo "============================================="
echo "  CSVs saved to : $OUTPUT_DIR/"
echo "  Succeeded     : $SUCCESS_COUNT / $TOTAL_HOSTS hosts"
echo "  Failed        : $FAILED_COUNT hosts"
if [[ $FAILED_COUNT -gt 0 ]]; then
echo "  Failed list   : $LOG_FILE"
fi
echo "  Finished      : $(date)"
echo "============================================="
