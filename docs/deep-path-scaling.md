# Deep manifest path scaling

`test/depth-scaling.sh` creates a valid repository with one snapshot. The snapshot contains a chain of directories and a symlink at the end. Each directory path is longer than its parent. The script runs `foldback list`, checks its output, and prints the GHC runtime allocation statistics.

Build the executable in the development container, then run:

```sh
bin=$(cabal list-bin exe:foldback)
for depth in 200 400 800; do
  sh test/depth-scaling.sh "$bin" "$depth"
done
```

The total length of directory paths grows quadratically with depth, because every entry contains its full path. The ancestor check must grow with that input, not with the sum of every copied ancestor prefix.

Five alternating runs on GHC 9.12.2 with the project's `-O1` build produced the same allocated byte count each time. The baseline is `66b7c2f`, before the path index change. Both sides returned `deep\t0 files\t0 bytes`.

| Depth | Baseline bytes allocated | Changed bytes allocated |
| ---: | ---: | ---: |
| 200 | 225,731,736 | 70,520,592 |
| 400 | 1,488,577,216 | 270,314,072 |
| 800 | 10,711,118,376 | 1,059,231,232 |

The figures cover manifest parsing, validation, and the rest of `list`, not the ancestor check alone. The script checks a successful result on every run. Allocation is not a latency measurement, and the fixture does not represent every repository.
