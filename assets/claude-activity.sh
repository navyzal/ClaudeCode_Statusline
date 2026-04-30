#!/bin/bash
# claude-activity.sh — Claude Code hook dispatcher.
# Maintains /tmp/claude-activity.<uid>.<session_id>.json so the statusline can
# render a top-line activity banner (Working / tool-in-use / Wait / Done / Idle)
# isolated per Claude Code session. A sibling pending-file tracks open async
# work (Task subagents, background Bash shells, scheduled wakeups) so the
# statusline can show ⏳ Wait when a Stop fires while async work is still in
# flight.
#
# Usage (from ~/.claude/settings.json hook entries):
#   bash ~/.claude/scripts/claude-activity.sh user-prompt    # UserPromptSubmit
#   bash ~/.claude/scripts/claude-activity.sh tool-pre       # PreToolUse
#   bash ~/.claude/scripts/claude-activity.sh tool-post      # PostToolUse
#   bash ~/.claude/scripts/claude-activity.sh stop           # Stop
#   bash ~/.claude/scripts/claude-activity.sh subagent-stop  # SubagentStop
#
# State file schema:
#   {
#     "state":            "working" | "tool" | "waiting" | "done",
#     "tool":             "Bash" | null,
#     "turn_started_at":  <epoch> | null,   # set on user-prompt, preserved
#                                           # through tool-pre/tool-post
#     "ended_at":         <epoch> | null,   # set on stop / waiting→done flip
#     "pending":          <int>             # only on "waiting"; total pending
#   }
#
# Pending file schema (sibling, /tmp/claude-activity.<uid>.<sid>.pending.json):
#   {
#     "subagents": <int>,
#     "bg_bash":   [{"id":"<shell_id>", "at":<epoch>}, ...],
#     "wakeups":   [{"wake_at":<epoch>}, ...]
#   }
#
# IMPORTANT: Always exit 0 and stay fast (<50ms).

set +e

EVENT="${1:-}"
NOW=$(date +%s)

STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null)
fi

SESSION_ID=""
if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null)
fi
[ -z "$SESSION_ID" ] && SESSION_ID="_default"

UID_=$(id -u)
STATE_FILE="/tmp/claude-activity.${UID_}.${SESSION_ID}.json"
PENDING_FILE="/tmp/claude-activity.${UID_}.${SESSION_ID}.pending.json"

write_atomic() {
  # write_atomic <path> <content>
  local path="$1" content="$2"
  local tmp="${path}.tmp.$$"
  printf '%s' "$content" > "$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null
}

write_state() { write_atomic "$STATE_FILE" "$1"; }
write_pending() { write_atomic "$PENDING_FILE" "$1"; }

read_pending() {
  # Echo current pending JSON, or defaults if file missing/corrupt.
  if [ -r "$PENDING_FILE" ] && command -v jq >/dev/null 2>&1; then
    local out
    out=$(jq -c '.' "$PENDING_FILE" 2>/dev/null)
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return
    fi
  fi
  printf '{"subagents":0,"bg_bash":[],"wakeups":[]}'
}

prune_pending() {
  # Drop wakeups whose wake_at <= NOW, and bg_bash entries older than 1h.
  # Outputs the pruned JSON. Does not write.
  local pj="$1"
  printf '%s' "$pj" | jq -c --argjson now "$NOW" '
    .subagents = (.subagents // 0)
    | .bg_bash  = ((.bg_bash // []) | map(select(($now - (.at // 0)) < 3600)))
    | .wakeups  = ((.wakeups // []) | map(select((.wake_at // 0) > $now)))
  ' 2>/dev/null
}

pending_total() {
  # Echo total pending count from a pruned JSON.
  local pj="$1"
  printf '%s' "$pj" | jq -r '
    (.subagents // 0) + ((.bg_bash // []) | length) + ((.wakeups // []) | length)
  ' 2>/dev/null
}

# Read prev turn_started_at so tool-pre / tool-post preserve continuity.
prev_turn_started=""
if [ -r "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
  prev_turn_started=$(jq -r '.turn_started_at // empty' "$STATE_FILE" 2>/dev/null)
fi

case "$EVENT" in
  user-prompt)
    json=$(jq -n --argjson now "$NOW" '{
      state: "working",
      tool: null,
      turn_started_at: $now,
      ended_at: null
    }' 2>/dev/null)
    [ -n "$json" ] && write_state "$json"
    # Reset subagents on a new turn (defensive). Preserve bg_bash and wakeups,
    # which legitimately span turns.
    pending=$(read_pending)
    new_pending=$(printf '%s' "$pending" | jq -c '.subagents = 0' 2>/dev/null)
    [ -n "$new_pending" ] && write_pending "$new_pending"
    ;;

  tool-pre)
    tool_name=""
    if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
      tool_name=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_name // empty' 2>/dev/null)
    fi
    [ -z "$tool_name" ] && tool_name="tool"

    tstart="${prev_turn_started:-$NOW}"
    json=$(jq -n \
      --arg tool "$tool_name" \
      --argjson tstart "$tstart" \
      '{
        state: "tool",
        tool: $tool,
        turn_started_at: $tstart,
        ended_at: null
      }' 2>/dev/null)
    [ -n "$json" ] && write_state "$json"

    # Track open Task subagents.
    if [ "$tool_name" = "Task" ]; then
      pending=$(read_pending)
      new_pending=$(printf '%s' "$pending" | jq -c '.subagents = ((.subagents // 0) + 1)' 2>/dev/null)
      [ -n "$new_pending" ] && write_pending "$new_pending"
    fi

    # KillBash: drop the matching bg_bash entry pre-emptively (the kill is
    # about to happen; if it fails, the 1h prune will sweep eventually).
    if [ "$tool_name" = "KillBash" ]; then
      kill_id=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.shell_id // empty' 2>/dev/null)
      if [ -n "$kill_id" ]; then
        pending=$(read_pending)
        new_pending=$(printf '%s' "$pending" | jq -c --arg id "$kill_id" '
          .bg_bash = ((.bg_bash // []) | map(select(.id != $id)))
        ' 2>/dev/null)
        [ -n "$new_pending" ] && write_pending "$new_pending"
      fi
    fi
    ;;

  tool-post)
    tool_name=""
    if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
      tool_name=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_name // empty' 2>/dev/null)
    fi

    tstart="${prev_turn_started:-$NOW}"
    json=$(jq -n \
      --argjson tstart "$tstart" \
      '{
        state: "working",
        tool: null,
        turn_started_at: $tstart,
        ended_at: null
      }' 2>/dev/null)
    [ -n "$json" ] && write_state "$json"

    # Background Bash: capture shell_id when run_in_background=true.
    if [ "$tool_name" = "Bash" ]; then
      bg=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)
      if [ "$bg" = "true" ]; then
        sid=$(printf '%s' "$STDIN_JSON" | jq -r '
          .tool_response.shell_id //
          .tool_response.bash_id //
          .tool_response.id //
          .tool_use_id //
          empty
        ' 2>/dev/null)
        [ -z "$sid" ] && sid="bash_${NOW}_$$"
        pending=$(read_pending)
        new_pending=$(printf '%s' "$pending" | jq -c \
          --arg id "$sid" --argjson now "$NOW" '
          .bg_bash = ((.bg_bash // []) + [{id: $id, at: $now}])
        ' 2>/dev/null)
        [ -n "$new_pending" ] && write_pending "$new_pending"
      fi
    fi

    # BashOutput: drop entry if the shell has finished. Heuristic: response
    # indicates a non-running status, or response includes an exit code.
    if [ "$tool_name" = "BashOutput" ]; then
      out_id=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.bash_id // .tool_input.shell_id // empty' 2>/dev/null)
      finished=$(printf '%s' "$STDIN_JSON" | jq -r '
        if (.tool_response.status // "" | ascii_downcase) as $s
           | ($s == "completed" or $s == "exited" or $s == "killed" or $s == "failed")
        then "true"
        elif (.tool_response.exit_code // null) != null then "true"
        else "false" end
      ' 2>/dev/null)
      if [ -n "$out_id" ] && [ "$finished" = "true" ]; then
        pending=$(read_pending)
        new_pending=$(printf '%s' "$pending" | jq -c --arg id "$out_id" '
          .bg_bash = ((.bg_bash // []) | map(select(.id != $id)))
        ' 2>/dev/null)
        [ -n "$new_pending" ] && write_pending "$new_pending"
      fi
    fi

    # ScheduleWakeup: capture pending wake.
    if [ "$tool_name" = "ScheduleWakeup" ]; then
      delay=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.delaySeconds // empty' 2>/dev/null)
      if [ -n "$delay" ]; then
        pending=$(read_pending)
        new_pending=$(printf '%s' "$pending" | jq -c \
          --argjson wake "$(( NOW + delay ))" '
          .wakeups = ((.wakeups // []) + [{wake_at: $wake}])
        ' 2>/dev/null)
        [ -n "$new_pending" ] && write_pending "$new_pending"
      fi
    fi
    ;;

  stop)
    pending=$(read_pending)
    pruned=$(prune_pending "$pending")
    [ -n "$pruned" ] && write_pending "$pruned"
    total=$(pending_total "$pruned")
    [ -z "$total" ] && total=0

    if [ "$total" -gt 0 ]; then
      json=$(jq -n --argjson now "$NOW" --argjson n "$total" '{
        state: "waiting",
        tool: null,
        turn_started_at: null,
        ended_at: $now,
        pending: $n
      }' 2>/dev/null)
    else
      json=$(jq -n --argjson now "$NOW" '{
        state: "done",
        tool: null,
        turn_started_at: null,
        ended_at: $now
      }' 2>/dev/null)
    fi
    [ -n "$json" ] && write_state "$json"
    ;;

  subagent-stop)
    pending=$(read_pending)
    new_pending=$(printf '%s' "$pending" | jq -c '
      .subagents = ([(.subagents // 0) - 1, 0] | max)
    ' 2>/dev/null)
    [ -n "$new_pending" ] && write_pending "$new_pending"

    # If the main turn already Stopped (state == "waiting") and we just hit
    # zero pending, transition state to "done" with a fresh ended_at — that
    # gives the user a "Done" timestamp anchored to when async work actually
    # finished.
    if [ -r "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
      cur_state=$(jq -r '.state // empty' "$STATE_FILE" 2>/dev/null)
      if [ "$cur_state" = "waiting" ]; then
        pruned=$(prune_pending "$new_pending")
        [ -n "$pruned" ] && write_pending "$pruned"
        total=$(pending_total "$pruned")
        [ -z "$total" ] && total=0
        if [ "$total" -le 0 ]; then
          json=$(jq -n --argjson now "$NOW" '{
            state: "done",
            tool: null,
            turn_started_at: null,
            ended_at: $now
          }' 2>/dev/null)
          [ -n "$json" ] && write_state "$json"
        else
          # Update pending count on the state file.
          json=$(jq --argjson n "$total" '.pending = $n' "$STATE_FILE" 2>/dev/null)
          [ -n "$json" ] && write_state "$json"
        fi
      fi
    fi
    ;;

  *)
    # Unknown event — ignore silently.
    ;;
esac

exit 0
