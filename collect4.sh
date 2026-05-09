#!/usr/bin/env bash

# ============================================================

# master_collect.sh

# 

# Requirements:

# - .env file in same directory containing: SUDO_PASS=yourpassword

# - collect.sh in same directory

# - hosts.txt in same directory with one host per line

# 

# Usage:

# chmod +x master_collect.sh

# ./master_collect.sh

# 

# Output:

# csv_output/<hostname>.csv  — one CSV per host

# failed_hosts.log           — any hosts that failed

# ============================================================

HOSTS_FILE=”./hosts.txt”
COLLECT_SCRIPT=”./collect.sh”
OUTPUT_DIR=”./csv_output”
PARALLEL_JOBS=15
LOG_FILE=”./failed_hosts.log”

# — Load password from .env —

if [[ ! -f “.env” ]]; then
echo “ERROR: .env file not found — create it with: SUDO_PASS=yourpassword”
exit 1
fi
source .env

if [[ -z “$SUDO_PASS” ]]; then
echo “ERROR: SUDO_PASS not set in .env”
exit 1
fi

# — Sanity checks —

if [[ ! -f “$HOSTS_FILE” ]];     then echo “ERROR: hosts.txt not found”;  exit 1; fi
if [[ ! -f “$COLLECT_SCRIPT” ]]; then echo “ERROR: collect.sh not found”; exit 1; fi

mkdir -p “$OUTPUT_DIR”

> “$LOG_FILE”

# ———————————————–

# Worker function — runs once per host

# ———————————————–

run_on_host() {
local host=”$1”
local outfile=”${OUTPUT_DIR}/${host}.csv”

```
# Step 1 — SCP collect.sh to /tmp on remote host
scp -q \
    -o StrictHostKeyChecking=no \
    -o LogLevel=ERROR \
    -o ConnectTimeout=20 \
    "$COLLECT_SCRIPT" \
    "${host}:/tmp/collect.sh" 2>>"$LOG_FILE"

if [[ $? -ne 0 ]]; then
    echo "[FAIL-SCP] $host"
    echo "$host" >> "$LOG_FILE"
    return
fi

# Step 2 — Run collect.sh as sudo, cat CSV back, cleanup
ssh -t \
    -o StrictHostKeyChecking=no \
    -o LogLevel=ERROR \
    -o ConnectTimeout=20 \
    -o ServerAliveInterval=15 \
    "$host" \
    "echo '${SUDO_PASS}' | sudo -S -p '' bash /tmp/collect.sh && cat \$(ls -t /tmp/*.csv | head -1) && rm -f /tmp/collect.sh" \
    > "$outfile" 2>>"$LOG_FILE"

if [[ $? -ne 0 || ! -s "$outfile" ]]; then
    echo "[FAIL-SSH] $host"
    echo "$host" >> "$LOG_FILE"
    rm -f "$outfile"
else
    echo "[OK]       $host — $(wc -l < "$outfile") rows"
fi
```

}

export -f run_on_host
export COLLECT_SCRIPT OUTPUT_DIR LOG_FILE SUDO_PASS

# ———————————————–

# Main

# ———————————————–

TOTAL=$(grep -v ‘^\s*#’ “$HOSTS_FILE” | grep -v ‘^\s*$’ | wc -l)

echo “”
echo “=============================================”
echo “ Mass Collection Starting”
echo “=============================================”
echo “  Total hosts   : $TOTAL”
echo “  Parallel jobs : $PARALLEL_JOBS”
echo “  Output dir    : $OUTPUT_DIR”
echo “  Started       : $(date)”
echo “=============================================”
echo “”

grep -v ‘^\s*#’ “$HOSTS_FILE” | grep -v ‘^\s*$’ |   
xargs -P “$PARALLEL_JOBS” -I{} bash -c ‘run_on_host “$@”’ _ {}

SUCCESS=$(ls “$OUTPUT_DIR”/*.csv 2>/dev/null | wc -l)
FAILED=$(sort -u “$LOG_FILE” | grep -v ’^\s*$’ | wc -l)

echo “”
echo “=============================================”
echo “ Done!”
echo “=============================================”
echo “  CSVs saved to : $OUTPUT_DIR/”
echo “  Succeeded     : $SUCCESS / $TOTAL hosts”
echo “  Failed        : $FAILED hosts”
[[ $FAILED -gt 0 ]] && echo “  Failed list   : $LOG_FILE”
echo “  Finished      : $(date)”
echo “=============================================”