#!/usr/bin/env python3
"""Send fake runner requests to the mock control planes.

Stands in for the fake GitHub endpoint until it exists; it speaks the
POST /inject and POST /load calls described in METRICS.md, so pointing --url
at the real fake GitHub endpoint later needs no other change.

Examples:
  inject.py --count 300                 # mixed sizes, arriving over 5s
  inject.py --count 40 --vcpus 30       # only 30 vCPU runners
  inject.py --rate 80                   # raise steady background load
"""

import argparse
import json
import sys
import urllib.request


def post(url, body):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.load(resp)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default="http://localhost:8787")
    p.add_argument("--count", type=int, help="number of requests to inject into both control planes")
    p.add_argument("--vcpus", type=int, choices=[2, 4, 8, 16, 30], help="runner size (default: mixed)")
    p.add_argument("--spread", type=float, default=5, help="seconds over which the requests arrive")
    p.add_argument("--rate", type=float, help="set background requests per minute")
    args = p.parse_args()

    if args.count is None and args.rate is None:
        p.error("pass --count and/or --rate")
    try:
        if args.rate is not None:
            print(post(f"{args.url}/load", {"rate_per_min": args.rate}))
        if args.count is not None:
            print(post(f"{args.url}/inject", {"count": args.count, "vcpus": args.vcpus, "spread": args.spread}))
    except OSError as e:
        sys.exit(f"could not reach {args.url}: {e}")


if __name__ == "__main__":
    main()
