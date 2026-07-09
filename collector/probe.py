"""Feed verification probe — run once to confirm both MARTA feeds return usable data.

Checks:
  1. Bus GTFS-RT vehicle positions parse and contain vehicles with lat/long.
  2. Bus GTFS-RT trip updates parse.
  3. The known vehicle_id <-> trip_id mapping gotcha in MARTA data: do vehicle
     positions carry a trip_id, and does it line up with trip updates?
  4. Rail REST API responds with the expected per-station JSON shape.

This is throwaway verification, not part of the collector runtime.
"""

import os
import sys
from collections import Counter

import requests
from dotenv import load_dotenv
from google.transit import gtfs_realtime_pb2

load_dotenv()

BUS_VEHICLE_URL = "https://gtfs-rt.itsmarta.com/TMGTFSRealTimeWebService/vehicle/vehiclepositions.pb"
BUS_TRIPUPDATE_URL = "https://gtfs-rt.itsmarta.com/TMGTFSRealTimeWebService/tripupdate/tripupdates.pb"
RAIL_URL = (
    "https://developerservices.itsmarta.com:18096/itsmarta/railrealtimearrivals"
    "/developerservices/traindata?apiKey={key}"
)


def fetch_feed(url):
    resp = requests.get(url, timeout=20)
    resp.raise_for_status()
    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(resp.content)
    return feed


def probe_bus():
    print("=== BUS GTFS-RT ===")
    try:
        veh_feed = fetch_feed(BUS_VEHICLE_URL)
    except Exception as e:
        print(f"  FAIL vehicle positions: {e}")
        return
    vehicles = [e.vehicle for e in veh_feed.entity if e.HasField("vehicle")]
    print(f"  vehicle positions: {len(vehicles)} vehicles")
    with_pos = [v for v in vehicles if v.HasField("position")]
    with_trip = [v for v in vehicles if v.HasField("trip") and v.trip.trip_id]
    print(f"    with lat/long: {len(with_pos)}")
    print(f"    with trip_id:  {len(with_trip)}")
    if with_pos:
        v = with_pos[0]
        print(
            f"    sample: vehicle_id={v.vehicle.id!r} "
            f"trip_id={v.trip.trip_id!r} route_id={v.trip.route_id!r} "
            f"lat={v.position.latitude:.5f} lon={v.position.longitude:.5f}"
        )

    try:
        tu_feed = fetch_feed(BUS_TRIPUPDATE_URL)
    except Exception as e:
        print(f"  FAIL trip updates: {e}")
        return
    trip_updates = [e.trip_update for e in tu_feed.entity if e.HasField("trip_update")]
    print(f"  trip updates: {len(trip_updates)} trips")
    tu_trip_ids = {tu.trip.trip_id for tu in trip_updates if tu.trip.trip_id}

    # The gotcha: can we join vehicle positions to trip updates on trip_id?
    veh_trip_ids = {v.trip.trip_id for v in with_trip}
    if veh_trip_ids and tu_trip_ids:
        overlap = veh_trip_ids & tu_trip_ids
        print(
            f"  trip_id join: {len(overlap)}/{len(veh_trip_ids)} vehicle trip_ids "
            f"also present in trip updates"
        )
    else:
        print("  trip_id join: cannot test (one side has no trip_ids)")

    if tu_trip_ids:
        tu = trip_updates[0]
        n_stops = len(tu.stop_time_update)
        print(f"    sample trip_update: trip_id={tu.trip.trip_id!r} stop_time_updates={n_stops}")
        if n_stops:
            stu = tu.stop_time_update[0]
            delay = stu.arrival.delay if stu.HasField("arrival") else None
            print(f"      first stop: stop_id={stu.stop_id!r} arrival.delay={delay}")


def probe_rail():
    print("=== RAIL REST API ===")
    key = os.getenv("MARTA_RAIL_API_KEY")
    if not key:
        print("  FAIL: MARTA_RAIL_API_KEY not found in environment (.env)")
        return
    try:
        resp = requests.get(RAIL_URL.format(key=key), timeout=20)
        resp.raise_for_status()
        data = resp.json()
    except Exception as e:
        print(f"  FAIL: {e}")
        return
    print(f"  arrivals returned: {len(data)}")
    if not data:
        print("  (empty — could be off-hours; re-run during service)")
        return
    lines = Counter(r.get("LINE") for r in data)
    print(f"  lines: {dict(lines)}")
    r = data[0]
    print(f"  sample keys: {sorted(r.keys())}")
    print(
        f"  sample: station={r.get('STATION')!r} line={r.get('LINE')!r} "
        f"dir={r.get('DIRECTION')!r} waiting={r.get('WAITING_TIME')!r} "
        f"delay={r.get('DELAY')!r} lat={r.get('LATITUDE')!r} lon={r.get('LONGITUDE')!r}"
    )


if __name__ == "__main__":
    probe_bus()
    print()
    probe_rail()
    sys.exit(0)
