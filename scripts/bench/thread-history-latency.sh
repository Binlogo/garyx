#!/usr/bin/env bash
# Benchmark /api/threads/history against the local gateway.
#
# The user-query window path (`user_query_limit`) is the one that scans the
# transcript; run this before and after a change to that path.
#
#   scripts/bench/thread-history-latency.sh [thread_count] [samples]
#
# Reports the median of `samples` runs per cell, for both user-query targets in
# use: iOS asks for 3, desktop for 10. The cached-tail fast path is far more
# likely to miss at 10, so a regression can hide entirely if only 3 is measured.
#
# EVERYTHING HERE IS THE WARM PATH. The gateway keeps a per-thread parsed tail,
# and the first request against a thread builds it; with samples>1 the median is
# warm by construction. There is no way to measure the cold path from inside
# this script — that needs a gateway restart followed by exactly ONE request per
# thread, with nothing else touching that thread first.
#
# Responses are validated: a 200 can still carry a history error, and a silently
# empty page would otherwise read as a fast result.
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

printf '%9s  %12s  %10s  %10s  %10s  %10s  %10s\n' \
  SIZE 'BYTES' 'win(K=3)' 'win(K=10)' 'delta(3)' 'delta(10)' 'no-uql'
for f in $(ls -S "${TRANSCRIPTS}"/*.jsonl 2>/dev/null | head -n "$COUNT"); do
  size=$(du -h "$f" | cut -f1)
  bytes=$(wc -c < "$f" | tr -d ' ')
  b=$(basename "$f" .jsonl); b=${b#k_}
  tid=$(printf '%s' "$b" | xxd -r -p 2>/dev/null || true)
  case "$tid" in thread::*) ;; *) continue ;; esac
  enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$tid")

  # Pick a near-tail probe offset from the line count. This is an
  # approximation (it counts the Session header and misses a final
  # unterminated line) and is only ever used to choose an offset — it is never
  # reported or asserted as a total. Deliberately no API probe here: one would
  # build the cache before the measurements below.
  approx=$(wc -l < "$f" | tr -d ' ')
  after=0
  if [ "$approx" -gt 140 ] 2>/dev/null; then
    after=$(( approx - 140 ))
  fi

  # Newest-window open: what a client requests on entering a thread.
  read -r w3_t _ _ <<<"$(probe "${BASE}?thread_id=${enc}&limit=100&include_tool_messages=true&user_query_limit=3")"
  read -r w10_t _ _ <<<"$(probe "${BASE}?thread_id=${enc}&limit=100&include_tool_messages=true&user_query_limit=10")"
  # One iteration of the client's forward delta paging loop.
  read -r d3_t _ _ <<<"$(probe "${BASE}?thread_id=${enc}&limit=100&after_index=${after}&user_query_limit=3&include_tool_messages=true")"
  read -r d10_t _ _ <<<"$(probe "${BASE}?thread_id=${enc}&limit=100&after_index=${after}&user_query_limit=10&include_tool_messages=true")"
  # Control: identical request without the user-query window.
  read -r c_t _ _ <<<"$(probe "${BASE}?thread_id=${enc}&limit=100&after_index=${after}&include_tool_messages=true")"

  printf '%9s  %12s  %9ss  %9ss  %9ss  %9ss  %9ss\n' \
    "$size" "$bytes" "$w3_t" "$w10_t" "$d3_t" "$d10_t" "$c_t"
done
