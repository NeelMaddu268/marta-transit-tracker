"""The polling collector loop.

Polls both MARTA feeds on an interval, normalizes to the unified schema, and
writes to SQLite. Built to run unattended: each feed is fetched independently so
one failing doesn't sink the other, failures are logged and retried on the next
tick, and the loop never dies on a transient error.

Run:  python -m collector.collector
"""

import logging
import signal
import sqlite3
import time

from . import config, feeds
from .gtfs_static import Schedule
from .storage import Storage

log = logging.getLogger("collector")


class Collector:
    def __init__(self):
        self.storage = Storage(config.DB_PATH)
        # The schedule shares the storage DB file but uses its own connection so
        # the bulk lookup queries don't contend with write transactions.
        sched_conn = sqlite3.connect(config.DB_PATH, check_same_thread=False)
        sched_conn.execute("PRAGMA journal_mode=WAL;")
        self.schedule = Schedule(sched_conn)
        self._running = True

    def setup(self):
        """One-time startup: make sure the static schedule is loaded."""
        self.schedule.ensure_loaded()

    def poll_once(self):
        """Run a single poll of both feeds. Returns (bus_rows, rail_rows)."""
        now = int(time.time())
        bus_written = rail_written = 0

        try:
            bus_obs = feeds.fetch_bus(now, schedule=self.schedule)
            bus_written = self.storage.insert_observations(bus_obs)
            log.info("bus: %d observations, %d new rows", len(bus_obs), bus_written)
        except Exception:
            log.exception("bus poll failed; will retry next tick")

        try:
            rail_obs = feeds.fetch_rail(now)
            rail_written = self.storage.insert_observations(rail_obs)
            log.info("rail: %d observations, %d new rows", len(rail_obs), rail_written)
        except Exception:
            log.exception("rail poll failed; will retry next tick")

        return bus_written, rail_written

    def run(self):
        self.setup()
        log.info("collector started; polling every %ds", config.POLL_INTERVAL_SECONDS)
        last_schedule_check = time.time()
        while self._running:
            tick_started = time.time()
            # Refresh the static schedule roughly daily; ensure_loaded() only
            # actually re-downloads when the local copy is >1 week old.
            if tick_started - last_schedule_check > 24 * 3600:
                last_schedule_check = tick_started
                try:
                    self.schedule.ensure_loaded()
                except Exception:
                    log.exception("scheduled static-feed refresh failed; continuing")
            try:
                self.poll_once()
            except Exception:
                # Defensive: poll_once already catches per-feed errors, but never
                # let anything kill the loop.
                log.exception("unexpected error in poll cycle")
            # Sleep the remainder of the interval, responsive to shutdown.
            elapsed = time.time() - tick_started
            remaining = max(0.0, config.POLL_INTERVAL_SECONDS - elapsed)
            slept = 0.0
            while self._running and slept < remaining:
                time.sleep(min(1.0, remaining - slept))
                slept += 1.0
        log.info("collector stopped")

    def stop(self, *_):
        log.info("shutdown requested")
        self._running = False

    def close(self):
        self.storage.close()


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    collector = Collector()
    signal.signal(signal.SIGINT, collector.stop)
    signal.signal(signal.SIGTERM, collector.stop)
    try:
        collector.run()
    finally:
        collector.close()


if __name__ == "__main__":
    main()
