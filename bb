#!/usr/bin/env bash
# bb — blackbox archive review CLI (runs from your client, SSH-wraps the host).
#
# Usage:
#   bb search <pattern>          Ripgrep over all transcripts (case-insensitive)
#   bb today                     Show today's transcripts + summary
#   bb yesterday                 Show yesterday's transcripts + summary
#   bb date YYYY-MM-DD           Show transcripts for a specific date
#   bb tag <tag>                 List transcripts with a tag
#   bb summary today|yesterday|YYYY-MM-DD  Print a day's summary
#   bb log [N]                   Tail the bounce log (default 30 lines)
#   bb ls [YYYY-MM]              List archived dates (all, or for a month)
#   bb status                    Show pending sessions + last activity
#
# Configure: BLACKBOX_HOST (SSH target; default "blackbox-host")
#            BLACKBOX_ARCHIVE (remote archive root; default /data/blackbox)
#            BLACKBOX_INCOMING (remote incoming dir; default ~/blackbox-incoming)

set -euo pipefail

HOST="${BLACKBOX_HOST:-blackbox-host}"
ARCHIVE="${BLACKBOX_ARCHIVE:-/data/blackbox}"
INCOMING="${BLACKBOX_INCOMING:-~/blackbox-incoming}"

usage() {
    sed -n '2,14p' "$0" | sed 's/^# \?//'
    exit 1
}

[[ $# -lt 1 ]] && usage

cmd="$1"; shift

# Cross-platform yesterday (BSD date on macOS vs GNU date elsewhere)
yesterday_ymd() {
    date -v-1d +%Y/%m/%d 2>/dev/null || date -d '1 day ago' +%Y/%m/%d
}

normalize_date() {
    # Accept YYYY-MM-DD or today/yesterday → YYYY/MM/DD. Strict format check
    # prevents shell injection in the SSH heredocs that consume this value.
    case "$1" in
        today) date +%Y/%m/%d ;;
        yesterday) yesterday_ymd ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) echo "${1//-//}" ;;
        *)
            echo "ERROR: bad date '$1' (expected today | yesterday | YYYY-MM-DD)" >&2
            exit 1
            ;;
    esac
}

case "$cmd" in
    search)
        [[ $# -lt 1 ]] && { echo "Usage: bb search <pattern>"; exit 1; }
        pat=$(printf '%q' "$*")
        rc=0
        # shellcheck disable=SC2029
        out=$(ssh "$HOST" "
            command -v rg >/dev/null 2>&1 || { echo 'ERROR: rg not installed on host (sudo apt install ripgrep)' >&2; exit 127; }
            rg --color=always -n -C2 -i -- $pat '$ARCHIVE'/
        " 2>&1) || rc=$?
        # rg exit codes: 0=matches, 1=none, 2=error; 127=tool missing per our check
        case $rc in
            0) printf '%s\n' "$out" | ${PAGER:-less -R} ;;
            1) echo "No matches." ;;
            *) printf '%s\n' "$out" >&2; exit "$rc" ;;
        esac
        ;;

    today|yesterday)
        date_str=$(normalize_date "$cmd")
        ssh "$HOST" "
            d='$ARCHIVE/$date_str'
            if [ ! -d \"\$d\" ]; then
                echo 'No archive for $date_str yet.'
                exit 0
            fi
            echo '=== $date_str ==='
            ls -la \"\$d\"
            echo
            for f in \"\$d\"/transcript-*.md; do
                [ -f \"\$f\" ] && { echo \"--- \$(basename \$f) ---\"; cat \"\$f\"; echo; }
            done
            if [ -f \"\$d/summary.md\" ]; then
                echo '=== summary.md ==='
                cat \"\$d/summary.md\"
            fi
        " | ${PAGER:-less}
        ;;

    date)
        [[ $# -lt 1 ]] && { echo "Usage: bb date YYYY-MM-DD"; exit 1; }
        date_str=$(normalize_date "$1")
        ssh "$HOST" "
            d='$ARCHIVE/$date_str'
            if [ ! -d \"\$d\" ]; then
                echo 'No archive for that date.'
                exit 0
            fi
            ls -la \"\$d\"
            echo
            for f in \"\$d\"/transcript-*.md; do
                [ -f \"\$f\" ] && { echo \"--- \$(basename \$f) ---\"; cat \"\$f\"; echo; }
            done
        " | ${PAGER:-less}
        ;;

    tag)
        [[ $# -lt 1 ]] && { echo "Usage: bb tag <tag>"; exit 1; }
        pattern=$(printf '%q' "$1")
        rc=0
        # shellcheck disable=SC2029
        out=$(ssh "$HOST" "
            command -v rg >/dev/null 2>&1 || { echo 'ERROR: rg not installed on host (sudo apt install ripgrep)' >&2; exit 127; }
            rg -l --color=never -- \"tags:.*$pattern\" '$ARCHIVE'/
        " 2>&1) || rc=$?
        case $rc in
            0) printf '%s\n' "$out" | sed "s|$ARCHIVE/||" | sort ;;
            1) ;;  # no matches: print nothing (preserves existing behavior)
            *) printf '%s\n' "$out" >&2; exit "$rc" ;;
        esac
        ;;

    summary)
        [[ $# -lt 1 ]] && { echo "Usage: bb summary today|yesterday|YYYY-MM-DD"; exit 1; }
        date_str=$(normalize_date "$1")
        ssh "$HOST" "
            f='$ARCHIVE/$date_str/summary.md'
            if [ ! -f \"\$f\" ]; then
                echo 'No summary for $date_str. (Generated nightly by daily-summary.timer, or run daily-summary.py manually.)'
                exit 0
            fi
            cat \"\$f\"
        " | ${PAGER:-less}
        ;;

    log)
        n="${1:-30}"
        if [[ ! "$n" =~ ^[0-9]+$ ]]; then
            echo "ERROR: log count must be a positive integer (got: $n)" >&2
            exit 1
        fi
        ssh "$HOST" "
            f='$ARCHIVE/_log'
            if [ ! -f \"\$f\" ]; then
                echo 'No log yet (bounce-blackbox has not processed anything).'
                exit 0
            fi
            tail -n $n \"\$f\"
        "
        ;;

    ls)
        if [[ "$#" -ge 1 ]]; then
            # Validate YYYY-MM input format (prevent shell injection in SSH heredoc)
            if [[ ! "$1" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
                echo "ERROR: bad month '$1' (expected YYYY-MM)" >&2
                exit 1
            fi
            year="${1%-*}"
            month="${1#*-}"
            ssh "$HOST" "
                d='$ARCHIVE/$year/$month'
                if [ ! -d \"\$d\" ]; then
                    echo 'Nothing for $1.'
                    exit 0
                fi
                ls \"\$d\"/ | sort
            "
        else
            ssh "$HOST" "
                if [ ! -d '$ARCHIVE' ]; then
                    echo 'Archive root missing.'
                    exit 0
                fi
                find '$ARCHIVE' -mindepth 3 -maxdepth 3 -type d | sed 's|$ARCHIVE/||' | sort
            "
        fi
        ;;

    status)
        ssh "$HOST" "
            echo '=== Pending sessions (in incoming/) ==='
            if [ ! -d $INCOMING ]; then
                echo '  (incoming dir missing — run install-host.sh)'
            else
                pending=\$(ls -1 $INCOMING/ 2>/dev/null | grep '^session-' || true)
                if [ -z \"\$pending\" ]; then
                    echo '  (none)'
                else
                    echo \"\$pending\" | sed 's/^/  /'
                fi
            fi
            echo
            echo '=== In-flight uploads (.uploading flag — bbsync mid-rsync, wedged if older than ~5min) ==='
            if [ ! -d $INCOMING ]; then
                echo '  (incoming dir missing)'
            else
                in_flight=\$(find $INCOMING -maxdepth 2 -name .uploading -printf '%T@ %p\n' 2>/dev/null || true)
                if [ -n \"\$in_flight\" ]; then
                    echo \"\$in_flight\" | awk '{ age=systime()-\$1; printf \"  %s  (age: %ds)\n\", \$2, age }'
                else
                    echo '  (none)'
                fi
            fi
            echo
            echo '=== Last 10 log lines ==='
            if [ -f $ARCHIVE/_log ]; then
                tail -n 10 $ARCHIVE/_log
            else
                echo '  (no log yet)'
            fi
            echo
            echo '=== Disk usage ==='
            if [ -d $ARCHIVE ]; then
                du -sh $ARCHIVE
            else
                echo '  (archive missing)'
            fi
            echo
            echo '=== Timers ==='
            if command -v systemctl >/dev/null 2>&1; then
                systemctl list-timers bounce-blackbox.timer daily-summary.timer --no-pager 2>&1 | head -5
            else
                echo '  (systemctl not available)'
            fi
        "
        ;;

    -h|--help|help)
        usage
        ;;

    *)
        echo "Unknown command: $cmd" >&2
        usage
        ;;
esac
