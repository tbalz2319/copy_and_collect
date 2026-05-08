#!/usr/bin/env bash
# ============================================================
# master_collect.sh
#
# Requirements:
#   - Valid Kerberos ticket (run: kinit your_username@REALM.COM)
#   - collect.sh in the same directory as this script
#   - hosts.txt in the same directory as this script
#
# Usage:
#   chmod +x master_collect.sh
#   kinit your_username@REALM.COM
#   ./master_collect.sh
#
# Output:
#   csv_output/<hostname>.csv  — one CSV per host
#   failed_hosts.log           — any hosts that failed
# ============================================================

HOSTS_FILE="./hosts.txt"
COLLECT_SCRIPT="./collect.sh"
OUTPUT_DIR="./csv_output"
PARALLEL_JOBS=15
LOG_FILE="./failed_hosts.log"

# --- Setup ---
mkdir -p "$OUTPUT_DIR"
> "$LOG_FILE"

# Sanity checks
if [[ ! -f "$HOSTS_FILE" ]]; then
    echo "ERROR: hosts.txt not found"
    exit 1
fi

if [[ ! -f "$COLLECT_SCRIPT" ]]; then
    echo "ERROR: collect.sh not found in current directory"
    exit 1
fi

# Check Kerberos ticket is valid before starting
if ! klist -s 2>/dev/null; then
    echo "ERROR: No valid Kerberos ticket found — run: kinit your_username@REALM.COM"
    exit 1
fi

# -----------------------------------------------
# Worker function — runs once per host
# -----------------------------------------------
run_on_host() {
    local host="$1"
    local outfile="${OUTPUT_DIR}/${host}.csv"

    # Step 1 — SCP collect.sh to remote home directory
    scp -q \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=20 \
        -o KexAlgorithms=+diffie-hellman-group1-sha1 \
        -o HostKeyAlgorithms=+ssh-rsa \
        -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        "$COLLECT_SCRIPT" \
        "${host}:~/collect.sh" 2>>"$LOG_FILE"

    if [[ $? -ne 0 ]]; then
        echo "[FAIL-SCP]  $host"
        echo "$host" >> "$LOG_FILE"
        return
    fi

    # Step 2 — SSH in, run collect.sh as sudo, cat CSV back, cleanup
    ssh -q \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=20 \
        -o ServerAliveInterval=15 \
        -o KexAlgorithms=+diffie-hellman-group1-sha1 \
        -o HostKeyAlgorithms=+ssh-rsa \
        -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        "$host" \
        "sudo bash ~/collect.sh && cat \$(ls -t /tmp/*.csv | head -1) && rm -f ~/collect.sh" \
        > "$outfile" 2>>"$LOG_FILE"

    if [[ $? -ne 0 || ! -s "$outfile" ]]; then
        echo "[FAIL-SSH]  $host"
        echo "$host" >> "$LOG_FILE"
        rm -f "$outfile"
    else
        echo "[OK]        $host — $(wc -l < "$outfile") rows"
    fi
}

export -f run_on_host
export COLLECT_SCRIPT OUTPUT_DIR LOG_FILE

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
