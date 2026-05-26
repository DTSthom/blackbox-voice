#!/usr/bin/env bash
# install-client.sh — install bbsync + bb on a macOS client.
# Run from this checkout directory.
#
# Installs:
#   ~/bin/bbsync, ~/bin/bb                                (symlinks into this checkout)
#   ~/Library/LaunchAgents/com.blackbox.mount.plist       (optional: sshfs mount of host:/data/blackbox)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_DIR="$SCRIPT_DIR/launchagents"

echo "=== Blackbox client install ==="
echo "Script dir: $SCRIPT_DIR"
echo ""

if [[ "$(uname)" != "Darwin" ]]; then
    echo "WARN: not running on macOS (uname=$(uname))"
    read -p "Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

# --- Step 1: bin symlinks (bbsync + bb) ---
mkdir -p "$HOME/bin"
for tool in bbsync bb; do
    src="$SCRIPT_DIR/$tool"
    dst="$HOME/bin/$tool"
    if [[ ! -f "$src" ]]; then
        echo "ERROR: $src not found"
        exit 1
    fi
    chmod +x "$src"
    if [[ -L "$dst" || -f "$dst" ]]; then
        rm "$dst"
    fi
    ln -s "$src" "$dst"
    echo "  Linked: $dst → $src"
done

# --- Step 2: PATH check ---
if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
    echo ""
    echo "WARN: \$HOME/bin is not on \$PATH. Add to ~/.zshrc:"
    echo "  export PATH=\"\$HOME/bin:\$PATH\""
fi
# Non-tty SSH PATH needs ~/.zshenv (separate from interactive ~/.zshrc).
# Critical for: bbsync invoked over ssh, sshfs in LaunchAgent.
if [[ -f "$HOME/.zshenv" ]] && grep -q '/usr/local/bin' "$HOME/.zshenv" 2>/dev/null; then
    echo "  ~/.zshenv has /usr/local/bin on PATH (good for sshfs over non-tty SSH)"
else
    echo "  WARN: ~/.zshenv missing or doesn't include /usr/local/bin. Recommended:"
    echo "    echo 'export PATH=\"\$HOME/bin:/usr/local/bin:/opt/homebrew/bin:\$PATH\"' >> ~/.zshenv"
fi

# --- Step 3: SSH to BLACKBOX_HOST ---
HOST="${BLACKBOX_HOST:-blackbox-host}"
echo ""
echo "Checking SSH to \$BLACKBOX_HOST=$HOST ..."
if ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true 2>/dev/null; then
    echo "  OK"
else
    echo "  WARN: cannot SSH to '$HOST' — check ~/.ssh/config has a Host entry"
    echo "        (or set BLACKBOX_HOST=<your-ssh-target> in your shell env)"
fi

# --- Step 4: fuse-t + sshfs (optional; only for Finder browsability) ---
# Allows browsing host:/data/blackbox/ in Finder via a Tailscale/SSH mount.
# Skip this if you only want the bb CLI for archive access.
echo ""
echo "Checking fuse-t + sshfs (optional, for Finder browsability)..."
HAS_SSHFS=0
if [[ -x /usr/local/bin/sshfs ]]; then
    HAS_SSHFS=1
    echo "  OK (/usr/local/bin/sshfs)"
else
    echo "  Not installed. The bb CLI works without it; install only if you want"
    echo "  a Finder-mounted view of host:/data/blackbox/:"
    echo "    Download signed .pkg releases from https://github.com/macos-fuse-t/fuse-t/releases"
    echo "    and https://github.com/macos-fuse-t/sshfs/releases — install both, then re-run."
fi

# --- Step 5: LaunchAgent for auto-mount at login (only if sshfs present) ---
if [[ "$HAS_SSHFS" -eq 1 ]]; then
    echo ""
    echo "Installing LaunchAgent for auto-mount at login..."
    mkdir -p "$HOME/Library/LaunchAgents"
    plist="com.blackbox.mount.plist"
    src="$PLIST_DIR/$plist"
    dst="$HOME/Library/LaunchAgents/$plist"
    if [[ ! -f "$src" ]]; then
        echo "  WARN: $src not in repo — skipping"
    else
        label="${plist%.plist}"
        if launchctl list | awk '{print $3}' | grep -qx "$label"; then
            launchctl unload "$dst" 2>/dev/null || true
        fi
        # Substitute BLACKBOX_HOST into the plist so the mount points at this user's host
        sed "s|@HOST@|$HOST|g" "$src" > "$dst"
        plutil -lint "$dst" >/dev/null || { echo "  ERROR: $dst failed plutil lint"; exit 1; }
        launchctl load "$dst"
        echo "  installed + loaded: $plist (mount at ~/blackbox-archive)"
    fi
fi

echo ""
echo "=== Install complete ==="
echo ""
echo "Try: bb status"
echo "Plug in a Sony IC RECORDER, then: bbsync"
[[ "$HAS_SSHFS" -eq 1 ]] && echo "Or browse the archive at ~/blackbox-archive in Finder."
