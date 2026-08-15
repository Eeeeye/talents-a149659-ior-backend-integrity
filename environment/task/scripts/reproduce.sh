#!/usr/bin/env bash
set -uo pipefail

project_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
artifact_root=${1:-/tmp/ior-reproduction}
launcher=(mpirun --oversubscribe)

mkdir -p "$artifact_root"
cd "$project_root"

if [ ! -x src/ior ]; then
    scripts/build.sh >"$artifact_root/build.log" 2>&1 || exit 1
fi

run_case()
{
    local name=$1
    shift
    set +e
    "$@" >"$artifact_root/${name}.stdout" 2>"$artifact_root/${name}.stderr"
    local status=$?
    set -e
    printf '%s exit=%d\n' "$name" "$status"
}

set -e

run_case aio-corruption \
    "${launcher[@]}" -n 2 src/ior \
    -a AIO -b 4m -t 4k -s 2 -F -k -w -W -r -R -G 424242 \
    --aio.max-pending=128 --aio.granularity=16 \
    -o "$artifact_root/aio data"

run_case json-output \
    "${launcher[@]}" -n 2 src/ior \
    -a AIO -b 256k -t 4k -s 2 -F -k -w -r -v \
    --aio.max-pending=32 --aio.granularity=8 \
    -o "$artifact_root/json data" -O summaryFormat=JSON

run_case mpiio-accounting \
    "${launcher[@]}" -n 2 src/ior \
    -a MPIIO -b 96k -t 32k -s 2 -k -w -W -r -R -G 72821 \
    -o "$artifact_root/mpiio data"

echo "Artifacts written to: $artifact_root"
