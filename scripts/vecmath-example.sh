#!/usr/bin/env bash
set -euo pipefail
zig build example-vecmath
cp zig-out/lib/libvecmath.so examples/vecmath/vecmath.so
cd examples/vecmath
lua stubs.lua
lua example.lua
