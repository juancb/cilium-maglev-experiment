#!/usr/bin/env bash
# Probe what source IP the echo pods see from an incoming connection.
# Confirms whether Cilium SNAT is active (pod sees 172.30.0.X = node mgmt IP)
# or absent (pod sees 203.0.113.1 = original client IP).
#
# Method: temporarily patches the ConfigMap to prepend "SRCIP=<peer>\n" before
# "POD=<name>\n", opens one connection, reads the result, then reverts.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/common.sh

# kubectl wrapper that pipes stdin through docker exec
kci() { docker exec -i "${PFX}-node1" k3s kubectl "$@"; }

info "Checking cluster connectivity..."
kc get pods -l app=echo --no-headers 2>/dev/null | head -5 || \
  { red "Cannot reach cluster — is it up?"; exit 1; }

# Generate patched ConfigMap YAML on stdout (heredoc in function avoids pipe+heredoc conflict)
patched_cm() {
cat << 'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: echo-server
  namespace: default
data:
  server.py: |
    import os, socket, threading
    name = os.environ.get("POD_NAME", "?")
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", 8080)); srv.listen(2048)
    def handle(c):
        try:
            c.sendall(("SRCIP=%s\n" % c.getpeername()[0]).encode())
            c.sendall(("POD=%s\n" % name).encode())
            while True:
                d = c.recv(1024)
                if not d: break
                c.sendall(d)
        except Exception:
            pass
        finally:
            c.close()
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()
YAML
}

cleanup() {
  info "Reverting echo-server ConfigMap..."
  kc apply -f /opt/k8s/demo-app.yaml >/dev/null 2>&1 || true
  kc rollout restart deploy/echo >/dev/null 2>&1 || true
  kc rollout status deploy/echo --timeout=90s >/dev/null 2>&1 || true
  green "Reverted to original."
}
trap cleanup EXIT

info "Patching ConfigMap to emit SRCIP..."
patched_cm | kci apply -f - >/dev/null
kc rollout restart deploy/echo >/dev/null
kc rollout status deploy/echo --timeout=120s >/dev/null
sleep 2

info "Opening test connection to ${VIP}:${VIP_PORT}..."
PROBE_PY="
import socket, sys
s = socket.socket()
s.settimeout(10)
try:
    s.connect(('${VIP}', ${VIP_PORT}))
    data = b''
    while data.count(b'\\n') < 2:
        chunk = s.recv(256)
        if not chunk:
            break
        data += chunk
    sys.stdout.write(data.decode('utf-8', 'replace'))
except Exception as e:
    sys.stderr.write('connection failed: %s\\n' % e)
    sys.exit(1)
finally:
    s.close()
"
RESP=$(echo "$PROBE_PY" | docker exec -i "${CLIENT}" python3) || \
  { red "Connection to VIP failed"; exit 1; }

echo
echo "--- echo server response ---"
echo "$RESP"
echo "----------------------------"
echo

SRCIP=$(echo "$RESP" | grep '^SRCIP=' | head -1 | cut -d= -f2 | tr -d '\r\n')
POD=$(echo  "$RESP" | grep '^POD='   | head -1 | cut -d= -f2 | tr -d '\r\n')

printf 'Backend pod          : %s\n' "${POD:-<unknown>}"
printf 'Source IP at backend : %s\n' "${SRCIP:-<none — patch may not have propagated>}"
echo

if [ -z "$SRCIP" ]; then
  yellow "WARNING: no SRCIP line — try again after the rollout stabilises"
elif echo "$SRCIP" | grep -qE '^172\.30\.'; then
  red "SNAT ACTIVE: pod sees ${SRCIP} (node management IP, not client)"
  echo "  Cilium is SNATting service ingress to the ingress-node's management IP."
  echo "  When a flow re-homes to a different node the source IP changes -> RST."
  echo "  Maglev cannot help: the backend has no state for the new source IP."
  echo
  echo "  Fix: set loadBalancer.mode=dsr in Cilium Helm values."
  echo "  See k8s/cilium-values-dsr-maglev.yaml and k8s/cilium-values-dsr-nomaglev.yaml"
  echo "  then run: bash tests/04b-leaf-failure.sh"
elif echo "$SRCIP" | grep -qE '^203\.0\.113\.'; then
  green "NO SNAT: pod sees ${SRCIP} (original client IP preserved end-to-end)"
  echo "  DSR or masquerade=false mode is active."
  echo "  Maglev CAN now preserve connections across ingress-node changes."
  echo "  Run bash tests/04b-leaf-failure.sh to measure the 2-cell comparison."
else
  yellow "Unexpected source IP: ${SRCIP}"
  echo "  Expected 203.0.113.x (client) or 172.30.0.x (SNAT node mgmt IP)"
fi
