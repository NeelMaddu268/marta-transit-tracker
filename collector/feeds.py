"""Fetch and normalize both MARTA feeds into the unified observation schema.

Observation dict shape:
    source, route, stop, direction, vehicle_id, trip_id,
    scheduled_time, actual_time, delay_seconds, latitude, longitude, timestamp

Notes on the two sources:
  * Bus (GTFS-RT): vehicle positions carry lat/long but NOT current stop or
    delay. Trip updates carry per-stop delay but no position. We take each
    trip's current delay from its next-upcoming stop-time-update and join to
    the vehicle-position feed on trip_id for lat/long.
  * Rail (REST JSON): each row is already a train-at-station arrival with a
    delay. We compute epoch times from WAITING_SECONDS to avoid timezone/clock
    parsing of the string fields.
"""

import re

import requests
from google.transit import gtfs_realtime_pb2

from . import config


def _plausible_delay(delay):
    """Null out delays too large to be real (feed/schedule-match noise)."""
    if delay is None or abs(delay) > config.MAX_PLAUSIBLE_DELAY_SECONDS:
        return None
    return delay


def _parse_feed(url: str) -> gtfs_realtime_pb2.FeedMessage:
    resp = requests.get(url, timeout=config.HTTP_TIMEOUT_SECONDS)
    resp.raise_for_status()
    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(resp.content)
    return feed


def _stop_time(stu):
    """Return (epoch_time, delay) for a stop_time_update, preferring arrival."""
    if stu.HasField("arrival") and stu.arrival.time:
        return stu.arrival.time, (stu.arrival.delay if stu.arrival.HasField("delay") else None)
    if stu.HasField("departure") and stu.departure.time:
        return stu.departure.time, (stu.departure.delay if stu.departure.HasField("delay") else None)
    return None, None


def _current_stop(trip_update, now: int):
    """Pick the representative 'current' stop for a trip: the first upcoming
    stop-time-update (time >= now), falling back to the last one if the trip is
    at/near its end. Returns (stop_id, epoch_time, delay) or None."""
    stus = list(trip_update.stop_time_update)
    if not stus:
        return None
    for stu in stus:
        t, d = _stop_time(stu)
        if t is not None and t >= now:
            return stu.stop_id, t, d
    # No future stop found — use the last stop with a resolvable time.
    for stu in reversed(stus):
        t, d = _stop_time(stu)
        if t is not None:
            return stu.stop_id, t, d
    return None


def fetch_bus(now: int, schedule=None):
    """Fetch both bus feeds and return normalized observations for this poll.

    `schedule` is an optional gtfs_static.Schedule used to compute delay from
    the static timetable, since the RT feed never populates the delay field.
    """
    veh_feed = _parse_feed(config.BUS_VEHICLE_URL)
    tu_feed = _parse_feed(config.BUS_TRIPUPDATE_URL)
    return normalize_bus(veh_feed, tu_feed, now, schedule)


def normalize_bus(veh_feed, tu_feed, now: int, schedule=None):
    """Pure normalization of already-parsed bus feeds into observations."""
    # trip_id -> (lat, lon, vehicle_id) from the position feed.
    positions = {}
    for e in veh_feed.entity:
        if not e.HasField("vehicle"):
            continue
        v = e.vehicle
        if not v.trip.trip_id:
            continue
        lat = v.position.latitude if v.HasField("position") else None
        lon = v.position.longitude if v.HasField("position") else None
        positions[v.trip.trip_id] = (lat, lon, v.vehicle.id or None)

    observations = []
    for e in tu_feed.entity:
        if not e.HasField("trip_update"):
            continue
        tu = e.trip_update
        trip_id = tu.trip.trip_id or None
        cur = _current_stop(tu, now)
        if cur is None:
            continue
        stop_id, arr_time, delay = cur
        scheduled = (arr_time - delay) if (arr_time is not None and delay is not None) else None
        # RT feed omits delay for MARTA buses; derive it from the static schedule.
        if delay is None and schedule is not None and trip_id and stop_id and arr_time is not None:
            scheduled = schedule.scheduled_epoch(trip_id, stop_id, arr_time)
            if scheduled is not None:
                delay = arr_time - scheduled
        # Drop implausible delays (and the scheduled time they imply) as noise.
        if _plausible_delay(delay) is None:
            delay = None
            scheduled = None
        lat, lon, vehicle_id = positions.get(trip_id, (None, None, None))
        # Trip updates sometimes carry their own vehicle id; prefer it.
        if tu.HasField("vehicle") and tu.vehicle.id:
            vehicle_id = tu.vehicle.id
        observations.append({
            "source": "bus",
            "route": tu.trip.route_id or None,
            "stop": stop_id or None,
            "direction": None,
            "vehicle_id": vehicle_id,
            "trip_id": trip_id,
            "scheduled_time": scheduled,
            "actual_time": arr_time,
            "delay_seconds": delay,
            "latitude": lat,
            "longitude": lon,
            "timestamp": now,
        })
    return observations


_RAIL_DELAY_RE = re.compile(r"^T(-?\d+)S$")


def _parse_rail_delay(raw):
    """Rail DELAY is 'T<seconds>S' (e.g. 'T93S' late, 'T-3S' early). None if absent."""
    if not raw:
        return None
    m = _RAIL_DELAY_RE.match(raw.strip())
    return int(m.group(1)) if m else None


def _to_float(raw):
    try:
        return float(raw)
    except (TypeError, ValueError):
        return None


def _to_int(raw):
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def fetch_rail(now: int):
    """Return a list of normalized rail observations for this poll."""
    if not config.RAIL_API_KEY:
        raise RuntimeError("MARTA_RAIL_API_KEY is not set; cannot fetch rail feed")
    url = config.RAIL_URL_TEMPLATE.format(key=config.RAIL_API_KEY)
    resp = requests.get(url, timeout=config.HTTP_TIMEOUT_SECONDS)
    resp.raise_for_status()
    return normalize_rail(resp.json(), now)


def normalize_rail(data, now: int):
    """Pure normalization of the rail JSON payload into observations."""
    observations = []
    for r in data:
        delay = _plausible_delay(_parse_rail_delay(r.get("DELAY")))
        waiting = _to_int(r.get("WAITING_SECONDS"))
        # Predicted arrival as an epoch: poll time + seconds-until-arrival.
        actual = (now + waiting) if waiting is not None else None
        scheduled = (actual - delay) if (actual is not None and delay is not None) else None
        observations.append({
            "source": "rail",
            "route": r.get("LINE"),
            "stop": r.get("STATION"),
            "direction": r.get("DIRECTION"),
            "vehicle_id": r.get("TRAIN_ID"),
            "trip_id": None,
            "scheduled_time": scheduled,
            "actual_time": actual,
            "delay_seconds": delay,
            "latitude": _to_float(r.get("LATITUDE")),
            "longitude": _to_float(r.get("LONGITUDE")),
            "timestamp": now,
        })
    return observations
