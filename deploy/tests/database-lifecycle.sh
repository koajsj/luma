#!/usr/bin/env bash
# Local control-flow regression. No Docker, installed files or databases touched.
set -Eeuo pipefail
source "$(dirname "$0")/../lib.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
compose() {
    printf '%s\n' "$*" >> "$work/calls"
    [[ ${fail:-} != "$*" ]]
}
expected=$'up -d --wait postgres redis\nrun --rm --no-deps migrate\nrun --rm --no-deps db-grants\nup -d --no-deps --wait backend\nup -d --no-deps --wait caddy'
fail=''
start_services
[[ $(cat "$work/calls") == "$expected" ]]
for fail in 'up -d --wait postgres redis' 'run --rm --no-deps migrate' \
    'run --rm --no-deps db-grants' 'up -d --no-deps --wait backend'; do
    : > "$work/calls"
    if start_services; then printf 'Accepted failed stage: %s\n' "$fail" >&2; exit 1; fi
    [[ $(tail -1 "$work/calls") == "$fail" ]] # No API/proxy start after a failed prerequisite.
done
fail=''
: > "$work/calls"
resume_services
[[ $(cat "$work/calls") == $'up -d --no-deps --wait backend\nup -d --no-deps --wait caddy' ]]
printf 'Database lifecycle ordering and failure gates passed (control-flow only).\n'
