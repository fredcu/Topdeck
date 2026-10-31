#!/usr/bin/env bash
# Fails when App/Topdeck.weather.entitlements drifts from App/Topdeck.entitlements: apart from the keys the
# WeatherKit profile needs, the two files must hold the same entitlements.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cp App/Topdeck.weather.entitlements "$tmp"
for key in com.apple.developer.weatherkit com.apple.application-identifier com.apple.developer.team-identifier; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$tmp"
done
if ! diff <(plutil -convert xml1 -o - App/Topdeck.entitlements) <(plutil -convert xml1 -o - "$tmp"); then
    echo "error: App/Topdeck.weather.entitlements has drifted from App/Topdeck.entitlements"
    exit 1
fi
