#!/usr/bin/env bash
#
# Emits Monad node metrics for the node_exporter textfile collector.
#
# Every value is derived at run time. If this file's metrics stop changing,
# this script has stopped running: check the cron entry or systemd timer.
#
# Configuration (all optional, defaults preserve previous behaviour):
#   TARGET_DRIVE   device holding the TrieDB, e.g. "triedb" or "nvme1n1p1".
#                  Resolved from $MONAD_ENV_FILE when unset.
#   MONAD_HOME     monad-bft data directory. Default /home/monad/monad-bft
#   MONAD_ENV_FILE node .env file to read TARGET_DRIVE from. Default /home/monad/.env
#   JOURNAL_UNIT   systemd unit to read consensus state from. Default monad-bft
#   JOURNAL_LINES  how many journal lines to scan. Default 2000
#   OUTPUT_FILE    .prom file to write. Default <script dir>/data/monad-metrics-data.prom

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MONAD_HOME="${MONAD_HOME:-/home/monad/monad-bft}"
MONAD_ENV_FILE="${MONAD_ENV_FILE:-/home/monad/.env}"
JOURNAL_UNIT="${JOURNAL_UNIT:-monad-bft}"
JOURNAL_LINES="${JOURNAL_LINES:-2000}"
OUTPUT_FILE="${OUTPUT_FILE:-$script_dir/data/monad-metrics-data.prom}"
MONAD_MPT="${MONAD_MPT:-/usr/local/bin/monad-mpt}"

# Resolve the TrieDB device. Prefer an explicit TARGET_DRIVE, then the node
# .env, then the /dev/triedb udev symlink that the standard install creates.
if [ -z "${TARGET_DRIVE:-}" ] && [ -r "$MONAD_ENV_FILE" ]; then
    TARGET_DRIVE="$(grep -m1 '^TARGET_DRIVE=' "$MONAD_ENV_FILE" | cut -d= -f2- | tr -d '"'"'"' \r')"
fi
if [ -z "${TARGET_DRIVE:-}" ] && [ -e /dev/triedb ]; then
    TARGET_DRIVE="triedb"
fi
if [ -z "${TARGET_DRIVE:-}" ]; then
    echo "TARGET_DRIVE is not set, not in $MONAD_ENV_FILE, and /dev/triedb does not exist" >&2
    exit 1
fi
TRIEDB_DEV="/dev/${TARGET_DRIVE#/dev/}"

output_dir="$(dirname "$OUTPUT_FILE")"
mkdir -p "$output_dir" || { echo "Cannot create $output_dir" >&2; exit 1; }

# Build the file off to one side and move it into place at the end. node_exporter
# reads this directory continuously and would otherwise be able to observe a
# half-written file.
tmp_file="$(mktemp "$output_dir/.monad-metrics-data.XXXXXX")" || exit 1
trap 'rm -f "$tmp_file"' EXIT

# node_exporter discards the *entire* textfile on a single malformed line, so a
# metric whose source could not be parsed is omitted rather than written blank.
# One broken parser therefore costs one metric, not all of them.
emit_gauge() {
    local name=$1 help=$2 value=$3
    case "$value" in
        '' | *[!0-9]*) return 0 ;;
    esac
    printf '# HELP %s %s\n# TYPE %s gauge\n%s %s\n' "$name" "$help" "$name" "$name" "$value" >> "$tmp_file"
}

# "1.75 Tb" -> bytes. monad-mpt labels binary units as Tb/Gb/Mb/Kb.
to_bytes() {
    local value=$1 unit=$2 multiplier
    case "${unit,,}" in
        tb) multiplier=$((1024 ** 4)) ;;
        gb) multiplier=$((1024 ** 3)) ;;
        mb) multiplier=$((1024 ** 2)) ;;
        kb) multiplier=1024 ;;
        b)  multiplier=1 ;;
        *)  return 1 ;;
    esac
    case "$value" in
        '' | *[!0-9.]*) return 1 ;;
    esac
    awk -v v="$value" -v m="$multiplier" 'BEGIN { printf "%.0f", v * m }'
}

# TrieDB capacity. The header row reads "Capacity Used % Path" and the row under
# it carries all three, so one grep serves every field.
mpt_row="$("$MONAD_MPT" --storage "$TRIEDB_DEV" 2>/dev/null | grep -A1 'Capacity' | tail -n1 | tr -d '\r')"
if [ -n "$mpt_row" ]; then
    capacity_bytes="$(to_bytes "$(awk '{print $1}' <<<"$mpt_row")" "$(awk '{print $2}' <<<"$mpt_row")")" || capacity_bytes=""
    used_bytes="$(to_bytes "$(awk '{print $3}' <<<"$mpt_row")" "$(awk '{print $4}' <<<"$mpt_row")")" || used_bytes=""

    emit_gauge mc_triedb_total_bytes "Total capacity of $TRIEDB_DEV" "$capacity_bytes"
    emit_gauge mc_triedb_used_bytes "Used capacity of $TRIEDB_DEV" "$used_bytes"
    if [ -n "$capacity_bytes" ] && [ -n "$used_bytes" ]; then
        emit_gauge mc_triedb_avail_bytes "Available capacity of $TRIEDB_DEV" "$((capacity_bytes - used_bytes))"
    fi

    # monad-mpt rounds the byte columns to three significant figures, so a
    # percentage derived from them drifts by up to ~1 point. It prints its own
    # percentage at full precision, so publish that directly for alerting.
    used_percent="$(awk '{print $5}' <<<"$mpt_row" | tr -d '%')"
    case "$used_percent" in
        '' | *[!0-9.]*) ;;
        *) printf '# HELP %s %s\n# TYPE %s gauge\n%s %s\n' \
               mc_triedb_used_percent "Used percentage of $TRIEDB_DEV as reported by monad-mpt" \
               mc_triedb_used_percent mc_triedb_used_percent "$used_percent" >> "$tmp_file" ;;
    esac
else
    echo "Failed to read TrieDB capacity from $MONAD_MPT --storage $TRIEDB_DEV" >&2
fi

journal="$(journalctl -u "$JOURNAL_UNIT" -n "$JOURNAL_LINES" --no-pager 2>/dev/null)"

# Consensus epoch, logged as "epoch: 2094". The quantifier must be + and not *,
# or a zero-digit match wins the tail and the metric is emitted empty.
emit_gauge mc_current_epoch "Monad consensus epoch" \
    "$(grep -oE 'epoch: [0-9]+' <<<"$journal" | tail -n1 | grep -oE '[0-9]+')"

# Consensus round, logged as "round":"104796300".
emit_gauge mc_current_round "Monad consensus round" \
    "$(grep -oE '"round":"[0-9]+"' <<<"$journal" | tail -n1 | grep -oE '[0-9]+')"

emit_gauge mc_forkpoint_dir_count "File count of the Monad forkpoint directory" \
    "$(find "$MONAD_HOME/config/forkpoint" -type f 2>/dev/null | wc -l | tr -d ' ')"
emit_gauge mc_ledger_dir_count "File count of the Monad ledger directory" \
    "$(find "$MONAD_HOME/ledger" -type f 2>/dev/null | wc -l | tr -d ' ')"
emit_gauge mc_wal_dir_count "File count of Monad wal files" \
    "$(find "$MONAD_HOME" -type f -name 'wal_*' 2>/dev/null | wc -l | tr -d ' ')"

# Freshness heartbeat. Alert on time() - this metric to catch the collector
# dying silently, which is otherwise invisible: the gauges above simply hold
# their last value and every dashboard and alert keeps reading as healthy.
emit_gauge mc_collector_last_success_timestamp_seconds \
    "Unix time of the last successful collector run" "$(date +%s)"

mv -f "$tmp_file" "$OUTPUT_FILE" || { echo "Cannot write $OUTPUT_FILE" >&2; exit 1; }
trap - EXIT
chmod 0644 "$OUTPUT_FILE"
