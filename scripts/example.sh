#!/usr/bin/env bash
set -euo pipefail

list_examples() {
    printf '%s\n' \
        vecmath \
        app-config \
        process-inspector
}

fzf_args=(--prompt='zua example> ' --height=40% --reverse)
if [[ -n "${FZF_FILTER:-}" ]]; then
    fzf_args+=(--filter "$FZF_FILTER")
fi

selection="$(list_examples | fzf "${fzf_args[@]}")"
[[ -n "${selection:-}" ]]

"$(dirname "$0")/${selection}-example.sh"
