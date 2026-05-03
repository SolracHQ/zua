#!/usr/bin/env bash
set -euo pipefail

list_examples() {
    printf '%s\n' \
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
}

fzf_args=(--prompt='zua example> ' --height=40% --reverse)
if [[ -n "${FZF_FILTER:-}" ]]; then
    fzf_args+=(--filter "$FZF_FILTER")
fi

selection="$(list_examples | fzf "${fzf_args[@]}")"
[[ -n "${selection:-}" ]]

if [[ "$selection" == "dylib" ]]; then
    "$(dirname "$0")/dylib.sh"
else
    "$(dirname "$0")/run-example.sh" "$selection"
fi
