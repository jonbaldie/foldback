#!/bin/bash
set -eu
cd /workspace
F=$(cabal list-bin exe:foldback --offline)
D=/workspace/.explore-data
rm -rf "$D"; mkdir -p "$D/src/empty" "$D/src/sub"
printf 'hello\n' > "$D/src/a"; cp "$D/src/a" "$D/src/sub/copy"; ln -s ../a "$D/src/sub/link"
set -x
"$F" backup "$D/src" --repo "$D/repo" --name first
"$F" list --repo "$D/repo"
find "$D/repo/objects" -type f | wc -l
printf 'changed\n' > "$D/src/a"
"$F" backup "$D/src" --repo "$D/repo" --name second
"$F" list --repo "$D/repo"
find "$D/repo/objects" -type f | wc -l
if "$F" backup "$D/src" --repo "$D/repo" --name first; then exit 11; fi
"$F" restore first "$D/restored" --repo "$D/repo"
test "$(cat "$D/restored/a")" = hello
test "$(cat "$D/restored/sub/copy")" = hello
test "$(readlink "$D/restored/sub/link")" = ../a
test -d "$D/restored/empty"
if "$F" restore second "$D/restored" --repo "$D/repo"; then exit 12; fi
test "$(cat "$D/restored/a")" = hello
"$F" restore second "$D/restored2" --repo "$D/repo"
test "$(cat "$D/restored2/a")" = changed
"$F" verify --repo "$D/repo"
obj=$(find "$D/repo/objects" -type f | head -1)
printf corrupt > "$obj"
if "$F" verify --repo "$D/repo"; then exit 13; fi
if "$F" restore first "$D/corrupt-restore" --repo "$D/repo"; then echo 'first snapshot unaffected by selected object'; fi
set +x
echo 'Journeys completed'
