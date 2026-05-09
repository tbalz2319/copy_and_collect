#!/usr/bin/env bash
# ============================================================
# master_collect.sh
#
# Requirements:
#   - .env2 file in same directory containing: INFO_LIFE=yourpassword
#   - collect.sh in same directory
#   - hosts.txt in same directory with one host per line
#
# Usage:
#   chmod +x master_collect.sh
#   ./master_collect.sh
# ============================================================

HOSTS_FILE="./hosts.txt"
COLLECT_SCRIPT="./collect.sh"
OUTPUT_DIR="./csv_output"
PARALLEL_JOBS=15
LOG_FILE="./failed_hosts.log"

# --- Load password from .env2 ---
if [[ ! -f ".env2" ]]; then
    echo "ERROR: .env2 file not found — create it with: INFO_LIFE=yourpassword"
    exit 1
fi
source .env2

if [[ -z "$INFO_LIFE" ]]; then
    echo "ERROR: INFO_LIFE not set in .env2"
    exit 1
fi

# --- Sanity checks ---
if [[ ! -f "$HOSTS_FILE" ]];     then echo "ERROR: hosts.txt not found";  exit 1; fi
if [[ ! -f "$COLLECT_SCRIPT" ]]; then echo "ERROR: collect.sh not found"; exit 1; fi

mkdir -p "$OUTPUT_DIR"
> "$LOG_FILE"

# -----------------------------------------------
# Worker function — runs once per host
# -----------------------------------------------
run_on_host() {
    local host="$1"
    local outfile="${OUTPUT_DIR}/${host}.csv"

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

    # Step 2 — Build remote command as a variable to keep it clean
    # -tt forces TTY even through xargs (fixes sudo requiretty on RHEL5/6)
    # sudo cat needed because collect.sh runs as root and owns the CSV
    # stderr goes to logfile so chdir/.bashrc warnings never pollute the CSV
    REMOTE_CMD="echo '${INFO_LIFE}' | sudo -S -p '' bash /tmp/collect.sh 2>/dev/null; \
                CSV=\$(sudo -S -p '' ls -t /tmp/*.csv 2>/dev/null | head -1); \
                echo '${INFO_LIFE}' | sudo -S -p '' cat \$CSV 2>/dev/null; \
                echo '${INFO_LIFE}' | sudo -S -p '' rm -f /tmp/collect.sh 2>/dev/null"

    ssh -tt \
        -o StrictHostKeyChecking=no \
        -o LogLevel=ERROR \
        -o ConnectTimeout=20 \
        -o ServerAliveInterval=15 \
        "$host" "$REMOTE_CMD" \
        > "$outfile" 2>>"$LOG_FILE"

    if [[ $? -ne 0 || ! -s "$outfile" ]]; then
        echo "[FAIL-SSH] $host"
        echo "$host" >> "$LOG_FILE"
        rm -f "$outfile"
    else
        echo "[OK]       $host — $(wc -l < "$outfile") rows"
    fi
}

export -f run_on_host
export COLLECT_SCRIPT OUTPUT_DIR LOG_FILE INFO_LIFE

# -----------------------------------------------
# Main
# -----------------------------------------------
TOTAL=$(grep -v '^\s*#' "$HOSTS_FILE" | grep -v '^\s*$' | wc -l)

echo ""
echo "============================================="
echo " Mass Collection Starting"
echo "============================================="
echo "  Total hosts   : $TOTAL"
echo "  Parallel jobs : $PARALLEL_JOBS"
echo "  Output dir    : $OUTPUT_DIR"
echo "  Started       : $(date)"
echo "============================================="
echo ""

grep -v '^\s*#' "$HOSTS_FILE" | grep -v '^\s*$' | \
    xargs -P "$PARALLEL_JOBS" -I{} bash -c 'run_on_host "$@"' _ {}

SUCCESS=$(ls "$OUTPUT_DIR"/*.csv 2>/dev/null | wc -l)
FAILED=$(sort -u "$LOG_FILE" | grep -v '^\s*$' | wc -l)

echo ""
echo "============================================="
echo " Done!"
echo "============================================="
echo "  CSVs saved to : $OUTPUT_DIR/"
echo "  Succeeded     : $SUCCESS / $TOTAL hosts"
echo "  Failed        : $FAILED hosts"
[[ $FAILED -gt 0 ]] && echo "  Failed list   : $LOG_FILE"
echo "  Finished      : $(date)"
echo "============================================="
