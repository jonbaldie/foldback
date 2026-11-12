# Snapshot count residency

`test/snapshot-count-scaling.sh` builds a repository with a chosen number of snapshots. Every snapshot has the same shape: a root, one directory, and 2,000 regular-file entries that cycle through the same 16 objects. Adding snapshots therefore adds manifests but no new objects and no larger manifests. The script checks that `list` prints one line per snapshot and that `verify` succeeds. Then it prints the GHC peak residency (`maximum residency` from `+RTS -s`) for each command.

Build the executable in the development container, then run:

```sh
bin=$(cabal list-bin exe:foldback)
for snapshots in 5 20 80; do
  sh test/snapshot-count-scaling.sh "$bin" "$snapshots"
done
```

The baseline is `7e425eb`. It loaded every committed snapshot into one list before `list` built its summaries or `verify` gathered object references, so every parsed manifest stayed live until the command finished. The changed code folds over the sorted names, so each manifest's entries can be collected once its summary or reference tally is taken. GHC 9.12.2, project `-O1` build:

| Snapshots | Baseline `list` | Changed `list` | Baseline `verify` | Changed `verify` |
| ---: | ---: | ---: | ---: | ---: |
| 5 | 27,139,344 | 7,049,080 | 27,139,088 | 13,709,144 |
| 20 | 125,026,880 | 7,052,752 | 125,026,336 | 13,711,712 |
| 80 | 530,453,304 | 7,071,336 | 530,472,664 | 13,723,024 |

All figures are bytes. The baseline grows by about 6.7 MB per snapshot. The changed residency is about one manifest's worth, and it stays flat.

Some growth remains, and it is expected. From 5 to 80 snapshots, `list` grows by about 22 KB, for the sorted snapshot names and the summaries it returns. `verify` grows by about 14 KB, for the sorted snapshot names. `verify` also keeps one set of recorded sizes for each unique object, which is fixed in this fixture. `verify` peaks higher than `list` because one manifest's entries and the object-size map are live together.

The test `list and verify residency ignores snapshot count` in `test/Main.hs` runs a smaller version of this experiment on every test run: 4 against 32 snapshots of 1,000 entries each. On the baseline, `list` rose from 6.3 MB to 55.6 MB there.

Residency is sampled at major collections, so it is not an exact live-heap measurement. The fixture also does not represent every repository.
