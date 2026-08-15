#!/usr/bin/env bash
set -uo pipefail

project_root=/work/ior
verifier_root=/logs/verifier
case_root="/tmp/ior-verifier.$$"
reward_file="$verifier_root/reward.txt"
result_file="$verifier_root/results.tsv"
failures=0
CASE_RC=0
CASE_STDOUT=
CASE_STDERR=

mkdir -p "$verifier_root" "$case_root"
printf '0\n' >"$reward_file"
printf 'status\tcase\tdetail\n' >"$result_file"

pass_case()
{
    printf 'PASS\t%s\t%s\n' "$1" "${2:-ok}" | tee -a "$result_file"
}

fail_case()
{
    failures=$((failures + 1))
    printf 'FAIL\t%s\t%s\n' "$1" "$2" | tee -a "$result_file" >&2
}

run_capture()
{
    local name=$1
    local limit=$2
    shift 2
    CASE_STDOUT="$case_root/${name}.stdout"
    CASE_STDERR="$case_root/${name}.stderr"
    set +e
    timeout --signal=TERM --kill-after=2s "${limit}s" "$@" \
        >"$CASE_STDOUT" 2>"$CASE_STDERR"
    CASE_RC=$?
    set -e
}

has_integrity_error()
{
    grep -Eiq 'Incorrect data|ERROR: cannot (read|write)|data corruption' "$1" "$2"
}

has_human_summary()
{
    grep -q 'Summary of all tests:' "$1" \
        && grep -Eq '^[[:space:]]*write[[:space:]]' "$1" \
        && grep -Eq '^[[:space:]]*read[[:space:]]' "$1"
}

expect_clean_success()
{
    local name=$1
    if [ "$CASE_RC" -ne 0 ]; then
        fail_case "$name" "exit=$CASE_RC"
    elif has_integrity_error "$CASE_STDOUT" "$CASE_STDERR"; then
        fail_case "$name" "integrity error was reported"
    elif ! has_human_summary "$CASE_STDOUT"; then
        fail_case "$name" "human-readable write/read summary is missing"
    else
        pass_case "$name"
    fi
}

expect_mpiio_success()
{
    local name=$1
    if [ "$CASE_RC" -ne 0 ]; then
        fail_case "$name" "exit=$CASE_RC"
    elif has_integrity_error "$CASE_STDOUT" "$CASE_STDERR"; then
        fail_case "$name" "integrity error was reported"
    elif grep -Eiq 'partial (read|write)\(\)|too many retries' \
        "$CASE_STDOUT" "$CASE_STDERR"; then
        fail_case "$name" "a complete request was misclassified"
    elif ! has_human_summary "$CASE_STDOUT"; then
        fail_case "$name" "human-readable write/read summary is missing"
    else
        pass_case "$name"
    fi
}

expect_rejected()
{
    local name=$1
    if [ "$CASE_RC" -eq 0 ]; then
        fail_case "$name" "invalid limits were accepted"
    elif [ "$CASE_RC" -eq 124 ] || [ "$CASE_RC" -eq 137 ]; then
        fail_case "$name" "invalid limits caused a timeout"
    else
        pass_case "$name" "rejected with exit=$CASE_RC"
    fi
}

finish()
{
    if [ "$failures" -eq 0 ]; then
        printf '1\n' >"$reward_file"
        echo "All verifier cases passed."
        exit 0
    fi
    printf '0\n' >"$reward_file"
    echo "$failures verifier case(s) failed." >&2
    exit 1
}

cd "$project_root" || {
    fail_case setup "missing $project_root"
    finish
}

set +e
timeout --signal=TERM --kill-after=2s 240s ./scripts/build.sh \
    >"$case_root/build.stdout" 2>"$case_root/build.stderr"
build_rc=$?
set -e
if [ "$build_rc" -ne 0 ] || [ ! -x src/ior ]; then
    fail_case build "offline build failed with exit=$build_rc"
    finish
fi

elf_magic=$(od -An -t x1 -N4 src/ior | tr -d ' \n')
if [ "$elf_magic" != "7f454c46" ]; then
    fail_case build-artifact "src/ior is not an ELF executable"
    finish
fi
pass_case build "ELF binary produced"

if grep -R -n -E '/tests(/|\b)|/logs/verifier|reward\.txt' \
    --include='*.c' --include='*.h' --include='*.sh' src scripts/build.sh \
    >"$case_root/trust-zone-scan.txt" 2>&1; then
    fail_case trust-zone "candidate implementation references verifier-only paths"
fi

common_mpi=(mpirun --oversubscribe)

posix_path="$case_root/posix path/data"
mkdir -p "$(dirname -- "$posix_path")"
run_capture posix-first 45 "${common_mpi[@]}" -n 2 src/ior \
    -a POSIX -b 192k -t 24k -s 2 -F -k -w -W -r -R -G 314159 \
    -o "$posix_path"
expect_clean_success posix-first
run_capture posix-repeat 45 "${common_mpi[@]}" -n 2 src/ior \
    -a POSIX -b 192k -t 24k -s 2 -F -k -w -W -r -R -G 314159 \
    -o "$posix_path"
expect_clean_success posix-repeat

aio_one_path="$case_root/aio concurrent/data"
mkdir -p "$(dirname -- "$aio_one_path")"
run_capture aio-concurrent-128 90 "${common_mpi[@]}" -n 2 src/ior \
    -a AIO -b 4m -t 4k -s 2 -F -k -w -W -r -R -G 424242 \
    --aio.max-pending=128 --aio.granularity=16 -o "$aio_one_path"
expect_clean_success aio-concurrent-128

aio_two_path="$case_root/aio uneven/data"
mkdir -p "$(dirname -- "$aio_two_path")"
run_capture aio-concurrent-17 75 "${common_mpi[@]}" -n 1 src/ior \
    -a AIO -b 3m -t 8k -s 2 -F -k -w -W -r -R -G 987654 \
    --aio.max-pending=17 --aio.granularity=7 -o "$aio_two_path"
expect_clean_success aio-concurrent-17

aio_three_path="$case_root/aio boundary/data"
mkdir -p "$(dirname -- "$aio_three_path")"
run_capture aio-concurrent-8 75 "${common_mpi[@]}" -n 3 src/ior \
    -a AIO -b 2m -t 64k -s 2 -F -k -w -W -r -R -G 246810 \
    --aio.max-pending=8 --aio.granularity=8 -o "$aio_three_path"
expect_clean_success aio-concurrent-8

aio_four_path="$case_root/aio granularity one/data"
mkdir -p "$(dirname -- "$aio_four_path")"
run_capture aio-granularity-1 75 "${common_mpi[@]}" -n 2 src/ior \
    -a AIO -b 2m -t 16k -s 2 -F -k -w -W -r -R -G 112358 \
    --aio.max-pending=8 --aio.granularity=1 -o "$aio_four_path"
expect_clean_success aio-granularity-1

run_capture aio-invalid-pending 20 "${common_mpi[@]}" -n 1 src/ior \
    -a AIO -b 64k -t 4k -s 1 -F -w -r \
    --aio.max-pending=7 --aio.granularity=1 \
    -o "$case_root/aio-invalid-pending"
expect_rejected aio-invalid-pending

run_capture aio-invalid-granularity 20 "${common_mpi[@]}" -n 1 src/ior \
    -a AIO -b 64k -t 4k -s 1 -F -w -r \
    --aio.max-pending=8 --aio.granularity=9 \
    -o "$case_root/aio-invalid-granularity"
expect_rejected aio-invalid-granularity

for specification in 'POSIX:1' 'MPIIO:2' 'AIO:3'; do
    api=${specification%%:*}
    ranks=${specification##*:}
    lower_api=$(printf '%s' "$api" | tr '[:upper:]' '[:lower:]')
    json_path="$case_root/json $lower_api/data"
    mkdir -p "$(dirname -- "$json_path")"
    extra_options=()
    if [ "$api" = AIO ]; then
        extra_options=(--aio.max-pending=11 --aio.granularity=5)
    fi
    run_capture "json-$lower_api" 60 "${common_mpi[@]}" -n "$ranks" src/ior \
        -a "$api" -b 160k -t 8k -s 2 -F -k -w -r -v -G 13579 \
        "${extra_options[@]}" -o "$json_path" -O summaryFormat=JSON
    if [ "$CASE_RC" -ne 0 ]; then
        fail_case "json-$lower_api" "benchmark exit=$CASE_RC"
    elif ! perl /tests/validate_json.pl "$CASE_STDOUT" "$api" "$ranks" \
        8192 163840 1 \
        >"$case_root/json-$lower_api.validate" 2>&1; then
        fail_case "json-$lower_api" "stdout is not a complete semantic JSON summary"
    else
        pass_case "json-$lower_api"
    fi
done

mpiio_explicit_path="$case_root/mpiio explicit/data"
mkdir -p "$(dirname -- "$mpiio_explicit_path")"
run_capture mpiio-explicit 60 "${common_mpi[@]}" -n 2 src/ior \
    -a MPIIO -b 96k -t 32k -s 2 -k -w -W -r -R -G 192837 \
    -o "$mpiio_explicit_path"
expect_mpiio_success mpiio-explicit

mpiio_large_path="$case_root/mpiio 64k/data"
mkdir -p "$(dirname -- "$mpiio_large_path")"
run_capture mpiio-explicit-64k 60 "${common_mpi[@]}" -n 1 src/ior \
    -a MPIIO -b 256k -t 64k -s 2 -k -w -W -r -R -G 192841 \
    -o "$mpiio_large_path"
expect_mpiio_success mpiio-explicit-64k

mpiio_view_path="$case_root/mpiio view/data"
mkdir -p "$(dirname -- "$mpiio_view_path")"
run_capture mpiio-file-view 60 "${common_mpi[@]}" -n 2 src/ior \
    -a MPIIO -b 96k -t 32k -s 2 -k -w -W -r -R -G 192838 \
    --mpiio.useFileView -o "$mpiio_view_path"
expect_mpiio_success mpiio-file-view

mpiio_collective_path="$case_root/mpiio collective/data"
mkdir -p "$(dirname -- "$mpiio_collective_path")"
run_capture mpiio-collective 60 "${common_mpi[@]}" -n 3 src/ior \
    -a MPIIO -b 128k -t 16k -s 2 -k -w -W -r -R -c -G 192839 \
    -o "$mpiio_collective_path"
expect_mpiio_success mpiio-collective

mpiio_fpp_path="$case_root/mpiio file per process/data"
mkdir -p "$(dirname -- "$mpiio_fpp_path")"
run_capture mpiio-file-per-process 60 "${common_mpi[@]}" -n 3 src/ior \
    -a MPIIO -b 72k -t 8k -s 2 -F -k -w -W -r -R -G 192840 \
    -o "$mpiio_fpp_path"
expect_mpiio_success mpiio-file-per-process

finish
