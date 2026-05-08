#!/usr/bin/env bash
# ============================================================
# master_collect.sh
# ============================================================

HOSTS_FILE="./hosts.txt"
COLLECT_SCRIPT="./collect.sh"
OUTPUT_DIR="./csv_output"
PARALLEL_JOBS=15
LOG_FILE="./failed_hosts.log"

mkdir -p "$OUTPUT_DIR"
> "$LOG_FILE"

if [[ ! -f "$HOSTS_FILE" ]];    then echo "ERROR: hosts.txt not found";  exit 1; fi
if [[ ! -f "$COLLECT_SCRIPT" ]]; then echo "ERROR: collect.sh not found"; exit 1; fi

if ! klist -s 2>/dev/null; then
    echo "ERROR: No valid Kerberos ticket — run: kinit your_username@REALM.COM"
    exit 1
fi

SSH_OPTS="-q -t \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=20 \
    -o ServerAliveInterval=15"

SCP_OPTS="-q \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout=20"

# -----------------------------------------------
run_on_host() {
    local host="$1"
    local outfile="${OUTPUT_DIR}/${host}.csv"

    # Step 1 — push collect.sh to /tmp on remote server
    scp $SCP_OPTS "$COLLECT_SCRIPT" "${host}:/tmp/collect.sh" 2>>"$LOG_FILE"
    if [[ $? -ne 0 ]]; then
        echo "[FAIL-SCP] $host"
        echo "$host" >> "$LOG_FILE"
        return
    fi

    # Step 2 — run as sudo, cat CSV back locally
    ssh $SSH_OPTS "$host" \
        "sudo bash /tmp/collect.sh && cat \$(ls -t /tmp/*.csv | head -1) && rm -f /tmp/collect.sh" \
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
export COLLECT_SCRIPT OUTPUT_DIR LOG_FILE SSH_OPTS SCP_OPTS

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
