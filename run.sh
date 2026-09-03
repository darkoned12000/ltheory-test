#!/bin/bash
# Launch the Limit Theory engine.
#
# Usage: ./run.sh [AppName]
#   AppName defaults to 'LTheory' (e.g. ./run.sh LTheory)
#
# On Wayland we drive SDL2 through the native Wayland backend so the window is a
# first-class compositor client (rather than a tiler-less throwaway X server).
# A native-Wayland window gets proper decorations, a close button, and lets
# Hyprland tile/clamp it to the requested size. DISPLAY is cleared so a stale
# X11 address never makes SDL fall back to an unreachable/undecorated X server.

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-LTheory}"

export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$ROOT/bin:$ROOT/libphx/ext/lib/linux64"

if [[ -n "$WAYLAND_DISPLAY" ]]; then
    export SDL_VIDEODRIVER="wayland"
    unset DISPLAY
fi

exec "$ROOT/bin/lt64r" "$APP"
