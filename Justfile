set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

run *ARGS:
    zig build run -- {{ARGS}}

test:
    ./scripts/ci.sh test

examples:
    ./scripts/ci.sh examples

all:
    ./scripts/ci.sh

run-example name:
    ./scripts/run-example.sh {{name}}

example:
    ./scripts/example.sh

docs:
    @cd handbook && mdbook serve --open
