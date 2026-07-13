"""Generate ios .../Resources/route_shapes.json from GTFS static.

For each route (keyed by short name, matching live vehicles) pick the most-used
shape per direction from trips.txt, pull its points from shapes.txt, and
decimate to <= MAX_POINTS for map display. Output:
    { "140": [ [[lat,lon], ...], [[lat,lon], ...] ], "RED": [...], ... }
Run:  ./venv/bin/python tools/gen_route_shapes.py
"""

import csv
import json
import os
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GTFS = os.path.join(ROOT, "data", "gtfs_static")
OUT = os.path.join(ROOT, "ios", "MartaTracker", "MartaTracker", "Resources", "route_shapes.json")

MAX_POINTS = 120


def main():
    # route_id -> short-name key
    id2key = {}
    with open(os.path.join(GTFS, "routes.txt")) as f:
        for r in csv.DictReader(f):
            id2key[r["route_id"]] = (r.get("route_short_name") or "").strip() or r["route_id"]

    # (route key, direction) -> most common shape_id
    counts = defaultdict(Counter)
    with open(os.path.join(GTFS, "trips.txt")) as f:
        for r in csv.DictReader(f):
            key = id2key.get(r["route_id"])
            sid = (r.get("shape_id") or "").strip()
            if key and sid:
                counts[(key, r.get("direction_id") or "0")][sid] += 1
    wanted = {}   # shape_id -> set of route keys
    for (key, _d), c in counts.items():
        sid = c.most_common(1)[0][0]
        wanted.setdefault(sid, set()).add(key)
    print(f"representative shapes: {len(wanted)} across {len({k for s in wanted.values() for k in s})} routes")

    # stream shapes.txt, keep only wanted shape ids
    points = defaultdict(list)   # shape_id -> [(seq, lat, lon)]
    with open(os.path.join(GTFS, "shapes.txt")) as f:
        for r in csv.DictReader(f):
            sid = r["shape_id"]
            if sid in wanted:
                points[sid].append((int(r["shape_pt_sequence"]),
                                    round(float(r["shape_pt_lat"]), 5),
                                    round(float(r["shape_pt_lon"]), 5)))

    out = defaultdict(list)
    for sid, pts in points.items():
        pts.sort()
        coords = [[p[1], p[2]] for p in pts]
        if len(coords) > MAX_POINTS:               # uniform decimation, keep ends
            step = (len(coords) - 1) / (MAX_POINTS - 1)
            coords = [coords[round(i * step)] for i in range(MAX_POINTS)]
        for key in wanted[sid]:
            if coords not in out[key]:             # dedupe identical directions
                out[key].append(coords)

    with open(OUT, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    size = os.path.getsize(OUT)
    print(f"wrote {OUT}: {len(out)} routes, {size/1024:.0f} KB")
    for k in ("RED", "GOLD", "BLUE", "GREEN", "140", "2"):
        if k in out:
            print(f"  {k}: {len(out[k])} polylines, {[len(p) for p in out[k]]} pts")


if __name__ == "__main__":
    main()
