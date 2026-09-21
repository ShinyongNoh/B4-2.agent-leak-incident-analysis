set -u

PROCESS_NAME="agent-leak-app"
TARGET_PID=""
INTERVAL=1
DURATION=0
OUTPUT="monitor.log"

usage() {
    sed -n '2,8p' "$0"
    cat <<'EOF'

Options:
  -p PID       Monitor this exact process ID.
  -n NAME      Process name/command to locate (default: agent-leak-app).
  -i SECONDS   Sampling interval (default: 1).
  -d SECONDS   Stop after this many seconds; 0 means until the process exits.
  -o FILE      Output log path (default: monitor.log).
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
        :) echo "Missing argument for -$OPTARG" >&2; usage >&2; exit 2 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage >&2; exit 2 ;;
    esac
done

if ! [[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
    echo "INTERVAL must be numeric and DURATION must be a non-negative integer" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUTPUT")"

find_pid() {
    if [[ -n "$TARGET_PID" ]]; then
        printf '%s\n' "$TARGET_PID"
        return 0
    fi

    if command -v pgrep >/dev/null 2>&1 && ((${#PROCESS_NAME} <= 15)); then
        pid="$(pgrep -x "$PROCESS_NAME" | head -n 1 || true)"
        if [[ -z "$pid" ]]; then
            pid="$(ps -eo pid=,pcpu=,comm=,args= 2>/dev/null | awk -v name="$PROCESS_NAME" -v self="$$" '$1 != self && $3 !~ /(monitor|bash|su|ps|awk|sleep)/ && $0 ~ name {if (($2 + 0) > best) {best = $2 + 0; selected = $1}} END {print selected}' || true)"
        fi
        printf '%s\n' "$pid"
        return 0
    fi

    ps -eo pid=,pcpu=,comm=,args= 2>/dev/null | awk -v name="$PROCESS_NAME" -v self="$$" '$1 != self && $3 !~ /(monitor|bash|su|ps|awk|sleep)/ && $0 ~ name {if (($2 + 0) > best) {best = $2 + 0; selected = $1}} END {print selected}'
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S%z'
}

write_system_snapshot() {
    local ts="$1"
    local pid="$2"
    local row cpu mem rss etime stat threads comm

    if [[ -z "$TARGET_PID" ]]; then
        row="$(ps -eo pid=,pcpu=,pmem=,rss=,etime=,stat=,nlwp=,comm=,args= 2>/dev/null | awk -v name="$PROCESS_NAME" -v self="$$" '
            $1 != self && $8 !~ /(monitor|bash|su|ps|awk|sleep)/ && $0 ~ name {
                count++;
                cpu += $2;
                mem += $3;
                rss += $4;
                threads += $7;
                if (($2 + 0) > maxcpu) { maxcpu = $2 + 0; leader = $1 }
                if (firststat == "") { firststat = $6; firstcomm = $8; elapsed = $5 }
            }
            END {
                if (count > 0) printf "%d %.2f %.2f %d %s %s %d %s", count, cpu, mem, rss, elapsed, firststat, threads, firstcomm;
            }')"
        if [[ -z "$row" ]]; then
            printf '[%s] PROCESS:%s PID:%s STATUS:EXITED\n' "$ts" "$PROCESS_NAME" "$pid" >> "$OUTPUT"
            return 1
        fi
        read -r count cpu mem rss etime stat threads comm <<< "$row"
        printf '[%s] PROCESS:%s PID:%s PIDS:%s CPU:%s%% MEM:%s%% RSS_KB:%s ELAPSED:%s STAT:%s THREADS:%s COMM:%s\n' \
            "$ts" "$PROCESS_NAME" "$pid" "$count" "$cpu" "$mem" "$rss" "$etime" "$stat" "$threads" "$comm" >> "$OUTPUT"
    else
        row="$(ps -p "$pid" -o '%cpu=,%mem=,rss=,etime=,stat=,nlwp=,comm=' 2>/dev/null | awk '{$1=$1; print}')"
        if [[ -z "$row" ]]; then
            printf '[%s] PROCESS:%s PID:%s STATUS:EXITED\n' "$ts" "$PROCESS_NAME" "$pid" >> "$OUTPUT"
            return 1
        fi

        read -r cpu mem rss etime stat threads comm <<< "$row"
        printf '[%s] PROCESS:%s PID:%s CPU:%s%% MEM:%s%% RSS_KB:%s ELAPSED:%s STAT:%s THREADS:%s COMM:%s\n' \
            "$ts" "$PROCESS_NAME" "$pid" "$cpu" "$mem" "$rss" "$etime" "$stat" "$threads" "$comm" >> "$OUTPUT"
    fi

    if command -v free >/dev/null 2>&1; then
        free -m | awk -v ts="$ts" 'NR == 2 {printf "[%s] SYSTEM_MEMORY: total_mb=%s used_mb=%s free_mb=%s available_mb=%s\n", ts, $2, $3, $4, $7}' >> "$OUTPUT"
    fi

    if command -v uptime >/dev/null 2>&1; then
        printf '[%s] LOAD: %s\n' "$ts" "$(uptime | sed 's/^[[:space:]]*//')" >> "$OUTPUT"
    fi

    return 0
}

start_epoch="$(date +%s)"
last_pid=""
{
    printf '# monitor.sh started=%s host=%s kernel=%s\n' "$(timestamp)" "$(hostname)" "$(uname -srmo 2>/dev/null || uname -a)"
    printf '# process_name=%s pid=%s interval=%ss duration=%ss\n' "$PROCESS_NAME" "${TARGET_PID:-auto}" "$INTERVAL" "$DURATION"
} >> "$OUTPUT"

while :; do
    current_epoch="$(date +%s)"
    if (( DURATION > 0 && current_epoch - start_epoch >= DURATION )); then
        printf '[%s] MONITOR:TIME_LIMIT_REACHED\n' "$(timestamp)" >> "$OUTPUT"
        break
    fi

    pid="$(find_pid || true)"
    if [[ -z "$pid" ]]; then
        printf '[%s] PROCESS:%s STATUS:NOT_FOUND\n' "$(timestamp)" "$PROCESS_NAME" >> "$OUTPUT"
        if [[ -n "$last_pid" ]]; then
            printf '[%s] MONITOR:PROCESS_EXITED PID:%s\n' "$(timestamp)" "$last_pid" >> "$OUTPUT"
            break
        fi
    else
        last_pid="$pid"
        if ! write_system_snapshot "$(timestamp)" "$pid"; then
            printf '[%s] MONITOR:PROCESS_EXITED PID:%s\n' "$(timestamp)" "$pid" >> "$OUTPUT"
            break
        fi
    fi

    sleep "$INTERVAL"
done

printf '[%s] monitor.sh finished\n' "$(timestamp)" >> "$OUTPUT"
