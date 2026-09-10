Status: needs-triage

# Peak memory grows linearly with the largest file processed (backup/verify/restore), despite documented streaming

Found by runtime-instrumented testing (RTS `-s` GC statistics), 2026-09-10 (foldback 0.1.0.0, commit 1c7348c, macOS, normal build; an `--ghc-options=-rtsopts` scratch build was used once for GC-sizing confirmation and deleted).
Evidence: `/tmp/foldback-exploratory-20260910/` (round-3 report: `report-round3.md`, replay logs `repro-mem-{1,2,3}.txt`, script `repro-linear-memory.sh`).

## User impact

README documents that "an individual file is streamed once into a temporary object" in 64 KiB chunks, but peak heap usage is proportional to the file size. A user backing up (or verifying/restoring) a 10 GB file can expect roughly 9–12 GB RSS — the opposite of streaming, with OOM/machine-pressure risk on typical laptops. Measured on the normal build (`+RTS -s`):

| file size | max residency (backup) | total memory in use |
|---|---|---|
| 50 MB | 37.8 MB | 63 MiB |
| 200 MB | 130–151 MB | 252 MiB |
| 400 MB | 302 MB | 494 MiB |
| 800 MB | 605 MB | 986 MiB |

~0.75× file size in peak live heap, ~1.2× in RSS — for backup, verify, and restore alike. With GC pressure forced (`+RTS -A64k` on a disclosed `-rtsopts` instrumentation build) residency is unchanged (151 MB at 200 MB): retention, not GC laziness.

## Replay (confirmed 3/3 on the normal build from a known starting state)

```sh
./repro-linear-memory.sh <foldback-binary> <scratch-dir> 200
# backup 200MB: ~130–151MB max residency, 252 MiB total in use
# verify:       ~168MB max residency
# restore:      ~185MB max residency (restore byte-identical every time)
```

Script body: create an N MB random file, `backup … +RTS -s | grep residency`, same for `verify` and `restore`.

## Expected vs actual

- Expected: memory bounded by chunk size (64 KiB) plus small state, independent of file size.
- Actual: peak residency and RSS linear in file size for every command that touches file contents.

## Mechanism hypothesis (for root-cause investigation)

The streaming loops pass the hash context as a plain argument without forcing it:

- `copyAndHash output (SHA256.update context chunk) (size + …) input` (`src/Foldback/Repository.hs:262`)
- `hashChunks (SHA256.update context chunk) input` (`src/Foldback/Repository.hs:284`)

Each iteration allocates an unevaluated `update` thunk whose closure references one 64 KiB chunk plus the previous thunk; nothing forces intermediate contexts until `finalize`, so every chunk stays live simultaneously. A strictness annotation on the accumulator per iteration (e.g. `seq`/bang on `context` and `size`) should restore constant-memory streaming — verify by re-running the reproducer.

## Comments