#!/usr/bin/env bash
# Runtime HoloNodeDemo smoke test. Process-status and marker handling lives in
# configure.run_holo_integration_test(), which is covered by
# tools/validate_holo_runner.py; keeping one implementation avoids drift.
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import configure
raise SystemExit(configure.run_holo_integration_test())
PY

echo "HOLO TEST: PASS"
