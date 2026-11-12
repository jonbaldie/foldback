#!/bin/sh
# Peak residency of `list` and `verify` as the snapshot count grows while
# each snapshot's size and the repository's unique object set stay fixed.
# Usage: sh test/snapshot-count-scaling.sh BIN SNAPSHOTS [FILES_PER_SNAPSHOT]
set -eu
bin="$1"
snapshots="$2"
files="${3:-2000}"
objects=16
repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
mkdir "$repo/objects" "$repo/snapshots"
printf 'foldback 1\n' > "$repo/FORMAT"
digests=""
i=0
while [ "$i" -lt "$objects" ]; do
  printf 'object %04d\n' "$i" > "$repo/objects/tmp"
  digest=$(sha256sum "$repo/objects/tmp" | cut -d ' ' -f1)
  mv "$repo/objects/tmp" "$repo/objects/$digest"
  digests="$digests $digest"
  i=$((i + 1))
done
s=0
while [ "$s" -lt "$snapshots" ]; do
  name=$(printf 's%06d' "$s")
  perl -e '
    my ($name, $files, @digests) = @ARGV;
    my $dir = "a-moderately-long-directory-name-shared-by-every-file-entry";
    print "Snapshot {snapshotFormat = 1, snapshotName = \"$name\", snapshotCreatedAt = 1, snapshotEntries = [Directory \".\",Directory \"$dir\"";
    for my $f (0 .. $files - 1) {
      my $d = $digests[$f % @digests];
      printf ",RegularFile \"%s/file-%06d\" (Digest {unDigest = \"%s\"}) 12", $dir, $f, $d;
    }
    print "], snapshotFileCount = $files, snapshotTotalBytes = " . ($files * 12) . "}\n";
  ' "$name" "$files" $digests > "$repo/snapshots/$name"
  sha256sum "$repo/snapshots/$name" | cut -d ' ' -f1 > "$repo/snapshots/.$name.digest"
  s=$((s + 1))
done
residency() {
  grep 'maximum residency' | awk '{ gsub(",", "", $1); print $1 }'
}
listed=$("$bin" list --repo "$repo" | wc -l | tr -d ' ')
[ "$listed" = "$snapshots" ]
"$bin" verify --repo "$repo" > /dev/null
list_bytes=$("$bin" list --repo "$repo" +RTS -s -RTS 2>&1 >/dev/null | residency)
verify_bytes=$("$bin" verify --repo "$repo" +RTS -s -RTS 2>&1 >/dev/null | residency)
printf '%s\t%s\tlist=%s\tverify=%s\n' "$snapshots" "$files" "$list_bytes" "$verify_bytes"
