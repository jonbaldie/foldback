# Exploratory CLI transcript

- Source revision: `b91cfb8d16e53fe9e582a8841ef10086ea693725`
- Executable: the locally built `foldback` binary (`cabal list-bin exe:foldback`).
- Isolated instance: `$RUN`
- Published copy normalizes local machine paths to `$RUN` and `<foldback executable>`; command output and exit codes are otherwise retained.
- Initial fixture: hidden file, empty file, nested empty directories, two files with identical content, a file symlink, a directory symlink, and a dangling symlink.
- Tree comparisons include relative path, node kind, symlink target, and file bytes.

## Action 1: `"<foldback executable>" "--version"`

- Exit: `0`
- stdout:
```text
foldback 0.1.4.0
```
- stderr:
```text

```

## Action 2: `"<foldback executable>" "backup" "$RUN/source" "--repo" "$RUN/repository" "--name" "before"`

- Exit: `0`
- stdout:
```text
snapshot before: 4 files, 29 bytes
```
- stderr:
```text

```

## Action 3: `"<foldback executable>" "list" "--repo" "$RUN/repository"`

- Exit: `0`
- stdout:
```text
before	4 files	29 bytes
```
- stderr:
```text

```

## Action 4: `"<foldback executable>" "verify" "--repo" "$RUN/repository"`

- Exit: `0`
- stdout:
```text
verified 1 snapshots, 3 objects
```
- stderr:
```text

```

## Action 5: `"<foldback executable>" "restore" "before" "$RUN/restored-before" "--repo" "$RUN/repository"`

- Exit: `0`
- stdout:
```text
restored before to $RUN/restored-before
```
- stderr:
```text

```

## Action 6: `"<foldback executable>" "backup" "$RUN/source" "--repo" "$RUN/repository" "--name" "after"`

- Exit: `0`
- stdout:
```text
snapshot after: 5 files, 39 bytes
```
- stderr:
```text

```

## Action 7: `"<foldback executable>" "list" "--repo" "$RUN/repository"`

- Exit: `0`
- stdout:
```text
after	5 files	39 bytes
before	4 files	29 bytes
```
- stderr:
```text

```

## Action 8: `"<foldback executable>" "verify" "--repo" "$RUN/repository"`

- Exit: `0`
- stdout:
```text
verified 2 snapshots, 4 objects
```
- stderr:
```text

```

## Action 9: `"<foldback executable>" "restore" "after" "$RUN/restored-after" "--repo" "$RUN/repository"`

- Exit: `0`
- stdout:
```text
restored after to $RUN/restored-after
```
- stderr:
```text

```

## Action 10: `"<foldback executable>" "backup" "$RUN/source" "--repo" "$RUN/repository" "--name" "before"`

- Exit: `1`
- stdout:
```text

```
- stderr:
```text
user error (snapshot already exists: before)
```

## Action 11: `"<foldback executable>" "list" "--repo" "$RUN/repository"`

- Exit: `0`
- stdout:
```text
after	5 files	39 bytes
before	4 files	29 bytes
```
- stderr:
```text

```

## Action 12: `"<foldback executable>" "restore" "before" "$RUN/nonempty-target" "--repo" "$RUN/repository"`

- Exit: `1`
- stdout:
```text

```
- stderr:
```text
user error (restore target is not empty: $RUN/nonempty-target)
```

## Action 13: `"<foldback executable>" "restore" "before" "$RUN/parent-link/restore-replay-one" "--repo" "$RUN/repository"`

- Exit: `1`
- stdout:
```text

```
- stderr:
```text
user error (restore target is not a directory: $RUN/parent-link/restore-replay-one)
```

## Action 14: `"<foldback executable>" "restore" "before" "$RUN/parent-link/restore-replay-two" "--repo" "$RUN/repository"`

- Exit: `1`
- stdout:
```text

```
- stderr:
```text
user error (restore target is not a directory: $RUN/parent-link/restore-replay-two)
```

## Action 15: `"<foldback executable>" "restore" "before" "$RUN/direct-target" "--repo" "$RUN/repository"`

- Exit: `1`
- stdout:
```text

```
- stderr:
```text
user error (restore target is not a directory: $RUN/direct-target)
```

## Action 16: `"<foldback executable>" "verify" "--repo" "$RUN/corrupt-repository"`

- Exit: `1`
- stdout:
```text

```
- stderr:
```text
user error (corrupt object: abb7f0ae43ba52cc56233a5ecb4dfa11765f26b1282a18346d811b6a85af19c1)
```

## Action 17: `"<foldback executable>" "verify" "--repo" "$RUN/corrupt-repository"`

- Exit: `1`
- stdout:
```text

```
- stderr:
```text
user error (corrupt object: abb7f0ae43ba52cc56233a5ecb4dfa11765f26b1282a18346d811b6a85af19c1)
```

## Checked lasting state

- Initial source and restored snapshot match: `true` (12 entries).
- Mutated source and restored second snapshot match: `true` (13 entries).
- Initial repository: 1 snapshot and 3 distinct content objects; after the second backup: 2 snapshots and 4 objects.
- Reusing `before` failed and left the listing unchanged.
- Refusing the non-empty restore target preserved its only existing file.
- Two restores through an intermediate symlink and one restore to a symlink target failed without writing below the link referent.
- Two verification attempts against an altered non-empty object both reported `corrupt object`.

## Driver adjustments

The first pass assertion expected symlink refusal stderr to contain `symbolic link`; the CLI instead returned exit 1 with `user error (restore target is not a directory: <target>)`, and created nothing under the symlink referent. Replay accepted the nonzero refusal only after checking for side effects. A first corruption-fixture selection chose the zero-byte object, so byte flipping failed in the driver; replay selected a non-empty object and completed the corruption check. Both were driver issues, not product failures.
