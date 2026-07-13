# MARTA Tracker — iOS app (Phases 1–2)

SwiftUI app showing live MARTA bus + train positions on a map, plus a favorites
tab with upcoming arrivals for saved stations/stops.

Per the project plan, Phases 1–2 talk **directly** to MARTA's feeds — they do not
use the Python service yet.

- **Phase 1 — Map:** live bus/train positions, line-colored, refreshing on a
  timer. Tap a vehicle for its upcoming stops + ETAs (+ delay for trains).
- **Phase 2 — Favorites:** save rail stations / bus stops; the Favorites tab
  shows a merged list of upcoming arrivals across them, sorted by time, with
  pull-to-refresh, empty state, and a searchable add sheet. Favorites persist in
  `UserDefaults`.
- **Phase 3 — Delays:** the Delays tab queries the local Python collector
  service (`MartaServiceBaseURL`, default `http://127.0.0.1:8000`) for historical
  stats — routes/lines ranked by typical delay, and a per-route hourly breakdown
  chart (Swift Charts). Degrades gracefully with a "service unreachable" state +
  Retry when the collector API isn't running. Needs the collector API up
  (`python -m collector.api`); the simulator reaches it via the host loopback.
  ML predictions are deferred until more data has accumulated.

- **Phase 5 — Search & commutes:** the Map has a search bar (routes, rail
  stations, bus stops). Tap a station/stop for a **detail** view of live arrivals
  (with a favorite star); tap a route for its **live vehicles grouped by where
  they're headed** on a mini-map. Save a **commute** ({stop → route → destination},
  e.g. Windward P&R → 140 → North Springs) — it pins to the top of that route's
  detail and appears in a Commutes section on Favorites. Route/destination data is
  bundled (`routes.json`, `trip_headsigns.json`).

- **Phase 6 — Daily-driver polish:** stop/station views are grouped departure
  boards ("140 → North Springs: 8 min, then 23, 38") with per-second countdowns;
  the map draws the four rail lines (and favorited routes' paths) and declutters
  buses when zoomed out; favorite pins are tappable; **Near me** (location button)
  lists the closest stops/stations; **Settings** (gear) lets you change the
  collector URL without rebuilding (stored in UserDefaults) and test the
  connection; and the app has an icon. Regenerate bundled route shapes with
  `./venv/bin/python tools/gen_route_shapes.py`, the icon with
  `swift tools/gen_app_icon.swift`.

- **Phase 7 — Widget & tests:** a home-screen **widget** (long-press home →
  ＋ → "MARTA Commute") shows live countdowns for your saved commute; it reads
  commutes from the App Group and fetches the bus feed directly, so it works
  without the Mac. Commutes are **bay-proof**: all sibling bays of a
  park-and-ride are matched (MARTA boards each direction at a specific bay —
  e.g. 140→North Springs uses Windward Bay C only). Unit tests live in
  `MartaTrackerTests` (`xcodebuild test -scheme MartaTracker`), including a
  frozen-fixture check of the protobuf decoder against the reference parser.

- **Phase 8 — Facilities & bays:** park-and-rides/stations appear as **one
  place** everywhere (search, favorites, nearby, pickers) instead of per-bay
  entries, grouped via GTFS `parent_station`. Departure boards tell you **which
  bay to wait at** per destination ("140 → North Springs · Wait at Bay C") —
  including on the widget. Existing bay-level favorites/commutes migrate
  automatically.

- **Route map:** on any route's page, tap **Full map** (on the mini-map) for a
  full-screen map showing only that route — its path drawn, its live vehicles
  labeled by destination, framed to the route.

- **Phase 11 — Reminders, crowding, alerts:** tap the **🔔 bell** on your commute
  card for a "time to leave" notification 5 minutes before the departure
  (predictions at that range are stable — measured ±1-2 min). Buses that report
  **crowding** show it ("Seats available / Standing room / Full") on route pages,
  departure boards, and the commute card. MARTA **service alerts** (detours,
  outages) appear as orange banners on affected route and stop pages.

- **Phase 12 — Smarter context:** departure boards and the commute card add a
  **"usually +X min at this hour"** chip from your own collected history (shown
  only when statistically meaningful; needs the collector API). Departure
  **reminders re-aim themselves** while the app is open — if the prediction
  drifts more than a minute, the pending notification is rescheduled. The map
  search shows your **recent** stops/routes when focused and empty.

A few clearly-marked test-only launch env vars exist for UI verification
(`MARTA_START_TAB`, `MARTA_SEED_FAVORITES`, `MARTA_PRESENT_ADD`,
`MARTA_DETAIL_ROUTE`, `MARTA_SEARCH`, `MARTA_NAV_ROUTE`, `MARTA_NAV_PLACE_*`,
`MARTA_SEED_COMMUTE`) — no effect on a normal launch.

## What's here

- **Bus** — GTFS-Realtime protobuf (no API key). Decoded by a small,
  dependency-free protobuf reader (`Services/ProtobufReader.swift` +
  `Services/GTFSRealtime.swift`) rather than pulling in SwiftProtobuf. The
  decoder is verified byte-for-byte against the reference Python parser.
- **Rail** — realtime REST JSON (needs the MARTA rail API key). Delay comes
  straight from the feed (`T93S` = 93s late).
- Bus delay is **not** shown in Phase 1: the RT feed omits it and computing it
  needs the 125 MB static schedule (too large to bundle). Buses show position +
  predicted ETAs; delay/history lands in Phase 3 via the Python service.

## Requirements

- **Full Xcode** (not just Command Line Tools) — the app uses the iOS 17 MapKit
  SwiftUI `Map` API and can only be built/run from Xcode or `xcodebuild`.
- iOS 17+ target.

## Setup

1. **Secrets.** The build injects the rail API key from a gitignored xcconfig.
   A real `MartaTracker/Config/Secrets.xcconfig` was generated from the
   project's `.env`. If it's missing, create it:
   ```sh
   cd ios/MartaTracker/MartaTracker/Config
   cp Secrets.example.xcconfig Secrets.xcconfig
   # then edit Secrets.xcconfig and paste your MARTA rail API key
   ```

2. **Generate the Xcode project** (already generated; regenerate after adding
   files):
   ```sh
   brew install xcodegen        # once
   cd ios/MartaTracker
   xcodegen generate
   ```

3. **Open & run:**
   ```sh
   open ios/MartaTracker/MartaTracker.xcodeproj
   ```
   Select an iPhone simulator and Run.

## Project layout

```
MartaTracker/
  MartaTrackerApp.swift        app entry
  Models/                      Vehicle, Arrival
  Services/
    ProtobufReader.swift       minimal protobuf wire decoder
    GTFSRealtime.swift         GTFS-RT FeedMessage -> models
    BusFeed.swift              fetch + decode bus feeds
    RailFeed.swift             fetch + decode rail JSON
    StopCatalog.swift          bus stop_id -> name (bundled stops.txt)
    MartaService.swift         orchestrates both, refresh timer, tap->arrivals
  Views/
    MapScreen.swift            the live map
    VehicleMarker.swift        map annotation
    ArrivalsSheet.swift        tap-a-vehicle detail sheet
  Resources/stops.txt          bundled GTFS static stop names
  Config/Secrets.xcconfig      gitignored, holds the rail key
  Info.plist
project.yml                    XcodeGen spec
```

## Notes

- `Info.plist` scopes an App Transport Security exception to `itsmarta.com`
  because the rail endpoint is HTTPS on a non-standard port with an older TLS
  config.
- The map refreshes every 20s while visible.
