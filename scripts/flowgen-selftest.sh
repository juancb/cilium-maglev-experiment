#!/usr/bin/env bash
# flowgen-selftest.sh — prove flowgen CAN detect a broken TCP connection.
#
# Runs a local echo server on the CLIENT container (port 9999), then connects
# flowgen to it directly (no VIP, no Cilium, no ECMP in the path).  After flows
# establish we kill the server and verify that flowgen reports broken flows.
#
# Expected: ~100% broken (all flows lose their server and timeout within 5 s).
# If we see 0% broken here, flowgen itself is the bug.

set -euo pipefail
CLIENT="clab-maglev-clos-client"
RESULTS="/mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment/results"
PORT=9999
N=10
DUR=30
TAG="flowgen_selftest"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

# --- 1. start a minimal echo server on the client ---
yellow "[*] starting echo server on client:${PORT}"
docker exec "$CLIENT" pkill -f "echo_srv.py" 2>/dev/null || true

docker exec "$CLIENT" bash -c "cat > /tmp/echo_srv.py << 'PYEOF'
import socket, threading, os
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', ${PORT}))
srv.listen(256)
def h(c):
    try:
        c.sendall(b'POD=selftest\n')
        while True:
            d = c.recv(1024)
            if not d: break
            c.sendall(d)
    except: pass
    finally: c.close()
while True:
    conn, _ = srv.accept()
    threading.Thread(target=h, args=(conn,), daemon=True).start()
PYEOF
python3 /tmp/echo_srv.py &
echo \$!"
sleep 0.5

# verify server is up
docker exec "$CLIENT" bash -c "echo 'POD=check' | nc -w1 127.0.0.1 ${PORT}" | head -1 \
  | grep -q 'POD=selftest' && yellow "[*] echo server responding OK" \
  || { red "ABORT: echo server not responding"; exit 1; }

# --- 2. start flowgen against 127.0.0.1:PORT inside the client ---
yellow "[*] starting ${N} flows via flowgen (target 127.0.0.1:${PORT})"
mkdir -p "${RESULTS}"
docker exec "$CLIENT" rm -f /tmp/${TAG}.json /tmp/${TAG}.ready 2>/dev/null || true

docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
    --vip 127.0.0.1 --port "$PORT" --count "$N" --duration "$DUR" \
    --out "/tmp/${TAG}.json" --ready-file "/tmp/${TAG}.ready"

# wait for all flows to establish
for _ in $(seq 1 20); do
  docker exec "$CLIENT" test -f /tmp/${TAG}.ready 2>/dev/null && break
  sleep 1
done
docker exec "$CLIENT" test -f /tmp/${TAG}.ready || { red "ABORT: flows never established"; exit 1; }
yellow "[*] flows established — sleeping 3 s then killing echo server"
sleep 3

# --- 3. kill the echo server mid-test ---
KILLTIME=$(date +%s)
yellow "[*] killing echo server at $(date)"
docker exec "$CLIENT" pkill -f "echo_srv.py" 2>/dev/null || true

# wait for flowgen to finish
for _ in $(seq 1 "${DUR}"); do
  docker exec "$CLIENT" test -s /tmp/${TAG}.json 2>/dev/null && break
  sleep 1
done

docker cp "${CLIENT}:/tmp/${TAG}.json" "${RESULTS}/${TAG}.json" 2>/dev/null || true

# --- 4. report ---
if command -v jq >/dev/null 2>&1 && [ -s "${RESULTS}/${TAG}.json" ]; then
  BROKEN=$(jq --argjson t "$KILLTIME" \
    '[.flows[] | select(.status=="broken" and .established_at!=null and (.broke_at//0) >= $t)] | length' \
    "${RESULTS}/${TAG}.json")
  EST=$(jq '.summary.established' "${RESULTS}/${TAG}.json")
  PCT=$(awk "BEGIN{printf \"%.0f\", 100*${BROKEN}/${EST:-1}}")
  if [ "${BROKEN:-0}" -gt 0 ]; then
    green "SELFTEST PASS: ${BROKEN}/${EST} flows broken (${PCT}%) — flowgen detects breaks"
  else
    red "SELFTEST FAIL: 0/${EST} broken — flowgen did NOT detect the killed server!"
    red "  Check: does socket.timeout propagate correctly inside the client container?"
    jq '.flows[:3]' "${RESULTS}/${TAG}.json" 2>/dev/null || true
  fi
else
  red "No JSON result — flowgen may not have run"
fi
