# Restore trustworthy I/O validation across IOR backends

## Background

This repository contains IOR, used by an HPC operations team to qualify a
parallel filesystem before compute partitions are opened to users. The same
binary exercises POSIX, MPI-IO, and Linux native AIO and emits either a human
summary or a JSON document consumed by the qualification pipeline.

The current Starter builds, and ordinary POSIX runs look healthy. The full
qualification profile does not: asynchronous checks report data corruption,
normal MPI-IO transfers are repeatedly misclassified as incomplete, and JSON
mode produces output that parsers reject. Less common production boundaries
also expose dropped AIO submissions and duplicate file targets during seeded
rank shuffling. A qualification result is usable only when every selected
backend, every rank-to-file assignment, and the result document are
trustworthy.

Work in `/work/ior`. All required tools and dependencies are already present.

## Initial symptoms

Build and reproduce the supplied incident with:

```bash
./scripts/build.sh
./scripts/reproduce.sh "/tmp/ior reproduction"
```

On the Starter, the artifact directory shows all of the following:

- the concurrent AIO case reports `Incorrect data` during write-check and/or
  read-check;
- `json-output.stdout` is not one decodable JSON document and can contain
  ordinary log or numeric lines inside the document;
- an ordinary MPI-IO run emits messages such as `65536 of 32768 bytes`,
  retries an operation that already completed, and eventually aborts.

Additional production-style invocations expose these boundaries:

- JSON paths or arguments containing quotes, backslashes, or ASCII control
  characters corrupt the document instead of round-tripping as strings;
- repeating `-Z` for seeded shuffle mode can direct more than one rank to the
  same file while another file is not read at all.

## Required final behavior

Repair the implementation so that all requirements below hold.

### 1. Build and preserved behavior

- `./scripts/build.sh` must complete using the supplied toolchain and produce
  `./src/ior`.
- Existing CLI options and the POSIX, MPIIO, and AIO backend names must remain
  available. Do not replace IOR with a wrapper or a different program.
- Ordinary POSIX write, read, write-check, and read-check runs must continue to
  succeed with their existing data pattern and human-readable summary.
- Paths containing spaces, one to three local MPI ranks, file-per-process and
  shared-file layouts must work. Repeating an ordinary POSIX run against the
  same path must also remain safe.

### 2. Linux AIO completion and buffer integrity

For aligned transfers from 4 KiB through 64 KiB, `aio.max-pending` values from
8 through 128, and `aio.granularity` values from 1 through the configured
pending limit:

- `-w -W -r -R` must exit zero and report no incorrect data;
- concurrent requests must not observe later reuse of caller-owned transfer
  storage;
- when IOR immediately consumes a read buffer for write-check or read-check,
  the backend must not return until that specific read is complete;
- flushing and finalizing must complete every submitted normal operation
  without hanging or reporting success while bytes remain outstanding;
- a positive `io_submit` result smaller than the requested batch accepts only
  that prefix: all remaining requests must still be submitted exactly once;
- transient libaio `-EINTR` returns from submission or completion collection
  must be retried without losing, duplicating, or prematurely completing I/O;
- a completion is successful only when its primary result equals that
  request's byte count and its secondary result is zero. A short completion,
  negative completion, or nonzero secondary result must terminate the run
  nonzero with an explicit AIO diagnostic rather than hang or silently pass;
- the existing validation of `aio.max-pending < 8` and
  `aio.granularity > aio.max-pending` must remain in force.

### 3. MPI-IO completed-byte accounting

For explicit-offset, collective, and `--mpiio.useFileView` access, the
completed-byte count returned to IOR must equal the amount of data actually
transferred.

- A fully completed request must not be reported as smaller or larger than the
  requested transfer.
- Transfer sizes from 8 KiB through 64 KiB must complete without spurious
  `partial read()` or `partial write()` warnings and without unnecessary retry.
- File-view access using derived transfer datatypes must be measured in bytes,
  not in an unrelated predefined datatype's elements.
- Existing CLI selection of explicit-offset, collective, and file-view modes
  must remain available.

### 4. Machine-readable output

When `-O summaryFormat=JSON` is selected, standard output must contain exactly
one RFC 8259 JSON document for POSIX, MPIIO, and AIO runs. This also applies to
multi-rank execution and `-v`.

- No rank may add a diagnostic number, banner, participation line, or trailing
  bracket outside the document.
- Every JSON string must use RFC 8259 escaping. In particular, command-line
  arguments and paths containing `"`, `\`, tab, newline, carriage return,
  backspace, form feed, or another representable U+0001--U+001F character must
  decode to the original string value rather than corrupting the document.
- The top level must be an object containing non-empty string fields
  `Version`, `Began`, `Finished`, and `Command line`, plus `tests` and
  `summary` arrays. Additional normal IOR fields are allowed.
- For one CLI test invocation, `tests` must contain exactly one object. Its
  `Parameters` object must contain:
  - `api`: a string equal to the selected backend name;
  - `tasksPerNode`: a number equal to the launched local MPI task count;
  - `transferSize` and `blockSize`: numbers in bytes equal to the selected
    `-t` and `-b` values;
  - `filePerProc`: the numeric `0` or `1` value matching whether `-F`
    is disabled or enabled;
  - `segmentCount`: a number equal to the selected `-s` value.
- That test object's `Results` field must be an array. When both write and
  read are requested, it must contain objects whose `access` strings are
  `write` and `read`. Each such object must contain non-negative numeric
  `bwMiB`, `blockKiB`, `xferKiB`, `iops`, and `totalTime` fields;
  `blockKiB` and `xferKiB` must equal the selected byte sizes divided by
  1024.
- `summary` must be a non-empty array. When both write and read are requested,
  it must contain at least one object for each operation. Every such object
  must contain `operation` (`write` or `read`), `API` (the selected
  backend string), and numeric `numTasks`, `transferSize`, `blockSize`,
  `filePerProc`, and `segmentCount` values matching the invocation.
- Producing an empty object, omitting the required metadata or records, or
  reporting parameters that do not match the invocation is not acceptable.
- When a configuration file contains multiple `RUN` entries, `tests` must
  contain one object per entry in run order, and `summary` must contain the
  corresponding write/read records for every entry. No entry may overwrite,
  duplicate, or absorb another entry's records.
- Human-readable output without JSON mode must remain available.

### 5. Seeded rank-shuffle readback

For file-per-process POSIX readback with three to five local MPI ranks,
repeating `-Z` twice selects seeded shuffle mode. For a fixed `-X` seed and
repetition:

- every launched rank must read exactly one rank file;
- the selected file indices must form a one-to-one permutation of all rank
  files, with no duplicate target and no omitted file;
- at least one rank must be moved away from its own file;
- repeating the same invocation must reproduce the same mapping;
- a single `-Z` must retain its existing random-reorder behavior.

At verbose level 3, the existing `task N reading PATH` lines must truthfully
identify the files actually opened. Compliant implementations may choose any
deterministic permutation; one exact hard-coded order is not required.

## Failure safety and limits

- Do not hide `Incorrect data`, force exit status zero, fabricate a summary or
  rank mapping, disable checks, serialize the entire benchmark in a front-end
  wrapper, or substitute another I/O API for the selected backend.
- The repair must work for values within the stated ranges rather than only
  for the literal seeds and sizes in the public reproducer.
- Normal completion must close its files and finish all selected operations
  before the process exits.

## Allowed changes

You may modify IOR source and build material under:

```text
src/**
config/**
Makefile.am
configure.ac
scripts/build.sh
```

Do not modify the supplied incident logs, case files, source/licensing notices,
or `scripts/reproduce.sh`. Do not add system packages or fetch additional code.
Tests and the reference repair are not present in the candidate environment.
