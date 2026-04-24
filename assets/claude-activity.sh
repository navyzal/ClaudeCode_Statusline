#!/bin/bash
# claude-activity.sh — Claude Code hook dispatcher.
# Maintains /tmp/claude-activity.<uid>.<session_id>.json so the statusline can
# render a top-line activity banner (Working / tool-in-use / Done / Idle) that
# is isolated per Claude Code session.
#
# Usage (from ~/.claude/settings.json hook entries):
#   bash ~/.claude/scripts/claude-activity.sh user-prompt
#   bash ~/.claude/scripts/claude-activity.sh tool-pre
#   bash ~/.claude/scripts/claude-activity.sh tool-post
#   bash ~/.claude/scripts/claude-activity.sh stop
#
# Hook stdin is a JSON blob from Claude Code. We always need `.session_id` to
# scope the state file; tool-pre additionally reads `.tool_name`. Other events
# ignore stdin beyond the session id.
#
# State schema (single canonical elapsed anchor: turn_started_at):
#   {
#     "state":            "working" | "tool" | "done",
#     "tool":             "Bash" | null,
#     "turn_started_at":  <epoch> | null,   # set on user-prompt, preserved
#                                           # through tool-pre/tool-post
#     "ended_at":         <epoch> | null    # set on stop
#   }
#
# Elapsed = now - turn_started_at, identical whether the state is "working"
# or "tool" — so the counter keeps ticking without jumps when a tool starts
# or finishes.
#
# IMPORTANT: Always exit 0 and stay fast (<50ms) — a blocking hook here would
# stall every turn.

set +e

EVENT="${1:-}"
NOW=$(date +%s)

# Slurp stdin once; hooks give us one JSON object.
STDIN_JSON=""
if [ ! -t 0 ]; then
  STDIN_JSON=$(cat 2>/dev/null)
fi

SESSION_ID=""
if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null)
fi
# Fallback if a hook invocation lacks session_id (shouldn't happen in normal
# Claude Code runs, but defensive): use a shared file so the banner at least
# still works in single-session setups.
[ -z "$SESSION_ID" ] && SESSION_ID="_default"

STATE_FILE="/tmp/claude-activity.$(id -u).${SESSION_ID}.json"
TMP_FILE="${STATE_FILE}.tmp.$$"

# Read prev turn_started_at so tool-pre / tool-post preserve continuity.
prev_turn_started=""
if [ -r "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
  prev_turn_started=$(jq -r '.turn_started_at // empty' "$STATE_FILE" 2>/dev/null)
fi

write_state() {
  printf '%s' "$1" > "$TMP_FILE" 2>/dev/null && mv -f "$TMP_FILE" "$STATE_FILE" 2>/dev/null
}

case "$EVENT" in
  user-prompt)
    # New turn begins; reset anchor.
    json=$(jq -n --argjson now "$NOW" '{
      state: "working",
      tool: null,
      turn_started_at: $now,
      ended_at: null
    }' 2>/dev/null)
    [ -n "$json" ] && write_state "$json"
    ;;

  tool-pre)
    # Tool starting inside the current turn. Preserve turn_started_at so
    # elapsed time does not restart.
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
    ;;

  tool-post)
    # Tool finished; still within the turn.
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
    ;;

  stop)
    # Turn ended.
    json=$(jq -n --argjson now "$NOW" '{
      state: "done",
      tool: null,
      turn_started_at: null,
      ended_at: $now
    }' 2>/dev/null)
    [ -n "$json" ] && write_state "$json"

    # Kill any previous refresh loop for this session (prevents stacking).
    loop_pid_file="/tmp/claude-activity-loop.$(id -u).${SESSION_ID}.pid"
    if [ -r "$loop_pid_file" ]; then
      old_pid=$(cat "$loop_pid_file" 2>/dev/null)
      [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null
      rm -f "$loop_pid_file"
    fi

    # Launch a background loop that touches the state file so the statusline
    # keeps re-rendering the "elapsed since done" counter.
    #   - First 60s: touch every 2s (second-level resolution).
    #   - 60s..1h:   touch every 60s (minute-level resolution).
    #   - After 1h:  terminate.
    # Loop also exits early if state changes away from "done".
    DONE_SEC_PHASE=60
    DONE_MAX_TTL=3600
    (
      end_ts=$NOW
      sec_deadline=$(( end_ts + DONE_SEC_PHASE ))
      final_deadline=$(( end_ts + DONE_MAX_TTL ))
      while :; do
        now_ts=$(date +%s)
        [ "$now_ts" -ge "$final_deadline" ] && break
        if [ "$now_ts" -lt "$sec_deadline" ]; then
          sleep 2
        else
          sleep 60
        fi
        # Re-read state; stop loop if state changed away from done
        cur_state=$(jq -r '.state // empty' "$STATE_FILE" 2>/dev/null)
        [ "$cur_state" != "done" ] && break
        # Touch file mtime so Claude Code's statusline re-renders
        touch "$STATE_FILE" 2>/dev/null
      done
      rm -f "$loop_pid_file" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    # Use $! (bg subshell PID) — NOT $$ from inside the subshell, which would
    # be the parent shell's PID. Write the PID synchronously from the parent
    # so the next stop-hook invocation can kill us reliably.
    loop_pid=$!
    printf '%d' "$loop_pid" > "$loop_pid_file" 2>/dev/null
    disown "$loop_pid" 2>/dev/null
    ;;

  *)
    # Unknown event — ignore silently.
    ;;
esac

exit 0
