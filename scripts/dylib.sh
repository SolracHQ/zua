#!/usr/bin/env bash
set -euo pipefail
zig build vecmath --release=safe
mkdir -p example/dylib
cp zig-out/lib/*vecmath* example/dylib/vecmath.so
cd example/dylib && lua use_it.lua
