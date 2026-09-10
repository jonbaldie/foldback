Status: needs-triage

# `backup` accepts a snapshot name beginning with `-` that `restore` can never address

Found by exploratory testing round 2, 2026-09-10 (foldback 0.1.0.0, commit 1c7348c, macOS, normal build).
Evidence: `/tmp/foldback-exploratory-20260910/` (round-2 report: `report-round2.md`, replay logs `repro-optlike-{1,2,3}.txt`, script `repro-optionlike-name.sh`).

## User impact

A user can create a snapshot the CLI itself can never restore: `list` shows the snapshot and `verify` reports a healthy repository, but `restore` (and every other command that takes SNAPSHOT) rejects the name as `unknown option`, and there is no end-of-options separator to escape it. The data is in the repository but unreachable through the supported interface, with no warning at creation time.

## Replay (confirmed 3/3 from a known starting state)

```sh
FB=<foldback-binary>; DIR=<scratch>
mkdir -p "$DIR/src"; printf 'data\n' > "$DIR/src/a.txt"
$FB backup "$DIR/src" --repo "$DIR/repo" --name -w
# → "snapshot -w: 1 file, 5 bytes", exit 0
$FB list --repo "$DIR/repo"
# → "-w\t1 files\t5 bytes"
$FB restore -w "$DIR/out" --repo "$DIR/repo"
# → "unknown option: -w", exit 1
$FB restore -- -w "$DIR/out" --repo "$DIR/repo"
# → "unknown option: --", exit 1 (no end-of-options support)
```

## Expected vs actual

- Expected: `backup` refuses a snapshot name that starts with `-` (consistent with the option parser every other command runs the name through), or the name is addressable by `restore`.
- Actual: `backup` accepts; `restore` cannot address; verify silently reports the repository as healthy.

## Grounding

Snapshot-name validation permits `letters, digits, '.', '_' and '-'` — `-w` passes the charset — and the value is consumed blindly as `--name`'s argument. But the restore/list/verify parser (`src/Foldback.hs`, `parseArguments`) treats any token starting with `-` as an option (`unknown option: <token>`) with no `--` terminator.

## Fix direction (either side suffices)

- Reject snapshot names whose first character is `-` at backup time; or
- support an end-of-options separator in the argument parser.

## Comments