#!/usr/bin/env bash
# install-host.sh — bootstrap the blackbox pipeline on the Linux host that
# runs Whisper + daily-summary. Run from this checkout directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPERATOR_USER="${USER}"
BLACKBOX_ROOT="${BLACKBOX_ROOT:-/data/blackbox}"
INCOMING="$HOME/blackbox-incoming"

echo "=== Blackbox host install ==="
echo "Operator:     $OPERATOR_USER"
echo "Script dir:   $SCRIPT_DIR"
echo "Archive root: $BLACKBOX_ROOT"
echo "Incoming:     $INCOMING"
echo ""

# --- Required tools ---
# - ffprobe: duration metadata in transcripts
# - shred:   secure-delete of audio post-transcription
# - rsync:   used by the uploader (client side)
# - python3: daily-summary.py uses only stdlib + subprocess (no SDK)
# - ssh:     client uploads via SSH
# - flock:   bounce_blackbox.sh lockfile
# - curl:    optional, only used if BLACKBOX_NTFY_TOPIC is set for push alerts
# - rg:      bb search/tag depend on ripgrep
echo "Checking dependencies..."
MISSING=()
for tool in ffprobe shred rsync python3 ssh flock curl rg; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING+=("$tool")
    fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "MISSING tools: ${MISSING[*]}"
    echo "Install via: sudo apt install ffmpeg coreutils rsync openssh-client util-linux curl ripgrep"
    exit 1
fi
echo "  OK"

# --- Whisper detection ---
WHISPER_BIN=""
for candidate in \
    "$HOME/whisper.cpp/build/bin/whisper-cli" \
    "/usr/local/bin/whisper-cli"; do
    if [[ -x "$candidate" ]]; then WHISPER_BIN="$candidate"; break; fi
done

if [[ -z "$WHISPER_BIN" ]]; then
    echo "WARN: whisper.cpp not auto-detected."
    echo "      Set WHISPER_BIN in your environment, or edit bounce_blackbox.sh directly."
    echo "      Build with: git clone https://github.com/ggerganov/whisper.cpp && cd whisper.cpp && make"
else
    echo "Whisper binary: $WHISPER_BIN"
fi

# --- Whisper small model (default; override via BLACKBOX_WHISPER_MODEL) ---
WHISPER_MODEL_PATH=""
for candidate in \
    "$HOME/whisper.cpp/models/ggml-small.bin" \
    "/usr/local/share/whisper-models/ggml-small.bin"; do
    if [[ -f "$candidate" ]]; then WHISPER_MODEL_PATH="$candidate"; break; fi
done

if [[ -z "$WHISPER_MODEL_PATH" ]]; then
    echo "WARN: small model not found."
    if [[ -d "$HOME/whisper.cpp/models" ]]; then
        echo "  Download with:"
        echo "    cd $HOME/whisper.cpp && bash models/download-ggml-model.sh small"
    fi
else
    echo "Whisper model:  $WHISPER_MODEL_PATH"
fi

echo ""
echo "Note: blackbox defaults to Whisper SMALL. Override with BLACKBOX_WHISPER_MODEL=medium"
echo "      after downloading the medium model."

# --- Create dirs ---
echo ""
echo "Creating directories..."
mkdir -p "$INCOMING"
chmod 700 "$INCOMING"
echo "  $INCOMING (700)"

if [[ ! -d "$BLACKBOX_ROOT" ]]; then
    echo "Creating $BLACKBOX_ROOT (requires sudo)..."
    sudo mkdir -p "$BLACKBOX_ROOT"
    sudo chown "$OPERATOR_USER:$OPERATOR_USER" "$BLACKBOX_ROOT"
    # `mkdir -p` creates intermediate dirs (e.g. /data) using root's umask.
    # On hosts with a restrictive root umask (077 — common on Jetson and
    # hardened images) the parent is born 0700 root:root, so the operator
    # can't traverse into it to reach their own archive and the `chmod 700`
    # below fails with "Permission denied". Make the immediate parent
    # operator-traversable.
    PARENT_DIR="$(dirname "$BLACKBOX_ROOT")"
    if [[ "$PARENT_DIR" != "/" ]]; then
        sudo chmod o+rx "$PARENT_DIR" 2>/dev/null || true
    fi
fi
chmod 700 "$BLACKBOX_ROOT"
touch "$BLACKBOX_ROOT/_log"
chmod 600 "$BLACKBOX_ROOT/_log"
echo "  $BLACKBOX_ROOT (700)"
echo "  $BLACKBOX_ROOT/_log (600)"

# --- Claude CLI presence check (daily-summary uses Max sub via local CLI, not API) ---
CLAUDE_BIN="$HOME/.local/bin/claude"
echo ""
echo "Checking Claude CLI (used by daily-summary via Max sub auth)..."
if [[ ! -x "$CLAUDE_BIN" ]]; then
    echo "  WARN: $CLAUDE_BIN not found or not executable."
    echo "  Install Claude Code via nvm + npm install -g @anthropic-ai/claude-code,"
    echo "  then symlink: ln -sf ~/.nvm/versions/node/<version>/bin/claude $CLAUDE_BIN"
    echo "  Then run 'claude /login' interactively before re-running this install."
    exit 1
fi
echo "  $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>/dev/null | head -1))"

if [[ ! -d "$HOME/.claude" ]] && [[ ! -f "$HOME/.config/claude/credentials.json" ]]; then
    echo "  WARN: no Claude config dir found — daily-summary will fail until you run:"
    echo "    claude /login"
fi

# --- Systemd units ---
echo ""
echo "Installing systemd units (requires sudo)..."
# install-host.sh runs as the operator user. Substitute /home/<user> into the
# unit files so they point at this user's checkout, not a hardcoded path.
for unit in bounce-blackbox.timer bounce-blackbox.service daily-summary.timer daily-summary.service; do
    src="$SCRIPT_DIR/systemd/$unit"
    dst="/etc/systemd/system/$unit"
    sudo cp "$src" "$dst"
    # Replace the canonical placeholders with this user's actual paths
    sudo sed -i \
        -e "s|@USER@|$OPERATOR_USER|g" \
        -e "s|@HOME@|$HOME|g" \
        -e "s|@SCRIPT_DIR@|$SCRIPT_DIR|g" \
        "$dst"
    echo "  installed: $unit"
done

sudo systemctl daemon-reload
sudo systemctl enable --now bounce-blackbox.timer
sudo systemctl enable --now daily-summary.timer
echo "  bounce-blackbox.timer + daily-summary.timer enabled"

# --- Make scripts executable ---
chmod +x "$SCRIPT_DIR/bounce_blackbox.sh" "$SCRIPT_DIR/daily-summary.py" "$SCRIPT_DIR/alert-on-fail.sh" 2>/dev/null || true

echo ""
echo "=== Install complete ==="
echo ""
echo "Verify:"
echo "  systemctl status bounce-blackbox.timer"
echo "  systemctl list-timers bounce-blackbox.timer daily-summary.timer --no-pager"
echo ""
echo "Smoke test (drop a test mp3):"
echo "  mkdir -p $INCOMING/session-test"
echo "  cp /path/to/test.mp3 $INCOMING/session-test/"
echo "  tail -f $BLACKBOX_ROOT/_log"
echo ""
echo "Client side: install-client.sh on your Mac (or run bbsync + bb directly)."
echo "Push alerts: set BLACKBOX_NTFY_TOPIC=your-ntfy-topic in /etc/environment to enable."
