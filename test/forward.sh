#!/bin/sh
# Forwarding + cache test for dnsmasq (forward.c / cache.c). No root, no system files,
# no network beyond 127.0.0.1. Two instances: an "upstream" that answers from static records,
# and a "forwarder" with no local records of its own that forwards to it and caches the replies.
# Usage: test/forward.sh   (from the repo root; builds first if src/dnsmasq is missing)
# Exit code 0 = every check passed.

set -u
cd "$(dirname "$0")/.." || exit 1

UP_PORT=${UP_PORT:-5356}
FWD_PORT=${FWD_PORT:-5357}
UP_LOG=$(mktemp -t dnsmasq-up.XXXXXX)
FWD_LOG=$(mktemp -t dnsmasq-fwd.XXXXXX)
PASS=0; FAIL=0; UP_PID=; FWD_PID=

cleanup() {
  [ -n "$FWD_PID" ] && kill "$FWD_PID" 2>/dev/null
  [ -n "$UP_PID" ] && kill "$UP_PID" 2>/dev/null
  rm -f "$UP_LOG" "$FWD_LOG"
}
trap cleanup EXIT INT TERM

check() {  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "       expected: $2"; echo "       got:      $3"; fi
}
q() { dig +short +time=2 +tries=1 @127.0.0.1 -p "$FWD_PORT" "$@" | sort | tr '\n' ' ' | sed 's/ $//'; }
status() { dig +time=2 +tries=1 @127.0.0.1 -p "$FWD_PORT" "$@" | sed -n 's/.*status: \([A-Z]*\).*/\1/p'; }
logged() { grep -c "$1" "$FWD_LOG"; }   # number of matching lines in the forwarder log

[ -x src/dnsmasq ] || make >/dev/null 2>&1
check "src/dnsmasq exists after make" "yes" "$([ -x src/dnsmasq ] && echo yes || echo no)"

# 1. upstream: owns everything under .test, answers with a 300 s TTL so the forwarder can cache
./src/dnsmasq -d -p "$UP_PORT" -C /dev/null --no-resolv --no-hosts --pid-file= \
  --log-queries --log-facility=- \
  --local=/test/ --local-ttl=300 \
  --address=/up.test/192.0.2.50 \
  --host-record=srv.test,192.0.2.60 \
  >"$UP_LOG" 2>&1 &
UP_PID=$!

# 2. forwarder: no local records except one --address, everything else goes to the upstream
./src/dnsmasq -d -p "$FWD_PORT" -C /dev/null --no-resolv --no-hosts --pid-file= \
  --log-queries --log-facility=- \
  --cache-size=150 \
  --server=127.0.0.1#"$UP_PORT" \
  --address=/local.test/10.0.0.1 \
  >"$FWD_LOG" 2>&1 &
FWD_PID=$!
sleep 1
check "upstream is running"  "running" "$(kill -0 "$UP_PID"  2>/dev/null && echo running || echo dead)"
check "forwarder is running" "running" "$(kill -0 "$FWD_PID" 2>/dev/null && echo running || echo dead)"
check "forwarder logs its upstream server" "1" "$(logged "using nameserver 127.0.0.1#$UP_PORT")"

# 3. first query is forwarded upstream and answered
check "A up.test via forwarder (answer from upstream)" "192.0.2.50" "$(q up.test A)"
check "  ... was forwarded"            "1" "$(logged "forwarded up.test to 127.0.0.1#$UP_PORT")"
check "  ... upstream saw the query"   "1" "$(grep -c 'query\[A\] up.test from 127.0.0.1' "$UP_LOG")"
check "  ... reply logged as from upstream" "1" "$(logged "reply up.test is 192.0.2.50")"

# 4. repeat query is served from the forwarder's cache, not forwarded again
check "A up.test again (same answer)"  "192.0.2.50" "$(q up.test A)"
check "  ... served from cache"        "1" "$(logged "cached up.test is 192.0.2.50")"
check "  ... not forwarded a second time" "1" "$(logged "forwarded up.test to 127.0.0.1#$UP_PORT")"
check "  ... upstream still saw only one query" "1" "$(grep -c 'query\[A\] up.test from 127.0.0.1' "$UP_LOG")"

# 5. the forwarder's own --address record is answered locally, never forwarded
check "A local.test (forwarder's --address)" "10.0.0.1" "$(q local.test A)"
check "  ... answered from config"     "1" "$(logged "config local.test is 10.0.0.1")"
check "  ... never forwarded"          "0" "$(logged "forwarded local.test")"

# 6. a --host-record on the upstream round-trips too, and NXDOMAIN is passed through
check "A srv.test via forwarder (--host-record upstream)" "192.0.2.60" "$(q srv.test A)"
check "NXDOMAIN from upstream passes through" "NXDOMAIN" "$(status nothing.test A)"

# 7. cache introspection over CHAOS, and TCP goes through the same path
check "CHAOS TXT cachesize.bind reports --cache-size" "\"150\"" "$(q chaos txt cachesize.bind)"
check "A up.test over TCP (cached)"    "192.0.2.50" "$(q +tcp up.test A)"

# 8. clean shutdown
kill "$FWD_PID"; kill "$UP_PID"; sleep 0.5
grep -q "exiting on receipt of SIGTERM" "$FWD_LOG"; check "forwarder exits cleanly on SIGTERM" "0" "$?"
grep -q "exiting on receipt of SIGTERM" "$UP_LOG";  check "upstream exits cleanly on SIGTERM"  "0" "$?"
FWD_PID=; UP_PID=

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
