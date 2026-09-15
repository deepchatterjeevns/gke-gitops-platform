#!/usr/bin/env python3
"""generate_traffic.py — synthetic load against demo-app.

Drives the http_requests_total counter the SLO rules + AnalysisTemplate
consume. Modes:
  --mode steady   : clean traffic (rollback test baseline)
  --mode fault    : traffic hitting FAULT_PERCENT-injected pods (MTTD/SLO)
"""
import argparse
import time
import urllib.request
import urllib.error
import threading
import sys

REQS = {"total": 0, "errors": 0}


def hit(url: str) -> None:
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            r.read()
    except urllib.error.HTTPError as e:
        REQS["errors"] += 1
        if e.code not in (500, 401):
            raise
    finally:
        REQS["total"] += 1


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--rate", type=float, default=5.0, help="requests/sec")
    p.add_argument("--duration", type=float, default=120.0, help="seconds")
    args = p.parse_args()

    threads = []
    t_end = time.time() + args.duration
    interval = 1.0 / args.rate
    print(f"hitting {args.url} @ {args.rate} rps for {args.duration}s", file=sys.stderr)
    while time.time() < t_end:
        t = threading.Thread(target=hit, args=(args.url,), daemon=True)
        t.start()
        threads.append(t)
        time.sleep(interval)
    for t in threads:
        t.join(timeout=5)
    print(f"done: {REQS['total']} reqs, {REQS['errors']} errors", file=sys.stderr)


if __name__ == "__main__":
    main()
