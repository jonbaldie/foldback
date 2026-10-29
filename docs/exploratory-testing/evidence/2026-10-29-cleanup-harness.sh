#!/bin/bash
set -Eeuo pipefail
cd /home/ubuntu/Code/pstack/jonbaldie/foldback-explore-cleanup
name=foldback-explore-cleanup-20261029
image=foldback-explore-cleanup-20261029
pid=''
cleanup() {
  rc=$?
  trap - EXIT INT TERM
  set +e
  echo "CLEANUP starting (pass exit $rc)"
  docker rm -f "$name" 2>&1
  docker image rm "$image" 2>&1
  sudo -n rm -rf .explore-data
  echo 'CLEANUP container check:'
  docker ps -a --filter "name=^/${name}$" --format '{{.ID}} {{.Names}}'
  echo 'CLEANUP image check:'
  docker image ls "$image" --format '{{.ID}} {{.Repository}}'
  echo 'CLEANUP volume check:'
  docker volume ls --filter "name=$name" --format '{{.Name}}'
  echo "CLEANUP recorded container init PID: ${pid:-not-started}"
  if [ -n "$pid" ]; then
    if kill -0 "$pid" 2>/dev/null; then echo 'CLEANUP FAIL init PID still alive'; rc=1; else echo 'CLEANUP init PID absent'; fi
  fi
  echo 'CLEANUP host process name check:'
  ps -eo pid,args | grep '[f]oldback-explore-cleanup-20261029' || true
  echo 'CLEANUP host listening ports for recorded PID:'
  if [ -n "$pid" ]; then ss -lntup 2>/dev/null | grep "pid=$pid," || echo 'none'; fi
  if [ -e .explore-data ]; then echo 'CLEANUP FAIL test data remains'; rc=1; else echo 'CLEANUP test data absent'; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'REGISTERED cleanup before docker build: container=%s image=%s, no ports or volumes published\n' "$name" "$image"
docker build -f dev.Dockerfile -t "$image" .
gitdir=$(git rev-parse --path-format=absolute --git-common-dir)
docker run -d --rm --init --name "$name" --cpus=2 --memory=2g --memory-swap=2g --pids-limit=256 --tmpfs /workspace/dist-newstyle:rw,exec,size=512m --tmpfs /workspace/dist-cov:rw,exec,size=512m --tmpfs /tmp:rw,exec,size=512m -v "$PWD":/workspace -v "$gitdir":"$gitdir" "$image" sleep 14400
pid=$(docker inspect --format '{{.State.Pid}}' "$name")
echo "REGISTERED init PID=$pid"
echo 'Container port bindings:'
docker inspect --format '{{json .HostConfig.PortBindings}}' "$name"
docker exec "$name" cabal build exe:foldback --offline
docker exec "$name" bash /workspace/docs/exploratory-testing/evidence/2026-10-29-cli-journeys.sh
echo 'PASS journeys'
