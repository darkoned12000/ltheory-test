#!/bin/bash
# Launch the Limit Theory engine.
#
# Usage: ./run.sh [AppName]
#   AppName defaults to 'LTheory' (e.g. ./run.sh LTheory)
#
# The executable and its shared libraries (libphx64r.so, FMOD) live under
# ./bin and ./libphx/ext/lib/linux64. They are found via $ORIGIN-based rpath,
# so LD_LIBRARY_PATH is normally NOT required. This script still exports it as
# a safety net for unusual setups.

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-LTheory}"

export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$ROOT/bin:$ROOT/libphx/ext/lib/linux64"

exec "$ROOT/bin/lt64r" "$APP"
