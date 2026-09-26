# Foldback CLI exploratory pass — 2026-09-26

## Setup

- Exercised Foldback 0.1.4.0 from source revision `b91cfb8d16e53fe9e582a8841ef10086ea693725`, which is included in the remote `main` branch at the time of this pass.
- Built with `cabal build exe:foldback` on macOS 26.6.2 arm64, GHC 9.12.1, and Cabal 3.16.1.0. The build succeeded.
- Used a fresh temporary source tree, repository, and restore destinations. No project files or pre-existing scratch data were used as fixtures.
- Captured every CLI command, exit code, stdout, and stderr in the [terminal transcript](evidence/2026-09-26-foldback-cli-transcript.md). The published transcript replaces machine-specific paths with `$RUN` and an executable placeholder.

## Journeys exercised

### 1. Back up and restore a representative tree

The source contained a hidden file, an empty file, nested empty directories, two files with identical contents, and file, directory, and dangling symlinks. The README promises that regular file contents and empty directories are preserved, identical contents are deduplicated, and symlinks are recorded without being followed.

`backup` reported 4 files and 29 bytes. `list` showed the committed snapshot, and `verify` reported 1 snapshot and 3 objects. Restoring the snapshot reproduced all 12 non-root entries, including file bytes, empty directories, symlink types, and symlink targets.

### 2. Take a second snapshot after a source change

Added one regular file, then backed up the same source under a second name. `list` showed both snapshots with the expected file and byte totals. `verify` reported 2 snapshots and 4 objects, confirming that the second snapshot added one distinct content object. The restored first and second snapshots each matched their respective source tree.

Reusing the first snapshot name failed with `snapshot already exists: before`; a subsequent `list` showed the original two snapshots unchanged.

### 3. Check restore safeguards and corruption detection

- Restore to a non-empty directory failed and left its existing file unchanged.
- Restore through an intermediate symlink failed twice from fresh target paths, with nothing created under the symlink referent.
- Restore to a symlink target failed without creating anything under its referent.
- After changing a non-empty content object in a copied repository, two `verify` runs both failed with `corrupt object`.

## Findings

No confirmed bugs were found, so no GitHub bug issue was created.

The symlink restore refusals report `restore target is not a directory` rather than naming the symlink component. The refusal and safety outcome matched the documented behavior on both replays, so this was not filed as a bug. It is a usability observation from the attempted restore journey.

## Coverage limits

This pass did not exercise special files, concurrent operations, process interruption, very large files, or non-macOS filesystems. The Cabal test suite was not run; this pass used the CLI directly and only built the executable.
