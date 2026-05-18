#!/usr/bin/env bash
set -euo pipefail

zig build run-example-app-config -- examples/app-config/stubs.lua
mv app-config.d.lua examples/app-config/app-config.d.lua
zig build run-example-app-config -- examples/app-config/example.lua
