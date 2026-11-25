#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf screenshot/*
timeout -k 2 30 env PHX_MUTE=1 PHX_WINDOWED=1 PHX_FIXED_SIZE=1024,768 \
  PHX_FIXED_DT=0.016 PHX_SAVENOW=phase1-save-test ./run.sh LTheory > /tmp/opencode/save_test.log 2>&1 || true
if grep -q "\[SAVE TEST\] FAIL:" /tmp/opencode/save_test.log; then
  echo "SAVE TEST: FAIL"; grep "\[SAVE TEST\] FAIL:" /tmp/opencode/save_test.log; exit 1
fi
if ! grep -q "\[SAVE TEST\] ALL CHECKS PASSED" /tmp/opencode/save_test.log; then
  echo "SAVE TEST: no PASS marker"; tail -20 /tmp/opencode/save_test.log; exit 1
fi
echo "SAVE TEST: PASS"; grep "\[SAVE TEST\]" /tmp/opencode/save_test.log