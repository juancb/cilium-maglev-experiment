#!/usr/bin/env python3
"""
flowgen — open N long-lived TCP flows to the Service VIP, learn which backend serves each,
hold them open with app-level keepalives, and record exactly when each flow breaks.

Used by tests/03-failover.sh: start flowgen, let flows establish, fail a spine, then measure
how many flows reset. With Maglev a re-homed flow keeps its backend (survives); without it the
new ingress node picks a different backend and the flow resets.

Output: a JSON file (--out) with per-flow {srcport, backend, status, established_at, broke_at}
and a summary block. Exit code is always 0; the test script interprets the JSON.

Usage:
  flowgen.py --vip 192.0.2.10 --port 8080 --count 300 --duration 60 --out results/run.json
"""
import argparse, json, socket, struct, sys, threading, time

def now():
    return time.time()

class Flow:
    __slots__ = ("idx", "sock", "srcport", "backend", "status", "established_at", "broke_at")
    def __init__(self, idx):
        self.idx = idx
        self.sock = None
        self.srcport = None
        self.backend = None
        self.status = "pending"      # pending | established | broken | closed
        self.established_at = None
        self.broke_at = None

def run_flow(flow, vip, port, src, stop_at, lock):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.settimeout(5.0)
        if src:
            s.bind((src, 0))
        s.connect((vip, port))
        flow.srcport = s.getsockname()[1]
        # read the "POD=<name>\n" greeting to learn the backend
        greeting = b""
        while b"\n" not in greeting:
            chunk = s.recv(256)
            if not chunk:
                raise ConnectionError("closed before greeting")
            greeting += chunk
        line = greeting.split(b"\n", 1)[0].decode(errors="replace")
        flow.backend = line.split("=", 1)[1] if "=" in line else line
        flow.sock = s
        with lock:
            flow.status = "established"
            flow.established_at = now()
    except Exception:
        with lock:
            flow.status = "broken"
            flow.broke_at = now()
        return

    # hold open with a keepalive byte each second; a reset/blackhole trips send or recv
    while now() < stop_at:
        try:
            s.sendall(b".")
            echo = s.recv(16)
            if not echo:
                raise ConnectionError("peer closed")
        except Exception:
            with lock:
                flow.status = "broken"
                flow.broke_at = now()
            return
        time.sleep(0.100) # Changed by Juan to generate more traffic, 1 byte per second seems like it might miss transitions
    with lock:
        if flow.status == "established":
            flow.status = "closed"
    try:
        s.close()
    except Exception:
        pass

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vip", required=True)
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--count", type=int, default=300)
    ap.add_argument("--duration", type=int, default=60)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ready-file", default=None,
                    help="touch this path once all flows are established (signals the harness)")
    ap.add_argument("--src", default=None,
                    help="source IP to bind before connect (e.g. 203.0.113.1)")
    args = ap.parse_args()

    lock = threading.Lock()
    flows = [Flow(i) for i in range(args.count)]
    stop_at = now() + args.duration
    threads = []
    for f in flows:
        t = threading.Thread(target=run_flow, args=(f, args.vip, args.port, args.src, stop_at, lock),
                             daemon=True)
        t.start()
        threads.append(t)

    # wait until flows have settled (established or broken) then signal readiness
    t0 = now()
    while now() - t0 < 15:
        with lock:
            pending = sum(1 for f in flows if f.status == "pending")
        if pending == 0:
            break
        time.sleep(0.2)
    with lock:
        established = sum(1 for f in flows if f.status == "established")
    sys.stderr.write("[flowgen] %d/%d flows established\n" % (established, args.count))
    if args.ready_file:
        open(args.ready_file, "w").write(str(established))

    for t in threads:
        t.join()

    with lock:
        records = [{"idx": f.idx, "srcport": f.srcport, "backend": f.backend,
                    "status": f.status, "established_at": f.established_at,
                    "broke_at": f.broke_at} for f in flows]
    broken = [r for r in records if r["status"] == "broken" and r["established_at"]]
    never  = [r for r in records if r["status"] == "broken" and not r["established_at"]]
    survived = [r for r in records if r["status"] in ("closed", "established")]
    # backend distribution among flows that established
    dist = {}
    for r in records:
        if r["backend"]:
            dist[r["backend"]] = dist.get(r["backend"], 0) + 1
    summary = {
        "count": args.count,
        "established": len(broken) + len(survived),
        "never_established": len(never),
        "broken_after_establish": len(broken),
        "survived": len(survived),
        "backend_distribution": dist,
    }
    json.dump({"summary": summary, "flows": records}, open(args.out, "w"), indent=2)
    sys.stderr.write("[flowgen] summary: %s\n" % json.dumps(summary))

if __name__ == "__main__":
    main()
