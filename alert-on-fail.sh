#!/bin/bash
# alert-on-fail.sh — systemd ExecStopPost helper; fires ntfy on non-success.
# Usage: ExecStopPost=/path/to/alert-on-fail.sh <unit-name>
#
# Environment provided by systemd (ExecStopPost context):
#   SERVICE_RESULT  — "success", "exit-code", "signal", "timeout", "core-dump"
#   EXIT_CODE       — "exited" or signal name
#   EXIT_STATUS     — numeric exit code (or signal number)
#
# Topic: $BLACKBOX_NTFY_TOPIC (no default — alerts are skipped if unset).
# Best-effort: failures here are silent so they don't mask the original fault.

set -u

UNIT_NAME="${1:-unknown-unit}"
TOPIC="${BLACKBOX_NTFY_TOPIC:-}"

RESULT="${SERVICE_RESULT:-unknown}"
EXITCODE="${EXIT_CODE:-?}"
EXITSTATUS="${EXIT_STATUS:-?}"

# Success → nothing to alert on. ExecStopPost runs for both success and failure.
[ "$RESULT" = "success" ] && exit 0

# No topic configured → operator hasn't opted into push alerts. Skip silently.
[ -z "$TOPIC" ] && exit 0

# bounce-blackbox uses exit 6 to signal "all attempted files failed this run."
# Other non-zero exits = sanity-check failures or unexpected aborts.
case "$EXITSTATUS" in
    6) detail="all attempted audio files failed transcription this run" ;;
    *) detail="systemd-level failure (timeout / signal / non-zero exit)" ;;
esac

curl -fsS --max-time 10 \
  -H "Title: blackbox $UNIT_NAME FAILED" \
  -H "Priority: high" \
  -H "Tags: warning,floppy_disk" \
  -d "Unit: $UNIT_NAME on $(hostname). result=$RESULT exit_code=$EXITCODE exit_status=$EXITSTATUS. $detail. Inspect: journalctl -u $UNIT_NAME -n 50" \
  "https://ntfy.sh/${TOPIC}" >/dev/null 2>&1 || true

exit 0
