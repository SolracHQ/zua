#!/usr/bin/env bash
set -euo pipefail

case "${1:-all}" in
    test)
        zig build test
        ;;
    examples)
        zig build examples
        ;;
    all)
        zig build test
        zig build examples
        ;;
    *)
        echo "usage: $0 [test|examples|all]" >&2
        exit 1
        ;;
esac
