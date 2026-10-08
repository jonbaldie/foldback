# Foldback

Agent guidance for working on the Foldback content-addressed backup CLI.

## Agent skills

### Issue tracker

Issues and specs for this repo live as GitHub issues. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Development container

Build, test, run, and debug Foldback only inside the capped container that
`dev.Dockerfile` defines. Do not run `cabal`, `ghc`, or a host-built `foldback`
binary on the macOS host.

Build the image when `foldback.cabal` dependencies change, then start one
container for the checkout:

```bash
docker build -f dev.Dockerfile -t foldback-dev .
gitdir="$(git rev-parse --path-format=absolute --git-common-dir)"
name="foldback-dev-$(basename "$PWD")"
docker run -d --rm --init --name "$name" \
  --cpus=2 --memory=2g --memory-swap=2g --pids-limit=256 \
  --tmpfs /workspace/dist-newstyle:rw,exec,size=512m \
  --tmpfs /workspace/dist-cov:rw,exec,size=512m \
  --tmpfs /tmp:rw,exec,size=512m \
  -v "$PWD":/workspace -v "$gitdir":"$gitdir" \
  foldback-dev sleep 14400
```

The limits are 2 CPUs, 2 GiB memory with no swap, 256 processes, and 512 MiB
each for `dist-newstyle`, `dist-cov`, and `/tmp`. The tmpfs mounts hold all
build and coverage output, and their contents count toward the memory limit.
The CI steps and a CGPT campaign use about 0.8 GiB of memory and 120 MiB of
build output. The container stops after 4 hours.

Run the CI steps with `docker exec "$name"`:

```bash
docker exec "$name" cabal check
docker exec "$name" cabal build exe:foldback
docker exec "$name" cabal test foldback-test --test-show-details=always
docker exec "$name" cabal run exe:foldback -- --help
```

Run CGPT the same way:

```bash
docker exec "$name" cabal build exe:foldback --enable-coverage --builddir dist-cov
docker exec "$name" cabal run foldback-cgpt -- --generations 20 --seed 1
```

The image uses GHC 9.12.2; CI uses GHC 9.12.1. Remove the container with
`docker rm -f "$name"`.

## Definition of Done

- Respect the host's storage. Before you finish, remove the development
  container (`docker rm -f "$name"`), delete build output from the checkout
  (`rm -rf dist-newstyle dist-cov`), and remove the development image
  (`docker image prune -a -f --filter label=dev-image=foldback`).
