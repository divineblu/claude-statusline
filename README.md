# Claude Code Statusline

A custom status line script for [Claude Code](https://claude.ai/code) that displays useful context at a glance.

```
📁 project:main | Opus 4.6 (1M context) | 5h: 12% (3h 42m) | 7d: 8% (5d 2h) | ☀️ 73.8°F
```

## What it shows

- **Folder + git branch** (e.g., `project:main`)
- **Model name** (e.g., `Opus 4.6 (1M context)`)
- **5-hour usage** with reset countdown
- **7-day usage** with reset countdown (shown when >= 5%)
- **Weather** with temperature based on your location

## Requirements

- macOS (uses Keychain for OAuth token, CoreLocation for weather)
- `jq` for JSON parsing
- `python3` for ISO 8601 timestamp parsing
- `curl` for API calls

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

Claude Code pipes a JSON blob to your script's stdin on every status update. The JSON contains workspace info, model name, rate limits, context window stats, and more. The script reads it, formats a one-line string, and prints it to stdout which becomes the status bar.

## Caching

- **Usage data**: cached for 60 seconds at `/tmp/claude_usage_cache`
- **Weather**: cached for 10 minutes at `/tmp/claude_weather_cache`
- **Location**: cached for 30 minutes at `/tmp/claude_location_cache`

## Location (weather)

The script uses a bundled macOS app (`~/.claude/ClaudeLocation.app`) to get coordinates via CoreLocation. If you don't have this helper app, the weather section will simply not appear.
