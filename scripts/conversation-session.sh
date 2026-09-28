#!/bin/sh
# Explicit online test: speech, including pre-wake speech, goes to OpenAI.
# Limits: 15 minutes / 30 audio uploads. Silence is discarded.
set -eu
export SIMCTL_CHILD_TARS_PAUSE_VOICE=0
export SIMCTL_CHILD_TARS_EARLY_RESPONSE="${TARS_EARLY_RESPONSE:-0}"
export SIMCTL_CHILD_TARS_STREAM_VOICE="${TARS_STREAM_VOICE:-0}"
export SIMCTL_CHILD_TARS_ONLINE_WAKE=1
export SIMCTL_CHILD_TARS_VOICE_SESSION=conversation
export SIMCTL_CHILD_TARS_VOICE_CHECKS=0
export SIMCTL_CHILD_TARS_LOCAL_VOICE_PROBE=0
export SIMCTL_CHILD_TARS_MANUAL_DIAGNOSTICS=0
exec xcrun simctl launch --terminate-running-process booted com.pisi.tarsxr
