#!/usr/bin/env python3
"""Step 3 CLI — refresh shelf stock from the Arduino (or dummy data).

Gets per-bin item counts, sets each bin's quantity in the shared inventory DB to
the counted value (vision = truth), then reports items at/below the reorder
threshold. Uses the real Arduino when ARDUINO_URL is set; otherwise generates
dummy counts so the flow works without hardware. Talks to the DB directly — no
server required.

Usage:
    decoai-refresh [--json] [--dry-run] [--dummy] [--reorder-only]

    --dry-run       show the counts that would be applied; don't touch the DB
    --dummy         force dummy counts even if ARDUINO_URL is set
    --reorder-only  emit just the reorder JSON array (for the Amazon URL Builder)

Exit codes: 0 = success, 1 = Arduino unreachable.
"""
import argparse
import json
import os
import sys
from pathlib import Path

_SVC = Path(__file__).resolve().parents[1]      # inventory-management/ (has app/)
sys.path.insert(0, str(_SVC.parent))            # repo root (has database/)
sys.path.insert(0, str(_SVC))

from dotenv import load_dotenv                                         # noqa: E402
load_dotenv(_SVC.parent / ".env")

from database.db import init_db                                        # noqa: E402
from app.refresh import apply_counts, dummy_counts, poll_arduino      # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="decoai-refresh",
        description="Step 3: refresh shelf stock from the Arduino vision counts.",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON instead of text")
    parser.add_argument("--dry-run", action="store_true",
                        help="show counts without updating the DB")
    parser.add_argument("--dummy", action="store_true",
                        help="force dummy counts even if ARDUINO_URL is set")
    parser.add_argument("--reorder-only", action="store_true",
                        help="emit only the reorder items JSON array")
    args = parser.parse_args()

    init_db()

    use_arduino = bool(os.environ.get("ARDUINO_URL")) and not args.dummy
    if use_arduino:
        try:
            counts = poll_arduino()
            source = "arduino"
        except Exception as e:
            print(f"ERROR: Arduino unreachable: {e}", file=sys.stderr)
            return 1
    else:
        counts = dummy_counts()
        source = "dummy"

    if args.dry_run:
        payload = {"source": source, "dry_run": True,
                   "counts": [c.model_dump() for c in counts]}
        if args.json:
            print(json.dumps(payload, indent=2))
        else:
            print(f"[dry-run] {source} counts for {len(counts)} bin(s):")
            for c in counts:
                print(f"  bin {c.bin_id}: {c.count}")
            print("[dry-run] DB not modified")
        return 0

    result = apply_counts(counts, source=source)
    reorder = [r.model_dump() for r in result.reorder_items]

    if args.reorder_only:
        print(json.dumps(reorder))
        return 0

    if args.json:
        print(json.dumps(result.model_dump(), indent=2))
    else:
        print(f"Source: {source}  -  {result.bins_seen} bin(s) reported")
        for c in counts:
            print(f"  bin {c.bin_id}: {c.count}")
        print(f"Updated {result.items_updated} item(s) in the DB.")
        if reorder:
            print(f"\n{len(reorder)} item(s) need reordering:")
            for r in reorder:
                name = " ".join(x for x in (r.get("color"), r["item_name"]) if x)
                print(f"  - {name} (qty {r['quantity']}, bin {r.get('bin_id')})")
        else:
            print("\nNothing to reorder.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
