#!/usr/bin/env bash
# Headless UI smoke test for the main menu + market flow.
#
# Boots LTheory with PHX_UITEST=1, which drives the menu/market/undock
# flow and prints [UITEST] PASS/FAIL lines. Exits non-zero if any FAIL
# (or if ALL CHECKS PASSED is missing).
set -euo pipefail
cd "$(dirname "$0")/.."

rm -f screenshot/*
timeout 120 env PHX_MUTE=1 PHX_WINDOWED=1 PHX_FIXED_SIZE=1024,768 \
  PHX_FIXED_DT=0.016 PHX_UITEST=1 ./run.sh LTheory > /tmp/opencode/ui_test.log 2>&1 || true

if grep -q "\[UITEST\] FAIL:" /tmp/opencode/ui_test.log; then
  echo "UI TEST: FAIL"
  grep "\[UITEST\] FAIL:" /tmp/opencode/ui_test.log
  exit 1
fi
if ! grep -q "\[UITEST\] ALL CHECKS PASSED" /tmp/opencode/ui_test.log; then
  echo "UI TEST: no PASS marker (crash or hang?)"
  tail -20 /tmp/opencode/ui_test.log
  exit 1
fi
echo "UI TEST: PASS"
grep "\[UITEST\] PASS:" /tmp/opencode/ui_test.log