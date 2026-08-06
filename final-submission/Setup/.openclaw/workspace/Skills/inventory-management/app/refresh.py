"""Inventory Refresh — the 'Refresh (CRON JOB)' node from Diagram 2.

On a schedule, the PC polls the Arduino (which runs YOLOv8 vision over the
shelf) for per-bin item counts, then reconciles them into the shared inventory
DB. The vision count is treated as truth: each bin's `quantity` is SET to what
the Arduino sees. After syncing, a reorder check collects items at/below a
threshold into a missing-items list (same shape the Cost Estimator and Amazon
URL Builder consume).

Config (env vars):
    ARDUINO_URL              base URL of the Arduino vision service. If unset, a
                             DUMMY generator is used instead (see dummy_counts)
                             so the full refresh flow is testable without hardware.
    REFRESH_INTERVAL_SECONDS polling interval for external schedulers (default 300).
    REORDER_THRESHOLD        quantity at/below which an item is flagged to reorder
                             (default 5).

Arduino contract:
    GET {ARDUINO_URL}/bins -> [{"bin_id": "A1", "count": 42}, ...]
"""
import os
import random
from typing import Optional

import httpx
from pydantic import BaseModel, Field

from database.db import get_conn


class BinCount(BaseModel):
    """One bin's YOLO vision count from the Arduino."""
    bin_id: str
    count: int = Field(ge=0)


class ReorderItem(BaseModel):
    """An item at/below the reorder threshold — feeds the Amazon URL builder."""
    item_name: str
    color: Optional[str] = None
    quantity: int
    bin_id: Optional[str] = None


class RefreshResult(BaseModel):
    source: str                 # "arduino" or "dummy" — where the counts came from
    bins_seen: int
    items_updated: int          # rows whose quantity changed
    reorder_items: list[ReorderItem]


def _threshold() -> int:
    try:
        return int(os.environ.get("REORDER_THRESHOLD", "5"))
    except ValueError:
        return 5


def dummy_counts() -> list[BinCount]:
    """Generate plausible shelf counts for every bin currently in the DB.

    Stands in for the Arduino's YOLOv8 vision so the whole refresh path can be
    exercised without hardware. Counts are random but deliberately spread across
    the reorder threshold, so each run produces a mix of well-stocked and
    low-stock bins (i.e. a non-empty reorder list most of the time).
    """
    with get_conn() as conn:
        bins = [r["bin_id"] for r in conn.execute(
            "SELECT DISTINCT bin_id FROM items WHERE bin_id IS NOT NULL ORDER BY bin_id"
        ).fetchall()]

    threshold = _threshold()
    counts: list[BinCount] = []
    for i, bin_id in enumerate(bins):
        # Alternate: some bins land at/below the threshold, others well above it.
        if i % 2 == 0:
            counts.append(BinCount(bin_id=bin_id, count=random.randint(0, threshold)))
        else:
            counts.append(BinCount(bin_id=bin_id, count=random.randint(threshold + 10, 200)))
    return counts


def poll_arduino() -> list[BinCount]:
    """Fetch per-bin vision counts from the Arduino. Raises if unreachable."""
    base = os.environ.get("ARDUINO_URL")
    if not base:
        raise RuntimeError("ARDUINO_URL is not set")
    resp = httpx.get(f"{base.rstrip('/')}/bins", timeout=15)
    resp.raise_for_status()
    return [BinCount.model_validate(b) for b in resp.json()]


def apply_counts(counts: list[BinCount], source: str = "arduino") -> RefreshResult:
    """Set each bin's quantity to its vision count, then run the reorder check.

    Vision count is authoritative (set, not delta). Only rows whose quantity
    actually changes are counted as updated. Bins with no matching item row are
    ignored (the item must be created first via invoice upload or the API).
    """
    updated = 0
    with get_conn() as conn:
        for bc in counts:
            cur = conn.execute(
                """UPDATE items
                   SET quantity = ?, updated_at = datetime('now')
                   WHERE bin_id = ? AND quantity != ?""",
                (bc.count, bc.bin_id, bc.count),
            )
            updated += cur.rowcount

        threshold = _threshold()
        rows = conn.execute(
            """SELECT item_name, color, quantity, bin_id FROM items
               WHERE quantity <= ? ORDER BY quantity, item_name""",
            (threshold,),
        ).fetchall()

    reorder = [ReorderItem(**dict(r)) for r in rows]
    return RefreshResult(source=source, bins_seen=len(counts),
                         items_updated=updated, reorder_items=reorder)


def refresh_from_arduino() -> RefreshResult:
    """Full refresh cycle: get counts, then reconcile into the DB.

    Uses the real Arduino when ARDUINO_URL is set; otherwise falls back to
    generated dummy counts so the flow works end-to-end without hardware. The
    result's `source` field says which was used.
    """
    if os.environ.get("ARDUINO_URL"):
        return apply_counts(poll_arduino(), source="arduino")
    return apply_counts(dummy_counts(), source="dummy")
