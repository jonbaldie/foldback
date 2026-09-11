Status: ready-for-agent

# Foreign or transient metadata files in `snapshots/` (.DS_Store, aborted temp files) permanently break `list` and `verify`

Found by exploratory and stateful testing, 2026-09-11 (foldback 0.1.0.0, commit 53e78c7, macOS/APFS, normal build).
Evidence: `/tmp/foldback-finding-bugs-20260911/` (report: `report.md`, replay logs `repro-metadata-{1,2,3}.txt`, script `repro-metadata-files.sh`).

## User impact

README explicitly promotes the repository as inspectable:
```text
The repository is deliberately inspectable:
repository/
|-- FORMAT
|-- objects/
|   `-- <sha256>
`-- snapshots/
    `-- <name>
```

However, if a user inspects `repository/snapshots/` using standard macOS desktop tools (e.g. opening the folder in Finder, which automatically generates a `.DS_Store` file), or if an interrupted backup leaves an uninstalled temporary file (`.snapshot-*` created by `openBinaryTempFile`), the entire repository becomes permanently unlistable and unverifiable:
- `foldback list --repo <repo>` immediately crashes with `user error (invalid snapshot: .../.DS_Store)`, exit 1.
- `foldback verify --repo <repo>` immediately crashes with `user error (invalid snapshot: .../.DS_Store)`, exit 1.
- The user cannot inspect what snapshots exist, check repository health, or use normal CLI tooling.
- The snapshot data itself is completely intact and can still be restored if the user remembers the snapshot name, proving this is a metadata parsing flaw rather than data corruption.
- Foldback offers no mechanism or command to ignore, purge, or bypass non-snapshot files in `snapshots/`.

An identical issue affects `repository/objects/`, where Finder's `.DS_Store` or an aborted backup's `.incoming-*` temporary file causes `foldback verify` to fail with `user error (invalid object name: .DS_Store)`.

## Replay (confirmed 3/3 from a known starting state)

```sh
#!/bin/zsh
set -euo pipefail
FB=<foldback-binary>; DIR=<scratch-dir>

rm -rf "$DIR"
mkdir -p "$DIR/src" "$DIR/out"
printf 'important data\n' > "$DIR/src/a.txt"

"$FB" backup "$DIR/src" --repo "$DIR/repo" --name s1
"$FB" list --repo "$DIR/repo"    # OK: "s1\t1 files\t15 bytes"
"$FB" verify --repo "$DIR/repo"  # OK: "verified 1 snapshots, 1 objects"

# Simulate macOS Finder inspecting snapshots/ or an aborted backup leaving a temp file
printf '\x00\x00\x00\x01Bud1\x00\x00\x10\x00' > "$DIR/repo/snapshots/.DS_Store"

"$FB" list --repo "$DIR/repo"
# → user error (invalid snapshot: .../repo/snapshots/.DS_Store), exit 1

"$FB" verify --repo "$DIR/repo"
# → user error (invalid snapshot: .../repo/snapshots/.DS_Store), exit 1

# Direct restore of s1 still succeeds, proving data is intact
"$FB" restore s1 "$DIR/out" --repo "$DIR/repo"
# → restored s1 to .../out, exit 0
```

## Expected vs actual

- **Expected**: `list` and `verify` ignore hidden files (starting with `.`), ignore Foldback's own `.snapshot-*` temp files, or skip non-snapshot metadata files rather than crashing the command.
- **Actual**: `list` and `verify` crash on any non-snapshot file in `snapshots/`, rendering healthy repositories inoperable.

## Grounding

In `src/Foldback/Repository.hs:132-140`:

```haskell
listSnapshots :: FilePath -> IO [SnapshotInfo]
listSnapshots repository = do
  ensureRepository repository
  names <- sort <$> listDirectory (repository </> "snapshots")
  mapM loadInfo names
 where
  loadInfo name = do
    validateSnapshotName name
    snapshot <- readNamedSnapshot repository name
...
```

`listDirectory` returns all files, including dotfiles.
In `validateSnapshotName` (`src/Foldback/Repository.hs:211-220`):

```haskell
validateSnapshotName name =
  unless valid (ioError (userError "snapshot names may contain only letters, digits, '.', '_' and '-'"))
 where
  valid =
    not (null name)
      && name /= "."
      && name /= ".."
      && all (\character -> isAlphaNum character || character `elem` ("._-" :: String)) name
```

`validateSnapshotName` accepts `.DS_Store` and `.snapshot-*` because `.` is in `"._-"`. It only rejects `"."` and `".."` specifically.

`readNamedSnapshot` then calls `readSnapshot` (`src/Foldback/Repository.hs:311-318`):

```haskell
readSnapshot path = do
  exists <- doesFileExist path
  unless exists (ioError (userError ("snapshot does not exist: " <> takeName path)))
  content <- readFile path
  case readMaybe content of
    Nothing -> ioError (userError ("invalid snapshot: " <> path))
    Just snapshot -> pure snapshot
```

`readMaybe` fails to parse binary or non-Haskell content, throwing an uncaught IO error that terminates `list` and `verify`.

Furthermore, `writeSnapshot` (`src/Foldback/Repository.hs:297`) uses `openBinaryTempFile (takeDirectory destination) ".snapshot-"`, placing its temporary staging files directly into `snapshots/` under a filename that matches `validateSnapshotName`.

## Fix direction

1. In `listSnapshots` (and `verifyRepository` for `objects`):
   - Ignore dotfiles (`filter (not . isPrefixOf ".") names`), or ignore files matching `".snapshot-*"` / `".incoming-*"`.
2. Alternatively or additionally, in `validateSnapshotName`:
   - Disallow snapshot names beginning with `.` (`head name /= '.'`).
3. Place staging temporary files in a dedicated scratch directory or ensure they are excluded from listing passes.

## Comments

## Triage Notes

> *This was generated by AI during triage.*

Verified by reproduction (2026-09-11): the reported replay reproduces exactly — a `.DS_Store` in `snapshots/` makes `list` and `verify` crash with `invalid snapshot`, while direct `restore` of the named snapshot still succeeds.

Redundancy check: no filtering of directory listings exists anywhere; the object-side listing in `verify` is equally unfiltered and fails on a foreign file with `invalid object name`. No prior rejections in `.out-of-scope/`.

**Category:** bug. **State:** `ready-for-agent` — fully specified with grounded root cause and clear fix direction; the precise filtering strategy is within agent discretion.

### Agent Brief

**Category:** bug
**Summary:** Make `list` and `verify` ignore foreign/transient files in `snapshots/` and `objects/` (dotfiles, aborted staging files) instead of crashing

**Current behavior:**
`list` and `verify` treat every entry of `snapshots/` (and every entry of `objects/` for verify) as a repository artifact. A dotfile such as `.DS_Store` — or an aborted backup's staging file (`.snapshot-*`, `.incoming-*`), which the backup machinery itself stages inside those directories — is accepted by name validation (charset allows a leading `.`), fails record parsing or digest validation, and crashes the command. A healthy repository becomes permanently unlistable and unverifiable even though all snapshot data is intact and directly restorable by name.

**Desired behavior:**
Directory scans of `snapshots/` and `objects/` consider only repository artifacts: a foreign or transient file (dotfile, or a staging filename the tool itself uses) is ignored by `list` and `verify` rather than fatal. Consistently, creating a snapshot whose name would collide with what gets ignored should not be possible — snapshot names that start with `.` should be refused at backup time with the existing name-validation error class. `verify`'s counting should report only real repository artifacts. Staging temp files may remain in the live directories, but if they are ignored by the scans, an interrupted backup's leftovers must not block any command.

**Key interfaces:**
- The snapshot-listing function in the repository module (currently: list directory, sort, load every entry): filter out names that are not legitimate snapshot records before loading.
- The object-scan in the repository-verification function (currently: list directory, verify every entry as an object): apply the analogous filter.
- The snapshot-name validation predicate: extend to reject a leading `.` at creation time (mirroring the treatment of a leading `-` if that lands first — coordinate so both prefix rules live in the same predicate).
- The staging-file prefixes used by the backup and snapshot-writing paths (`.incoming-` in objects, `.snapshot-` in snapshots): these names must be covered by the filter.

**Acceptance criteria:**
- [ ] A `.DS_Store`-style file in `snapshots/` does not break `list` or `verify`; the real snapshots are listed and counted as before
- [ ] The same file in `objects/` does not break `verify`
- [ ] A leftover `.snapshot-*` / `.incoming-*` staging file does not break `list` or `verify`
- [ ] `backup --name .foo` (any leading-dot name) is refused with the name-validation error, non-zero exit, no snapshot created
- [ ] `restore <name> ...` of a real snapshot is unaffected
- [ ] Existing tests pass; new tests cover foreign files in both directories

**Out of scope:**
- Deleting or cleaning up foreign files (ignore, don't purge)
- A dedicated scratch/staging subdirectory for temp files (acceptable only if trivially motivated; the filter is the primary fix)
- Changing the object or snapshot storage format
