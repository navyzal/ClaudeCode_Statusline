#!/bin/bash
# codex-usage.sh — emit Codex usage JSON for the statusline.
#
# Mode + provider detection comes from Codex's own config, NOT from scanning
# old log rows (which can falsely match after the user switches auth):
#   ~/.codex/auth.json    → "auth_mode": "apikey"   → api_key mode
#                           anything else (chatgpt…) → subscription mode
#   ~/.codex/config.toml  → model_provider = "azure" → Azure, else OpenAI
#
# Subscription output (unchanged; reads rate_limits from logs_2.sqlite):
#   {"available":true,"mode":"subscription","provider":"OpenAI",
#    "five_hour":{"used_percentage":N,"resets_at":EPOCH},
#    "seven_day":{"used_percentage":N,"resets_at":EPOCH},"sampled_at":EPOCH}
#
# API-key output. Window = "today" (since local midnight). Usage is parsed
# from `response.completed` SSE events in logs_2.sqlite (authoritative token
# counts: input_tokens, cached_tokens, output_tokens incl. reasoning). Cost
# is ALWAYS an estimate — PRICING holds published OpenAI list rates (or
# placeholders for models we haven't confirmed), never the user's actual
# Azure contract. `cost_is_estimate` is therefore always true, and
# `cost_confidence` classifies which prices were used:
#   "list_verified"      — every model priced from a user-confirmed list rate
#   "list_mixed"         — user-confirmed list + placeholders in same window
#   "placeholder"        — only placeholder rates applied
#   "azure_contract"     — (future) every model priced from a confirmed Azure rate
# Per-model entries carry `pricing_source` so the caller can render accuracy.
# Azure billing diverges from OpenAI list prices; this helper CANNOT show the
# contract-actual number without a rate table the user provides.
#   {"available":true,"mode":"api_key","provider":"OpenAI"|"Azure",
#    "window":"today","tokens":{"input":N,"cached":N,"output":N},
#    "cost_usd":N,"cost_is_estimate":true,"cost_confidence":"...",
#    "by_model":{"<model>":{...,"pricing_source":"..."}},"sampled_at":EPOCH}
#
# Unavailable:
#   {"available":false}
#
# 60s cache at /tmp/codex-usage.<uid>.json so per-render cost stays low.

set -u

CACHE="/tmp/codex-usage.$(id -u).json"
TTL=60
AUTH_FILE="${HOME}/.codex/auth.json"
CONFIG_FILE="${HOME}/.codex/config.toml"
LOGS_DB="${HOME}/.codex/logs_2.sqlite"
STATE_DB="${HOME}/.codex/state_5.sqlite"

emit_unavailable() { printf '{"available":false}'; }

# Serve fresh cache.
if [ -f "$CACHE" ]; then
  now=$(date +%s)
  # GNU stat (-c %Y) first, then BSD/macOS (-f %m). NOTE: order matters — GNU
  # `stat -f` does NOT fail on Linux, it prints filesystem info, which would
  # poison the arithmetic below (and abort under `set -u`). Guard non-numeric.
  mtime=$(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0)
  case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
  if [ "$(( now - mtime ))" -lt "$TTL" ]; then
    cat "$CACHE"
    exit 0
  fi
fi

# Require jq + python3 (NOT the sqlite3 CLI). python3 reads logs_2.sqlite via its
# built-in sqlite3 module, so this works on machines without the sqlite3 binary.
if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  out=$(emit_unavailable)
  printf '%s' "$out" > "$CACHE" 2>/dev/null
  printf '%s' "$out"
  exit 0
fi

# ---- Read auth_mode from ~/.codex/auth.json (authoritative) ----
auth_mode=""
if [ -r "$AUTH_FILE" ]; then
  auth_mode=$(jq -r '.auth_mode // .tokens.auth_mode // empty' "$AUTH_FILE" 2>/dev/null)
fi

# ---- Read model_provider from ~/.codex/config.toml ----
# TOML parse is minimal: grep the top-level `model_provider = "..."` line.
provider="OpenAI"
if [ -r "$CONFIG_FILE" ]; then
  mp=$(awk -F'=' '
    /^[[:space:]]*\[/ { in_tbl=1; next }
    !in_tbl && $1 ~ /^[[:space:]]*model_provider[[:space:]]*$/ {
      gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", $2)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2; exit
    }
  ' "$CONFIG_FILE" 2>/dev/null)
  case "$(printf '%s' "$mp" | tr '[:upper:]' '[:lower:]')" in
    azure) provider="Azure" ;;
    ""|openai) provider="OpenAI" ;;
    *) provider=$(printf '%s' "$mp" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}') ;;
  esac
fi

now_epoch=$(date +%s)

# =========================================================================
# API-key mode: auth.json says apikey → skip rate_limits, compute from tokens
# =========================================================================
if [ "$auth_mode" = "apikey" ]; then
  # Local-midnight epoch (aligns with how billing consoles show daily spend).
  window_start=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)
  [ -z "$window_start" ] && window_start=$(date -d "$(date +%Y-%m-%d) 00:00:00" +%s 2>/dev/null)
  [ -z "$window_start" ] && window_start=$(( now_epoch - 86400 ))

  out=""
  if [ -r "$LOGS_DB" ] && command -v python3 >/dev/null 2>&1; then
    out=$(WINDOW_START="$window_start" \
          NOW_EPOCH="$now_epoch" \
          PROVIDER="$provider" \
          LOGS_DB="$LOGS_DB" \
          python3 - <<'PY'
import json, os, re, sqlite3, sys

# Per-1M-token pricing: (prefix, (input, cached_input, output), source).
# Longest-prefix match wins. Sources:
#   list_openai   — user-confirmed OpenAI published list price
#   placeholder   — unverified guess; flag to user, do not trust figure
#   azure_contract — user-supplied Azure contract rate (none yet)
# When the user is on Azure, even list_openai is an estimate because Azure
# bills under a separate contract — the output always carries
# cost_is_estimate:true.
PRICING = [
    ("gpt-5.3-codex", (1.75,  0.175, 14.00), "list_openai"),
    ("gpt-5.3",       (1.25,  0.125, 10.00), "placeholder"),
    ("gpt-5.5",       (1.25,  0.125, 10.00), "placeholder"),
    ("gpt-5.4",       (1.25,  0.125, 10.00), "placeholder"),
    ("gpt-5",         (1.25,  0.125, 10.00), "placeholder"),
    ("gpt-4o",        (2.50,  1.25,  10.00), "placeholder"),
]

def price_for(model: str):
    if not model:
        return None
    best = None
    for prefix, rates, source in PRICING:
        if model.startswith(prefix) and (best is None or len(prefix) > len(best[0])):
            best = (prefix, rates, source)
    return best  # (prefix, rates, source) or None

window_start = int(os.environ["WINDOW_START"])
now_epoch    = int(os.environ["NOW_EPOCH"])
provider     = os.environ["PROVIDER"]
db_path      = os.environ["LOGS_DB"]

conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
cur = conn.cursor()
cur.execute(
    "SELECT feedback_log_body FROM logs "
    "WHERE ts >= ? "
    "  AND instr(feedback_log_body, '\"type\":\"response.completed\"') > 0",
    (window_start,),
)

# Extract the JSON object starting at 'SSE event: ' (or at the first '{' after
# the type marker). Fall back to a regex for the usage block if full-parse
# fails — some log lines truncate the trailing `}`s.
json_obj_re = re.compile(r'SSE event:\s*(\{)')
usage_re    = re.compile(r'"usage"\s*:\s*(\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\})')
model_re    = re.compile(r'"model"\s*:\s*"([^"]+)"')

def extract_usage(body: str):
    m = json_obj_re.search(body)
    if m:
        start = m.end() - 1
        depth = 0; in_str = False; esc = False
        for i in range(start, len(body)):
            c = body[i]
            if esc: esc = False; continue
            if c == '\\': esc = True; continue
            if c == '"': in_str = not in_str; continue
            if in_str: continue
            if c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    try:
                        obj = json.loads(body[start:i+1])
                        resp = obj.get("response") or obj
                        return resp.get("usage"), resp.get("model")
                    except Exception:
                        break
    mu = usage_re.search(body)
    if not mu:
        return None, None
    try:
        u = json.loads(mu.group(1))
    except Exception:
        return None, None
    mm = model_re.search(body)
    return u, (mm.group(1) if mm else None)

tok_in = 0; tok_cached = 0; tok_out = 0
cost = 0.0
by_model = {}
unpriced_models = set()
event_count = 0

for (body,) in cur:
    usage, model = extract_usage(body)
    if not usage:
        continue
    event_count += 1
    i_raw = int(usage.get("input_tokens") or 0)
    c_raw = int((usage.get("input_tokens_details") or {}).get("cached_tokens") or 0)
    o_raw = int(usage.get("output_tokens") or 0)
    # input_tokens already includes cached_tokens in the Responses API.
    i_billed = max(i_raw - c_raw, 0)

    tok_in     += i_billed
    tok_cached += c_raw
    tok_out    += o_raw

    priced = price_for(model or "")
    if priced is None:
        unpriced_models.add(model or "unknown")
        continue
    _prefix, (pi, pc, po), source = priced
    inc = (i_billed * pi + c_raw * pc + o_raw * po) / 1_000_000.0
    cost += inc

    bm = by_model.setdefault(
        model or "unknown",
        {"input": 0, "cached": 0, "output": 0, "cost_usd": 0.0,
         "pricing_source": source},
    )
    bm["input"]    += i_billed
    bm["cached"]   += c_raw
    bm["output"]   += o_raw
    bm["cost_usd"] += inc

for bm in by_model.values():
    bm["cost_usd"] = round(bm["cost_usd"], 4)

# Confidence: weight by cost share so a trailing $0.01 placeholder in an
# otherwise-verified window doesn't downgrade the whole estimate. If every
# dollar came from list_openai entries → list_verified. Any nonzero share
# from placeholder → list_mixed or placeholder.
sources_by_cost = {}
for bm in by_model.values():
    sources_by_cost[bm["pricing_source"]] = sources_by_cost.get(bm["pricing_source"], 0.0) + bm["cost_usd"]
total_priced = sum(sources_by_cost.values()) or 0.0
placeholder_share = (sources_by_cost.get("placeholder", 0.0) / total_priced) if total_priced else 0.0
list_share        = (sources_by_cost.get("list_openai", 0.0) / total_priced) if total_priced else 0.0
azure_share       = (sources_by_cost.get("azure_contract", 0.0) / total_priced) if total_priced else 0.0
if azure_share >= 0.999:
    confidence = "azure_contract"
elif placeholder_share < 0.01 and list_share > 0:
    confidence = "list_verified"
elif list_share > 0 and placeholder_share >= 0.01:
    confidence = "list_mixed"
elif placeholder_share >= 0.999:
    confidence = "placeholder"
else:
    confidence = "unknown"

out = {
    "available": True,
    "mode": "api_key",
    "provider": provider,
    "window": "today",
    "tokens": {"input": tok_in, "cached": tok_cached, "output": tok_out},
    "cost_usd": round(cost, 4),
    "cost_is_estimate": True,
    "cost_confidence": confidence,
    "pricing_note": (
        "Azure contract rates unknown; priced with published list rates where available."
        if provider == "Azure"
        else "Priced with published list rates; actual billing may differ."
    ),
    "by_model": by_model,
    "event_count": event_count,
    "sampled_at": now_epoch,
}
if unpriced_models:
    out["unpriced_models"] = sorted(unpriced_models)
sys.stdout.write(json.dumps(out, separators=(",", ":")))
PY
)
  fi

  if [ -z "$out" ]; then
    out=$(jq -cn --arg provider "$provider" --argjson ts "$now_epoch" \
      '{available:true, mode:"api_key", provider:$provider, window:"today",
        tokens:{input:0,cached:0,output:0}, cost_usd:0,
        cost_is_estimate:true, cost_confidence:"unknown",
        sampled_at:$ts, note:"no response.completed events in window"}')
  fi

  printf '%s' "$out" > "$CACHE" 2>/dev/null
  printf '%s' "$out"
  exit 0
fi

# =========================================================================
# Subscription mode.
# Preferred: ask a live `codex app-server` (via the codex-companion broker)
# for fresh rate limits via `account/rateLimits/read` — this is what the TUI's
# /usage screen does. The legacy log-scan source only updates when a new turn
# starts, so it goes hours stale during long Claude Code sessions.
# Fallback: scan logs_2.sqlite for the most recent codex.rate_limits event.
# =========================================================================
if command -v python3 >/dev/null 2>&1; then
  rpc_out=$(PROVIDER="$provider" NOW_EPOCH="$now_epoch" python3 - <<'PY'
import glob, json, os, socket, sys, time

now      = int(os.environ["NOW_EPOCH"])
provider = os.environ["PROVIDER"]
tmpdir   = (os.environ.get("TMPDIR") or "/tmp").rstrip("/")

# Codex-companion broker.sock files. The cwd of the user-facing Codex session
# isn't knowable here, so we just probe the most-recently-touched ones — newer
# brokers run newer codex versions that support account/rateLimits/read.
candidates = sorted(
    glob.glob(f"{tmpdir}/cxc-*/broker.sock") +
    glob.glob("/tmp/cxc-*/broker.sock"),
    key=lambda p: os.path.getmtime(os.path.dirname(p)),
    reverse=True,
)

def is_alive(pid_path):
    try:
        pid = int(open(pid_path).read().strip())
        os.kill(pid, 0)
        return True
    except Exception:
        return False

# Returns (result, error_code).
#   result: dict on success, None otherwise.
#   error_code: "busy" / "unsupported" / "timeout" / "error" — used to skip
#               legacy-version brokers on subsequent attempts in the same run.
def try_one(sock_path, connect_timeout=0.3, read_timeout=1.5):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(connect_timeout)
    try:
        s.connect(sock_path)
        s.settimeout(read_timeout)
        f = s.makefile("rwb", buffering=0)
        f.write(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n')
        f.readline()
        f.write(b'{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}\n')
        line = f.readline()
        if not line:
            return None, "error"
        obj = json.loads(line)
        if obj.get("error"):
            code = obj["error"].get("code")
            if code == -32001:   return None, "busy"
            if code == -32601:   return None, "unsupported"
            return None, "error"
        return obj.get("result"), None
    except socket.timeout:
        return None, "timeout"
    except Exception:
        return None, "error"
    finally:
        try: s.close()
        except Exception: pass

result = None
deadline = time.time() + 4.0
attempts = 0
unsupported_dirs = set()  # within-run skip list for legacy-version brokers
for sock_path in candidates:
    if time.time() > deadline or attempts >= 8:
        break
    broker_dir = os.path.dirname(sock_path)
    if broker_dir in unsupported_dirs:
        continue
    pid_path = os.path.join(broker_dir, "broker.pid")
    if not (os.path.exists(pid_path) and is_alive(pid_path)):
        continue
    attempts += 1
    res, err = try_one(sock_path)
    if res is not None:
        result = res
        break
    if err == "unsupported":
        unsupported_dirs.add(broker_dir)

if not result:
    sys.exit(1)

def window(w):
    if not w:
        return None
    return {
        "used_percentage": int(w.get("usedPercent") or 0),
        "resets_at":       int(w.get("resetsAt") or 0),
    }

main_rl = result.get("rateLimits") or {}
spark_rl = None
for v in (result.get("rateLimitsByLimitId") or {}).values():
    if (v or {}).get("limitName") == "GPT-5.3-Codex-Spark":
        spark_rl = v
        break

out = {
    "available":       True,
    "mode":            "subscription",
    "provider":        provider,
    "sampled_at":      now,
    "source":          "rpc",
    "five_hour":       window(main_rl.get("primary")),
    "seven_day":       window(main_rl.get("secondary")),
    "spark_five_hour": window(spark_rl.get("primary"))   if spark_rl else None,
    "spark_seven_day": window(spark_rl.get("secondary")) if spark_rl else None,
}
sys.stdout.write(json.dumps(out, separators=(",", ":")))
PY
)
  if [ -n "$rpc_out" ]; then
    printf '%s' "$rpc_out" > "$CACHE" 2>/dev/null
    printf '%s' "$rpc_out"
    exit 0
  fi
fi

# Fallback: scan logs_2.sqlite for the most recent codex.rate_limits event.
# Read via python3's built-in sqlite3 module (no sqlite3 CLI dependency) and
# emit the same JSON shape the RPC path produces. Field mapping from the log
# row: used_percent→used_percentage, reset_at→resets_at, buckets keyed by
# window_minutes (300→5h, 10080→7d), with positional fallback.
if [ -r "$LOGS_DB" ]; then
  sub_out=$(PROVIDER="$provider" NOW_EPOCH="$now_epoch" LOGS_DB="$LOGS_DB" python3 - <<'PY'
import json, os, sqlite3, sys

provider = os.environ["PROVIDER"]
db_path  = os.environ["LOGS_DB"]
MARKER   = '{"type":"codex.rate_limits'

try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    row = conn.execute(
        "SELECT ts, feedback_log_body FROM logs "
        "WHERE instr(feedback_log_body, ?) > 0 "
        "ORDER BY ts DESC LIMIT 1",
        (MARKER,),
    ).fetchone()
except Exception:
    sys.exit(1)

if not row:
    sys.exit(1)
ts, body = row
idx = body.find(MARKER)
if idx < 0:
    sys.exit(1)

# Brace-match the JSON object starting at the marker (log lines can carry a
# trailing tail after the object).
depth = 0; in_str = False; esc = False; obj = None
for i in range(idx, len(body)):
    c = body[i]
    if esc:        esc = False; continue
    if c == '\\':  esc = True;  continue
    if c == '"':   in_str = not in_str; continue
    if in_str:     continue
    if c == '{':   depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            try:
                obj = json.loads(body[idx:i+1])
            except Exception:
                obj = None
            break
if not obj:
    sys.exit(1)

def pick(buckets, minutes, pos):
    for b in buckets:
        if b and b.get("window_minutes") == minutes:
            return b
    return buckets[pos] if len(buckets) > pos else None

def win(b):
    if not b:
        return None
    return {"used_percentage": int(b.get("used_percent") or 0),
            "resets_at":       int(b.get("reset_at") or 0)}

rl   = obj.get("rate_limits") or {}
main = [b for b in (rl.get("primary"), rl.get("secondary")) if b]
sp   = (obj.get("additional_rate_limits") or {}).get("GPT-5.3-Codex-Spark") or {}
spb  = [b for b in (sp.get("primary"), sp.get("secondary")) if b]

if not main:
    sys.exit(1)

out = {
    "available":       True,
    "mode":            "subscription",
    "provider":        provider,
    "sampled_at":      int(ts),
    "source":          "log",
    "five_hour":       win(pick(main, 300, 0)),
    "seven_day":       win(pick(main, 10080, 1)),
    "spark_five_hour": win(pick(spb, 300, 0)),
    "spark_seven_day": win(pick(spb, 10080, 1)),
}
sys.stdout.write(json.dumps(out, separators=(",", ":")))
PY
)
  if [ -n "$sub_out" ]; then
    printf '%s' "$sub_out" > "$CACHE" 2>/dev/null
    printf '%s' "$sub_out"
    exit 0
  fi
fi

out=$(emit_unavailable)
printf '%s' "$out" > "$CACHE" 2>/dev/null
printf '%s' "$out"
