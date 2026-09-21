#!/usr/bin/env bash

# Compact process monitor for agent-leak-app.
# It records only the data needed to diagnose OOM, CPU, and Deadlock cases.

set -u

PROCESS_NAME="agent-leak-app"
TARGET_PID=""
INTERVAL=1
DURATION=0
OUTPUT="monitor.log"

usage() {
    cat <<'EOF'
Usage: ./monitor.sh [options]

Options:
  -p PID       Monitor one PID.
  -n NAME      Match an executable/command name (default: agent-leak-app).
  -i SECONDS   Sampling interval (default: 1).
  -d SECONDS   Stop after this duration; 0 means until the process exits.
  -o FILE      Output file (default: monitor.log, overwritten per run).
  -h           Show this help.
EOF
}

while getopts ":p:n:i:d:o:h" opt; do
    case "$opt" in
        p) TARGET_PID="$OPTARG" ;;
        n) PROCESS_NAME="$OPTARG" ;;
        i) INTERVAL="$OPTARG" ;;
        d) DURATION="$OPTARG" ;;
        o) OUTPUT="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "Missing argument for -$OPTARG" >&2; exit 2 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; exit 2 ;;
    esac
done

if ! [[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
    echo "INTERVAL must be numeric and DURATION must be a non-negative integer" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUTPUT")"
: > "$OUTPUT"

now() {
    date '+%Y-%m-%d %H:%M:%S%z'
}

write_log() {
    printf '%s\n' "$1" >> "$OUTPUT"
}

process_rows() {
    ps -eo pid=,pcpu=,pmem=,rss=,stat=,nlwp=,comm=,args= 2>/dev/null |
        awk -v name="$PROCESS_NAME" -v self="$$" '
            $1 != self && $7 !~ /(monitor|bash|su|ps|awk|sleep)/ && $0 ~ name {print}'
}

find_pid() {
    if [[ -n "$TARGET_PID" ]]; then
        ps -p "$TARGET_PID" -o pid= 2>/dev/null | awk '{$1=$1; print; exit}'
    else
        process_rows | awk 'NR == 1 {print $1; exit}'
    fi
}

write_auto_snapshot() {
    local row
    row="$(process_rows | awk '
        {
            count++;
            pids = pids (count == 1 ? "" : ",") $1;
            cpu += $2;
            mem += $3;
            rss += $4;
            threads += $6;
            if (state == "") state = $5;
        }
        END {
            if (count > 0) printf "%s\t%.2f\t%.2f\t%.2f\t%d\t%s", pids, cpu, mem, rss / 1024, threads, state;
        }')"

    [[ -n "$row" ]] || return 1

    local pids cpu mem rss_mb threads state
    IFS=$'\t' read -r pids cpu mem rss_mb threads state <<< "$row"
    printf '%-25s PID=%-15s CPU=%6s%% MEM=%6s%% RSS=%8sMB THR=%-3s STATE=%s\n' \
        "$(now)" "$pids" "$cpu" "$mem" "$rss_mb" "$threads" "$state" >> "$OUTPUT"
}

write_pid_snapshot() {
    local pid="$1"
    local row
    row="$(ps -p "$pid" -o '%cpu=,%mem=,rss=,stat=,nlwp=' 2>/dev/null | awk '{$1=$1; print}')"
    [[ -n "$row" ]] || return 1

    local cpu mem rss_kb state threads
    read -r cpu mem rss_kb state threads <<< "$row"
    printf '%-25s PID=%-15s CPU=%6s%% MEM=%6s%% RSS=%8.2fMB THR=%-3s STATE=%s\n' \
        "$(now)" "$pid" "$cpu" "$mem" "$((rss_kb / 1024))" "$threads" "$state" >> "$OUTPUT"
}

start_epoch="$(date +%s)"
last_pid=""
waiting_logged=0

{
    printf '# monitor.sh process=%s interval=%ss duration=%ss\n' \
        "$PROCESS_NAME" "$INTERVAL" "$DURATION"
    printf '# time                     PID(S)          CPU%%    MEM%%       RSS       THR STATE\n'
} >> "$OUTPUT"

while :; do
    current_epoch="$(date +%s)"
    if (( DURATION > 0 && current_epoch - start_epoch >= DURATION )); then
        write_log "$(now) EVENT=TIME_LIMIT_REACHED"
        break
    fi

    pid="$(find_pid || true)"
    if [[ -z "$pid" ]]; then
        if [[ -n "$last_pid" ]]; then
            write_log "$(now) EVENT=PROCESS_EXITED PID=$last_pid"
            break
        fi
        if (( waiting_logged == 0 )); then
            write_log "$(now) EVENT=WAITING_FOR_PROCESS name=$PROCESS_NAME"
            waiting_logged=1
        fi
    else
        last_pid="$pid"
        waiting_logged=0
        if [[ -n "$TARGET_PID" ]]; then
            if ! write_pid_snapshot "$pid"; then
                write_log "$(now) EVENT=PROCESS_EXITED PID=$pid"
                break
            fi
        else
            if ! write_auto_snapshot; then
                write_log "$(now) EVENT=PROCESS_EXITED PID=$pid"
                break
            fi
        fi
    fi

    sleep "$INTERVAL"
done

write_log "$(now) EVENT=MONITOR_FINISHED"
