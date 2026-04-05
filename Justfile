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
        guided-tour \
        introduction \
        functions \
        data-structures \
        custom-types

run-example name:
    zig build "run-example-{{name}}"

example:
    @fzf_args=(--prompt='zua example> ' --height=40% --reverse); \
    if [[ -n "${FZF_FILTER:-}" ]]; then \
        fzf_args+=(--filter "$FZF_FILTER"); \
    fi; \
    selection="$(just list-examples | fzf "${fzf_args[@]}")"; \
    [[ -n "${selection:-}" ]]; \
    just run-example "${selection}"