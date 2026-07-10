#!/usr/bin/env bash
# Build or serve the MARTA OpenTripPlanner instance.
#
#   ./run-otp.sh build    # build graph.obj from OSM + GTFS in data/
#   ./run-otp.sh serve    # load graph.obj and serve the routing API on :8080
#
# OTP auto-detects the .osm.pbf and GTFS .zip in the data/ directory.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
JAR="$DIR/otp-shaded-2.9.0.jar"
DATA="$DIR/data"
HEAP="${OTP_HEAP:-6G}"

case "${1:-}" in
  build)
    exec java -Xmx"$HEAP" -jar "$JAR" --build --save "$DATA"
    ;;
  serve|run)
    exec java -Xmx"$HEAP" -jar "$JAR" --load "$DATA"
    ;;
  *)
    echo "usage: $0 {build|serve}" >&2
    exit 1
    ;;
esac
