#!/bin/bash
# context-threshold-check.sh — Stop hook: auto-handoff at context threshold.
#
# Pairs with statusline-command.sh, which caches the live context window %
# (from Claude Code's stdin JSON `.context_window.used_percentage`) into
# /tmp/claude-ctx-pct.<uid>.<session_id>. This Stop hook reads that cache
# and, if the value is at or above the configured threshold (default 80%),
# emits a hookSpecificOutput.additionalContext payload so the next model
# turn sees a system reminder telling it to write a HANDOFF and stop the
# autonomous round loop.
#
# Why this design:
# - Stop hook stdin does NOT carry context_window — only statusline does.
#   The cache file is the bridge.
# - Plain stdout from a Stop hook is ignored by Claude Code; structured
#   hookSpecificOutput JSON with additionalContext is the supported channel
#   to inject text into the next turn.
# - Threshold default 80 matches Anthropic's prompt-cache TTL guidance and
#   the autonomous-rounds memory rule. Override via env CLAUDE_CONTEXT_HANDOFF_THRESHOLD.
#
# IMPORTANT: Always exit 0 and stay fast (<50ms). Failures must not block Stop.

set +e

THRESHOLD_PCT="${CLAUDE_CONTEXT_HANDOFF_THRESHOLD:-80}"

STDIN_JSON=$(cat 2>/dev/null)
SESSION_ID=""
if [ -n "$STDIN_JSON" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null)
fi

[ -z "$SESSION_ID" ] && exit 0

UID_=$(id -u 2>/dev/null || printf 'unknown')
CACHE_FILE="/tmp/claude-ctx-pct.${UID_}.${SESSION_ID}"

[ ! -r "$CACHE_FILE" ] && exit 0

ctx_pct=$(tr -d ' \n\r' < "$CACHE_FILE" 2>/dev/null)
[ -z "$ctx_pct" ] && exit 0

# Drop decimals: "82.4" -> "82"
ctx_int=${ctx_pct%.*}
[ -z "$ctx_int" ] && ctx_int=0

# Bash arithmetic on non-numeric is fatal under set -e; guard explicitly.
case "$ctx_int" in
  ''|*[!0-9]*) exit 0 ;;
esac

if [ "$ctx_int" -lt "$THRESHOLD_PCT" ]; then
  exit 0
fi

# Threshold reached — inject reminder for the next turn.
# additionalContext is appended to the next user/system message the model sees,
# so phrase it as instructions the model should act on.
msg="⚠️ Context window ${ctx_int}% (threshold ${THRESHOLD_PCT}%) — autonomous-loop stop point reached. Per the autonomous-rounds memory rule (\`feedback_autonomous_rounds.md\`), do NOT start a new round. Instead: (1) finish any in-flight commit/codex review, (2) write HANDOFF-r{N+1}.md capturing current round state + next-round candidates + known issues, (3) commit the handoff, (4) report a 1-paragraph stop summary to the user, (5) STOP. The next session can resume from the handoff."

# Emit JSON with hookSpecificOutput.additionalContext.
# Use jq if present for safe escaping; fall back to a hand-built JSON otherwise.
if command -v jq >/dev/null 2>&1; then
  jq -nc --arg msg "$msg" '{
    hookSpecificOutput: {
      hookEventName: "Stop",
      additionalContext: $msg
    }
  }'
else
  # Minimal escape: backslashes and double quotes only. msg is a fixed-form
  # string assembled above — no untrusted input, so this is safe enough.
  esc=${msg//\\/\\\\}
  esc=${esc//\"/\\\"}
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"%s"}}\n' "$esc"
fi

exit 0
