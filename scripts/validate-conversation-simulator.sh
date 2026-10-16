#!/usr/bin/env bash
# One Mac-only offline pass: portable checks, native URLProtocol mocks, iOS builds,
# then the existing simulated audio/camera cycle in an iPhone Simulator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'Requires macOS + Xcode; no device is needed.'; exit 1; }
export TARS_VALIDATION_DIR="${TARS_VALIDATION_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/tars-conversation-validation.XXXXXX")}"
cd "$ROOT"
if [[ "${1:-}" == --cycle-only ]]; then
  echo 'Build Debug + simulated app cycle; standalone checks and Release already passed in the previous full run.'
  if ! xcodebuild -project TARSXR.xcodeproj -scheme TARSXR -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$TARS_VALIDATION_DIR/DerivedData" \
      CODE_SIGNING_ALLOWED=NO build > "$TARS_VALIDATION_DIR/debug-cycle.log" 2>&1; then
    grep -n -B 3 -A 8 'error:' "$TARS_VALIDATION_DIR/debug-cycle.log" || tail -80 "$TARS_VALIDATION_DIR/debug-cycle.log"
    exit 1
  fi
else
  bash scripts/validate-runtime-boundary.sh
fi
DEVICES_JSON="$TARS_VALIDATION_DIR/simulator-devices.json"
xcrun simctl list devices available --json > "$DEVICES_JSON"
SIM_ID="${TARS_SIMULATOR_ID:-$(python3 - "$DEVICES_JSON" <<'PY'
import json,sys
items=[d for runtime,devices in json.load(open(sys.argv[1]))['devices'].items() if '.iOS-' in runtime and int(runtime.rsplit('.iOS-',1)[1].split('-')[0]) >= 18 for d in devices if d.get('isAvailable') and 'iPhone' in d.get('name','')]
items.sort(key=lambda d:d.get('state')!='Booted')
if not items: raise SystemExit('No available iPhone Simulator. Install an iOS runtime in Xcode first.')
print(items[0]['udid'])
PY
)}"
if ! xcrun simctl list devices booted | grep -Fq "$SIM_ID"; then xcrun simctl boot "$SIM_ID"; fi
xcrun simctl bootstatus "$SIM_ID" -b
APP="$TARS_VALIDATION_DIR/DerivedData/Build/Products/Debug-iphonesimulator/TARSXR.app"
# Xcode's product name can differ from the display name.
if [[ ! -d "$APP" ]]; then APP="$TARS_VALIDATION_DIR/DerivedData/Build/Products/Debug-iphonesimulator/MyApp.app"; fi
[[ -d "$APP" ]] || { echo "Simulator app missing: $APP"; exit 1; }
xcrun simctl install "$SIM_ID" "$APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")
CONTAINER=$(xcrun simctl get_app_container "$SIM_ID" "$BUNDLE_ID" data)
rm -f "$CONTAINER/Documents/voice-cycle-checks.txt"
SIMCTL_CHILD_TARS_VOICE_CHECKS=1 SIMCTL_CHILD_TARS_PAUSE_VOICE=1 SIMCTL_CHILD_TARS_ONLINE_WAKE=0 \
  xcrun simctl launch --terminate-running-process "$SIM_ID" "$BUNDLE_ID"
cleanup() { xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
for ((attempt=0; attempt<90; attempt++)); do
  if [[ -f "$CONTAINER/Documents/voice-cycle-checks.txt" ]]; then
    cp "$CONTAINER/Documents/voice-cycle-checks.txt" "$TARS_VALIDATION_DIR/voice-cycle-checks.txt"
    cat "$TARS_VALIDATION_DIR/voice-cycle-checks.txt"
    grep -q '^PASS:' "$TARS_VALIDATION_DIR/voice-cycle-checks.txt"
    if [[ "${1:-}" == --cycle-only ]]; then
      echo 'PASS: Debug build + simulated app cycle. Full checks/Release were not rerun in this invocation.'
    else
      echo 'PASS: Mac builds, mocked providers and simulated app cycle. Physical XR acoustics/thermal remain unverified.'
    fi
    echo "Logs: $TARS_VALIDATION_DIR"
    exit 0
  fi
  sleep 1
done
echo "FAIL: simulated app cycle did not produce its result. Logs: $TARS_VALIDATION_DIR"
exit 1
