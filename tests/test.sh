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

expect_aio_fault_failure()
{
    local name=$1
    local diagnostic=$2
    if [ "$CASE_RC" -eq 0 ]; then
        fail_case "$name" "faulted completion was accepted"
    elif [ "$CASE_RC" -eq 124 ] || [ "$CASE_RC" -eq 137 ]; then
        fail_case "$name" "faulted completion caused a timeout"
    elif ! grep -Eiq "$diagnostic" "$CASE_STDOUT" "$CASE_STDERR"; then
        fail_case "$name" "explicit AIO completion diagnostic is missing"
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

aio_fault_shim="$case_root/libaio-faults.so"
if ! cc -shared -fPIC -O2 -Wall -Wextra \
    -o "$aio_fault_shim" /tests/aio_fault_shim.c -ldl \
    >"$case_root/aio-shim-build.stdout" \
    2>"$case_root/aio-shim-build.stderr"; then
    fail_case aio-fault-shim-build "verifier fault injector did not compile"
    finish
fi
pass_case aio-fault-shim-build "verifier-only injector compiled"

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

aio_transient_path="$case_root/aio transient boundaries/data"
mkdir -p "$(dirname -- "$aio_transient_path")"
run_capture aio-transient-boundaries 60 env \
    LD_PRELOAD="$aio_fault_shim" \
    IOR_AIO_FAULT_MODE=transient-boundaries \
    "${common_mpi[@]}" -n 1 src/ior \
    -a AIO -b 512k -t 4k -s 1 -F -k -w -W -r -R -G 161803 \
    --aio.max-pending=16 --aio.granularity=8 -o "$aio_transient_path"
expect_clean_success aio-transient-boundaries

aio_short_path="$case_root/aio short completion/data"
mkdir -p "$(dirname -- "$aio_short_path")"
run_capture aio-short-completion 30 env \
    LD_PRELOAD="$aio_fault_shim" \
    IOR_AIO_FAULT_MODE=short-completion \
    "${common_mpi[@]}" -n 1 src/ior \
    -a AIO -b 128k -t 4k -s 1 -F -k -w -G 141421 \
    --aio.max-pending=8 --aio.granularity=4 -o "$aio_short_path"
expect_aio_fault_failure aio-short-completion \
    'AIO, short completion|AIO short verification read'

aio_negative_path="$case_root/aio negative completion/data"
mkdir -p "$(dirname -- "$aio_negative_path")"
run_capture aio-negative-completion 30 env \
    LD_PRELOAD="$aio_fault_shim" \
    IOR_AIO_FAULT_MODE=negative-completion \
    "${common_mpi[@]}" -n 1 src/ior \
    -a AIO -b 128k -t 4k -s 1 -F -k -w -G 151657 \
    --aio.max-pending=8 --aio.granularity=4 -o "$aio_negative_path"
expect_aio_fault_failure aio-negative-completion \
    'AIO, error in io_event result|AIO error:'

aio_secondary_path="$case_root/aio secondary error/data"
mkdir -p "$(dirname -- "$aio_secondary_path")"
run_capture aio-secondary-error 30 env \
    LD_PRELOAD="$aio_fault_shim" \
    IOR_AIO_FAULT_MODE=secondary-error \
    "${common_mpi[@]}" -n 1 src/ior \
    -a AIO -b 128k -t 4k -s 1 -F -k -w -G 173205 \
    --aio.max-pending=8 --aio.granularity=4 -o "$aio_secondary_path"
expect_aio_fault_failure aio-secondary-error \
    'AIO, secondary completion error|AIO secondary error'

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
        8192 163840 1 2 \
        >"$case_root/json-$lower_api.validate" 2>&1; then
        fail_case "json-$lower_api" "stdout is not a complete semantic JSON summary"
    else
        pass_case "json-$lower_api"
    fi
done

json_escaped_path="$case_root/json \"quoted\" \\ backslash"$'\t'"tab"$'\n'"newline"$'\r'"return"$'\b'"backspace"$'\f'"formfeed/data"
mkdir -p "$(dirname -- "$json_escaped_path")"
run_capture json-escaped-path 60 "${common_mpi[@]}" -n 2 src/ior \
    -a POSIX -b 96k -t 12k -s 3 -F -k -w -r -v -G 223606 \
    -o "$json_escaped_path" -O summaryFormat=JSON
if [ "$CASE_RC" -ne 0 ]; then
    fail_case json-escaped-path "benchmark exit=$CASE_RC"
elif ! perl /tests/validate_json.pl "$CASE_STDOUT" POSIX 2 \
    12288 98304 1 3 "$json_escaped_path" \
    >"$case_root/json-escaped-path.validate" 2>&1; then
    fail_case json-escaped-path "JSON strings did not round-trip the path"
else
    pass_case json-escaped-path
fi

run_capture json-multiple-runs 75 "${common_mpi[@]}" -n 2 src/ior \
    -f /tests/json-multi.ior -O summaryFormat=JSON
if [ "$CASE_RC" -ne 0 ]; then
    fail_case json-multiple-runs "benchmark exit=$CASE_RC"
elif ! perl /tests/validate_json_multi.pl "$CASE_STDOUT" \
    >"$case_root/json-multiple-runs.validate" 2>&1; then
    fail_case json-multiple-runs "multi-RUN JSON document is incomplete"
else
    pass_case json-multiple-runs
fi

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

rank_single_path="$case_root/rank single z/data"
mkdir -p "$(dirname -- "$rank_single_path")"
run_capture rank-single-z 45 "${common_mpi[@]}" -n 3 src/ior \
    -a POSIX -b 64k -t 4k -s 1 -F -k -w -W -r -R -Z -X=17 -vv \
    -G 244949 -o "$rank_single_path"
expect_clean_success rank-single-z

rank_shuffle_path="$case_root/rank shuffle/data"
mkdir -p "$(dirname -- "$rank_shuffle_path")"
run_capture rank-shuffle-first 45 "${common_mpi[@]}" -n 3 src/ior \
    -a POSIX -b 64k -t 4k -s 1 -F -k -w -r -Z -Z -X=0 -vvv \
    -o "$rank_shuffle_path"
rank_shuffle_first_rc=$CASE_RC
rank_shuffle_first_stdout=$CASE_STDOUT
run_capture rank-shuffle-repeat 45 "${common_mpi[@]}" -n 3 src/ior \
    -a POSIX -b 64k -t 4k -s 1 -F -k -w -r -Z -Z -X=0 -vvv \
    -o "$rank_shuffle_path"
rank_shuffle_repeat_rc=$CASE_RC
rank_shuffle_repeat_stdout=$CASE_STDOUT
if [ "$rank_shuffle_first_rc" -ne 0 ] || [ "$rank_shuffle_repeat_rc" -ne 0 ]; then
    fail_case rank-shuffle-permutation \
        "benchmark exits=$rank_shuffle_first_rc,$rank_shuffle_repeat_rc"
elif ! perl /tests/validate_rank_shuffle.pl "$rank_shuffle_first_stdout" 3 \
    >"$case_root/rank-shuffle-first.map" 2>"$case_root/rank-shuffle-first.validate" \
    || ! perl /tests/validate_rank_shuffle.pl "$rank_shuffle_repeat_stdout" 3 \
    >"$case_root/rank-shuffle-repeat.map" 2>"$case_root/rank-shuffle-repeat.validate"; then
    fail_case rank-shuffle-permutation "read targets are not a one-to-one permutation"
elif ! cmp -s "$case_root/rank-shuffle-first.map" \
    "$case_root/rank-shuffle-repeat.map"; then
    fail_case rank-shuffle-permutation "fixed seed did not reproduce the mapping"
else
    pass_case rank-shuffle-permutation
fi

rank_shuffle_five_path="$case_root/rank shuffle five/data"
mkdir -p "$(dirname -- "$rank_shuffle_five_path")"
run_capture rank-shuffle-five 45 "${common_mpi[@]}" -n 5 src/ior \
    -a POSIX -b 32k -t 4k -s 1 -F -k -w -r -Z -Z -X=2 -vvv \
    -o "$rank_shuffle_five_path"
if [ "$CASE_RC" -ne 0 ]; then
    fail_case rank-shuffle-five "benchmark exit=$CASE_RC"
elif ! perl /tests/validate_rank_shuffle.pl "$CASE_STDOUT" 5 \
    >"$case_root/rank-shuffle-five.map" 2>"$case_root/rank-shuffle-five.validate"; then
    fail_case rank-shuffle-five "five-rank targets are not a one-to-one permutation"
else
    pass_case rank-shuffle-five
fi

finish
