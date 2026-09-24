#!/usr/bin/env python3
"""
connprobe — open NEW short-lived TCP connections to a VIP at a fixed rate and record which
ones fail. Complements flowgen: flowgen measures whether ESTABLISHED flows survive a
disruption, connprobe measures whether NEW connections can be made during it (e.g. an
eTP=Local node that still attracts traffic after losing its local backend, or a VIP
withdrawn while an agent restarts).

Each attempt: connect (timeout --timeout), read the "POD=<name>" greeting, close.

Output (--out) JSON: {"summary": {...}, "attempts": [{"t", "ok", "err", "backend"}]}.
Exit code is always 0; the test script interprets the JSON.

Usage:
  connprobe.py --vip 192.0.2.20 --port 8080 --hz 10 --duration 90 --out /tmp/p.json
"""
import argparse, errno, json, socket, sys, threading, time


def classify(exc):
    if isinstance(exc, socket.timeout):
        return "timeout"
    if isinstance(exc, ConnectionRefusedError):
        return "refused"
    if isinstance(exc, ConnectionResetError):
        return "reset"
    e = getattr(exc, "errno", None)
    if e in (errno.EHOSTUNREACH, errno.ENETUNREACH):
        return "unreachable"
    if isinstance(exc, ConnectionError):
        return "peer_closed"
    return "other"


def attempt(rec, vip, port, src, timeout):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        if src:
            s.bind((src, 0))
        s.connect((vip, port))
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(256)
            if not chunk:
                raise ConnectionError("closed before greeting")
            buf += chunk
        line = buf.split(b"\n", 1)[0].decode(errors="replace")
        rec["backend"] = line.split("=", 1)[1] if "=" in line else line
        rec["ok"] = True
    except Exception as exc:
        rec["ok"] = False
        rec["err"] = classify(exc)
    finally:
        try:
            s.close()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vip", required=True)
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--hz", type=float, default=10.0, help="new connections per second")
    ap.add_argument("--duration", type=int, default=60)
    ap.add_argument("--timeout", type=float, default=1.0)
    ap.add_argument("--src", default=None)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    records, threads = [], []
    period = 1.0 / args.hz
    t0 = time.time()
    k = 0
    # fixed-rate schedule: a slow/timing-out attempt must not lower the sampling rate
    while True:
        due = t0 + k * period
        if due - t0 >= args.duration:
            break
        delay = due - time.time()
        if delay > 0:
            time.sleep(delay)
        rec = {"t": time.time(), "ok": None, "err": None, "backend": None}
        records.append(rec)
        th = threading.Thread(target=attempt, args=(rec, args.vip, args.port, args.src, args.timeout),
                              daemon=True)
        th.start()
        threads.append(th)
        k += 1
    for th in threads:
        th.join(args.timeout + 2)

    fails = [r for r in records if r["ok"] is not True]
    errs = {}
    for r in fails:
        errs[r["err"] or "unfinished"] = errs.get(r["err"] or "unfinished", 0) + 1
    summary = {"vip": args.vip, "hz": args.hz, "attempts": len(records),
               "failed": len(fails), "errors": errs}
    json.dump({"summary": summary, "attempts": records}, open(args.out, "w"))
    sys.stderr.write("[connprobe] %s\n" % json.dumps(summary))


if __name__ == "__main__":
    main()
