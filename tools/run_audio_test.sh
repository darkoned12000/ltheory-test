#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -f screenshot/*
timeout 120 env PHX_MUTE=1 PHX_WINDOWED=1 PHX_FIXED_SIZE=1024,768 \
  PHX_FIXED_DT=0.016 PHX_AUDIOTEST=1 ./run.sh LTheory > /tmp/opencode/audio_test.log 2>&1 || true
if grep -q "\[AUDIOTEST\] FAIL:" /tmp/opencode/audio_test.log; then
  echo "AUDIO TEST: FAIL"; grep "\[AUDIOTEST\] FAIL:" /tmp/opencode/audio_test.log; exit 1
fi
if ! grep -q "\[AUDIOTEST\] ALL CHECKS PASSED" /tmp/opencode/audio_test.log; then
  echo "AUDIO TEST: no PASS marker"; tail -20 /tmp/opencode/audio_test.log; exit 1
fi
echo "AUDIO TEST: PASS"; grep "\[AUDIOTEST\] PASS:" /tmp/opencode/audio_test.log