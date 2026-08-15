#!/usr/bin/env bash
set -euo pipefail

project_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build_jobs=${BUILD_JOBS:-2}

case "$build_jobs" in
    ''|*[!0-9]*)
        echo "BUILD_JOBS must be a positive integer" >&2
        exit 2
        ;;
    0)
        echo "BUILD_JOBS must be greater than zero" >&2
        exit 2
        ;;
esac

cd "$project_root"
./bootstrap
CC=mpicc ./configure --with-aio --with-mpiio --with-posix
make -j"$build_jobs"
