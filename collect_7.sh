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

    # Step 2 — Run collect.sh, grab remote CSV filename, detect RHEL version
    # Wraps CSV output in markers to strip all noise/warnings
    # Also grabs: the exact /tmp CSV filename and the RHEL version
    REMOTE_CMD="echo '${INFO_LIFE}' | sudo -S -p '' bash /tmp/collect.sh 2>/dev/null; \
                CSV=\$(echo '${INFO_LIFE}' | sudo -S -p '' ls -t /tmp/*connections*.csv 2>/dev/null | head -1); \
                OS_TAG=\$(if grep -qi 'vmware\|nsx' /etc/os-release 2>/dev/null || uname -r 2>/dev/null | grep -qi 'vmware\|nsx'; then echo vmware; elif grep -qi ubuntu /etc/os-release 2>/dev/null || [ -f /etc/lsb-release ]; then echo ubuntu; elif [ -f /etc/redhat-release ]; then VER=\$(rpm -q --queryformat '%{VERSION}' redhat-release 2>/dev/null | cut -c1); echo rhel\${VER}; else echo unknown; fi); \
                echo '##CSV_START##'; \
                echo '${INFO_LIFE}' | sudo -S -p '' cat \$CSV 2>/dev/null; \
                echo '##CSV_END##'; \
                echo '##META_START##'; \
                echo \$CSV; \
                echo \$OS_TAG; \
                echo '##META_END##'; \
                echo '${INFO_LIFE}' | sudo -S -p '' rm -f /tmp/collect.sh 2>/dev/null"

    local raw
    raw=$(ssh -tt \
        -o StrictHostKeyChecking=no \
        -o LogLevel=ERROR \
        -o ConnectTimeout=20 \
        -o ServerAliveInterval=15 \
        "$host" "$REMOTE_CMD" 2>>"$LOG_FILE")

    # Extract the remote CSV filename and RHEL version from meta block
    local meta
    meta=$(echo "$raw" | sed -n '/##META_START##/,/##META_END##/{ /##META_START##/d; /##META_END##/d; p }')
    local remote_csv_name os_tag
    remote_csv_name=$(echo "$meta" | head -1 | xargs basename 2>/dev/null)
    os_tag=$(echo "$meta" | tail -1 | tr -d '\r\n ')

    # Build output filename: original_name_without_ext + _os_tag.csv
    # e.g. hostname_20260508_230856_connections_rhel6.csv
    #      hostname_20260508_230856_connections_ubuntu.csv
    #      hostname_20260508_230856_connections_vmware.csv
    local base_name
    base_name=$(echo "$remote_csv_name" | sed 's/\.csv$//')

    if [[ -z "$os_tag" ]]; then
        os_tag="unknown"
    fi

    local outfile="${OUTPUT_DIR}/${base_name}_${os_tag}.csv"

    # Strip everything before the real CSV header — pure data only
    echo "$raw" \
        | sed -n '/##CSV_START##/,/##CSV_END##/{ /##CSV_START##/d; /##CSV_END##/d; p }' \
        | awk '/^Source Server IP Address,/{found=1} found' \
        > "$outfile"

    if [[ $? -ne 0 || ! -s "$outfile" ]]; then
        echo "[FAIL-SSH] $host"
        echo "$host" >> "$LOG_FILE"
        rm -f "$outfile"
    else
        echo "[OK]       $host (${os_tag}) — $(wc -l < "$outfile") rows → $(basename $outfile)"
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
