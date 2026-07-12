"""DB maintenance for the collector's SQLite store.

The observations table is the historical training set, so nothing is deleted
unless you explicitly ask. Growth is roughly 60-80 MB/day of active service.

    python -m collector.maintenance                # report sizes/counts
    python -m collector.maintenance --vacuum       # reclaim free pages
    python -m collector.maintenance --prune-days N # DELETE rows older than N days
"""

import argparse
import os
import sqlite3
import time

from . import config


def stats(conn: sqlite3.Connection) -> dict:
    row = conn.execute(
        "SELECT COUNT(*), MIN(timestamp), MAX(timestamp) FROM observations"
    ).fetchone()
    return {"rows": row[0], "oldest": row[1], "newest": row[2]}


def prune(conn: sqlite3.Connection, days: int, now: int | None = None) -> int:
    """Delete observations older than `days`. Returns rows deleted."""
    cutoff = (now or int(time.time())) - days * 86400
    cur = conn.execute("DELETE FROM observations WHERE timestamp < ?", (cutoff,))
    conn.commit()
    return cur.rowcount


def vacuum(conn: sqlite3.Connection):
    conn.execute("VACUUM")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vacuum", action="store_true", help="reclaim free pages")
    parser.add_argument("--prune-days", type=int, metavar="N",
                        help="delete observations older than N days (irreversible)")
    args = parser.parse_args()

    size_before = os.path.getsize(config.DB_PATH)
    conn = sqlite3.connect(config.DB_PATH)
    s = stats(conn)
    span_days = (s["newest"] - s["oldest"]) / 86400 if s["rows"] else 0
    print(f"db: {config.DB_PATH} ({size_before / 1e6:.1f} MB)")
    print(f"observations: {s['rows']:,} spanning {span_days:.1f} days")

    if args.prune_days:
        deleted = prune(conn, args.prune_days)
        print(f"pruned {deleted:,} rows older than {args.prune_days} days")

    if args.vacuum or args.prune_days:
        print("vacuuming...")
        vacuum(conn)
        conn.close()
        size_after = os.path.getsize(config.DB_PATH)
        print(f"size: {size_before / 1e6:.1f} MB -> {size_after / 1e6:.1f} MB")
    else:
        conn.close()


if __name__ == "__main__":
    main()
