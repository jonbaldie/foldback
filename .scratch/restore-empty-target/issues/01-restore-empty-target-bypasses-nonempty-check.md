Status: needs-triage

# `restore` with empty target string `""` bypasses non-empty check and silently overwrites local files

Found by exploratory testing round 4, 2026-09-10 (foldback 0.1.0.0, commit 1c7348c, macOS, normal build).
Evidence: `/tmp/foldback-exploratory-round4/` (round-4 report: `report-round4.md`, replay logs `repro-empty-target-{1,2,3}.txt`, script `repro-empty-target.sh`).

## User impact

A user who invokes `restore` with an empty string target — for example from an unset or empty shell variable `foldback restore <snapshot> "$TARGET" --repo <repo>`, or mistyping `""` thinking it means the current directory — experiences silent data loss:
- The documented safety guarantee ("Restore refuses non-empty targets") is completely bypassed.
- `restore` exits 0 and reports `restored <snapshot> to `.
- Existing files in the current working directory with names matching files in the snapshot are silently overwritten and destroyed.
- Other local files in the directory remain mixed with the newly restored files.

In contrast, restoring to `.` (`foldback restore <snapshot> .`) correctly refuses with `user error (restore target is not empty: .)`.

## Replay (confirmed 3/3 from a known starting state)

```sh
#!/bin/zsh
set -euo pipefail
FB=<foldback-binary>; DIR=<scratch-dir>

rm -rf "$DIR"
mkdir -p "$DIR/src" "$DIR/work"
printf 'from-backup\n' > "$DIR/src/data.txt"
printf 'precious-local\n' > "$DIR/work/data.txt"
printf 'unrelated-local\n' > "$DIR/work/other.txt"

"$FB" backup "$DIR/src" --repo "$DIR/repo" --name s1 > /dev/null

cd "$DIR/work"
"$FB" restore s1 "" --repo "$DIR/repo"
# → "restored s1 to \n", exit 0
cat "$DIR/work/data.txt"
# → "from-backup" (local file was silently overwritten!)
```

## Expected vs actual

- **Expected**: `restore` refuses an empty target argument `""` (e.g. `restore target cannot be empty`), or treats `""` as cwd and enforces the documented "Restore refuses non-empty targets" check, refusing to overwrite existing files.
- **Actual**: `restore` exits 0, bypasses the non-empty check, and silently overwrites files in the current working directory.

## Grounding

In `src/Foldback/Repository.hs:377`:

```haskell
prepareTarget :: FilePath -> IO ()
prepareTarget target = do
  exists <- doesPathExist target
  if exists
    then do
      isDirectory <- doesDirectoryExist target
      unless isDirectory (ioError (userError ("restore target is not a directory: " <> target)))
      contents <- listDirectory target
      unless (null contents) (ioError (userError ("restore target is not empty: " <> target)))
    else createDirectoryIfMissing True target
```

In Haskell's `System.Directory`, `doesPathExist ""` returns `False`. Because `exists` is `False`, `prepareTarget ""` takes the `else` branch, calling `createDirectoryIfMissing True ""` which is a no-op. It never checks `doesDirectoryExist` or `listDirectory`.

Subsequently, in `restoreEntry`, `target </> path` evaluates to `"" </> path` which is `path` (relative to the current working directory). `copyFile` then overwrites any matching file already present in the working directory.

## Fix direction

In `prepareTarget` (or in `parseCommand ("restore" : ...)`):
- Explicitly reject empty string target: `when (null target) (ioError (userError "restore target cannot be empty"))`; or
- Normalize/canonicalize `target` before existence checking (e.g. `makeAbsolute target`), so `""` resolves to the current directory and is subject to the `listDirectory` non-empty check.

## Comments
