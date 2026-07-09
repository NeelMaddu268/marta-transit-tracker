"""GTFS static schedule: download, load into SQLite, and look up scheduled times.

MARTA bus trip updates give predicted arrival times but no delay, so we compute
delay = predicted - scheduled. Scheduled times come from static stop_times.txt,
keyed by (trip_id, stop_id). The join is clean (verified 369/369 RT trips and
all (trip,stop) pairs present in static).

arrival_time in GTFS is a time-of-day that may exceed 24:00:00 for trips that
run past midnight, so we store it as seconds-since-service-midnight and resolve
the actual calendar service day at query time by picking the candidate day that
puts the scheduled time closest to the observed (predicted) time.
"""

import csv
import logging
import sys
import time
import zipfile
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import requests

from . import config

log = logging.getLogger("collector.gtfs_static")

# MARTA operates on Eastern time; GTFS static times are local clock times.
AGENCY_TZ = ZoneInfo("America/New_York")

GTFS_STATIC_URL = "https://www.itsmarta.com/google_transit_feed/google_transit.zip"
STATIC_DIR = config.ROOT / "data" / "gtfs_static"
ZIP_PATH = STATIC_DIR / "google_transit.zip"

# Refresh the static feed if the loaded copy is older than this.
STATIC_MAX_AGE_SECONDS = 7 * 24 * 3600

DAY_SECONDS = 86400

SCHEDULE_SCHEMA = """
CREATE TABLE IF NOT EXISTS schedule (
    trip_id         TEXT NOT NULL,
    stop_id         TEXT NOT NULL,
    arrival_seconds INTEGER NOT NULL,   -- seconds since service-day midnight
    PRIMARY KEY (trip_id, stop_id)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS schedule_meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
"""


def _parse_gtfs_time(hms: str):
    """'HH:MM:SS' (H may be >= 24) -> seconds since service midnight, or None."""
    try:
        h, m, s = hms.split(":")
        return int(h) * 3600 + int(m) * 60 + int(s)
    except (ValueError, AttributeError):
        return None


def download_static(force: bool = False) -> bool:
    """Download the GTFS static zip if missing/stale. Returns True if fetched."""
    STATIC_DIR.mkdir(parents=True, exist_ok=True)
    if not force and ZIP_PATH.exists():
        age = time.time() - ZIP_PATH.stat().st_mtime
        if age < STATIC_MAX_AGE_SECONDS:
            return False
    log.info("downloading GTFS static feed...")
    resp = requests.get(GTFS_STATIC_URL, timeout=120, stream=True)
    resp.raise_for_status()
    tmp = ZIP_PATH.with_suffix(".zip.tmp")
    with open(tmp, "wb") as fh:
        for chunk in resp.iter_content(chunk_size=1 << 16):
            fh.write(chunk)
    tmp.replace(ZIP_PATH)
    log.info("downloaded GTFS static (%d bytes)", ZIP_PATH.stat().st_size)
    return True


class Schedule:
    """Scheduled-arrival lookup backed by the collector's SQLite connection."""

    def __init__(self, conn):
        self.conn = conn
        conn.executescript(SCHEDULE_SCHEMA)
        conn.commit()

    def _loaded_version(self):
        row = self.conn.execute(
            "SELECT value FROM schedule_meta WHERE key='zip_mtime'"
        ).fetchone()
        return row[0] if row else None

    def ensure_loaded(self, force_reload: bool = False):
        """Download static feed if stale and (re)load stop_times into SQLite if
        the loaded copy doesn't match the current zip."""
        fetched = download_static()
        if not ZIP_PATH.exists():
            raise RuntimeError("GTFS static zip missing and download failed")
        zip_mtime = str(int(ZIP_PATH.stat().st_mtime))
        if not force_reload and self._loaded_version() == zip_mtime:
            count = self.conn.execute("SELECT COUNT(*) FROM schedule").fetchone()[0]
            log.info("schedule already loaded (%d rows)", count)
            return
        self._load_stop_times(zip_mtime)

    def _load_stop_times(self, zip_mtime: str):
        log.info("loading stop_times.txt into schedule table (this takes a bit)...")
        started = time.time()
        self.conn.execute("DELETE FROM schedule")
        rows = []
        inserted = 0
        with zipfile.ZipFile(ZIP_PATH) as zf:
            with zf.open("stop_times.txt") as raw:
                text = (line.decode("utf-8") for line in raw)
                reader = csv.DictReader(text)
                for r in reader:
                    secs = _parse_gtfs_time(r["arrival_time"])
                    if secs is None:
                        continue
                    rows.append((r["trip_id"], r["stop_id"], secs))
                    if len(rows) >= 50000:
                        self.conn.executemany(
                            "INSERT OR REPLACE INTO schedule VALUES (?,?,?)", rows
                        )
                        inserted += len(rows)
                        rows.clear()
        if rows:
            self.conn.executemany(
                "INSERT OR REPLACE INTO schedule VALUES (?,?,?)", rows
            )
            inserted += len(rows)
        self.conn.execute(
            "INSERT OR REPLACE INTO schedule_meta VALUES ('zip_mtime', ?)", (zip_mtime,)
        )
        self.conn.commit()
        log.info("loaded %d schedule rows in %.1fs", inserted, time.time() - started)

    def scheduled_epoch(self, trip_id: str, stop_id: str, near_epoch: int):
        """Return the scheduled arrival epoch for (trip_id, stop_id), choosing
        the service day that lands closest to near_epoch. None if not scheduled."""
        row = self.conn.execute(
            "SELECT arrival_seconds FROM schedule WHERE trip_id=? AND stop_id=?",
            (trip_id, stop_id),
        ).fetchone()
        if row is None:
            return None
        secs = row[0]
        # Anchor to Eastern-local midnight of near_epoch (GTFS times are local
        # clock times), then test +/- a day so we pick the correct service day
        # regardless of after-midnight (>24h) rollover.
        local_midnight = datetime.fromtimestamp(near_epoch, AGENCY_TZ).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        candidates = [
            (local_midnight + timedelta(days=offset)).timestamp() + secs
            for offset in (-1, 0, 1)
        ]
        return int(min(candidates, key=lambda e: abs(e - near_epoch)))


if __name__ == "__main__":
    # Manual load/refresh: python -m collector.gtfs_static
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    import sqlite3
    config.DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(config.DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL;")
    sched = Schedule(conn)
    sched.ensure_loaded(force_reload="--force" in sys.argv)
    print("schedule rows:", conn.execute("SELECT COUNT(*) FROM schedule").fetchone()[0])
