#!/usr/bin/env bash
# LZ Claude Code status line — PAI-style, 5-line layout
# Receives Claude Code JSON on stdin; must stay fast (<100ms after first run)

input=$(cat)

# ── Parse JSON fields ──────────────────────────────────────────────────────────
_j() { echo "$input" | jq -r "$1 // empty"; }

version=$(_j '.version')
model=$(_j '.model.display_name')
used=$(_j '.context_window.used_percentage')
cost=$(_j '.cost_usd')
duration_ms=$(_j '.total_duration_ms')
rl_5h=$(_j '.rate_limits.five_hour.used_percentage')
rl_7d=$(_j '.rate_limits.seven_day.used_percentage')
rl_5h_reset=$(_j '.rate_limits.five_hour.resets_at')
rl_7d_reset=$(_j '.rate_limits.seven_day.resets_at')
cwd=$(_j '.workspace.current_dir')
cwd="${cwd:-$(pwd)}"

# ── ANSI helpers ───────────────────────────────────────────────────────────────
RST=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
BLUE=$'\033[34m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
BBLUE=$'\033[1;34m'   # bold blue
SEP="${DIM}│${RST}"   # dim pipe separator

# Dim separator line (horizontal rule)
HRULE="${DIM}────────────────────────────────────────────────────────────${RST}"

# ── Weather (cached, 30-min TTL, non-blocking) ─────────────────────────────────
WEATHER_CACHE=/tmp/claude-statusline-weather
weather=""
_refresh_weather() {
  ( curl -sf --max-time 5 'wttr.in/?format=%t+%C' > "${WEATHER_CACHE}.tmp" 2>/dev/null \
    && mv "${WEATHER_CACHE}.tmp" "$WEATHER_CACHE" ) &
  disown 2>/dev/null || true
}
if [ -f "$WEATHER_CACHE" ]; then
  # stale if modified more than 30 min ago (find returns it if older)
  if find "$WEATHER_CACHE" -mmin +30 -print 2>/dev/null | grep -q .; then
    # use stale value, refresh in background
    weather=$(cat "$WEATHER_CACHE" 2>/dev/null)
    _refresh_weather
  else
    weather=$(cat "$WEATHER_CACHE" 2>/dev/null)
  fi
else
  # no cache yet — try a fast inline fetch; fall back to silent omit
  weather=$(curl -sf --max-time 1 'wttr.in/?format=%t+%C' 2>/dev/null || true)
  [ -n "$weather" ] && echo "$weather" > "$WEATHER_CACHE"
fi

# ── Helper: pct color ──────────────────────────────────────────────────────────
_pct_color() {
  local pct=$1
  if   [ "$pct" -ge 80 ]; then printf '%s' "$RED"
  elif [ "$pct" -ge 60 ]; then printf '%s' "$YELLOW"
  else                          printf '%s' "$GREEN"
  fi
}

# ── Helper: reset-time label ───────────────────────────────────────────────────
_reset_label() {
  local epoch=$1 fmt=${2:-%-I:%M%p}
  [ -z "$epoch" ] && return
  # epoch must be a number
  [[ "$epoch" =~ ^[0-9]+$ ]] || return
  local hhmm
  hhmm=$(date -r "$epoch" +"$fmt" 2>/dev/null || date -d "@$epoch" +"$fmt" 2>/dev/null || true)
  [ -n "$hhmm" ] && printf ' %s↻%s%s' "$DIM" "$hhmm" "$RST"
}

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 1 — header: dim rule + bold-blue title + time + weather
# ═══════════════════════════════════════════════════════════════════════════════
time_now=$(date +%-I:%M%p)
line1="${HRULE}"$'\n'
line1+="${DIM}─── ${RST}${BBLUE}LZ STATUSLINE${RST}"
line1+="  ${DIM}${time_now}${RST}"
[ -n "$weather" ] && line1+="  ${DIM}${weather}${RST}"

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 2 — ENV: CC version + model
# ═══════════════════════════════════════════════════════════════════════════════
line2=""
if [ -n "$version" ]; then
  line2+="${DIM}CC:${RST} ${BLUE}${version}${RST}"
fi
if [ -n "$model" ]; then
  [ -n "$line2" ] && line2+="  ${SEP}  "
  line2+="${DIM}Model:${RST} ${CYAN}${model}${RST}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 3 — CONTEXT bar (30 blocks)
# ═══════════════════════════════════════════════════════════════════════════════
line3=""
if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")
  bar_width=30
  filled=$(( used_int * bar_width / 100 ))
  free=$(( bar_width - filled ))

  bar_color=$(_pct_color "$used_int")

  filled_str=""
  for (( i=0; i<filled; i++ )); do filled_str+="█"; done
  free_str=""
  for (( i=0; i<free; i++ )); do free_str+="⣿"; done

  line3="${BLUE}◉ CONTEXT:${RST} "
  line3+="${bar_color}${filled_str}${RST}"
  line3+="${DIM}${bar_color}${free_str}${RST}"
  line3+=" ${bar_color}${used_int}%${RST}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 4 — USAGE: rate limits + cost + duration
# ═══════════════════════════════════════════════════════════════════════════════
line4_parts=()

if [ -n "$rl_5h" ]; then
  pct5=$(printf '%.0f' "$rl_5h")
  c=$(_pct_color "$pct5")
  seg="${DIM}5H:${RST} ${c}${pct5}%${RST}"
  seg+=$(_reset_label "$rl_5h_reset")
  line4_parts+=("$seg")
fi

if [ -n "$rl_7d" ]; then
  pct7=$(printf '%.0f' "$rl_7d")
  c=$(_pct_color "$pct7")
  seg="${DIM}WK:${RST} ${c}${pct7}%${RST}"
  seg+=$(_reset_label "$rl_7d_reset" '%a %-m/%-d %-I:%M%p')
  line4_parts+=("$seg")
fi

if [ -n "$cost" ]; then
  cost_fmt=$(printf '%.2f' "$cost")
  line4_parts+=("${YELLOW}\$${cost_fmt}${RST}")
fi

if [ -n "$duration_ms" ] && [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
  total_s=$(( duration_ms / 1000 ))
  mins=$(( total_s / 60 ))
  secs=$(( total_s % 60 ))
  if [ "$mins" -gt 0 ]; then
    line4_parts+=("${DIM}${mins}m ${secs}s${RST}")
  else
    line4_parts+=("${DIM}${secs}s${RST}")
  fi
fi

line4=""
if [ "${#line4_parts[@]}" -gt 0 ]; then
  line4="${YELLOW}▰ USAGE:${RST} "
  first=1
  for part in "${line4_parts[@]}"; do
    [ "$first" -eq 1 ] && first=0 || line4+="  ${SEP}  "
    line4+="$part"
  done
fi

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 5 — PWD: dir basename + git branch
# ═══════════════════════════════════════════════════════════════════════════════
dir_base="$(basename "$cwd")"
line5="${CYAN}◆ PWD:${RST} ${dir_base}"

if branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
            || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null); then
  dirty=""
  if ! git -C "$cwd" --no-optional-locks diff --quiet --ignore-submodules -- 2>/dev/null \
  || ! git -C "$cwd" --no-optional-locks diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
    dirty="*"
  fi
  line5+="  ${SEP}  🌿 ${GREEN}${branch}${dirty}${RST}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# OUTPUT — emit all non-empty lines
# ═══════════════════════════════════════════════════════════════════════════════
printf '%s\n' "$line1"
[ -n "$line2" ] && printf '%s\n' "$line2"
[ -n "$line3" ] && printf '%s\n' "$line3"
[ -n "$line4" ] && printf '%s\n' "$line4"
printf '%s\n' "$line5"
printf '%s\n' "$HRULE"
