#!/usr/bin/env bash
# Usage: sign-weather.sh <Topdeck.app> <signing identity>
# WeatherKit is a restricted entitlement: an app that claims it needs an embedded provisioning profile or
# macOS kills it at launch. When a matching profile is installed, embeds it and re-signs the outer app with
# App/Topdeck.weather.entitlements. With none (CI, most contributors) it prints one line and changes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$1"
identity="$2"

profile="$(python3 -I - <<'PY'
import datetime, glob, os, plistlib, subprocess
found = []
for path in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.provisionprofile")):
    try:
        data = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True, check=True).stdout
        info = plistlib.loads(data)
        entitlements = info["Entitlements"]
        expires = info["ExpirationDate"]
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=datetime.timezone.utc)
        if (entitlements.get("com.apple.application-identifier") == "GAFSTKL3RH.net.icuai.topdeck"
                and entitlements.get("com.apple.developer.weatherkit") is True
                and "OSX" in info.get("Platform", [])
                and expires > datetime.datetime.now(datetime.timezone.utc)):
            found.append((info["CreationDate"], path))
    except Exception:
        continue
if found:
    print(max(found)[1])
PY
)"

if [[ -z "$profile" ]]; then
    echo "weather: no WeatherKit provisioning profile for net.icuai.topdeck, so the app is not signed for it (weather shows unavailable)"
    exit 0
fi
cp "$profile" "$app/Contents/embedded.provisionprofile"
# Outer app only: no --deep, so the helpers and frameworks keep the signatures the build gave them.
codesign --force --sign "$identity" --options runtime --timestamp=none \
    --entitlements App/Topdeck.weather.entitlements "$app"
echo "weather: signed with WeatherKit profile $(basename "$profile")"
