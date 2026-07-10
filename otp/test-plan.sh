#!/usr/bin/env bash
# Verify OTP routing with a real multimodal trip: North Springs area (far north,
# RED line) -> Airport (far south, GOLD/RED line). A good plan should use rail.
#
# Usage: ./test-plan.sh   (OTP must be serving on :8080)
set -euo pipefail

ENDPOINT="http://localhost:8080/otp/gtfs/v1"

read -r -d '' QUERY <<'GRAPHQL' || true
{
  "query": "{ plan(from: {lat: 33.9450, lon: -84.3573}, to: {lat: 33.6407, lon: -84.4460}, transportModes: [{mode: WALK}, {mode: TRANSIT}], numItineraries: 3) { itineraries { duration walkDistance legs { mode duration distance route { shortName longName } from { name } to { name } } } } }"
}
GRAPHQL

curl -sS -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "OTPTimeout: 30000" \
  -d "$QUERY"
echo
