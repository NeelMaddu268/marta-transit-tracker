# MARTA Trip Planning — OpenTripPlanner (Phase 4)

Multimodal (bus + rail + walk) trip planning, powered by
[OpenTripPlanner 2](https://www.opentripplanner.org/) with MARTA's GTFS and an
Atlanta-area OpenStreetMap extract.

**Why upstream OTP2, not MARTA's fork:** MARTA's `itsmarta/OpenTripPlanner` fork
is a plain mirror of upstream `dev-2.x` with no MARTA-specific changes, so we use
the upstream release directly.

## Layout

```
otp/
  otp-shaded-2.9.0.jar     OTP 2.9 (gitignored; from Maven Central)
  run-otp.sh               build | serve helper
  test-plan.sh             sample multimodal plan query
  data/                    (gitignored large inputs + built graph)
    marta-gtfs.zip         MARTA GTFS static (bus + rail + streetcar)
    georgia.osm.pbf        OSM street network (Geofabrik)
    graph.obj              built graph (~465 MB)
```

## Setup (from scratch)

Requires Java 21+ (built/verified on Java 25).

```sh
# 1. OTP jar
curl -L -o otp/otp-shaded-2.9.0.jar \
  https://repo1.maven.org/maven2/org/opentripplanner/otp-shaded/2.9.0/otp-shaded-2.9.0.jar

# 2. Inputs into otp/data/
cp data/gtfs_static/google_transit.zip otp/data/marta-gtfs.zip
curl -L -o otp/data/georgia.osm.pbf \
  https://download.geofabrik.de/north-america/us/georgia-latest.osm.pbf

# 3. Build the graph (~15 min, ~8 GB heap; one-time)
OTP_HEAP=8G otp/run-otp.sh build

# 4. Serve the routing API on :8080 (loads graph.obj, ~30 s)
OTP_HEAP=6G otp/run-otp.sh serve
```

## Querying

GraphQL endpoint: `http://localhost:8080/otp/gtfs/v1` (debug UI at
`http://localhost:8080`). Example:

```sh
otp/test-plan.sh        # North Springs -> Airport (routes via RED line)
```

A `plan(from, to, date, time, transportModes, numItineraries)` query returns
itineraries with per-leg `mode` / `route` / `from` / `to` / `duration`. Verified
2026-07-10: pure-rail trips and bus→rail→rail→bus trips with transfers both plan
correctly.

Note: OTP 2.9's GTFS GraphQL `Itinerary` has no `transfers` field — infer it from
the number of non-WALK legs.

## App integration

Done: the Python service's `GET /plan` proxies OTP and annotates each transit leg
with our historical delay stats (median + on-time% for that route, preferring the
leg's departure hour). The iOS **Trip** tab calls `/plan` and renders itineraries
with those annotations. OTP must be serving for trip planning to work; when it
isn't, the app shows a clear "trip planner unreachable" message.

## Optional future polish

- Clip OSM to metro Atlanta (smaller/faster graph than whole-Georgia).
- Add a GTFS-RT updater in `router-config.json` for realtime-aware routing.
- Run OTP under launchd/a supervisor if you want trip planning always available.
