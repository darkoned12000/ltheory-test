#!/bin/bash
# Bootstrap Limit Theory on Linux: install dependencies, configure, and build.
#
# Usage: ./bootstrap.sh
#
# Requires: sudo privileges (for apt) and Python 3.

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "==> Installing system dependencies (sudo) ..."
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  cmake \
  python3 \
  libglu1-mesa-dev \
  libglew-dev \
  libsdl2-dev \
  libfreetype6-dev \
  liblz4-dev \
  libluajit-5.1-dev \
  libbullet-dev

echo "==> Configuring build ..."
python3 configure.py

echo "==> Building ..."
python3 configure.py build

echo
echo "Build complete. Run the engine with:"
echo "  ./run.sh LTheory"
