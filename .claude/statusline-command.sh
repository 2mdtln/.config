#!/usr/bin/env bash

input=$(cat)

# --- JSON helper: prefer jq, fall back to python3 ---
# Usage: _jq '.some.path // empty'
# The global $input variable must already be set.
_jq() {
  local filter="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r "$filter"
    return
  fi
  # python3 fallback: handles dotted-path filters and '// empty'
  printf '%s' "$input" | python3 -c "
import sys, json
def resolve(obj, expr):
    expr = expr.strip()
    use_empty = False
    if '// empty' in expr:
        expr = expr.replace('// empty', '').strip()
        use_empty = True
    if expr.startswith('.'):
        expr = expr[1:]
    val = obj
    for p in (expr.split('.') if expr else []):
        if p == '':
            continue
        try:
            val = val[p]
        except (KeyError, TypeError):
            val = None
            break
    if val is None or val == '':
        print('' if use_empty else 'null', end='')
    else:
        print(str(val), end='')
try:
    data = json.loads(sys.stdin.read())
    resolve(data, '$filter')
except Exception:
    pass
"
}

# --- Colors (ANSI) via $'...' so ESC bytes are literal from the start ---
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'

FG_WHITE=$'\033[37m'
FG_CYAN=$'\033[36m'
FG_GREEN=$'\033[32m'
FG_YELLOW=$'\033[33m'
FG_RED=$'\033[31m'
FG_MAGENTA=$'\033[35m'
FG_BLUE=$'\033[34m'
FG_GRAY=$'\033[90m'

# --- Helpers ---

# Format a percentage with color: green < 50, yellow < 80, red >= 80
color_pct() {
  local pct="$1"
  local ipct
  ipct=$(printf "%.0f" "$pct" 2>/dev/null) || ipct=0
  if [ "$ipct" -ge 80 ]; then
    printf "%s%d%%%s" "$FG_RED" "$ipct" "$RESET"
  elif [ "$ipct" -ge 50 ]; then
    printf "%s%d%%%s" "$FG_YELLOW" "$ipct" "$RESET"
  else
    printf "%s%d%%%s" "$FG_GREEN" "$ipct" "$RESET"
  fi
}

# Build a mini bar out of 10 blocks
bar_10() {
  local pct="$1"
  local filled
  filled=$(awk "BEGIN { printf \"%d\", ($pct / 10 + 0.5) }")
  [ "$filled" -gt 10 ] && filled=10
  local empty=$((10 - filled))
  local bar=""
  local color
  local i
  if [ "$filled" -ge 8 ]; then
    color="$FG_RED"
  elif [ "$filled" -ge 5 ]; then
    color="$FG_YELLOW"
  else
    color="$FG_GREEN"
  fi
  for i in $(seq 1 "$filled"); do bar="${bar}█"; done
  for i in $(seq 1 "$empty");  do bar="${bar}░"; done
  printf "%s%s%s" "$color" "$bar" "$RESET"
}

# Convert a Unix epoch to "Xd Xh Xm" countdown from now
countdown() {
  local resets_at="$1"
  local now
  now=$(date +%s)
  local diff=$((resets_at - now))
  if [ "$diff" -le 0 ]; then
    printf "%snow%s" "$FG_GREEN" "$RESET"
    return
  fi
  local days=$(( diff / 86400 ))
  local hours=$(( (diff % 86400) / 3600 ))
  local mins=$(( (diff % 3600) / 60 ))
  local out=""
  [ "$days" -gt 0 ] && out="${days}d "
  out="${out}${hours}h ${mins}m"
  printf "%s%s%s" "$FG_GRAY" "$out" "$RESET"
}

# --- Separator ---
SEP="${FG_GRAY} │ ${RESET}"

# ── Context window ────────────────────────────────────────────────
# used_percentage is null before the first API call; fall back to
# calculating from current_usage.input_tokens if the pre-calculated
# field is missing.
ctx_used=$(_jq '.context_window.used_percentage // empty')

if [ -z "$ctx_used" ]; then
  # Try to derive from raw token counts
  ctx_input=$(_jq '.context_window.current_usage.input_tokens // empty')
  ctx_size=$(_jq '.context_window.context_window_size // empty')
  if [ -n "$ctx_input" ] && [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ]; then
    ctx_used=$(awk "BEGIN { printf \"%.1f\", ($ctx_input / $ctx_size) * 100 }")
  fi
fi

ctx_part=""
if [ -n "$ctx_used" ]; then
  ctx_pct_str=$(color_pct "$ctx_used")
  ctx_bar=$(bar_10 "$ctx_used")
  ctx_part="${FG_CYAN}CTX${RESET} ${ctx_bar} ${ctx_pct_str}"
fi

# ── 5-hour limit ─────────────────────────────────────────────────
five_pct=$(_jq '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(_jq '.rate_limits.five_hour.resets_at // empty')

five_part=""
if [ -n "$five_pct" ]; then
  five_pct_str=$(color_pct "$five_pct")
  five_bar=$(bar_10 "$five_pct")
  five_cd=""
  [ -n "$five_reset" ] && five_cd=" $(countdown "$five_reset")"
  five_part="${FG_MAGENTA}5H${RESET} ${five_bar} ${five_pct_str}${five_cd}"
fi

# ── 7-day limit ──────────────────────────────────────────────────
week_pct=$(_jq '.rate_limits.seven_day.used_percentage // empty')
week_reset=$(_jq '.rate_limits.seven_day.resets_at // empty')

week_part=""
if [ -n "$week_pct" ]; then
  week_pct_str=$(color_pct "$week_pct")
  week_bar=$(bar_10 "$week_pct")
  week_cd=""
  [ -n "$week_reset" ] && week_cd=" $(countdown "$week_reset")"
  week_part="${FG_BLUE}7D${RESET} ${week_bar} ${week_pct_str}${week_cd}"
fi

# ── Assemble ─────────────────────────────────────────────────────
parts=()
[ -n "$ctx_part"  ] && parts+=("$ctx_part")
[ -n "$five_part" ] && parts+=("$five_part")
[ -n "$week_part" ] && parts+=("$week_part")

if [ ${#parts[@]} -eq 0 ]; then
  # No usage data at all yet — show model name so the bar is not blank
  model=$(_jq '.model.display_name // empty')
  if [ -n "$model" ]; then
    printf "%s%s%s\n" "$FG_GRAY" "$model" "$RESET"
  else
    printf "%sstarting...%s\n" "$FG_GRAY" "$RESET"
  fi
  exit 0
fi

# Join with separator
line=""
for i in "${!parts[@]}"; do
  if [ "$i" -eq 0 ]; then
    line="${parts[$i]}"
  else
    line="${line}${SEP}${parts[$i]}"
  fi
done

printf "%s\n" "$line"
