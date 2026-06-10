#!/usr/bin/env bash
# LZ Claude Code status line — compact 3-line layout
#   1: model · CC version │ date + time + weather
#   2: context bar │ rate limits / cost / duration
#   3: pwd + git branch + ahead/behind
# Receives Claude Code JSON on stdin; must stay fast (<100ms after first run)

input=$(cat)

# ── Parse JSON fields ──────────────────────────────────────────────────────────
_j() { echo "$input" | jq -r "$1 // empty"; }

version=$(_j '.version')
model=$(_j '.model.display_name')
used=$(_j '.context_window.used_percentage')
ctx_used_tok=$(_j '.context_window.total_input_tokens')
ctx_window=$(_j '.context_window.context_window_size')
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
MAGENTA=$'\033[35m'
SEP="${DIM}│${RST}"   # dim pipe separator
DOT=" ${DIM}·${RST} " # dim middle-dot separator

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

# ── Helpers: visible width (ANSI stripped) + right-padding ─────────────────────
_vlen() {
  local s
  s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')
  printf '%d' "${#s}"
}
_pad_to() {
  local s=$1 n
  n=$(_vlen "$s")
  while [ "$n" -lt "$2" ]; do s+=" "; n=$((n+1)); done
  printf '%s' "$s"
}

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 1 — model · CC version │ date + time + weather
# ═══════════════════════════════════════════════════════════════════════════════
env=""
[ -n "$model" ] && env+="${CYAN}${model}${RST}"
if [ -n "$version" ]; then
  [ -n "$env" ] && env+="$DOT"
  env+="${DIM}CC ${version}${RST}"
fi
l1_left=""
[ -n "$env" ] && l1_left="${MAGENTA}✦${RST} ${env}"

time_now=$(date '+%a %-m/%-d %-I:%M%p')
l1_right="${CYAN}◷${RST} ${DIM}${time_now}${RST}"
[ -n "$weather" ] && l1_right+="  ${YELLOW}☼${RST} ${DIM}${weather}${RST}"

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 2 — context bar │ rate limits / cost / duration
# ═══════════════════════════════════════════════════════════════════════════════
l2_left=""
if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")
  bar_width=10
  filled=$(( used_int * bar_width / 100 ))
  # always show at least one block once any context is used
  [ "$used_int" -gt 0 ] && [ "$filled" -eq 0 ] && filled=1
  free=$(( bar_width - filled ))

  bar_color=$(_pct_color "$used_int")

  filled_str=""
  for (( i=0; i<filled; i++ )); do filled_str+="█"; done
  free_str=""
  for (( i=0; i<free; i++ )); do free_str+="⣿"; done

  # Format token counts as e.g. "87k/200k"
  ctx_tok_label=""
  if [ -n "$ctx_used_tok" ] && [ -n "$ctx_window" ] \
     && [[ "$ctx_used_tok" =~ ^[0-9]+$ ]] && [[ "$ctx_window" =~ ^[0-9]+$ ]]; then
    _k() { printf '%dk' "$(( ($1 + 500) / 1000 ))"; }
    ctx_tok_label=" ${DIM}$(_k "$ctx_used_tok")/$(_k "$ctx_window")${RST}"
  fi

  l2_left="${BLUE}◉ CTX${RST} "
  l2_left+="${bar_color}${filled_str}${RST}"
  l2_left+="${DIM}${bar_color}${free_str}${RST}"
  l2_left+=" ${bar_color}${used_int}%${RST}"
  l2_left+="${ctx_tok_label}"
fi

usage_parts=()

if [ -n "$rl_5h" ]; then
  pct5=$(printf '%.0f' "$rl_5h")
  c=$(_pct_color "$pct5")
  seg="${DIM}5H${RST} ${c}${pct5}%${RST}"
  seg+=$(_reset_label "$rl_5h_reset")
  usage_parts+=("$seg")
fi

if [ -n "$rl_7d" ]; then
  pct7=$(printf '%.0f' "$rl_7d")
  c=$(_pct_color "$pct7")
  seg="${DIM}WK${RST} ${c}${pct7}%${RST}"
  seg+=$(_reset_label "$rl_7d_reset" '%a %-I:%M%p')
  usage_parts+=("$seg")
fi

if [ -n "$cost" ]; then
  cost_fmt=$(printf '%.2f' "$cost")
  usage_parts+=("${YELLOW}\$${cost_fmt}${RST}")
fi

if [ -n "$duration_ms" ] && [[ "$duration_ms" =~ ^[0-9]+$ ]]; then
  total_s=$(( duration_ms / 1000 ))
  mins=$(( total_s / 60 ))
  secs=$(( total_s % 60 ))
  if [ "$mins" -gt 0 ]; then
    usage_parts+=("${DIM}${mins}m ${secs}s${RST}")
  else
    usage_parts+=("${DIM}${secs}s${RST}")
  fi
fi

l2_right=""
if [ "${#usage_parts[@]}" -gt 0 ]; then
  l2_right="${YELLOW}◎${RST} "
  first=1
  for part in "${usage_parts[@]}"; do
    [ "$first" -eq 1 ] && first=0 || l2_right+="$DOT"
    l2_right+="$part"
  done
fi

# ── Align the │ separators: pad both left segments to the same width ──────────
if [ -n "$l1_left" ] && [ -n "$l1_right" ] && [ -n "$l2_left" ] && [ -n "$l2_right" ]; then
  w1=$(_vlen "$l1_left")
  w2=$(_vlen "$l2_left")
  maxw=$(( w1 > w2 ? w1 : w2 ))
  l1_left=$(_pad_to "$l1_left" "$maxw")
  l2_left=$(_pad_to "$l2_left" "$maxw")
fi

line1="$l1_left"
if [ -n "$l1_right" ]; then
  [ -n "$line1" ] && line1+="  ${SEP}  "
  line1+="$l1_right"
fi

line2="$l2_left"
if [ -n "$l2_right" ]; then
  [ -n "$line2" ] && line2+="  ${SEP}  "
  line2+="$l2_right"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# LINE 3 — pwd + git branch
# ═══════════════════════════════════════════════════════════════════════════════
dir_base="$(basename "$cwd")"
line3="${CYAN}◆${RST} ${dir_base}"

if branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null \
            || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null); then
  dirty=""
  if ! git -C "$cwd" --no-optional-locks diff --quiet --ignore-submodules -- 2>/dev/null \
  || ! git -C "$cwd" --no-optional-locks diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
    dirty="*"
  fi
  line3+="  ${GREEN}⎇ ${branch}${RST}${YELLOW}${dirty}${RST}"

  # ahead/behind vs upstream (rev-list prints "<behind><TAB><ahead>")
  if ab=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null); then
    behind=${ab%%	*}
    ahead=${ab##*	}
    [ "$ahead"  != "0" ] && line3+=" ${GREEN}↑${ahead}${RST}"
    [ "$behind" != "0" ] && line3+=" ${RED}↓${behind}${RST}"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# OUTPUT — emit all non-empty lines
# ═══════════════════════════════════════════════════════════════════════════════
printf '%s\n' "$line1"
[ -n "$line2" ] && printf '%s\n' "$line2"
printf '%s\n' "$line3"
