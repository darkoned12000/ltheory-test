#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf screenshot/*
timeout 120 env PHX_MUTE=1 PHX_WINDOWED=1 PHX_FIXED_SIZE=1024,768 \
  PHX_FIXED_DT=0.016 PHX_ECONTEST=1 ./run.sh LTheory > /tmp/opencode/econ_test.log 2>&1 || true
if grep -q "\[ECONTEST\] FAIL:" /tmp/opencode/econ_test.log; then
  echo "ECON TEST: FAIL"; grep "\[ECONTEST\] FAIL:" /tmp/opencode/econ_test.log; exit 1
fi
if ! grep -q "\[ECONTEST\] ALL CHECKS PASSED" /tmp/opencode/econ_test.log; then
  echo "ECON TEST: no PASS marker"; tail -20 /tmp/opencode/econ_test.log; exit 1
fi
echo "ECON TEST: PASS"; grep "\[ECONTEST\] PASS:" /tmp/opencode/econ_test.log