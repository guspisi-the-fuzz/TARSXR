#!/bin/bash
# Builds/tests only. Does not run the app, send commands, pair hardware or commit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TARS_VALIDATION_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/tars-xr-validation.XXXXXX")}" 
mkdir -p "$OUT"
cd "$ROOT"
ulimit -c 0
SWIFT_FLAGS=(-swift-version 5 -Onone)
if [[ "$(uname -s)" == Darwin ]]; then
  SWIFT_FLAGS+=(-sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$(uname -m)-apple-macosx13.0")
  SWIFTC="$(xcrun --find swiftc)"
  xcodebuild -version > "$OUT/xcode-version.log"
else
  SWIFTC="$(command -v swiftc)"
fi
"$SWIFTC" --version > "$OUT/swift-version.log"
run_check() {
  local name="$1"; shift
  echo "Compilando e testando: $name"
  if ! "$SWIFTC" "${SWIFT_FLAGS[@]}" "$@" -o "$OUT/$name" > "$OUT/$name.build.log" 2>&1; then
    cat "$OUT/$name.build.log"; return 1
  fi
  "$OUT/$name" > "$OUT/$name.test.log" 2>&1 || { cat "$OUT/$name.test.log"; return 1; }
  cat "$OUT/$name.test.log"
}
build_ios() {
  local config="$1" platform="$2" label="$3"
  echo "Build iOS: $label"
  if ! xcodebuild -project TARSXR.xcodeproj -scheme TARSXR -configuration "$config" \
    -destination "generic/platform=$platform" -derivedDataPath "$OUT/DerivedData" \
    CODE_SIGNING_ALLOWED=NO build > "$OUT/$label.log" 2>&1; then
    tail -100 "$OUT/$label.log"; return 1
  fi
  grep -F '** BUILD SUCCEEDED **' "$OUT/$label.log" || return 1
}
if [[ "$(uname -s)" == Darwin ]]; then build_ios Debug 'iOS Simulator' debug-before-tests; fi
run_check reconnection MyApp/ReconnectionPolicy.swift Tests/ReconnectionPolicyChecks.swift
run_check pronunciation MyApp/AudioTestPronunciation.swift Tests/AudioTestPronunciationChecks.swift
run_check voice MyApp/VoiceActivationPolicy.swift Tests/VoiceActivationChecks.swift
run_check device-clock MyApp/XRDeviceClock.swift Tests/XRDeviceClockChecks.swift
MEMORY=(MyApp/XRPersistentMemory.swift MyApp/XRMemoryIntent.swift MyApp/MemoryTARSRuntime.swift)
export TARS_MEMORY_FIXTURE_OUT="$OUT/xr-memory-wire-fixture.json"
run_check persistent-memory MyApp/HUDModels.swift MyApp/TARSRuntime.swift "${MEMORY[@]}" Tests/XRMemoryChecks.swift
run_check memory-trace -DDEBUG MyApp/HUDModels.swift MyApp/TARSRuntime.swift "${MEMORY[@]}" Tests/XRMemoryDiagnosticsChecks.swift
run_check memory-speech-intent MyApp/HUDModels.swift MyApp/TARSRuntime.swift "${MEMORY[@]}" MyApp/VoiceActivationPolicy.swift Tests/XRMemorySpeechIntentChecks.swift
run_check memory-relations -DDEBUG MyApp/HUDModels.swift MyApp/TARSRuntime.swift "${MEMORY[@]}" MyApp/VoiceActivationPolicy.swift Tests/XRMemoryRelationChecks.swift
COMMON=(MyApp/HUDModels.swift MyApp/TARSRuntime.swift MyApp/RemoteTARSRuntime.swift MyApp/XRDeviceClock.swift)
run_check remote-runtime "${COMMON[@]}" Tests/RemoteRuntimeChecks.swift
if [[ "$(uname -s)" == Darwin ]]; then
  run_check concrete-client "${COMMON[@]}" MyApp/TARSClient.swift Tests/ClientReconnectionChecks.swift
  run_check concrete-runtime "${COMMON[@]}" MyApp/TARSClient.swift Tests/RuntimeHTTPChecks.swift
  run_check device-clock-http "${COMMON[@]}" MyApp/TARSClient.swift Tests/XRClockHTTPChecks.swift
  run_check memory-http "${COMMON[@]}" "${MEMORY[@]}" MyApp/TARSClient.swift Tests/XRMemoryHTTPChecks.swift
  build_ios Debug 'iOS Simulator' debug-after-tests
  build_ios Release iOS release-device
  printf 'PASS: Swift checks + Debug/Release iOS builds. Device behavior not tested.\n' | tee "$OUT/RESULT.txt"
else
  printf 'PASS: portable Swift checks only. NOT RUN: concrete HTTP checks and iOS builds (requires macOS/Xcode).\n' | tee "$OUT/RESULT.txt"
fi
printf 'Logs: %s\n' "$OUT"
