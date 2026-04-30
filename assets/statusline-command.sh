#!/bin/bash
# Claude Code statusline: up to 8 lines
#   ● Working · <tool>? · <elapsed>     (or ✓ Done · Ns ago / ○ Idle)
#   {user} | {git_branch or "Git not init"} [wt: name]
#   {dir}
#   [Context Window] {bar} {pct}% | {model} | {effort}
#   *Claude Code ~5h {bar} {pct}% | {remaining} | ({reset})
#   *Claude Code ~7d {bar} {pct}% | {remaining} | ({reset})
#   Codex Review ~5h {bar} {pct}% | {remaining} | ({reset}) [age?]   ← subscription
#   Codex Review ~7d {bar} {pct}% | {remaining} | ({reset}) [age?]   ← subscription
#   -- OR (API-key mode, replaces both rows above with one line) --
#   Codex {OpenAI|Azure} 💰 ${cost} (today) [age?]                   ← API-key
# *Claude Code rows come from Claude's rate_limits (stdin JSON), rendered in
# Claude brand orange. Codex rows come from the Codex CLI's SQLite log via
# ~/.claude/scripts/codex-usage.sh (60s cached), rendered in Codex brand blue.
# In API-key mode, the helper detects the absence of rate_limits events and
# instead sums total_cost from the last 1h of usage events. [Context Window]
# keeps threshold-based green/yellow/red so the "about to overflow" signal
# stays loud.

input=$(cat)

# ---- ANSI colors ----
C_BLUE=$'\033[34m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'
C_MAGENTA=$'\033[35m'
C_WHITE=$'\033[37m'
C_GRAY=$'\033[90m'
C_GREEN=$'\033[32m'
C_RED=$'\033[31m'
C_RESET=$'\033[0m'
# Brand colors (256-color palette): Claude = warm orange (#D97757-ish),
# Codex = vivid blue. Used for CC/CX rate-limit bars so each provider's
# utilization is identifiable at a glance.
C_CLAUDE=$'\033[38;5;208m'
C_CODEX=$'\033[38;5;39m'

SEP="${C_GRAY} | ${C_RESET}"

# ---- jq helper ----
jqv() {
  printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null
}

# ---- Resolve dir + git state ----
user=$(whoami)

raw_dir=$(jqv '.workspace.current_dir')
[ -z "$raw_dir" ] && raw_dir=$(jqv '.cwd')
[ -z "$raw_dir" ] && raw_dir="$PWD"
if [ -n "$HOME" ] && [[ "$raw_dir" == "$HOME"* ]]; then
  dir="~${raw_dir#$HOME}"
else
  dir="$raw_dir"
fi

branch=$(cd "$raw_dir" 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ -z "$branch" ] && branch="Git not init"

# Worktree detection: when --git-dir differs from --git-common-dir, we're in a
# linked worktree rather than the main checkout. Show "(wt: <toplevel-name>)"
# so it's obvious which working copy we're editing.
wt_tag=""
if [ "$branch" != "Git not init" ]; then
  _gdir=$(cd "$raw_dir" 2>/dev/null && git rev-parse --git-dir 2>/dev/null)
  _gcdir=$(cd "$raw_dir" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)
  if [ -n "$_gdir" ] && [ -n "$_gcdir" ] && [ "$_gdir" != "$_gcdir" ]; then
    _wtop=$(cd "$raw_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
    [ -n "$_wtop" ] && wt_tag="${SEP}${C_GRAY}(wt: $(basename "$_wtop"))${C_RESET}"
  fi
fi

# Line 1: user | branch [wt]   (dir moved to its own line below)
line1="${C_BLUE}${user}${C_RESET}${SEP}${C_CYAN}${branch}${C_RESET}${wt_tag}"
# Line 2: dir
line_dir="${C_YELLOW}${dir}${C_RESET}"

# ---- Bar builder (10 cells, █/░) ----
# Usage: make_bar <pct> [fixed_color]
#   With no second arg, color follows usage thresholds (green/yellow/red).
#   With a fixed color (e.g. $C_CLAUDE), the bar is painted that color regardless
#   of usage — used for CC/CX bars where provider identity matters more than
#   the threshold signal.
make_bar() {
  local pct=$1
  local fixed_color=${2:-}
  [ -z "$pct" ] && pct=0
  if [ "$pct" -lt 0 ]; then pct=0; fi
  if [ "$pct" -gt 100 ]; then pct=100; fi

  local filled=$(( pct / 10 ))
  local empty=$(( 10 - filled ))

  local color
  if [ -n "$fixed_color" ]; then
    color=$fixed_color
  elif [ "$pct" -lt 50 ]; then
    color=$C_GREEN
  elif [ "$pct" -lt 80 ]; then
    color=$C_YELLOW
  else
    color=$C_RED
  fi

  local bar=""
  local i=0
  while [ "$i" -lt "$filled" ]; do
    bar+="█"
    i=$((i+1))
  done
  i=0
  while [ "$i" -lt "$empty" ]; do
    bar+="░"
    i=$((i+1))
  done

  printf '%s%s%s' "$color" "$bar" "$C_RESET"
}

fmt_pct() {
  local pct=$1
  [ -z "$pct" ] && pct=0
  printf '%s%3d%%%s' "$C_WHITE" "$pct" "$C_RESET"
}

fmt_remain_5h() {
  local secs=$1
  if [ -z "$secs" ] || [ "$secs" -le 0 ]; then
    printf ''
    return
  fi
  local h=$(( secs / 3600 ))
  local m=$(( (secs % 3600) / 60 ))
  printf '%d:%02d' "$h" "$m"
}

fmt_remain_7d() {
  local secs=$1
  if [ -z "$secs" ] || [ "$secs" -le 0 ]; then
    printf ''
    return
  fi
  local d=$(( secs / 86400 ))
  local h=$(( (secs % 86400) / 3600 ))
  local m=$(( (secs % 3600) / 60 ))
  printf '%d:%02d:%02d' "$d" "$h" "$m"
}

fmt_elapsed() {
  # Short elapsed-time formatter for the activity line.
  #  0-59s    -> "12s"
  #  1-59m    -> "2:34"
  #  >= 1h    -> "1:02:03"
  local s=$1
  [ -z "$s" ] && { printf ''; return; }
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 60 ]; then
    printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%d:%02d' "$((s/60))" "$((s%60))"
  else
    printf '%d:%02d:%02d' "$((s/3600))" "$(((s%3600)/60))" "$((s%60))"
  fi
}

fmt_reset_time() {
  # resets_at is a Unix epoch number (integer), not ISO string
  local ts=$1
  local now_s=$2
  [ -z "$ts" ] && { printf ''; return; }
  if [ "$ts" -le "$now_s" ]; then
    printf 'now'
    return
  fi
  local mon day hm
  mon=$(date -r "$ts" "+%-m" 2>/dev/null)
  day=$(date -r "$ts" "+%-d" 2>/dev/null)
  hm=$(date -r "$ts" "+%H:%M" 2>/dev/null)
  printf '%s/%s %s' "$mon" "$day" "$hm"
}

now_s=$(date "+%s")

# ---- Line 2: ctx | model | effort ----
ctx_pct=$(jqv '.context_window.used_percentage')
model=$(jqv '.model.display_name')
model=${model// context/}
effort=$(jqv '.output_style.name')

line2=""
if [ -n "$ctx_pct" ]; then
  ctx_int=${ctx_pct%.*}
  [ -z "$ctx_int" ] && ctx_int=0
  bar=$(make_bar "$ctx_int")
  pct=$(fmt_pct "$ctx_int")
  line2="${C_WHITE}[Context Window]${C_RESET} ${bar} ${pct}"
  [ -n "$model" ]  && line2+="${SEP}${C_CYAN}${model}${C_RESET}"
  [ -n "$effort" ] && line2+="${SEP}${C_MAGENTA}${effort}${C_RESET}"
fi

# ---- Line 3: ~5h ----
h5_pct=$(jqv '.rate_limits.five_hour.used_percentage')
h5_reset=$(jqv '.rate_limits.five_hour.resets_at')

line3=""
if [ -n "$h5_pct" ]; then
  h5_int=${h5_pct%.*}
  [ -z "$h5_int" ] && h5_int=0
  bar=$(make_bar "$h5_int" "$C_CLAUDE")
  pct=$(fmt_pct "$h5_int")
  line3="${C_CLAUDE}*Claude Code ~5h${C_RESET} ${bar} ${pct}"

  if [ -n "$h5_reset" ] && [ "$h5_reset" -gt "$now_s" ]; then
    remain=$(fmt_remain_5h $(( h5_reset - now_s )))
    [ -n "$remain" ] && line3+="${SEP}${C_WHITE}${remain}${C_RESET}"
  fi
  reset_str=$(fmt_reset_time "$h5_reset" "$now_s")
  [ -n "$reset_str" ] && line3+="${SEP}${C_GRAY}(${reset_str})${C_RESET}"
fi

# ---- Line 4: ~7d ----
d7_pct=$(jqv '.rate_limits.seven_day.used_percentage')
d7_reset=$(jqv '.rate_limits.seven_day.resets_at')

line4=""
if [ -n "$d7_pct" ]; then
  d7_int=${d7_pct%.*}
  [ -z "$d7_int" ] && d7_int=0
  bar=$(make_bar "$d7_int" "$C_CLAUDE")
  pct=$(fmt_pct "$d7_int")
  line4="${C_CLAUDE}*Claude Code ~7d${C_RESET} ${bar} ${pct}"

  if [ -n "$d7_reset" ] && [ "$d7_reset" -gt "$now_s" ]; then
    remain=$(fmt_remain_7d $(( d7_reset - now_s )))
    [ -n "$remain" ] && line4+="${SEP}${C_WHITE}${remain}${C_RESET}"
  fi
  reset_str=$(fmt_reset_time "$d7_reset" "$now_s")
  [ -n "$reset_str" ] && line4+="${SEP}${C_GRAY}(${reset_str})${C_RESET}"
fi

# ---- Lines 5 & 6: Codex CX ~5h / ~7d  (or line 5 only in API-key mode) ----
# Pulled from ~/.codex/logs_2.sqlite via helper. 60s TTL cache inside helper.
# Subscription mode → two rows (~5h, ~7d) with usage bars.
# API-key mode      → single row: "Codex {provider} 💰 ${cost}" (last 1h).
line5=""
line6=""
cx_helper="${HOME}/.claude/scripts/codex-usage.sh"

fmt_sample_age() {
  # Human-readable age of sample (Xm / Xh / Xd), grey.
  local sampled=$1
  [ -z "$sampled" ] && { printf ''; return; }
  local age=$(( now_s - sampled ))
  [ "$age" -lt 0 ] && age=0
  local txt
  if [ "$age" -lt 60 ]; then
    txt="${age}s ago"
  elif [ "$age" -lt 3600 ]; then
    txt="$(( age / 60 ))m ago"
  elif [ "$age" -lt 86400 ]; then
    txt="$(( age / 3600 ))h ago"
  else
    txt="$(( age / 86400 ))d ago"
  fi
  printf '%s[%s]%s' "$C_GRAY" "$txt" "$C_RESET"
}

if [ -x "$cx_helper" ]; then
  cx_json=$("$cx_helper" 2>/dev/null)
  if [ -n "$cx_json" ]; then
    cx_available=$(printf '%s' "$cx_json" | jq -r '.available // false' 2>/dev/null)
    if [ "$cx_available" = "true" ]; then
      cx_mode=$(printf '%s' "$cx_json" | jq -r '.mode // "subscription"' 2>/dev/null)
      cx_provider=$(printf '%s' "$cx_json" | jq -r '.provider // "OpenAI"' 2>/dev/null)
      cx_sampled=$(printf '%s' "$cx_json" | jq -r '.sampled_at // empty' 2>/dev/null)
      age_suffix=$(fmt_sample_age "$cx_sampled")

      if [ "$cx_mode" = "api_key" ]; then
        # --- API-key mode: single cost line ---
        cx_cost=$(printf '%s' "$cx_json" | jq -r '.cost_usd // empty' 2>/dev/null)
        cx_window=$(printf '%s' "$cx_json" | jq -r '.window // empty' 2>/dev/null)
        cx_est=$(printf '%s' "$cx_json"   | jq -r '.cost_is_estimate // false' 2>/dev/null)
        cx_conf=$(printf '%s' "$cx_json"  | jq -r '.cost_confidence // empty' 2>/dev/null)
        if [ -n "$cx_cost" ]; then
          # "~" prefix and (est) suffix when the figure is not contract-actual.
          # Confidence classes — see codex-usage.sh header:
          #   azure_contract   → exact number, no prefix
          #   list_verified    → "~" prefix, "(list)"  — list rates, not Azure contract
          #   list_mixed       → "~" prefix, "(est*)"  — list + placeholder mix
          #   placeholder/other→ "~" prefix, "(est)"   — all guessed rates
          price_tag=""
          prefix=""
          if [ "$cx_est" = "true" ]; then
            prefix="~"
            case "$cx_conf" in
              list_verified) price_tag="list" ;;
              list_mixed)    price_tag="est*" ;;
              azure_contract) prefix=""; price_tag="" ;;
              *)             price_tag="est" ;;
            esac
          fi
          cost_fmt=$(printf '%s' "$cx_cost" | awk -v p="$prefix" '{printf "%s$%.4f", p, $1+0}')
          line5="${C_CODEX}Codex ${cx_provider}${C_RESET} 💰 ${C_WHITE}${cost_fmt}${C_RESET}"
          [ -n "$price_tag" ] && line5+="${C_GRAY}(${price_tag})${C_RESET}"
          # The window label ("today") is load-bearing: it tells the user this
          # isn't a live-session number. Without it the cost looks like it
          # belongs to the current turn, which is misleading.
          [ -n "$cx_window" ] && line5+="${SEP}${C_GRAY}(${cx_window})${C_RESET}"
          [ -n "$age_suffix" ] && line5+=" ${age_suffix}"
        fi
      else
        # --- Subscription mode: two rows (~5h, ~7d) ---

        # --- CX ~5h ---
        cx5_pct=$(printf '%s' "$cx_json"   | jq -r '.five_hour.used_percentage // empty' 2>/dev/null)
        cx5_reset=$(printf '%s' "$cx_json" | jq -r '.five_hour.resets_at       // empty' 2>/dev/null)
        if [ -n "$cx5_pct" ]; then
          cx5_int=${cx5_pct%.*}
          [ -z "$cx5_int" ] && cx5_int=0
          bar=$(make_bar "$cx5_int" "$C_CODEX")
          pct=$(fmt_pct "$cx5_int")
          line5="${C_CODEX}Codex Review ~5h${C_RESET} ${bar} ${pct}"
          if [ -n "$cx5_reset" ] && [ "$cx5_reset" -gt "$now_s" ]; then
            remain=$(fmt_remain_5h $(( cx5_reset - now_s )))
            [ -n "$remain" ] && line5+="${SEP}${C_WHITE}${remain}${C_RESET}"
          fi
          reset_str=$(fmt_reset_time "$cx5_reset" "$now_s")
          [ -n "$reset_str" ] && line5+="${SEP}${C_GRAY}(${reset_str})${C_RESET}"
          [ -n "$age_suffix" ] && line5+=" ${age_suffix}"
        fi

        # --- CX ~7d ---
        cx7_pct=$(printf '%s' "$cx_json"   | jq -r '.seven_day.used_percentage // empty' 2>/dev/null)
        cx7_reset=$(printf '%s' "$cx_json" | jq -r '.seven_day.resets_at       // empty' 2>/dev/null)
        if [ -n "$cx7_pct" ]; then
          cx7_int=${cx7_pct%.*}
          [ -z "$cx7_int" ] && cx7_int=0
          bar=$(make_bar "$cx7_int" "$C_CODEX")
          pct=$(fmt_pct "$cx7_int")
          line6="${C_CODEX}Codex Review ~7d${C_RESET} ${bar} ${pct}"
          if [ -n "$cx7_reset" ] && [ "$cx7_reset" -gt "$now_s" ]; then
            remain=$(fmt_remain_7d $(( cx7_reset - now_s )))
            [ -n "$remain" ] && line6+="${SEP}${C_WHITE}${remain}${C_RESET}"
          fi
          reset_str=$(fmt_reset_time "$cx7_reset" "$now_s")
          [ -n "$reset_str" ] && line6+="${SEP}${C_GRAY}(${reset_str})${C_RESET}"
          [ -n "$age_suffix" ] && line6+=" ${age_suffix}"
        fi
      fi
    fi
  fi
fi

# ---- Line 0: Activity (Working / tool / Wait / Done / Idle) ----
# Reads /tmp/claude-activity.<uid>.<session_id>.json (state) and a sibling
# .pending.json (open async work) written by ~/.claude/scripts/claude-activity.sh
# via the UserPromptSubmit / PreToolUse / PostToolUse / Stop / SubagentStop
# hooks. Files are keyed by session_id so concurrent Claude Code sessions
# don't stomp on each other's state.
#
# Elapsed for working/tool is computed from `turn_started_at` (set on
# user-prompt, preserved through tool transitions). Done shows both relative
# (Xs ago) and absolute (HH:MM:SS) time — Claude Code's statusline doesn't
# refresh on a timer between events, so the absolute timestamp is the
# reliable anchor when renders are sparse.
#
# DONE_TTL: how long (s) a "Done" banner remains before decaying to "Idle".
DONE_TTL=60
session_id=$(jqv '.session_id')
[ -z "$session_id" ] && session_id="_default"
activity_file="/tmp/claude-activity.$(id -u).${session_id}.json"
pending_file="/tmp/claude-activity.$(id -u).${session_id}.pending.json"
line_activity=""

# Compute live pending total from the pending file, pruning expired wakeups
# and >1h-old bg_bash entries on the read side. This lets the statusline
# auto-flip waiting→done as wakeups naturally expire, even without a hook
# firing in the meantime. Read-only: never rewrite the pending file from
# here (avoids races with hook writes).
pending_live=0
if [ -r "$pending_file" ]; then
  pending_live=$(jq -r --argjson now "$now_s" '
    ((.subagents // 0))
    + (((.bg_bash // []) | map(select(($now - (.at // 0)) < 3600))) | length)
    + (((.wakeups // []) | map(select((.wake_at // 0) > $now))) | length)
  ' "$pending_file" 2>/dev/null)
  [ -z "$pending_live" ] && pending_live=0
fi

if [ -r "$activity_file" ]; then
  a_state=$(jq  -r '.state           // empty' "$activity_file" 2>/dev/null)
  a_tool=$(jq   -r '.tool            // empty' "$activity_file" 2>/dev/null)
  a_tstart=$(jq -r '.turn_started_at // empty' "$activity_file" 2>/dev/null)
  a_ended=$(jq  -r '.ended_at        // empty' "$activity_file" 2>/dev/null)

  # If the state file says "waiting" but live pending hits zero (e.g. all
  # wakeups have naturally expired), render as Done at the original ended_at.
  if [ "$a_state" = "waiting" ] && [ "$pending_live" -le 0 ]; then
    a_state="done"
  fi

  case "$a_state" in
    tool|working)
      elapsed=$(fmt_elapsed $(( now_s - ${a_tstart:-$now_s} )))
      line_activity="${C_YELLOW}●${C_RESET} ${C_WHITE}Working${C_RESET}"
      [ "$a_state" = "tool" ] && [ -n "$a_tool" ] \
        && line_activity+="${SEP}${C_CYAN}${a_tool}${C_RESET}"
      [ -n "$elapsed" ]   && line_activity+="${SEP}${C_WHITE}${elapsed}${C_RESET}"
      ;;
    waiting)
      elapsed=$(fmt_elapsed $(( now_s - ${a_ended:-$now_s} )))
      line_activity="${C_YELLOW}⏳${C_RESET} ${C_WHITE}Wait${C_RESET}"
      [ "$pending_live" -gt 0 ] \
        && line_activity+="${SEP}${C_GRAY}(${pending_live} pending)${C_RESET}"
      [ -n "$elapsed" ] && line_activity+="${SEP}${C_GRAY}${elapsed}${C_RESET}"
      ;;
    done)
      if [ -n "$a_ended" ] && [ "$(( now_s - a_ended ))" -lt "$DONE_TTL" ]; then
        ago=$(fmt_elapsed $(( now_s - a_ended )))
        abs=$(date -r "$a_ended" "+%H:%M:%S" 2>/dev/null)
        line_activity="${C_GREEN}✓${C_RESET} ${C_WHITE}Done${C_RESET}${SEP}${C_GRAY}${ago} ago${C_RESET}"
        [ -n "$abs" ] && line_activity+="${SEP}${C_GRAY}${abs}${C_RESET}"
      else
        line_activity="${C_GRAY}○ Idle${C_RESET}"
      fi
      ;;
    *)
      line_activity="${C_GRAY}○ Idle${C_RESET}"
      ;;
  esac
fi

# ---- Output ----
# Emit all non-empty lines in order, separated by newlines, with NO trailing
# newline after the final line (matches the original script's behavior).
lines=()
[ -n "$line_activity" ] && lines+=("$line_activity")  # ← activity banner
[ -n "$line1" ]    && lines+=("$line1")     # user | branch [wt]
[ -n "$line_dir" ] && lines+=("$line_dir")  # dir
[ -n "$line2" ]    && lines+=("$line2")     # ctx | model | effort
[ -n "$line3" ]    && lines+=("$line3")     # CC ~5h
[ -n "$line4" ]    && lines+=("$line4")     # CC ~7d
[ -n "$line5" ]    && lines+=("$line5")     # CX ~5h
[ -n "$line6" ]    && lines+=("$line6")     # CX ~7d

total=${#lines[@]}
i=0
for l in "${lines[@]}"; do
  i=$((i+1))
  if [ "$i" -lt "$total" ]; then
    printf '%s\n' "$l"
  else
    printf '%s' "$l"
  fi
done
