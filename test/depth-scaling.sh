#!/bin/sh
set -eu
bin="$1"
depth="$2"
repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
mkdir "$repo/objects" "$repo/snapshots"
printf 'foldback 1\n' > "$repo/FORMAT"
perl -e '
  my $depth = shift;
  print "Snapshot {snapshotFormat = 1, snapshotName = \"deep\", snapshotCreatedAt = 1, snapshotEntries = [Directory \".\"";
  my $path = "";
  for (1..$depth) { $path .= ($path eq "" ? "" : "/") . "a"; print ",Directory \"$path\""; }
  print ",SymbolicLink \"$path/link\" \"target\"], snapshotFileCount = 0, snapshotTotalBytes = 0}\n";
' "$depth" > "$repo/snapshots/deep"
sha256sum "$repo/snapshots/deep" | cut -d ' ' -f1 > "$repo/snapshots/.deep.digest"
result=$("$bin" list --repo "$repo" +RTS -s -RTS)
expected=$(printf 'deep\t0 files\t0 bytes')
[ "$result" = "$expected" ]
printf '%s\n' "$result"
