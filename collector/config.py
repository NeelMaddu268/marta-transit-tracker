"""Shared configuration and constants for the collector."""

import os
from pathlib import Path

from dotenv import load_dotenv

# Project root = parent of this collector/ package.
ROOT = Path(__file__).resolve().parent.parent

# Load .env from the project root explicitly so it works regardless of cwd.
load_dotenv(ROOT / ".env")

RAIL_API_KEY = os.getenv("MARTA_RAIL_API_KEY")

# Feed endpoints.
BUS_VEHICLE_URL = "https://gtfs-rt.itsmarta.com/TMGTFSRealTimeWebService/vehicle/vehiclepositions.pb"
BUS_TRIPUPDATE_URL = "https://gtfs-rt.itsmarta.com/TMGTFSRealTimeWebService/tripupdate/tripupdates.pb"
RAIL_URL_TEMPLATE = (
    "https://developerservices.itsmarta.com:18096/itsmarta/railrealtimearrivals"
    "/developerservices/traindata?apiKey={key}"
)

# Polling interval (seconds). Top of the 30-60s range that suits these feeds,
# to keep long-term storage growth in check.
POLL_INTERVAL_SECONDS = int(os.getenv("POLL_INTERVAL_SECONDS", "45"))

# HTTP request timeout (seconds).
HTTP_TIMEOUT_SECONDS = 20

# Delays beyond this magnitude are almost certainly feed/schedule-match noise
# rather than a real bus/train that far off. We keep the observation but null
# the delay so the historical dataset isn't polluted. 1 hour is very generous.
MAX_PLAUSIBLE_DELAY_SECONDS = 3600

# SQLite database file (gitignored).
DB_PATH = ROOT / "data" / "marta.db"

# OpenTripPlanner GraphQL endpoint (Phase 4 trip planning).
OTP_GRAPHQL_URL = os.getenv("OTP_GRAPHQL_URL", "http://localhost:8080/otp/gtfs/v1")
