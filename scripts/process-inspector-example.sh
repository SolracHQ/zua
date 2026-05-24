#!/usr/bin/env bash
set -euo pipefail

zig build example-process-inspector

choice="$(
printf '%s\n' \
    'repl' \
    'example-script' \
    'generate-stubs' |
fzf --prompt='process-inspector> ' --height=40% --reverse
)"

case "$choice" in
    repl)
        zig build run-example-process-inspector
        ;;
    example-script)
        zig build run-example-process-inspector -- examples/process-inspector/example.lua
        ;;
    generate-stubs)
        zig build run-example-process-inspector -- examples/process-inspector/stubs.lua
        mv process-inspector.d.lua examples/process-inspector/process-inspector.d.lua
        echo "stubs written to examples/process-inspector/process-inspector.d.lua"
        ;;
    *)
        echo "aborted"
        exit 1
        ;;
esac
