"""Local REST API over the collected data (FastAPI).

Read-only queries against the same SQLite DB the collector writes to. WAL mode
lets reads run concurrently with the collector's writes.

Endpoints:
  GET /health                         - liveness + row counts + freshness
  GET /positions                      - latest known position per vehicle/train
  GET /arrivals                       - recent observations, filterable
  GET /stats/delay                    - historical avg/median delay by group
  GET /plan                           - multimodal trip plan (via OTP) with each
                                        transit leg annotated with our history

Run:  python -m uvicorn collector.api:app --reload
      (or: python -m collector.api)
"""

import sqlite3
import time
from datetime import datetime
from typing import Optional

import requests
from fastapi import FastAPI, HTTPException, Query

from . import config

app = FastAPI(title="MARTA Tracker API", version="0.1.0")


def get_conn() -> sqlite3.Connection:
    # Read-only connection so API queries can never corrupt collected data.
    uri = f"file:{config.DB_PATH}?mode=ro"
    conn = sqlite3.connect(uri, uri=True, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def _rows(cur) -> list[dict]:
    return [dict(r) for r in cur.fetchall()]


@app.get("/health")
def health():
    try:
        conn = get_conn()
    except sqlite3.OperationalError:
        raise HTTPException(503, "database not available yet (collector not started?)")
    try:
        total = conn.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
        by_source = {
            r["source"]: r["n"]
            for r in conn.execute(
                "SELECT source, COUNT(*) n FROM observations GROUP BY source"
            )
        }
        latest = conn.execute("SELECT MAX(timestamp) FROM observations").fetchone()[0]
    except sqlite3.OperationalError:
        raise HTTPException(503, "observations table not ready yet")
    finally:
        conn.close()
    return {
        "status": "ok",
        "total_observations": total,
        "by_source": by_source,
        "latest_observation_epoch": latest,
        "seconds_since_latest": (int(time.time()) - latest) if latest else None,
    }


@app.get("/positions")
def positions(
    source: Optional[str] = Query(None, pattern="^(bus|rail)$"),
    max_age_seconds: int = Query(300, ge=30, le=3600),
):
    """Latest known position for each vehicle/train seen within max_age_seconds."""
    conn = get_conn()
    cutoff = int(time.time()) - max_age_seconds
    # Most recent row per (source, vehicle_id) that has a position.
    sql = """
        SELECT source, route, stop, direction, vehicle_id, trip_id,
               delay_seconds, latitude, longitude, actual_time, timestamp
        FROM observations o
        WHERE latitude IS NOT NULL AND timestamp >= ?
          AND timestamp = (
              SELECT MAX(timestamp) FROM observations o2
              WHERE o2.source = o.source AND o2.vehicle_id = o.vehicle_id
                AND o2.latitude IS NOT NULL
          )
    """
    params: list = [cutoff]
    if source:
        sql += " AND source = ?"
        params.append(source)
    sql += " GROUP BY source, vehicle_id ORDER BY source, route"
    try:
        result = _rows(conn.execute(sql, params))
    finally:
        conn.close()
    return {"count": len(result), "vehicles": result}


@app.get("/arrivals")
def arrivals(
    stop: Optional[str] = None,
    route: Optional[str] = None,
    source: Optional[str] = Query(None, pattern="^(bus|rail)$"),
    since_seconds: int = Query(1800, ge=60, le=86400),
    limit: int = Query(200, ge=1, le=2000),
):
    """Recent observations, most recent first. Filter by stop/route/source."""
    conn = get_conn()
    cutoff = int(time.time()) - since_seconds
    where = ["timestamp >= ?"]
    params: list = [cutoff]
    if stop:
        where.append("stop = ?"); params.append(stop)
    if route:
        where.append("route = ?"); params.append(route)
    if source:
        where.append("source = ?"); params.append(source)
    sql = (
        "SELECT source, route, stop, direction, vehicle_id, scheduled_time, "
        "actual_time, delay_seconds, timestamp FROM observations WHERE "
        + " AND ".join(where)
        + " ORDER BY timestamp DESC, actual_time ASC LIMIT ?"
    )
    params.append(limit)
    try:
        result = _rows(conn.execute(sql, params))
    finally:
        conn.close()
    return {"count": len(result), "arrivals": result}


@app.get("/stats/delay")
def stats_delay(
    source: Optional[str] = Query(None, pattern="^(bus|rail)$"),
    route: Optional[str] = None,
    stop: Optional[str] = None,
    group_by: str = Query("route", pattern="^(route|stop|hour|route_hour|dow)$"),
    since_seconds: int = Query(7 * 86400, ge=3600),
    min_n: int = Query(1, ge=1),
):
    """Historical delay stats — the Phase 3 groundwork. Aggregates rows with a
    known delay into per-group stats including true percentiles (computed in
    Python, since SQLite has no percentile function), on-time rate, and the
    late/early split. On-time is defined as within ±60s of schedule."""
    conn = get_conn()
    cutoff = int(time.time()) - since_seconds
    where = ["delay_seconds IS NOT NULL", "timestamp >= ?"]
    params: list = [cutoff]
    if source:
        where.append("source = ?"); params.append(source)
    if route:
        where.append("route = ?"); params.append(route)
    if stop:
        where.append("stop = ?"); params.append(stop)

    group_exprs = {
        "route": "route",
        "stop": "stop",
        "hour": "CAST(strftime('%H', timestamp, 'unixepoch', 'localtime') AS INTEGER)",
        "route_hour": "route || '@' || strftime('%H', timestamp, 'unixepoch', 'localtime')",
        # 0=Sunday .. 6=Saturday, matching strftime('%w').
        "dow": "CAST(strftime('%w', timestamp, 'unixepoch', 'localtime') AS INTEGER)",
    }
    gexpr = group_exprs[group_by]
    sql = (
        f"SELECT {gexpr} AS grp, delay_seconds FROM observations WHERE "
        + " AND ".join(where)
    )
    try:
        by_group: dict = {}
        for grp, delay in conn.execute(sql, params):
            by_group.setdefault(grp, []).append(delay)
    finally:
        conn.close()

    groups = [
        _delay_group_stats(grp, delays)
        for grp, delays in by_group.items()
        if len(delays) >= min_n
    ]
    groups.sort(key=lambda g: g["n"], reverse=True)
    return {
        "group_by": group_by,
        "on_time_window_seconds": 60,
        "min_n": min_n,
        "groups": groups,
    }


def _percentile(sorted_values: list[int], q: float) -> int:
    """Nearest-rank percentile (q in 0..1) over a pre-sorted list."""
    if not sorted_values:
        return 0
    idx = max(0, min(len(sorted_values) - 1, round(q * (len(sorted_values) - 1))))
    return sorted_values[idx]


def _delay_group_stats(grp, delays: list[int]) -> dict:
    delays.sort()
    n = len(delays)
    on_time = sum(1 for d in delays if -60 <= d <= 60)
    late = sum(1 for d in delays if d > 60)
    early = sum(1 for d in delays if d < -60)
    return {
        "group": grp,
        "n": n,
        "avg_delay": round(sum(delays) / n, 1),
        "median_delay": _percentile(delays, 0.5),
        "p90_delay": _percentile(delays, 0.9),
        "min_delay": delays[0],
        "max_delay": delays[-1],
        "on_time_pct": round(100 * on_time / n, 1),
        "late_pct": round(100 * late / n, 1),
        "early_pct": round(100 * early / n, 1),
    }


# ---------------------------------------------------------------------------
# Trip planning (Phase 4): proxy OTP and annotate each transit leg with our
# collected historical delay stats — routing that knows which buses run late.
# ---------------------------------------------------------------------------

_OTP_PLAN_QUERY = """
query Plan($from: InputCoordinates!, $to: InputCoordinates!,
           $date: String, $time: String, $num: Int) {
  plan(from: $from, to: $to, date: $date, time: $time, numItineraries: $num,
       transportModes: [{mode: WALK}, {mode: TRANSIT}]) {
    itineraries {
      duration walkDistance startTime endTime
      legs {
        mode duration distance startTime endTime
        route { gtfsId shortName longName }
        from { name lat lon }
        to { name lat lon }
      }
    }
  }
}
"""

# Modes that aren't transit vehicles (no delay history to attach).
_NON_TRANSIT_MODES = {"WALK", "BICYCLE", "CAR", "SCOOTER", None}
# Below this many samples, fall back from route+hour to route-overall.
_MIN_HOUR_SAMPLES = 20


def _ms_to_s(ms):
    return int(ms / 1000) if ms else None


def _route_delay_stats(conn, candidates, hour):
    """Median delay + on-time% for a route (optionally at a given hour)."""
    placeholders = ",".join("?" for _ in candidates)
    where = [f"UPPER(route) IN ({placeholders})", "delay_seconds IS NOT NULL"]
    params: list = list(candidates)
    if hour is not None:
        where.append(
            "CAST(strftime('%H', timestamp, 'unixepoch', 'localtime') AS INTEGER) = ?"
        )
        params.append(hour)
    sql = "SELECT delay_seconds FROM observations WHERE " + " AND ".join(where)
    delays = [r[0] for r in conn.execute(sql, params)]
    if not delays:
        return None
    delays.sort()
    n = len(delays)
    on_time = sum(1 for d in delays if -60 <= d <= 60)
    return {
        "median_seconds": _percentile(delays, 0.5),
        "on_time_pct": round(100 * on_time / n, 1),
        "samples": n,
        "basis": "route_hour" if hour is not None else "route",
    }


def _leg_delay(conn, route, start_ms):
    """Historical delay annotation for a transit leg's route, preferring the
    leg's departure hour but falling back to the route overall."""
    candidates = set()
    for key in ("shortName", "longName", "gtfsId"):
        v = route.get(key)
        if v:
            candidates.add(v.split(":")[-1].upper())  # gtfsId "MARTA:2" -> "2"
    if not candidates:
        return None
    hour = datetime.fromtimestamp(start_ms / 1000).hour if start_ms else None
    if hour is not None:
        by_hour = _route_delay_stats(conn, candidates, hour)
        if by_hour and by_hour["samples"] >= _MIN_HOUR_SAMPLES:
            return by_hour
    return _route_delay_stats(conn, candidates, None)


def _simplify_leg(conn, leg):
    mode = leg.get("mode")
    route = leg.get("route") or {}
    out = {
        "mode": mode,
        "duration_seconds": leg.get("duration"),
        "distance_m": round(leg.get("distance") or 0),
        "start_epoch": _ms_to_s(leg.get("startTime")),
        "end_epoch": _ms_to_s(leg.get("endTime")),
        "from": (leg.get("from") or {}).get("name"),
        "to": (leg.get("to") or {}).get("name"),
        "route": route.get("shortName") or route.get("longName"),
        "route_long_name": route.get("longName"),
        "historical_delay": None,
    }
    if mode not in _NON_TRANSIT_MODES:
        out["historical_delay"] = _leg_delay(conn, route, leg.get("startTime"))
    return out


def _simplify_itinerary(conn, it):
    return {
        "duration_seconds": it.get("duration"),
        "walk_distance_m": round(it.get("walkDistance") or 0),
        "start_epoch": _ms_to_s(it.get("startTime")),
        "end_epoch": _ms_to_s(it.get("endTime")),
        "legs": [_simplify_leg(conn, leg) for leg in it.get("legs", [])],
    }


@app.get("/plan")
def plan(
    from_lat: float,
    from_lon: float,
    to_lat: float,
    to_lon: float,
    date: Optional[str] = None,
    time_: Optional[str] = Query(None, alias="time"),
    num: int = Query(3, ge=1, le=6),
):
    """Multimodal trip plan via OTP, with each transit leg annotated with our
    historical delay stats. `date` is YYYY-MM-DD, `time` is HH:MM:SS (agency
    local); omit for 'now'."""
    variables = {
        "from": {"lat": from_lat, "lon": from_lon},
        "to": {"lat": to_lat, "lon": to_lon},
        "date": date,
        "time": time_,
        "num": num,
    }
    try:
        resp = requests.post(
            config.OTP_GRAPHQL_URL,
            json={"query": _OTP_PLAN_QUERY, "variables": variables},
            timeout=30,
        )
        resp.raise_for_status()
        payload = resp.json()
    except requests.exceptions.RequestException:
        raise HTTPException(
            503, "Trip planner (OTP) isn't reachable. Start it: otp/run-otp.sh serve"
        )
    if payload.get("errors"):
        raise HTTPException(502, f"OTP error: {payload['errors'][0].get('message')}")

    itineraries = ((payload.get("data") or {}).get("plan") or {}).get("itineraries", []) or []
    conn = get_conn()
    try:
        result = [_simplify_itinerary(conn, it) for it in itineraries]
    finally:
        conn.close()
    return {"itineraries": result}


def main():
    import os
    import uvicorn
    # Default to localhost. Set API_HOST=0.0.0.0 to also serve the LAN (e.g. so a
    # phone on the same WiFi can reach it). Read-only API; only expose on a
    # trusted network.
    host = os.getenv("API_HOST", "127.0.0.1")
    uvicorn.run(app, host=host, port=8000)


if __name__ == "__main__":
    main()
