# Claude Code Statusline

A custom status line script for [Claude Code](https://claude.ai/code) that displays useful context at a glance in a compact 3-line layout.

```
✦ Fable 5 · CC 2.1.170          │  ◷ Tue 6/9 8:19PM  ☼ +87°F Sunny
◉ CTX ███⣿⣿⣿⣿⣿⣿⣿ 34% 43k/1000k  │  ◎ 5H 16% ↻10:40PM · WK 3% ↻Mon 6:00PM
◆ orbixia  ⎇ main* ↑2 ↓1
```

## What it shows

- **Line 1** — model name and Claude Code version, then day/date/time and current weather ([wttr.in](https://wttr.in))
- **Line 2** — context-window gauge with token counts (e.g. `43k/1000k`), 5-hour and weekly rate-limit usage with reset times, plus session cost and duration when reported
- **Line 3** — directory basename, git branch with dirty marker (`*`), and ahead/behind counts vs upstream (`↑2 ↓1`)

## Design notes

- The `│` separators on lines 1 and 2 are vertically aligned (ANSI-aware visible-width padding)
- Usage percentages are colored green → yellow (≥60%) → red (≥80%)
- All symbols are single-width text glyphs — no emoji or nerd-font requirement

## Requirements

- `bash`, `jq`, `curl`
- Weather is optional: if the network is unavailable the segment is silently omitted

## Setup

1. Copy the script somewhere persistent:

```bash
cp statusline.sh ~/.claude/statusline.sh
```

2. Add the following to your `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

3. Restart Claude Code. The status line appears at the top of your terminal.

## How it works

Claude Code pipes a JSON blob to your script's stdin on every status update. The JSON contains workspace info, model name, rate limits, context window stats, and more. The script reads it, formats the lines, and prints them to stdout which becomes the status bar.

## Caching

- **Weather**: cached for 30 minutes at `/tmp/claude-statusline-weather`; stale values are served instantly while a background refresh runs, so the status line never blocks on the network
