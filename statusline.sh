#!/bin/bash

# Status line script for Claude Code
# Displays: Folder:branch | Model | Usage (5h / 7d) | Weather

# Read JSON input from stdin
input=$(cat)

# --- FOLDER + GIT BRANCH ---
current_dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
if [ -n "$current_dir" ] && [ -d "$current_dir" ]; then
  folder_name=$(basename "$current_dir")
  git_branch=$(git -C "$current_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -n "$git_branch" ]; then
    folder_display="${folder_name}:${git_branch}"
  else
    folder_display="${folder_name}"
  fi
else
  folder_display="~"
fi

# --- MODEL NAME ---
model_name=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
model_short=$(echo "$model_name" | sed -E 's/Claude ([0-9.]+) (.*)/\2 \1/' | sed 's/Sonnet 4/Sonnet 4/')

# --- USAGE (cached 60s, reads OAuth token from macOS Keychain) ---
usage_cache="/tmp/claude_usage_cache"
usage_display=""

if [ -f "$usage_cache" ]; then
  cache_age=$(($(date +%s) - $(stat -f %m "$usage_cache" 2>/dev/null || echo 0)))
  if [ $cache_age -lt 60 ]; then
    usage_display=$(cat "$usage_cache")
  fi
fi

if [ -z "$usage_display" ]; then
  # Try to read OAuth token from macOS Keychain
  access_token=$(/usr/bin/security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  if [ $? -eq 0 ] && [ -n "$access_token" ]; then
    # Parse the JSON credentials to extract the actual token
    token=$(echo "$access_token" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    if [ -n "$token" ]; then
      # Fetch usage from Anthropic API
      usage_json=$(curl -s --max-time 3 \
        -H "Authorization: Bearer ${token}" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

      if [ $? -eq 0 ] && [ -n "$usage_json" ]; then
        five_hour=$(echo "$usage_json" | jq -r '.five_hour.utilization // empty' 2>/dev/null)
        seven_day=$(echo "$usage_json" | jq -r '.seven_day.utilization // empty' 2>/dev/null)
        five_reset=$(echo "$usage_json" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
        seven_reset=$(echo "$usage_json" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)

        # Format reset times as relative durations
        format_reset() {
          local reset_at="$1"
          if [ -z "$reset_at" ]; then echo ""; return; fi
          # Use python for reliable ISO 8601 parsing (handles timezone offsets correctly)
          local reset_epoch=$(python3 -c "
from datetime import datetime, timezone
import sys
try:
    dt = datetime.fromisoformat(sys.argv[1])
    print(int(dt.timestamp()))
except: pass
" "$reset_at" 2>/dev/null)
          if [ -z "$reset_epoch" ]; then echo ""; return; fi
          local now_epoch=$(date +%s)
          local diff=$(( reset_epoch - now_epoch ))
          if [ $diff -le 0 ]; then echo ""; return; fi
          local mins=$(( diff / 60 ))
          if [ $mins -lt 60 ]; then
            echo "${mins}m"
          else
            local hours=$(( mins / 60 ))
            local rem=$(( mins % 60 ))
            if [ $hours -ge 24 ]; then
              local days=$(( hours / 24 ))
              local rem_h=$(( hours % 24 ))
              if [ $rem_h -gt 0 ]; then echo "${days}d ${rem_h}h"; else echo "${days}d"; fi
            elif [ $rem -gt 0 ]; then
              echo "${hours}h ${rem}m"
            else
              echo "${hours}h"
            fi
          fi
        }

        if [ -n "$five_hour" ]; then
          five_pct=$(printf "%.0f" "$five_hour")
          five_reset_str=$(format_reset "$five_reset")
          if [ -n "$five_reset_str" ]; then
            usage_display="5h: ${five_pct}% (${five_reset_str})"
          else
            usage_display="5h: ${five_pct}%"
          fi
        fi

        if [ -n "$seven_day" ]; then
          seven_pct=$(printf "%.0f" "$seven_day")
          # Only show 7d if utilization >= 5% to keep the line clean
          if [ "$seven_pct" -ge 5 ] 2>/dev/null; then
            seven_reset_str=$(format_reset "$seven_reset")
            if [ -n "$seven_reset_str" ]; then
              seven_part="7d: ${seven_pct}% (${seven_reset_str})"
            else
              seven_part="7d: ${seven_pct}%"
            fi
            if [ -n "$usage_display" ]; then
              usage_display="${usage_display} | ${seven_part}"
            else
              usage_display="${seven_part}"
            fi
          fi
        fi

        # Cache the result
        if [ -n "$usage_display" ]; then
          echo "$usage_display" > "$usage_cache"
        fi
      fi
    fi
  fi
fi

# --- LOCATION (cached 30 min by the Swift helper) ---
location_cache="/tmp/claude_location_cache"
lat=""
lon=""

# Try reading cached location first; if stale or missing, refresh via app bundle
if [ -f "$location_cache" ]; then
  cache_age=$(($(date +%s) - $(stat -f %m "$location_cache" 2>/dev/null || echo 0)))
  if [ $cache_age -lt 1800 ]; then
    coords=$(cat "$location_cache")
    lat="${coords%%,*}"
    lon="${coords##*,}"
  fi
fi

if [ -z "$lat" ]; then
  # Launch as app bundle (background-only, no Dock icon) so CoreLocation permission works
  open -W "$HOME/.claude/ClaudeLocation.app" 2>/dev/null
  if [ -f "$location_cache" ]; then
    coords=$(cat "$location_cache")
    lat="${coords%%,*}"
    lon="${coords##*,}"
  fi
fi

# --- WEATHER (cached 10 min) ---
weather_cache="/tmp/claude_weather_cache"
weather_display=""

if [ -f "$weather_cache" ]; then
  cache_age=$(($(date +%s) - $(stat -f %m "$weather_cache" 2>/dev/null || echo 0)))
  if [ $cache_age -lt 600 ]; then
    weather_display=$(cat "$weather_cache")
  fi
fi

if [ -z "$weather_display" ] && [ -n "$lat" ]; then
  weather_json=$(curl -s --max-time 2 "https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,weather_code&temperature_unit=fahrenheit&timezone=auto" 2>/dev/null)

  if [ $? -eq 0 ] && [ -n "$weather_json" ]; then
    temp=$(echo "$weather_json" | jq -r '.current.temperature_2m' 2>/dev/null)
    weather_code=$(echo "$weather_json" | jq -r '.current.weather_code' 2>/dev/null)

    case "$weather_code" in
      0) icon="☀️";;
      1|2|3) icon="⛅";;
      45|48) icon="🌫️";;
      51|53|55|61|63|65) icon="🌧️";;
      71|73|75) icon="❄️";;
      80|81|82) icon="🌦️";;
      95|96|99) icon="⛈️";;
      *) icon="🌡️";;
    esac

    if [ "$temp" != "null" ] && [ -n "$temp" ]; then
      weather_display="${icon} ${temp}°F"
      echo "$weather_display" > "$weather_cache"
    fi
  fi
fi

# --- OUTPUT STATUS LINE ---
parts="📁 ${folder_display} | ${model_short}"
if [ -n "$usage_display" ]; then
  parts="${parts} | ${usage_display}"
fi
if [ -n "$weather_display" ]; then
  parts="${parts} | ${weather_display}"
fi
printf "%s" "$parts"
