#!/bin/bash
set -euo pipefail

project_root=${IOR_PROJECT_ROOT:-/work/ior}
solution_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
reference_patch="$solution_root/reference.patch"

cd "$project_root"

if patch --batch --silent --dry-run -p1 <"$reference_patch"; then
    patch --batch -p1 <"$reference_patch"
elif patch --batch --silent --dry-run -R -p1 <"$reference_patch"; then
    echo "Reference repair is already applied."
else
    echo "The source tree does not match the authorized Starter or repaired state." >&2
    exit 1
fi

./scripts/build.sh
