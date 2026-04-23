set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

test:
    zig build test

examples:
    zig build examples

all:
    just test
    just examples

list-examples:
    @printf '%s\n' \
        docs \
        guided-tour \
        introduction \
        functions \
        data-structures \
        custom-types \
        object-slices \
        nested-handle-ownership \
        custom-hooks \
        repl \
        iterable \
        dylib

run-example name:
    zig build "run-example-{{name}}"

dylib:
    @zig build vecmath
    @mkdir -p example/dylib
    @cp zig-out/lib/*vecmath* example/dylib/vecmath.so
    @cd example/dylib && lua use_it.lua

example:
    @fzf_args=(--prompt='zua example> ' --height=40% --reverse); \
    if [[ -n "${FZF_FILTER:-}" ]]; then \
        fzf_args+=(--filter "$FZF_FILTER"); \
    fi; \
    selection="$(just list-examples | fzf "${fzf_args[@]}")"; \
    [[ -n "${selection:-}" ]]; \
    if [[ "$selection" == "dylib" ]]; then \
        zig build vecmath; \
        mkdir -p dylib; \
        cp zig-out/lib/*vecmath* dylib/; \
    else \
        just run-example "${selection}"; \
    fi

docs:
    @cd handbook && mdbook build && rm -rf ../docs && mv book ../docs