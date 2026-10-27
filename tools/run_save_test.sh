#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf screenshot/*
timeout 120 env PHX_MUTE=1 PHX_WINDOWED=1 PHX_FIXED_SIZE=1024,768 \
  PHX_FIXED_DT=0.016 PHX_SAVETEST=1 ./run.sh LTheory > /tmp/opencode/save_test.log 2>&1 || true
if grep -q "\[SAVETEST\] FAIL:" /tmp/opencode/save_test.log; then
  echo "SAVE TEST: FAIL"; grep "\[SAVETEST\] FAIL:" /tmp/opencode/save_test.log; exit 1
fi
if ! grep -q "\[SAVETEST\] ALL CHECKS PASSED" /tmp/opencode/save_test.log; then
  echo "SAVE TEST: no PASS marker"; tail -20 /tmp/opencode/save_test.log; exit 1
fi
echo "SAVE TEST: PASS"; grep "\[SAVETEST\] PASS:" /tmp/opencode/save_test.log