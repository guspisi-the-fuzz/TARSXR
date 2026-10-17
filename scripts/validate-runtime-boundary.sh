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
  if ! "$SWIFTC" "${SWIFT_FLAGS[@]}" MyApp/SpokenRequest.swift MyApp/ConversationContext.swift MyApp/PreparedVoicePipeline.swift "$@" -o "$OUT/$name" > "$OUT/$name.build.log" 2>&1; then
    cat "$OUT/$name.build.log"; return 1
  fi
  "$OUT/$name" > "$OUT/$name.test.log" 2>&1 || { cat "$OUT/$name.test.log"; return 1; }
  python3 - "$OUT/$name.test.log" <<'PYRESULT'
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text(errors='replace').splitlines():
    if not line.startswith('[TARS_MEMORY]'): print(line)
PYRESULT
}
build_ios() {
  local config="$1" platform="$2" label="$3"
  echo "Build iOS: $label"
  if ! xcodebuild -project TARSXR.xcodeproj -scheme TARSXR -configuration "$config" \
    -destination "generic/platform=$platform" -derivedDataPath "$OUT/DerivedData" \
    CODE_SIGNING_ALLOWED=NO build > "$OUT/$label.log" 2>&1; then
    python3 - "$OUT/$label.log" <<'PYLOG'
from pathlib import Path
import sys
lines=Path(sys.argv[1]).read_text(errors='replace').splitlines()
selected=set()
for i,line in enumerate(lines):
    if 'error:' in line or 'fatal error:' in line:
        selected.update(range(max(0,i-3),min(len(lines),i+7)))
if selected:
    print('Compiler errors:')
    for i in sorted(selected): print(f'{i+1}: {lines[i][:1200]}')
else:
    print('\n'.join(lines[-100:]))
print('Full build log:',sys.argv[1])
PYLOG
    return 1
  fi
  grep -F '** BUILD SUCCEEDED **' "$OUT/$label.log" || return 1
}
if [[ "$(uname -s)" == Darwin ]]; then build_ios Debug 'iOS Simulator' debug-before-tests; fi
python3 - "$OUT/camera-parser.swift" <<'PYCODE'
from pathlib import Path
import sys
source = Path('MyApp/ReferenceCamera.swift').read_text()
a = source.index('struct VoiceCameraCommand:')
b = source.index('@MainActor\nenum VoiceCameraAction', a)
Path(sys.argv[1]).write_text('import Foundation\nenum AVCaptureDevice { enum Position: Equatable { case front, back } }\n' + source[a:b])
PYCODE
run_check conversation-camera-parser "$OUT/camera-parser.swift" Tests/ConversationCameraParserChecks.swift
run_check conversation-continuity MyApp/VoiceActivationPolicy.swift MyApp/HUDModels.swift MyApp/TARSRuntime.swift MyApp/XRPersistentMemory.swift MyApp/XRMemoryIntent.swift MyApp/MemoryTARSRuntime.swift Tests/ConversationContinuityChecks.swift
run_check memory-conversation MyApp/HUDModels.swift MyApp/TARSRuntime.swift MyApp/XRPersistentMemory.swift MyApp/XRMemoryIntent.swift MyApp/MemoryTARSRuntime.swift Tests/MemoryConversationChecks.swift
run_check frame-quality MyApp/FrameQuality.swift Tests/FrameQualityChecks.swift
run_check video-frame-gate MyApp/SequentialSessionCamera.swift Tests/VideoFrameGateChecks.swift
run_check sequential-vision MyApp/SequentialVisionPolicy.swift Tests/SequentialVisionChecks.swift
run_check vision-description MyApp/VisionDescriptionAvailability.swift MyApp/SequentialVisionPolicy.swift Tests/VisionDescriptionChecks.swift
run_check spoken-request Tests/SpokenRequestChecks.swift
run_check logic MyApp/XRLogic.swift Tests/XRLogicChecks.swift
run_check memory-reasoner MyApp/XRPersistentMemory.swift MyApp/XRMemoryIntent.swift MyApp/XRLogic.swift MyApp/XRMemoryReasoner.swift Tests/XRMemoryReasonerChecks.swift
if [[ "$(uname -s)" != Darwin ]]; then
  run_check memory-dialogue MyApp/HUDModels.swift MyApp/TARSRuntime.swift MyApp/XRPersistentMemory.swift MyApp/XRMemoryIntent.swift MyApp/MemoryTARSRuntime.swift MyApp/XRLogic.swift MyApp/XRMemoryReasoner.swift Tests/XRMemoryDialogueChecks.swift
fi
if [[ "$(uname -s)" == Darwin ]]; then
  run_check native-core MyApp/HUDModels.swift MyApp/TARSRuntime.swift MyApp/NativeWeatherLookup.swift MyApp/NativePublicLookup.swift MyApp/NativeAIKeychain.swift MyApp/XRLogic.swift MyApp/NativeAIService.swift MyApp/NativeAIRuntime.swift MyApp/NativeBodyCore.swift Tests/NativeCoreChecks.swift
  run_check memory-dialogue MyApp/HUDModels.swift MyApp/TARSRuntime.swift MyApp/XRPersistentMemory.swift MyApp/XRMemoryIntent.swift MyApp/MemoryTARSRuntime.swift MyApp/XRLogic.swift MyApp/XRMemoryReasoner.swift MyApp/NativeAIService.swift Tests/XRMemoryDialogueChecks.swift
  run_check native-ai MyApp/HUDModels.swift MyApp/TARSRuntime.swift MyApp/XRLogic.swift MyApp/NativeAIService.swift Tests/NativeAIChecks.swift
  run_check native-weather MyApp/HUDModels.swift MyApp/TARSRuntime.swift MyApp/NativeWeatherLookup.swift MyApp/MigratingTARSRuntime.swift MyApp/XRPersistentMemory.swift MyApp/XRMemoryIntent.swift MyApp/MemoryTARSRuntime.swift Tests/NativeWeatherChecks.swift
run_check spoken-repair MyApp/HUDModels.swift MyApp/TARSRuntime.swift MyApp/NativeWeatherLookup.swift MyApp/NativePublicLookup.swift Tests/SpokenRepairChecks.swift
fi
run_check mail-command MyApp/MailCommand.swift Tests/MailCommandChecks.swift
if [[ "$(uname -s)" == Darwin ]]; then
  run_check yahoo-mail MyApp/MailCommand.swift MyApp/YahooIMAP.swift MyApp/YahooMessage.swift Tests/YahooChecks.swift
fi
run_check reconnection MyApp/ReconnectionPolicy.swift Tests/ReconnectionPolicyChecks.swift
run_check youtube-music MyApp/YouTubeMusic.swift Tests/YouTubeMusicChecks.swift
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
