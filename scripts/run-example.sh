#!/usr/bin/env bash
set -euo pipefail
zig build "run-example-${1:?missing example name}"
