#!/bin/bash
set -eu
cd /workspace
F=$(cabal list-bin exe:foldback --offline)
D=/workspace/.explore-20261105
rm -rf "$D"
mkdir -p "$D/source/sub" "$D/source/empty" "$D/outside"
printf 'original\n' > "$D/source/a"
cp "$D/source/a" "$D/source/sub/copy"
ln -s ../a "$D/source/sub/link"
set -x
"$F" --help
"$F" backup "$D/source" --repo "$D/repo" --name first
"$F" list --repo "$D/repo"
test "$(find "$D/repo/objects" -type f | wc -l)" -eq 1
printf 'changed\n' > "$D/source/a"
"$F" backup "$D/source" --repo "$D/repo" --name second
"$F" list --repo "$D/repo"
test "$(find "$D/repo/objects" -type f | wc -l)" -eq 2
if "$F" backup "$D/source" --repo "$D/repo" --name first; then exit 11; fi
"$F" verify --repo "$D/repo"
"$F" restore first "$D/restored" --repo "$D/repo"
test "$(cat "$D/restored/a")" = original
test "$(cat "$D/restored/sub/copy")" = original
test "$(readlink "$D/restored/sub/link")" = ../a
test -d "$D/restored/empty"
if "$F" restore second "$D/restored" --repo "$D/repo"; then exit 12; fi
test "$(cat "$D/restored/a")" = original
"$F" restore second "$D/restored2" --repo "$D/repo"
test "$(cat "$D/restored2/a")" = changed
ln -s "$D/outside" "$D/link"
if "$F" restore first "$D/link/new" --repo "$D/repo"; then exit 13; fi
test ! -e "$D/outside/new"
object=$(printf 'changed\n' | sha256sum | cut -d' ' -f1)
printf corrupt > "$D/repo/objects/$object"
if "$F" verify --repo "$D/repo"; then exit 14; fi
if "$F" restore second "$D/corrupt-target" --repo "$D/repo"; then exit 15; fi
"$F" restore first "$D/unaffected" --repo "$D/repo"
test "$(cat "$D/unaffected/a")" = original
printf 'changed\n' > "$D/repo/objects/$object"
"$F" verify --repo "$D/repo"
"$F" restore second "$D/repaired" --repo "$D/repo"
test "$(cat "$D/repaired/a")" = changed
set +x
echo 'All journey assertions passed'
