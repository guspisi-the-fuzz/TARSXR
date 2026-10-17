#!/usr/bin/env bash
# Build/test only: never flash, connect serial, pair, ARM, move or publish.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export TARS_VALIDATION_DIR="${TARS_VALIDATION_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/tars-spatial-validation.XXXXXX")}"
if [[ "$(uname -s)" == Darwin ]]; then
  bash scripts/validate-conversation-simulator.sh
else
  bash scripts/validate-runtime-boundary.sh
fi
TARS_BODY_ROOT="${TARS_FIRMWARE_DIR:-$HOME/Documents/TARS/Software/TARS-RC3/tars-firmware}"
python3 scripts/audit-spatial-body.py "$TARS_BODY_ROOT" --output "$TARS_VALIDATION_DIR/firmware-inventory.json"
if [[ -f "$TARS_BODY_ROOT/scripts/test_host.sh" ]]; then
  bash "$TARS_BODY_ROOT/scripts/test_host.sh" > "$TARS_VALIDATION_DIR/firmware-host.log" 2>&1 || { cat "$TARS_VALIDATION_DIR/firmware-host.log"; exit 1; }
  cat "$TARS_VALIDATION_DIR/firmware-host.log"
else
  echo 'NOT RUN: firmware host tests; local firmware repository not found.'
fi
if [[ -f "$TARS_BODY_ROOT/platformio.ini" ]] && PLATFORMIO_SETTING_ENABLE_TELEMETRY=no python3 -m platformio --version > /dev/null 2>&1; then
  (cd "$TARS_BODY_ROOT" && PLATFORMIO_SETTING_ENABLE_TELEMETRY=no python3 -m platformio run) > "$TARS_VALIDATION_DIR/firmware-build.log" 2>&1 || { tail -80 "$TARS_VALIDATION_DIR/firmware-build.log"; exit 1; }
  tail -12 "$TARS_VALIDATION_DIR/firmware-build.log"
else
  echo 'NOT RUN: ESP32 build; requires local firmware repository and PlatformIO.'
fi
if [[ -f "$TARS_BODY_ROOT/scripts/test_virtual.sh" && -d "$TARS_BODY_ROOT/.pio/libdeps/esp32dev/ArduinoJson/src" ]]; then
  bash "$TARS_BODY_ROOT/scripts/test_virtual.sh" > "$TARS_VALIDATION_DIR/firmware-virtual.log" 2>&1 || { cat "$TARS_VALIDATION_DIR/firmware-virtual.log"; exit 1; }
  cat "$TARS_VALIDATION_DIR/firmware-virtual.log"
else
  echo 'NOT RUN: firmware integrated virtual tests; ArduinoJson dependency not installed in that repository.'
fi
printf '%s\n' 'Bancada validada apenas nas verificacoes executadas acima. NOT RUN significa pendencia.' 'Nenhum teste fisico, flash, movimento ou publicacao realizado. Integracao fisica de 4D continua pendente.' "Logs: $TARS_VALIDATION_DIR"
