#!/usr/bin/env bash
# bounce_blackbox.sh — process pending blackbox audio.
# Triggered by bounce-blackbox.timer every 60s. Lockfile prevents concurrent runs.
#
# For each session-* dir in ~/blackbox-incoming/:
#   - process each MP3/WAV
#   - run Whisper → transcript.md with frontmatter (timestamps, tags, duration)
#   - shred audio on success
#   - clean up empty session dir

set -euo pipefail

# --- Configuration --------------------------------------------------
INCOMING="$HOME/blackbox-incoming"
ARCHIVE_BASE="${BLACKBOX_BASE:-/data/blackbox}"
WHISPER_MODEL_NAME="${BLACKBOX_WHISPER_MODEL:-small}"
WHISPER_LANGUAGE="${BLACKBOX_WHISPER_LANG:-en}"

# Whisper binary + model — auto-detect, override via env if needed
WHISPER_BIN="${WHISPER_BIN:-}"
WHISPER_MODEL_PATH="${WHISPER_MODEL_PATH:-}"

if [[ -z "$WHISPER_BIN" ]]; then
    for candidate in \
        "$HOME/whisper.cpp/build/bin/whisper-cli" \
        "/usr/local/bin/whisper-cli"; do
        if [[ -x "$candidate" ]]; then WHISPER_BIN="$candidate"; break; fi
    done
fi

if [[ -z "$WHISPER_MODEL_PATH" ]]; then
    for candidate in \
        "$HOME/whisper.cpp/models/ggml-$WHISPER_MODEL_NAME.bin" \
        "/usr/local/share/whisper-models/ggml-$WHISPER_MODEL_NAME.bin"; do
        if [[ -f "$candidate" ]]; then WHISPER_MODEL_PATH="$candidate"; break; fi
    done
fi

LOG_FILE="$ARCHIVE_BASE/_log"
LOCKFILE="/tmp/bounce-blackbox.lock"
# Ingest latency = time from recording-clock to ingest-clock. Informational only.
INGEST_LATENCY_INFO_SEC=300
# Wedge detection: if any whisper-cli has been running longer than this, log + ntfy
# (rate-limited 1/hr). 4h default = longer than any single plausible field-day recording.
BLACKBOX_WEDGE_SEC="${BLACKBOX_WEDGE_SEC:-14400}"
# Log rotation: trim _log when it exceeds first threshold; keep last N lines.
LOG_ROTATE_THRESHOLD=7500
LOG_ROTATE_KEEP=5000

# --- ntfy helper (best-effort; never blocks the pipeline) ----------
ntfy_alert() {
    local title="$1" msg="$2"
    local topic="${BLACKBOX_NTFY_TOPIC:-}"
    [[ -z "$topic" ]] && return 0  # no topic configured: skip silently
    curl -fsS --max-time 10 \
        -H "Title: $title" -H "Priority: high" -H "Tags: warning,floppy_disk" \
        -d "$msg" "https://ntfy.sh/${topic}" >/dev/null 2>&1 || true
}

# --- Locking --------------------------------------------------------
exec 200>"$LOCKFILE"
flock -n 200 || exit 0  # another instance running; silent exit

# --- Logging --------------------------------------------------------
log() {
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$ts] $*" >> "$LOG_FILE"
}

# --- Defer if any whisper-cli is busy + wedge detection ----
# Cooperative scheduling: don't fight another whisper-cli for the GPU/CPU.
# pgrep returns 0 if any whisper-cli is running anywhere on the system.
# If the running whisper has been alive >BLACKBOX_WEDGE_SEC, log WEDGE + ntfy
# (rate-limited 1/hr via marker file).
if pgrep -x whisper-cli >/dev/null 2>&1; then
    oldest_age=$(ps -eo etimes,comm --no-headers 2>/dev/null \
                 | awk '$2=="whisper-cli" { print $1 }' \
                 | sort -nr | head -1)
    if [[ -n "$oldest_age" && "$oldest_age" -gt "$BLACKBOX_WEDGE_SEC" ]]; then
        wedge_marker="/tmp/blackbox-wedge-last-alerted"
        last=$(stat -c %Y "$wedge_marker" 2>/dev/null || echo 0)
        now=$(date +%s)
        if [[ $((now - last)) -gt 3600 ]]; then
            log "WEDGE: whisper-cli running for ${oldest_age}s (threshold ${BLACKBOX_WEDGE_SEC}s) — pipeline stalled"
            ntfy_alert "blackbox WEDGE" "whisper-cli wedged on $(hostname): age=${oldest_age}s. Inspect: ps -eo pid,etime,comm | grep whisper"
            touch "$wedge_marker"
        fi
    fi
    exit 0
fi

# --- Sanity checks --------------------------------------------------
if [[ ! -d "$INCOMING" ]]; then
    log "ERROR: incoming dir missing: $INCOMING"
    exit 1
fi
if [[ ! -d "$ARCHIVE_BASE" ]]; then
    log "ERROR: archive base missing: $ARCHIVE_BASE"
    exit 1
fi
if [[ -z "$WHISPER_BIN" || -z "$WHISPER_MODEL_PATH" ]]; then
    log "ERROR: whisper not found. WHISPER_BIN=$WHISPER_BIN WHISPER_MODEL_PATH=$WHISPER_MODEL_PATH"
    exit 1
fi

# --- Per-file processing function -----------------------------------
process_audio() {
    local audio="$1"
    local session_dir
    session_dir="$(dirname "$audio")"
    local tags_file="$session_dir/tags.txt"
    local filename
    filename="$(basename "$audio")"
    local basename_noext="${filename%.*}"

    # --- Parse recorder timestamp from Sony filename (YYMMDD_HHMMSS) ---
    # Recorder is set to operator's local time. Interpret rec_ts in that TZ so
    # epoch arithmetic is consistent regardless of host system timezone.
    local rec_date rec_time rec_ts rec_epoch
    local recorder_tz="${BLACKBOX_RECORDER_TZ:-America/New_York}"
    if [[ "$basename_noext" =~ ^([0-9]{2})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
        rec_date="20${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
        rec_time="${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
        rec_ts="${rec_date}T${rec_time}"
        rec_epoch=$(TZ="$recorder_tz" date -d "$rec_ts" +%s 2>/dev/null || echo "0")
    else
        # Fallback: use file mtime as recording time (rsync -a preserves device mtime)
        rec_ts=$(date -r "$audio" +%Y-%m-%dT%H:%M:%S)
        rec_date=$(date -r "$audio" +%Y-%m-%d)
        rec_epoch=0  # skip latency computation in fallback path
        log "WARN: filename $filename doesn't match Sony pattern, using mtime"
    fi

    local ingest_ts ingest_epoch
    ingest_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ingest_epoch=$(date +%s)

    # --- Ingest latency (informational only — NOT clock drift) ---
    # Latency = time between recording start and ingest. Includes recording duration,
    # post-recording delay before dock+sync, and rsync transfer time. Useful for
    # spotting pipeline backlogs; not a clock-drift signal.
    local latency latency_flag=""
    if [[ "$rec_epoch" -gt 0 ]]; then
        latency=$((ingest_epoch - rec_epoch))
        if [[ "$latency" -gt "$INGEST_LATENCY_INFO_SEC" ]]; then
            latency_flag="$latency"
        fi
    fi

    # --- Build date-tree archive path ---
    # NOTE: process_audio is called via `if process_audio ...` (main loop) which
    # SUPPRESSES set -e for the entire function body. Every potentially-failing
    # command below needs an explicit `if !` guard with `return 1`, or the
    # function will misleadingly return 0 on disk-full / perm-denied / similar.
    local year month day dest_dir dest_audio
    year=$(echo "$rec_date" | cut -d- -f1)
    month=$(echo "$rec_date" | cut -d- -f2)
    day=$(echo "$rec_date" | cut -d- -f3)
    dest_dir="$ARCHIVE_BASE/$year/$month/$day"
    if ! mkdir -p "$dest_dir/audio" 2>>"$LOG_FILE"; then
        log "ERROR: mkdir failed for $dest_dir/audio (disk full? perm?) — audio retained at $audio"
        return 1
    fi
    if ! chmod 700 "$dest_dir" "$dest_dir/audio" 2>>"$LOG_FILE"; then
        log "ERROR: chmod 700 failed on $dest_dir / audio/ — audio retained at $audio"
        return 1
    fi

    dest_audio="$dest_dir/audio/$filename"
    if ! mv "$audio" "$dest_audio" 2>>"$LOG_FILE"; then
        log "ERROR: mv $audio → $dest_audio failed (disk full? perm?) — audio retained at $audio"
        return 1
    fi
    if ! chmod 600 "$dest_audio" 2>>"$LOG_FILE"; then
        log "ERROR: chmod 600 failed on $dest_audio — audio is at $dest_audio with loose perms"
        return 1
    fi

    log "INGEST: $filename → $dest_audio (rec_ts=$rec_ts ingest_ts=$ingest_ts)"

    # --- Run Whisper ---
    # Capture stdout (timestamped segments: "[HH:MM:SS.mmm --> HH:MM:SS.mmm]  text")
    # Stderr (progress/diagnostics) goes to log.
    local whisper_txt="$dest_dir/.whisper-$basename_noext.txt"

    log "WHISPER: starting $filename (model=$WHISPER_MODEL_NAME lang=$WHISPER_LANGUAGE)"

    if ! "$WHISPER_BIN" \
            -m "$WHISPER_MODEL_PATH" \
            -f "$dest_audio" \
            -l "$WHISPER_LANGUAGE" \
            -np \
            > "$whisper_txt" 2>> "$LOG_FILE"; then
        log "ERROR: whisper failed on $filename — audio retained at $dest_audio"
        rm -f "$whisper_txt"
        return 1
    fi

    if [[ ! -s "$whisper_txt" ]]; then
        log "ERROR: whisper produced empty transcript for $filename"
        rm -f "$whisper_txt"
        return 1
    fi

    # --- Read tags from sidecar if present ---
    local tags_yaml=""
    if [[ -f "$tags_file" ]]; then
        local tags_line
        tags_line=$(grep -E '^tags:' "$tags_file" 2>/dev/null | cut -d: -f2- | sed 's/^ *//' || true)
        if [[ -n "$tags_line" ]]; then
            # Convert "foo, bar baz" → '["foo", "bar baz"]'
            tags_yaml="tags: [\"$(echo "$tags_line" | sed 's/, */", "/g')\"]"
        fi
    fi

    # --- Duration via ffprobe (capture exit code separately) ---
    # Numeric-guard the arithmetic: ffprobe can emit "N/A" or non-numeric on
    # malformed containers, which would crash `(( duration_sec / 60 ))` under set -e.
    local duration_sec="" duration_str="unknown" ffprobe_out ffprobe_rc=0
    ffprobe_out=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$dest_audio" 2>>"$LOG_FILE") || ffprobe_rc=$?
    if [[ "$ffprobe_rc" -ne 0 ]]; then
        log "WARN: ffprobe failed on $filename (rc=$ffprobe_rc) — duration will be 'unknown'"
    elif [[ -n "$ffprobe_out" ]]; then
        duration_sec="${ffprobe_out%.*}"
        if [[ "$duration_sec" =~ ^[0-9]+$ ]]; then
            duration_str="${duration_sec}s ($(( duration_sec / 60 ))m $(( duration_sec % 60 ))s)"
        else
            log "WARN: ffprobe returned non-numeric duration on $filename: ${ffprobe_out@Q} — keeping 'unknown'"
        fi
    fi

    # --- Build transcript.md (refuse to clobber existing — could be operator-edited) ---
    # Use a subshell + umask 077 so the file is born with 0600 perms in one step
    # (no race window where the file briefly exists at 0644 before a separate chmod).
    local transcript_md="$dest_dir/transcript-${basename_noext}.md"
    if [[ -f "$transcript_md" ]]; then
        log "ERROR: transcript already exists at $transcript_md — refusing to overwrite (move aside + re-run if you want to regenerate)"
        rm -f "$whisper_txt"
        return 1
    fi
    if ! (umask 077; {
        echo "---"
        echo "source_file: $filename"
        echo "recorder_timestamp: $rec_ts"
        echo "ingest_timestamp: $ingest_ts"
        echo "duration: $duration_str"
        echo "whisper_model: $WHISPER_MODEL_NAME"
        [[ -n "$tags_yaml" ]] && echo "$tags_yaml"
        echo "recorder_tz: $recorder_tz"
        [[ -n "$latency_flag" ]] && echo "ingest_latency_seconds: $latency_flag"
        echo "---"
        echo ""
        cat "$whisper_txt"
    } > "$transcript_md") 2>>"$LOG_FILE"; then
        log "ERROR: failed writing $transcript_md (disk full? perm?) — audio retained at $dest_audio, whisper_txt at $whisper_txt"
        rm -f "$transcript_md"  # drop the partial file
        return 1
    fi

    # --- Cleanup intermediate whisper output ---
    rm -f "$whisper_txt"

    # --- Shred audio (decided posture: no audio persistence) ---
    if shred -u "$dest_audio" 2>/dev/null; then
        log "DONE: $filename → $transcript_md (audio shredded)"
    else
        # shred may not be available on all systems; fall back to rm
        rm -f "$dest_audio"
        log "DONE: $filename → $transcript_md (audio deleted, shred unavailable)"
    fi

    return 0
}

# --- Cleanup empty session dirs ------------------------------------
cleanup_session() {
    local session_dir="$1"
    local tags_file="$session_dir/tags.txt"
    local session_base
    session_base=$(basename "$session_dir")

    # Only act on session-* dirs
    [[ "$session_base" =~ ^session- ]] || return 0

    # Check if any audio remains
    local remaining
    remaining=$(find "$session_dir" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.wav' \) 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$remaining" -gt 0 ]]; then
        return 0
    fi

    # All audio processed — archive tags.txt under the session's UTC date.
    # session_base is "session-YYYYMMDDTHHMMSSZ"; use that YYYYMMDD rather than
    # the host's local-clock date (which could be the WRONG day if processing
    # crosses local midnight — e.g., session @ 23:55 EST, bounce @ 00:05 would
    # land tags.txt in the following local day's dir).
    local session_date_dir
    if [[ "$session_base" =~ ^session-([0-9]{4})([0-9]{2})([0-9]{2})T ]]; then
        session_date_dir="$ARCHIVE_BASE/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
    else
        # Fallback (non-standard session name): operator-local date
        session_date_dir="$ARCHIVE_BASE/$(TZ="${BLACKBOX_RECORDER_TZ:-America/New_York}" date +%Y/%m/%d)"
    fi

    if [[ -f "$tags_file" ]]; then
        mkdir -p "$session_date_dir"
        mv "$tags_file" "$session_date_dir/.session-tags-$session_base.txt" 2>/dev/null || true
    fi

    rmdir "$session_dir" 2>/dev/null && log "SESSION: cleaned $session_base (tags → $session_date_dir)"
}

# --- Main loop ------------------------------------------------------
shopt -s nullglob

sessions=("$INCOMING"/session-*/)
if [[ ${#sessions[@]} -eq 0 ]]; then
    exit 0
fi

processed_count=0
failed_count=0

for session_dir in "$INCOMING"/session-*/; do
    session_dir="${session_dir%/}"  # strip trailing slash
    [[ -d "$session_dir" ]] || continue

    # Atomicity guard: the uploader (bbsync) writes .uploading at session-dir
    # creation, removes after rsync completes. Skip in-flight sessions to avoid
    # processing partial files OR cleanup_session archiving tags.txt before all
    # audio has landed.
    if [[ -f "$session_dir/.uploading" ]]; then
        log "SKIP: $(basename "$session_dir") — rsync in flight (.uploading present)"
        continue
    fi

    session_had_failure=0
    for audio in "$session_dir"/*.mp3 "$session_dir"/*.MP3 "$session_dir"/*.wav "$session_dir"/*.WAV; do
        [[ -f "$audio" ]] || continue

        # Defense-in-depth: skip files modified in the last 30s (likely still
        # uploading; covers manually-restored sessions where .uploading is absent)
        if [[ -n "$(find "$audio" -mmin -0.5 2>/dev/null)" ]]; then
            log "SKIP: $audio (modified <30s ago, likely still uploading)"
            continue
        fi

        if process_audio "$audio"; then
            processed_count=$((processed_count + 1))
        else
            failed_count=$((failed_count + 1))
            session_had_failure=1
        fi
    done

    # Only cleanup if every file succeeded for THIS session. On partial failure,
    # tags.txt stays in the session_dir so a manual operator re-run can pick it up.
    if [[ "$session_had_failure" -eq 0 ]]; then
        cleanup_session "$session_dir"
    else
        log "SESSION: $(basename "$session_dir") had failures — skipping cleanup so operator can recover"
    fi
done

if [[ "$processed_count" -gt 0 || "$failed_count" -gt 0 ]]; then
    log "RUN-END: processed=$processed_count failed=$failed_count"
fi

# Log rotation: trim _log if it exceeds threshold. Only checked on real-work runs
# (skip on silent defers/empty ticks) to avoid every-60s overhead.
# Per-step if-elif (not && chain) so a mid-rotation failure logs its cause.
if [[ "$processed_count" -gt 0 || "$failed_count" -gt 0 ]]; then
    if [[ -f "$LOG_FILE" ]]; then
        log_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "$log_lines" -gt "$LOG_ROTATE_THRESHOLD" ]]; then
            if ! tail -n "$LOG_ROTATE_KEEP" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null; then
                log "WARN: log-rotate tail failed (disk full? perm?) — _log untrimmed"
                rm -f "${LOG_FILE}.tmp"
            elif ! mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null; then
                log "WARN: log-rotate mv failed — rotated copy left at ${LOG_FILE}.tmp (operator: rm or mv manually)"
            else
                log "LOG-ROTATE: trimmed from ${log_lines} → ${LOG_ROTATE_KEEP} lines"
            fi
        fi
    fi
fi

# Exit code semantic: 0 = all good (or no work). 6 = every attempted file failed
# (systemd ExecStopPost catches this and fires ntfy).
if [[ "$processed_count" -eq 0 && "$failed_count" -gt 0 ]]; then
    exit 6
fi
exit 0
