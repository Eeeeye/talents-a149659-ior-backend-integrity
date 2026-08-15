# Captured Starter output

These excerpts were captured from the unmodified public Starter with
`scripts/reproduce.sh`. Container IDs, timestamps, capacity figures, and
throughput measurements were removed because they vary between runs. Error
text, command arguments, counts, offsets, and exit behavior are unchanged.

- `aio-corruption.log`: concurrent Linux AIO write-check/read-check failure.
- `json-output-invalid.log`: non-JSON lines embedded in JSON mode.
- `mpiio-accounting.log`: a completed 32 KiB request reported as 64 KiB,
  followed by the bounded retry failure.

Run the reproducer to obtain complete local logs and data files.
