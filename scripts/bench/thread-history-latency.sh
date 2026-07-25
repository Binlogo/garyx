#!/usr/bin/env bash
# Benchmark /api/threads/history against the local gateway.
#
# The user-query window path (`user_query_limit`) is the one that scans the
# transcript; run this before and after a change to that path.
#
#   scripts/bench/thread-history-latency.sh [thread_count] [samples]
#
# Cache state matters and this script cannot control it. The gateway keeps a
# per-thread parsed tail (bounded by a store-wide budget), so a long-running
# gateway serves most of these WARM. To measure the cold path, restart the
# gateway first and run with samples=1:
#
#   garyx gateway restart && scripts/bench/thread-history-latency.sh 3 1
#
# Every row reports the median of `samples` runs. Responses are validated: a
# 200 can still carry a history error, and a silently empty page would
# otherwise read as a fast result.
set -euo pipefail

COUNT="${1:-6}"
SAMPLES="${2:-3}"
PORT="${GARYX_GATEWAY_PORT:-31337}"
CONFIG="${GARYX_CONFIG:-$HOME/.garyx/garyx.json}"
TRANSCRIPTS="${GARYX_TRANSCRIPTS:-$HOME/.garyx/data/transcripts}"

TOKEN=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['gateway']['auth_token'])" "$CONFIG")
BASE="http://127.0.0.1:${PORT}/api/threads/history"

# Median wall time over SAMPLES runs, plus the returned message count and the
# API's own total. Fails loudly rather than reporting a fast error response.
probe() { # url -> "median_seconds returned total"
  python3 - "$1" "$SAMPLES" "$TOKEN" <<'PY'
import json, subprocess, sys, statistics
url, samples, token = sys.argv[1], int(sys.argv[2]), sys.argv[3]
times, returned, total = [], None, None
for _ in range(samples):
    out = subprocess.run(
        ["curl", "-s", "-w", "\n%{time_total}", "-H", f"Authorization: Bearer {token}", url],
        capture_output=True, text=True, check=True,
    ).stdout
    body, _, elapsed = out.rpartition("\n")
    times.append(float(elapsed))
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        sys.exit(f"non-JSON response from {url}: {body[:200]}")
    if isinstance(payload, dict) and payload.get("kind") == "garyx_api_error":
        sys.exit(f"API error from {url}: {payload.get('message')}")
    if payload.get("ok") is False:
        sys.exit(f"not ok from {url}: {body[:200]}")
    messages = payload.get("messages")
    if not isinstance(messages, list):
        sys.exit(f"no messages array from {url}: {body[:200]}")
    returned = len(messages)
    info = payload.get("page_info") or {}
    total = info.get("total_messages_in_thread")
print(f"{statistics.median(times):.4f} {returned} {total if total is not None else '-'}")
PY
}

printf '%9s  %12s  %10s  %10s  %10s  %14s\n' SIZE 'BYTES' 'window' 'delta' 'no-uql' 'returned/total'
for f in $(ls -S "${TRANSCRIPTS}"/*.jsonl 2>/dev/null | head -n "$COUNT"); do
  size=$(du -h "$f" | cut -f1)
  bytes=$(wc -c < "$f" | tr -d ' ')
  b=$(basename "$f" .jsonl); b=${b#k_}
  tid=$(printf '%s' "$b" | xxd -r -p 2>/dev/null || true)
  case "$tid" in thread::*) ;; *) continue ;; esac
  enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$tid")

  # Ask the API for its own record count first; never assert against `wc -l`,
  # which counts Session headers and misses a final unterminated line. When the
  # response carries no page_info, fall back to a line-count *approximation*
  # purely to pick a near-tail probe offset — it is never reported as a total.
  read -r _ _ api_total <<<"$(probe "${BASE}?thread_id=${enc}&limit=1&include_tool_messages=true")"
  if [ "$api_total" != "-" ] 2>/dev/null; then
    approx="$api_total"
  else
    approx=$(wc -l < "$f" | tr -d ' ')
  fi
  after=0
  if [ "$approx" -gt 140 ] 2>/dev/null; then
    after=$(( approx - 140 ))
  fi

  # Cold newest-window open: what the app requests on entering a thread.
  read -r w_t w_n w_tot <<<"$(probe "${BASE}?thread_id=${enc}&limit=100&include_tool_messages=true&user_query_limit=3")"
  # One iteration of the client's forward delta paging loop.
  read -r d_t _ _ <<<"$(probe "${BASE}?thread_id=${enc}&limit=100&after_index=${after}&user_query_limit=3&include_tool_messages=true")"
  # Control: identical request without the user-query window.
  read -r c_t _ _ <<<"$(probe "${BASE}?thread_id=${enc}&limit=100&after_index=${after}&include_tool_messages=true")"

  printf '%9s  %12s  %9ss  %9ss  %9ss  %14s\n' \
    "$size" "$bytes" "$w_t" "$d_t" "$c_t" "${w_n}/${w_tot}"
done
