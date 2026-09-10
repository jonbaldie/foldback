Status: needs-triage

# `verify` passes when snapshot-manifest entry paths are tampered; `restore` silently produces a wrong tree

Found by exploratory testing, 2026-09-10 (foldback 0.1.0.0, commit 1c7348c, macOS/APFS, normal build).
Evidence: `/tmp/foldback-exploratory-20260910/` (report: `report.md`, replay logs `repro-replay-{1,2,3}.txt`, script `repro-manifest-tamper.sh`).

## User impact

A snapshot record damaged on disk — the exact damage class the corruption journey is supposed to catch — gets **exit 0 from `verify`**, and a subsequent `restore` silently renames files: `a.txt`'s data appears as `z.txt`, the original filename is lost, with no warning anywhere. Inconsistent with the object layer, where the same access level of damage is refused loudly (`corrupt object`), and with README's promise to "Verify every manifest and content object".

## Replay (confirmed 3/3 from a known starting state)

```sh
#!/bin/zsh
FB=<foldback-binary>; DIR=<scratch>
rm -rf "$DIR"; mkdir -p "$DIR/src"
printf 'precious data\n' > "$DIR/src/a.txt"
$FB backup "$DIR/src" --repo "$DIR/repo" --name s
# Tamper: rename the entry path inside the still-well-formed show-record.
python3 - "$DIR/repo/snapshots/s" <<'EOF'
import sys
p = sys.argv[1]
d = open(p, 'rb').read()
i = d.index(b'"a.txt"')
open(p, 'wb').write(d[:i] + b'"z.txt"' + d[i + 7:])
EOF
$FB verify --repo "$DIR/repo"   # expected: failure. actual: "verified 1 snapshots, 1 objects", exit 0
$FB restore s "$DIR/out" --repo "$DIR/repo"   # actual: exit 0; out/z.txt contains a.txt's content
```

## Expected vs actual

- Expected: `verify` fails — the snapshot manifest is damaged.
- Actual: verify and restore both exit 0; the restored tree is silently wrong.

## Root cause (grounded)

Snapshots are `show`-serialized Haskell records parsed back with `read` (`readNamedSnapshot`). `verifyRepository` (`src/Foldback/Repository.hs:149`) hashes every object and checks referenced digests, sizes, and snapshot totals — but nothing covers the entry path strings; no digest of the manifest itself is stored, so well-formed records are trusted wholesale. `restore` re-validates only path safety.

Neighbouring damage classes are all correctly caught (checked and rejected as bugs): `snapshotTotalBytes` tampering → `snapshot byte count is inconsistent`; digest → missing object → `missing object`; traversal path → `unsafe snapshot path`. The gap is exactly the entry paths.

## Fix direction

Store a digest of the snapshot manifest record (or of the entry list) at commit time and check it in `verify` (and `restore`).

## Comments