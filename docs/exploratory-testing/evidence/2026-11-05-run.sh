#!/bin/bash
set -euo pipefail
W=$(git rev-parse --show-toplevel)
N=foldback-explore-20261105-cli
IMAGE=foldback-dev-35-independent:latest
G=$(git rev-parse --path-format=absolute --git-common-dir)
PID=''
cleanup() {
  docker rm -f "$N" >/dev/null 2>&1 || true
  sudo rm -rf "$W/.explore-20261105" "$W/dist-newstyle" "$W/dist-cov"
  echo 'Cleanup checks:'
  if docker container inspect "$N" >/dev/null 2>&1; then echo 'container remains'; return 1; fi
  echo 'container absent'
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then echo "PID $PID remains"; return 1; fi
  echo "container PID ${PID:-not-started} absent"
  if [ -n "$PID" ] && sudo ss -lntup | grep -F "pid=$PID,"; then echo 'PID owns a listening port'; return 1; fi
  echo 'container PID owns no listening ports'
  test -z "$(docker volume ls -q --filter name=foldback-explore-20261105)"
  test -z "$(docker images -q --filter reference='foldback-explore-20261105*')"
  for p in .explore-20261105 dist-newstyle dist-cov; do test ! -e "$W/$p"; done
  echo 'no run-named volumes or images, scratch, or build directories'
}
if docker container inspect "$N" >/dev/null 2>&1; then echo 'container name already taken'; exit 1; fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Registered container=$N image=$IMAGE, no published ports or named volumes"
docker image inspect "$IMAGE" --format 'Image ID: {{.Id}}'
docker run -d --rm --init --name "$N" --cpus=2 --memory=2g --memory-swap=2g --pids-limit=256 --tmpfs /workspace/dist-newstyle:rw,exec,size=512m --tmpfs /workspace/dist-cov:rw,exec,size=512m --tmpfs /tmp:rw,exec,size=512m -v "$W":/workspace -v "$G":"$G" "$IMAGE" sleep 14400
PID=$(docker inspect "$N" --format '{{.State.Pid}}')
echo "Container init PID: $PID"
echo 'Running cabal build exe:foldback --offline'
docker exec "$N" cabal build exe:foldback --offline
echo 'Running cabal test foldback-test --offline --test-show-details=always'
docker exec "$N" cabal test foldback-test --offline --test-show-details=always
echo 'Running CLI journeys'
docker exec "$N" bash /workspace/docs/exploratory-testing/evidence/2026-11-05-cli-journeys.sh
