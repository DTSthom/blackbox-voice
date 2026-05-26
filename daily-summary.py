#!/usr/bin/env python3
"""daily-summary.py — generate a one-page summary of a day's voice transcripts.

Reads all transcript-*.md files under $BLACKBOX_BASE/YYYY/MM/DD/ and produces summary.md
using Claude (Anthropic) via the local Claude CLI — Max subscription auth, no API key needed.

Usage:
    daily-summary.py                # process today's date (operator local TZ)
    daily-summary.py 2026-05-22     # process specific date
    daily-summary.py --force [DATE] # regenerate even if summary exists

Environment:
    BLACKBOX_BASE                   override archive base (default /data/blackbox)
    BLACKBOX_MODEL                  override Claude model (default sonnet)
    CLAUDE_BIN                      override claude binary path (default ~/.local/bin/claude)
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

ARCHIVE_BASE = Path(os.environ.get("BLACKBOX_BASE", "/data/blackbox"))
MODEL = os.environ.get("BLACKBOX_MODEL", "sonnet")
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", str(Path.home() / ".local" / "bin" / "claude"))
LOG_FILE = ARCHIVE_BASE / "_log"

SYSTEM_PROMPT = """You are summarizing a day's worth of personal ambient voice recordings for the operator. The recordings are auto-transcribed by Whisper; quality varies (some passages are clear, others noisy or partially garbled).

Each transcript has YAML frontmatter (source_file, recorder_timestamp, duration, tags) and a body of Whisper segments formatted as `[HH:MM:SS.mmm --> HH:MM:SS.mmm]  text`. The recorder_timestamp is the absolute wall-clock start of that recording; the offsets inside the body are relative to that start. When citing a moment, you can compute absolute time by adding the segment offset to the recorder_timestamp.

Your job: produce a one-page markdown summary that helps the operator search their archive later. Be specific, factual, and concise. Do NOT moralize, editorialize, or speculate about the operator's state of mind. If something is unclear or low-confidence, say so explicitly rather than guessing.

OUTPUT FORMAT (markdown):

# <Date> — Day Summary

## Overall arc
2-4 sentences on what the day looked like in shape: meetings, site visits, driving, deep work, etc. Pull from explicit tags AND from inferred context.

## Key conversations
Bulleted. For each substantive conversation:
- **Who**: names if identifiable from context (voices spoken, names dropped, tags)
- **About**: 1-2 sentences on the topic
- **Decisions / commitments**: anything explicit
- **Notable quotes**: VERBATIM in quotes, only if specific and unambiguous in the transcript

## People mentioned
Bulleted list of names that came up. Group co-occurrences when the transcripts show two people together.

## Open threads / follow-ups
Things discussed but unresolved. Who owes what, by when (if stated).

## Audio quality notes
1-2 lines on transcription confidence. Flag transcripts that were garbled or where Whisper clearly struggled.

GROUND RULES:
- Use only what's in the transcripts. Do not invent facts.
- If a name is ambiguous or could be a misspelling, say "(possibly X)".
- Do not include the literal transcript text in the summary — that's what the original transcripts are for.
- Keep total output under 800 words."""


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"[{ts}] daily-summary: {msg}\n"
    try:
        with LOG_FILE.open("a") as f:
            f.write(line)
    except Exception:
        print(line, end="", file=sys.stderr)


def find_transcripts(date_str: str) -> tuple[Path, list[Path]]:
    if not DATE_RE.match(date_str):
        raise ValueError(f"Bad date: {date_str!r} (expected YYYY-MM-DD)")
    parts = date_str.split("-")
    day_dir = ARCHIVE_BASE / parts[0] / parts[1] / parts[2]
    if not day_dir.is_dir():
        return day_dir, []
    return day_dir, sorted(day_dir.glob("transcript-*.md"))


def build_user_message(date_str: str, transcripts: list[Path]) -> str:
    parts = [f"Date: {date_str}", f"Transcript count: {len(transcripts)}", ""]
    for t in transcripts:
        parts.append(f"## File: {t.name}\n")
        parts.append(t.read_text())
        parts.append("\n---\n")
    return "\n".join(parts)


def main() -> int:
    args = sys.argv[1:]
    force = False
    if "--force" in args:
        force = True
        args = [a for a in args if a != "--force"]

    date_str = args[0] if args else datetime.now().strftime("%Y-%m-%d")

    try:
        day_dir, transcripts = find_transcripts(date_str)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if not transcripts:
        log(f"no transcripts for {date_str}")
        return 0

    summary_path = day_dir / "summary.md"
    if summary_path.exists() and not force:
        log(f"summary already exists for {date_str}, skipping (use --force to regenerate)")
        return 0

    if not Path(CLAUDE_BIN).exists():
        log(f"ERROR: claude binary not found at {CLAUDE_BIN}; cannot summarize {date_str}. "
            f"Ensure Claude CLI is installed and ~/.local/bin/claude is a valid symlink.")
        return 3

    log(f"summarizing {len(transcripts)} transcript(s) for {date_str} via {CLAUDE_BIN} (model={MODEL})")

    user_message = build_user_message(date_str, transcripts)

    started = datetime.now(timezone.utc)
    try:
        result = subprocess.run(
            [
                CLAUDE_BIN, "-p",
                "--model", MODEL,
                "--system-prompt", SYSTEM_PROMPT,
                "--output-format", "text",
            ],
            input=user_message,
            capture_output=True,
            text=True,
            timeout=600,
        )
    except subprocess.TimeoutExpired:
        log(f"ERROR: claude CLI timed out (>600s) for {date_str}")
        return 4
    except Exception as e:
        log(f"ERROR: claude CLI subprocess failed for {date_str}: {e}")
        return 4

    elapsed = (datetime.now(timezone.utc) - started).total_seconds()

    if result.returncode != 0:
        log(f"ERROR: claude CLI exited {result.returncode} for {date_str}: {result.stderr[:500]}")
        return 4

    summary_text = result.stdout.strip()
    if not summary_text:
        log(f"ERROR: claude CLI returned empty output for {date_str}")
        return 5

    frontmatter = (
        "---\n"
        f"date: {date_str}\n"
        f"transcript_count: {len(transcripts)}\n"
        f"generated: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
        f"model: {MODEL}\n"
        f"via: claude_cli_max_sub\n"
        f"elapsed_seconds: {elapsed:.1f}\n"
        "---\n\n"
    )

    # Atomic write: tmp + chmod + rename — readers never see a partial file,
    # and the file is born with 0600 perms in one step (no umask race window).
    tmp_path = summary_path.with_suffix(".md.tmp")
    tmp_path.write_text(frontmatter + summary_text + "\n")
    tmp_path.chmod(0o600)
    tmp_path.replace(summary_path)

    log(f"DONE: {date_str} → {summary_path} ({len(summary_text)} chars, {elapsed:.1f}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
