#!/usr/bin/env python3
"""
flowgen — open N long-lived TCP flows to the Service VIP, learn which backend serves each,
hold them open with app-level keepalives, and record exactly when each flow breaks.

Used by the failover tests (tests/04*.sh via tests/lib/failover-lib.sh): start flowgen, let
flows establish, inject a failure, then measure how many flows reset. With Maglev a re-homed
flow keeps its backend (survives); without it the new ingress node picks a different backend
and the flow resets.

Output: a JSON file (--out) with per-flow {srcport, backend, status, established_at, broke_at}
and a summary block. Exit code is always 0; the test script interprets the JSON.

Usage:
  flowgen.py --vip 192.0.2.10 --port 8080 --count 300 --duration 60 --out results/run.json
"""
import argparse, json, socket, struct, sys, threading, time

def now():
    return time.time()

class Flow:
    __slots__ = ("idx", "sock", "srcport", "backend", "status",
                 "established_at", "broke_at", "error_type", "max_stall", "stall_at")
    def __init__(self, idx):
        self.idx = idx
        self.sock = None
        self.srcport = None
        self.backend = None
        self.status = "pending"      # pending | established | broken | closed
        self.established_at = None
        self.broke_at = None
        self.error_type = None       # reset | timeout | peer_closed | other
        self.max_stall = 0.0         # longest keepalive round trip (s): a survived outage shows here
        self.stall_at = None         # when that longest round trip started


def classify_error(exc):
    """Map a socket exception to a coarse error class.

    Distinguishes a true RST (Maglev mismatch: wrong backend has no TCP state)
    from a timeout/blackhole (transient reconvergence during BGP holdtime).
    """
    import errno as _errno
    if isinstance(exc, socket.timeout):
        return "timeout"
    if isinstance(exc, ConnectionResetError):
        return "reset"
    err = getattr(exc, "errno", None)
    if err == _errno.ECONNRESET:
        return "reset"
    if err in (_errno.ETIMEDOUT, _errno.EHOSTUNREACH, _errno.ENETUNREACH):
        return "timeout"
    # our own ConnectionError("peer closed") / ("closed before greeting")
    if isinstance(exc, ConnectionError):
        return "peer_closed"
    return "other"

def run_flow(flow, vip, port, src, stop_at, lock, io_timeout=5.0):
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
        # io_timeout bounds how long a stalled flow may wait before we call it broken. The
        # 5s default counts a >5s stall as broken; a real TCP client would keep retransmitting,
        # so disruption tests pass a longer one and read the stall from max_stall instead.
        s.settimeout(io_timeout)
        with lock:
            flow.status = "established"
            flow.established_at = now()
    except Exception as exc:
        with lock:
            flow.status = "broken"
            flow.broke_at = now()
            flow.error_type = classify_error(exc)
        return

    # hold open with a keepalive byte each second; a reset/blackhole trips send or recv
    while now() < stop_at:
        try:
            sent = now()
            s.sendall(b".")
            echo = s.recv(16)
            if not echo:
                raise ConnectionError("peer closed")
            rtt = now() - sent
            if rtt > flow.max_stall:
                flow.max_stall, flow.stall_at = rtt, sent
        except Exception as exc:
            with lock:
                flow.status = "broken"
                flow.broke_at = now()
                flow.error_type = classify_error(exc)
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
    ap.add_argument("--timeout", type=float, default=5.0,
                    help="seconds an established flow may stall before it counts as broken")
    args = ap.parse_args()

    lock = threading.Lock()
    flows = [Flow(i) for i in range(args.count)]
    stop_at = now() + args.duration
    threads = []
    for f in flows:
        t = threading.Thread(target=run_flow, args=(f, args.vip, args.port, args.src, stop_at, lock, args.timeout),
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
                    "broke_at": f.broke_at, "error_type": f.error_type,
                    "max_stall": round(f.max_stall, 4), "stall_at": f.stall_at} for f in flows]
    broken = [r for r in records if r["status"] == "broken" and r["established_at"]]
    never  = [r for r in records if r["status"] == "broken" and not r["established_at"]]
    survived = [r for r in records if r["status"] in ("closed", "established")]
    # backend distribution among flows that established
    dist = {}
    for r in records:
        if r["backend"]:
            dist[r["backend"]] = dist.get(r["backend"], 0) + 1
    # error-type breakdown among flows broken AFTER establishing (the meaningful set):
    #   reset  → wrong backend had no TCP state (the Maglev-mismatch signal)
    #   timeout→ transient blackhole during BGP reconvergence (NOT a Maglev failure)
    err_breakdown = {}
    for r in broken:
        et = r["error_type"] or "other"
        err_breakdown[et] = err_breakdown.get(et, 0) + 1
    summary = {
        "count": args.count,
        "established": len(broken) + len(survived),
        "never_established": len(never),
        "broken_after_establish": len(broken),
        "broken_reset": err_breakdown.get("reset", 0),
        "broken_timeout": err_breakdown.get("timeout", 0),
        "broken_error_breakdown": err_breakdown,
        "survived": len(survived),
        "backend_distribution": dist,
    }
    json.dump({"summary": summary, "flows": records}, open(args.out, "w"), indent=2)
    sys.stderr.write("[flowgen] summary: %s\n" % json.dumps(summary))

if __name__ == "__main__":
    main()
