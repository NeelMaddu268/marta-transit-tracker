"""SQLite storage for normalized arrival/delay observations.

One table, `observations`, holds the unified schema for both bus and rail.
A UNIQUE natural key + INSERT OR IGNORE means we only keep a new row when a
given vehicle's delay at a given stop actually changes, rather than storing an
identical snapshot every poll. That keeps the historical dataset compact while
still capturing the full delay trajectory.
"""

import sqlite3
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS observations (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source          TEXT    NOT NULL,          -- 'bus' | 'rail'
    route           TEXT,                      -- bus route_id / rail LINE
    stop            TEXT,                      -- bus stop_id / rail STATION
    direction       TEXT,
    vehicle_id      TEXT,                      -- bus vehicle id / rail TRAIN_ID
    trip_id         TEXT,                      -- bus only
    scheduled_time  INTEGER,                   -- epoch seconds, nullable
    actual_time     INTEGER,                   -- epoch seconds (predicted arrival)
    delay_seconds   INTEGER,                   -- + late, - early
    latitude        REAL,
    longitude       REAL,
    timestamp       INTEGER NOT NULL           -- poll time, epoch seconds
);

-- Dedup key. Uses COALESCE because SQLite treats NULLs as distinct in a plain
-- UNIQUE constraint, which would defeat dedup for rail (trip_id NULL) and any
-- unknown-delay rows. A new row is only stored when a vehicle's delay at a stop
-- actually changes.
CREATE UNIQUE INDEX IF NOT EXISTS idx_obs_dedup ON observations (
    source,
    COALESCE(vehicle_id, ''),
    COALESCE(trip_id, ''),
    COALESCE(stop, ''),
    COALESCE(direction, ''),
    COALESCE(delay_seconds, -2147483648)
);

CREATE INDEX IF NOT EXISTS idx_obs_route_stop_ts
    ON observations (route, stop, timestamp);
CREATE INDEX IF NOT EXISTS idx_obs_source_ts
    ON observations (source, timestamp);
"""

_COLUMNS = (
    "source", "route", "stop", "direction", "vehicle_id", "trip_id",
    "scheduled_time", "actual_time", "delay_seconds", "latitude", "longitude",
    "timestamp",
)

_INSERT = (
    f"INSERT OR IGNORE INTO observations ({', '.join(_COLUMNS)}) "
    f"VALUES ({', '.join('?' for _ in _COLUMNS)})"
)


class Storage:
    def __init__(self, db_path: Path):
        db_path = Path(db_path)
        db_path.parent.mkdir(parents=True, exist_ok=True)
        # check_same_thread=False so the FastAPI process can open it read-only
        # from a request thread; the collector uses its own connection.
        self.conn = sqlite3.connect(db_path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL;")
        self.conn.execute("PRAGMA synchronous=NORMAL;")
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def insert_observations(self, observations) -> int:
        """Insert a batch of observation dicts. Returns rows actually inserted
        (dupes suppressed by the UNIQUE constraint are not counted)."""
        rows = [tuple(o.get(c) for c in _COLUMNS) for o in observations]
        before = self.conn.total_changes
        self.conn.executemany(_INSERT, rows)
        self.conn.commit()
        return self.conn.total_changes - before

    def close(self):
        self.conn.close()
