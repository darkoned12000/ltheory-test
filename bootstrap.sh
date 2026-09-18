#!/bin/bash
# Bootstrap Limit Theory: install dependencies, configure, and build.
#
# Detects the local package manager at runtime so this works on Arch (pacman),
# Debian/Ubuntu (apt) and macOS (brew). Requires sudo privileges for the system
# dependency step, plus Python 3 to run the engine's own tooling.
#
# Usage: ./bootstrap.sh

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "==> Detecting package manager ..."
if command -v pacman >/dev/null 2>&1; then
  PKG="pacman"; OS="arch"
elif command -v apt-get >/dev/null 2>&1; then
  PKG="apt-get"; OS="debian"
elif command -v brew >/dev/null 2>&1; then
  PKG="brew"; OS="macos"
else
  echo "==> ERROR: could not detect a supported package manager."
  echo "       Supported: Arch (pacman), Debian/Ubuntu (apt-get), macOS (brew)."
  exit 1
fi
echo "==> Detected $PKG on $OS ..."

echo "==> Installing system dependencies ($PKG) ..."
case "$OS" in
  arch)
    # Bullet 3 is the engine's pinned runtime; SDL3/GLEW/LuaJIT are refreshed to
    # match the host. FreeType stays vendored (libphx/ext/include), so omit it.
    # NOTE: Arch has no 'build-essential' package -- use base-devel instead.
    sudo pacman -S --noconfirm \
      base-devel cmake python3 git \
      sdl3 glew luajit bullet lz4 lua51-filesystem
    ;;
  debian)
    sudo apt-get update
    sudo apt-get install -y \
      build-essential cmake python3 git \
      libglu1-mesa-dev libglew-dev libsdl3-dev liblz4-dev \
      libluajit-5.1-dev libbullet-dev lua-filesystem
    ;;
  macos)
    brew update
    brew install \
      build-essential cmake python3 \
      sdl3 glew luajit bullet luarocks
    # LuaFileSystem for the LuaJIT 5.1 runtime (script/env/ext/IOEx.lua):
    luarocks --lua-version=5.1 install luafilesystem || true
    # FreeType ships with Xcode Command Line Tools; ensure they're present:
    xcode-select --install >/dev/null 2>&1 || true
    ;;
esac

echo "==> Configuring build ..."
python3 configure.py

echo "==> Building ..."
python3 configure.py build

echo
echo "Build complete. Run the engine with:"
echo "  ./run.sh LTheory"
