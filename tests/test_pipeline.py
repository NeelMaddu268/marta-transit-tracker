"""Correctness tests for the collector data pipeline.

These lock in the behavior of the irreplaceable historical dataset. Two of them
guard bugs already found and fixed during development:
  * scheduled_epoch must anchor on Eastern (not UTC) midnight.
  * the dedup key must treat NULL trip_id/delay as equal (COALESCE), or rail
    rows never dedup.
"""

import sqlite3
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from google.transit import gtfs_realtime_pb2

from collector import feeds
from collector.api import _percentile, _delay_group_stats, _route_delay_stats, _leg_delay
from collector.gtfs_static import Schedule, AGENCY_TZ
from collector.maintenance import prune, stats
from collector.storage import Storage

ET = ZoneInfo("America/New_York")


# --------------------------------------------------------------------------
# Rail delay parsing
# --------------------------------------------------------------------------

@pytest.mark.parametrize("raw,expected", [
    ("T93S", 93),
    ("T0S", 0),
    ("T-3S", -3),
    ("T-28S", -28),
    (" T99S ", 99),      # surrounding whitespace tolerated
    (None, None),
    ("", None),
    ("garbage", None),
    ("93", None),        # missing T..S wrapper
])
def test_parse_rail_delay(raw, expected):
    assert feeds._parse_rail_delay(raw) == expected


# --------------------------------------------------------------------------
# Plausibility clamp
# --------------------------------------------------------------------------

@pytest.mark.parametrize("value,expected", [
    (0, 0),
    (600, 600),
    (-600, -600),
    (3600, 3600),
    (3601, None),        # just past the bound
    (-3601, None),
    (100000, None),
    (None, None),
])
def test_plausible_delay(value, expected):
    assert feeds._plausible_delay(value) == expected


# --------------------------------------------------------------------------
# scheduled_epoch: Eastern-time anchoring + service-day selection
# --------------------------------------------------------------------------

def _make_schedule(rows):
    conn = sqlite3.connect(":memory:")
    sched = Schedule(conn)
    conn.executemany("INSERT INTO schedule VALUES (?,?,?)", rows)
    conn.commit()
    return sched


def test_scheduled_epoch_is_eastern_not_utc():
    # 08:30:00 local = 30600 seconds since service midnight.
    secs = 8 * 3600 + 30 * 60
    sched = _make_schedule([("T1", "S1", secs)])

    # The scheduled instant we expect: 2026-07-10 08:30 America/New_York.
    expected_dt = datetime(2026, 7, 10, 8, 30, 0, tzinfo=ET)
    expected_epoch = int(expected_dt.timestamp())

    # Query near that time (bus predicted to arrive ~30s late).
    near = expected_epoch + 30
    got = sched.scheduled_epoch("T1", "S1", near)
    assert got == expected_epoch
    # A UTC-anchored bug would be off by the 4-5h ET offset.
    assert abs(got - expected_epoch) < 2


def test_scheduled_epoch_picks_correct_service_day():
    secs = 8 * 3600 + 30 * 60  # 08:30 local
    sched = _make_schedule([("T1", "S1", secs)])
    # Ask about a time three days later; it should resolve to THAT day's 08:30,
    # not the seed day's.
    day3 = datetime(2026, 7, 13, 8, 31, 0, tzinfo=ET)
    got = sched.scheduled_epoch("T1", "S1", int(day3.timestamp()))
    expected = int(datetime(2026, 7, 13, 8, 30, 0, tzinfo=ET).timestamp())
    assert got == expected


def test_scheduled_epoch_after_midnight_rollover():
    # GTFS time 25:15:00 (1:15am on the *next* calendar day) for a late-night run.
    secs = 25 * 3600 + 15 * 60
    sched = _make_schedule([("T1", "S1", secs)])
    # A bus actually arriving ~1:15am on 2026-07-11 belongs to service day 07-10.
    arrival = datetime(2026, 7, 11, 1, 15, 0, tzinfo=ET)
    got = sched.scheduled_epoch("T1", "S1", int(arrival.timestamp()))
    assert abs(got - int(arrival.timestamp())) < 2


def test_scheduled_epoch_unknown_pair():
    sched = _make_schedule([("T1", "S1", 100)])
    assert sched.scheduled_epoch("nope", "nope", 1_780_000_000) is None


# --------------------------------------------------------------------------
# Storage dedup incl. NULL coalesce (the rail dedup bug)
# --------------------------------------------------------------------------

def _obs(**over):
    base = dict(
        source="rail", route="RED", stop="FIVE POINTS", direction="N",
        vehicle_id="401", trip_id=None, scheduled_time=100, actual_time=160,
        delay_seconds=60, latitude=33.7, longitude=-84.4, timestamp=1000,
    )
    base.update(over)
    return base


def test_dedup_suppresses_identical_rail_rows(tmp_path):
    store = Storage(tmp_path / "t.db")
    # trip_id is None for rail — must still dedup (COALESCE in the unique index).
    n1 = store.insert_observations([_obs()])
    n2 = store.insert_observations([_obs(timestamp=1045)])  # same key, later poll
    assert n1 == 1
    assert n2 == 0, "identical rail observation (NULL trip_id) should dedup"
    total = store.conn.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
    assert total == 1
    store.close()


def test_dedup_new_row_when_delay_changes(tmp_path):
    store = Storage(tmp_path / "t.db")
    store.insert_observations([_obs(delay_seconds=60)])
    store.insert_observations([_obs(delay_seconds=90)])   # delay changed
    total = store.conn.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
    assert total == 2
    store.close()


def test_dedup_direction_distinguishes(tmp_path):
    store = Storage(tmp_path / "t.db")
    store.insert_observations([_obs(direction="N", delay_seconds=None)])
    store.insert_observations([_obs(direction="S", delay_seconds=None)])
    total = store.conn.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
    assert total == 2, "opposite directions are distinct arrivals"
    store.close()


def test_dedup_null_delay_rows_collapse(tmp_path):
    store = Storage(tmp_path / "t.db")
    # Two unknown-delay observations for the same train/station/direction.
    store.insert_observations([_obs(delay_seconds=None, timestamp=1000)])
    store.insert_observations([_obs(delay_seconds=None, timestamp=1100)])
    total = store.conn.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
    assert total == 1, "NULL delay must coalesce, not count as always-distinct"
    store.close()


# --------------------------------------------------------------------------
# Rail normalization
# --------------------------------------------------------------------------

def test_normalize_rail_basic():
    now = 1_780_000_000
    data = [{
        "LINE": "RED", "STATION": "AIRPORT STATION", "DIRECTION": "N",
        "TRAIN_ID": "401", "WAITING_SECONDS": "60", "DELAY": "T93S",
        "LATITUDE": "33.64", "LONGITUDE": "-84.44",
    }]
    obs = feeds.normalize_rail(data, now)
    assert len(obs) == 1
    o = obs[0]
    assert o["source"] == "rail"
    assert o["delay_seconds"] == 93
    assert o["actual_time"] == now + 60
    assert o["scheduled_time"] == now + 60 - 93
    assert o["latitude"] == pytest.approx(33.64)


def test_normalize_rail_clamps_and_nulls():
    now = 1_780_000_000
    data = [{
        "LINE": "GOLD", "STATION": "DORAVILLE", "DIRECTION": "S",
        "TRAIN_ID": "", "WAITING_SECONDS": None, "DELAY": "T99999S",  # implausible
        "LATITUDE": None, "LONGITUDE": None,
    }]
    obs = feeds.normalize_rail(data, now)
    o = obs[0]
    assert o["delay_seconds"] is None      # clamped away
    assert o["actual_time"] is None        # no waiting seconds
    assert o["scheduled_time"] is None
    assert o["latitude"] is None


# --------------------------------------------------------------------------
# Bus normalization (synthetic feeds, no network)
# --------------------------------------------------------------------------

class _FakeSchedule:
    """Returns a fixed scheduled epoch so delay = arr_time - scheduled."""
    def __init__(self, scheduled):
        self._scheduled = scheduled

    def scheduled_epoch(self, trip_id, stop_id, near):
        return self._scheduled


def _bus_feeds(now):
    """Build a vehicle-positions feed and a trip-updates feed for one trip."""
    veh = gtfs_realtime_pb2.FeedMessage()
    veh.header.gtfs_realtime_version = "2.0"
    e = veh.entity.add()
    e.id = "v1"
    e.vehicle.trip.trip_id = "T1"
    e.vehicle.trip.route_id = "99"
    e.vehicle.vehicle.id = "BUS1"
    e.vehicle.position.latitude = 33.75
    e.vehicle.position.longitude = -84.39

    tu = gtfs_realtime_pb2.FeedMessage()
    tu.header.gtfs_realtime_version = "2.0"
    te = tu.entity.add()
    te.id = "t1"
    te.trip_update.trip.trip_id = "T1"
    te.trip_update.trip.route_id = "99"
    stu = te.trip_update.stop_time_update.add()
    stu.stop_sequence = 5
    stu.stop_id = "S1"
    stu.arrival.time = now + 300          # 5 min out, no delay field set
    return veh, tu


def test_normalize_bus_computes_delay_from_schedule():
    now = 1_780_000_000
    veh, tu = _bus_feeds(now)
    # Scheduled 120s before predicted arrival -> delay should be +120.
    sched = _FakeSchedule(scheduled=(now + 300) - 120)
    obs = feeds.normalize_bus(veh, tu, now, schedule=sched)
    assert len(obs) == 1
    o = obs[0]
    assert o["source"] == "bus"
    assert o["route"] == "99"
    assert o["stop"] == "S1"
    assert o["vehicle_id"] == "BUS1"
    assert o["delay_seconds"] == 120
    assert o["scheduled_time"] == now + 180
    assert o["actual_time"] == now + 300
    assert o["latitude"] == pytest.approx(33.75, abs=1e-4)


def test_normalize_bus_without_schedule_has_null_delay():
    now = 1_780_000_000
    veh, tu = _bus_feeds(now)
    obs = feeds.normalize_bus(veh, tu, now, schedule=None)
    assert obs[0]["delay_seconds"] is None
    # Position still joins from the vehicle feed.
    assert obs[0]["vehicle_id"] == "BUS1"


def test_normalize_bus_position_joins_by_trip():
    now = 1_780_000_000
    veh, tu = _bus_feeds(now)
    obs = feeds.normalize_bus(veh, tu, now, schedule=None)
    assert obs[0]["latitude"] is not None
    assert obs[0]["longitude"] is not None


# --------------------------------------------------------------------------
# Maintenance
# --------------------------------------------------------------------------

def test_prune_deletes_only_old_rows(tmp_path):
    store = Storage(tmp_path / "t.db")
    now = 1_780_000_000
    old_ts = now - 10 * 86400
    store.insert_observations([_obs(timestamp=old_ts, delay_seconds=1)])
    store.insert_observations([_obs(timestamp=now, delay_seconds=2)])
    deleted = prune(store.conn, days=7, now=now)
    assert deleted == 1
    s = stats(store.conn)
    assert s["rows"] == 1
    assert s["newest"] == now
    store.close()


# --------------------------------------------------------------------------
# Stats helpers
# --------------------------------------------------------------------------

def test_percentile():
    vals = list(range(1, 101))  # 1..100, pre-sorted
    assert _percentile(vals, 0.0) == 1
    # nearest-rank: index round(0.5*99)=50 -> value 51 (true median 50.5)
    assert _percentile(vals, 0.5) == 51
    assert _percentile(vals, 0.9) == 90
    assert _percentile(vals, 1.0) == 100
    assert _percentile([], 0.5) == 0
    assert _percentile([42], 0.5) == 42


def _seed_route(store, route, delays, source="bus"):
    for i, d in enumerate(delays):
        store.insert_observations([_obs(
            source=source, route=route, stop=f"S{i}", vehicle_id=f"v{i}",
            trip_id=f"t{i}", direction=None, delay_seconds=d,
        )])


def test_route_delay_stats_computes(tmp_path):
    store = Storage(tmp_path / "t.db")
    _seed_route(store, "2", [0, 120, 600, -30])  # on-time (|d|<=60): 0 and -30 -> 2/4
    s = _route_delay_stats(store.conn, {"2"}, None)
    assert s["samples"] == 4
    assert s["basis"] == "route"
    assert s["on_time_pct"] == 50.0
    assert s["median_seconds"] == _percentile([-30, 0, 120, 600], 0.5)
    assert _route_delay_stats(store.conn, {"NOPE"}, None) is None
    store.close()


def test_leg_delay_matches_by_shortname_gtfsid_and_case(tmp_path):
    store = Storage(tmp_path / "t.db")
    _seed_route(store, "2", [60, 120])
    _seed_route(store, "RED", [30, 45], source="rail")
    # bus: match by shortName and by gtfsId suffix ("MARTA:2" -> "2")
    assert _leg_delay(store.conn, {"shortName": "2"}, None)["samples"] == 2
    assert _leg_delay(store.conn, {"gtfsId": "MARTA:2"}, None)["samples"] == 2
    # rail: case-insensitive match on longName
    assert _leg_delay(store.conn, {"longName": "red"}, None)["samples"] == 2
    # no history -> None (graceful)
    assert _leg_delay(store.conn, {"shortName": "999"}, None) is None
    assert _leg_delay(store.conn, {}, None) is None
    store.close()


def test_delay_group_stats():
    # 10 values: 4 on-time, 4 late, 2 early.
    delays = [-120, -90, -30, 0, 30, 60, 120, 300, 600, 1200]
    s = _delay_group_stats("R", delays)
    assert s["n"] == 10
    assert s["min_delay"] == -120
    assert s["max_delay"] == 1200
    # on-time = within +/-60: -30,0,30,60 -> 4
    assert s["on_time_pct"] == 40.0
    # late > 60: 120,300,600,1200 -> 4
    assert s["late_pct"] == 40.0
    # early < -60: -120,-90 -> 2
    assert s["early_pct"] == 20.0
    assert s["median_delay"] == _percentile(sorted(delays), 0.5)
