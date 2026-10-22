#!/bin/sh
# Smoke test for dnsmasq. No root, no system files touched, no network beyond 127.0.0.1.
# Usage: test/smoke.sh   (from the repo root; builds first if src/dnsmasq is missing)
# Exit code 0 = every check passed.

set -u
cd "$(dirname "$0")/.." || exit 1

PORT=${PORT:-5355}
LOG=$(mktemp -t dnsmasq-smoke.XXXXXX)
PASS=0; FAIL=0; PID=

cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -f "$LOG"; }
trap cleanup EXIT INT TERM

check() {  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "       expected: $2"; echo "       got:      $3"; fi
}
q() { dig +short +time=2 +tries=1 @127.0.0.1 -p "$PORT" "$@" | sort | tr '\n' ' ' | sed 's/ $//'; }

# 1. build
[ -x src/dnsmasq ] || make >/dev/null 2>&1
check "src/dnsmasq exists after make" "yes" "$([ -x src/dnsmasq ] && echo yes || echo no)"

# 2. config syntax check on the shipped example
check "--test on dnsmasq.conf.example" "ok" "$(./src/dnsmasq --test -C dnsmasq.conf.example >/dev/null 2>&1 && echo ok || echo bad)"
check "--test rejects a bad option" "rejected" "$(./src/dnsmasq --test -C /dev/null --no-such-option >/dev/null 2>&1 && echo accepted || echo rejected)"

# 3. start a throwaway server: everything under .test is answered locally, nothing goes upstream
./src/dnsmasq -d -p "$PORT" -C /dev/null --no-resolv --no-hosts --pid-file= \
  --log-queries --log-facility=- \
  --local=/test/ \
  --address=/agent.test/10.9.8.7 \
  --host-record=box.test,192.0.2.1,2001:db8::1 \
  --cname=alias.test,box.test \
  --txt-record=hello.test,"smoke test" \
  --ptr-record=1.2.0.192.in-addr.arpa,box.test \
  >"$LOG" 2>&1 &
PID=$!
sleep 1
check "server is running" "running" "$(kill -0 "$PID" 2>/dev/null && echo running || echo dead)"
grep -q "started, version" "$LOG"; check "startup line logged" "0" "$?"

# 4. queries over UDP
check "A    agent.test     (--address)"        "10.9.8.7"                 "$(q agent.test A)"
check "A    sub.agent.test (--address covers subdomains)" "10.9.8.7"      "$(q sub.agent.test A)"
check "A    box.test       (--host-record)"    "192.0.2.1"                "$(q box.test A)"
check "AAAA box.test       (--host-record)"    "2001:db8::1"              "$(q box.test AAAA)"
check "CNAME alias.test -> box.test"           "192.0.2.1 box.test."      "$(q alias.test A)"
check "TXT  hello.test     (--txt-record)"     "\"smoke test\""           "$(q hello.test TXT)"
check "PTR  192.0.2.1      (--ptr-record)"     "box.test."                "$(q -x 192.0.2.1)"
check "NXDOMAIN for unknown name under --local" "NXDOMAIN" \
  "$(dig +time=2 +tries=1 @127.0.0.1 -p "$PORT" nothing.test A | sed -n 's/.*status: \([A-Z]*\).*/\1/p')"

# 5. same answer over TCP, and the cache serves the repeat
check "A    agent.test over TCP"               "10.9.8.7"                 "$(q +tcp agent.test A)"
q box.test A >/dev/null; q box.test A >/dev/null
check "queries are logged (--log-queries)" "yes" "$(grep -q 'query\[A\] box.test from 127.0.0.1' "$LOG" && echo yes || echo no)"

# 6. clean shutdown on SIGTERM
kill "$PID"; sleep 0.5
grep -q "exiting on receipt of SIGTERM" "$LOG"; check "exits cleanly on SIGTERM" "0" "$?"
PID=

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
