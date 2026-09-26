# Foldback

Foldback is an immutable, content-addressed filesystem backup tool. It takes snapshots of directory trees, deduplicates identical files across all snapshots using SHA-256 content addressing, and safely restores snapshots without following symlinks.

## What Foldback Does For You

- **Automatic Deduplication**: Every distinct file body is stored only once under its SHA-256 digest. Identical files across different directories, or unchanged files across multiple backups, consume no extra disk space.
- **Inspectable Repository**: The repository on disk is transparent and straightforward, not a black-box database:
  ```text
  repository/
  |-- FORMAT
  |-- objects/
  |   `-- <sha256>
  `-- snapshots/
      `-- <name>
  ```
- **Integrity Verification**: `foldback verify` checks that all snapshot manifests are consistent, every referenced object exists, and every stored content object matches its SHA-256 digest without corruption.
- **Safe Restoration**: Restores snapshots cleanly into empty or new directories, refusing to overwrite non-empty targets or traverse symlinks.
- **Atomic Operations**: Files and manifests are staged in temporary files and installed by rename, ensuring an interruption or crash never exposes a partially written object under a valid digest.

## Install and Build

Foldback requires GHC 9.6 or newer and Cabal.

```sh
cabal build
cabal install exe:foldback
```

This builds and installs the standalone `foldback` executable.

## Usage

### 1. Create a snapshot

Backup a source directory into an external repository. If the repository does not exist, it will be initialized automatically:

```sh
foldback backup ~/Documents --repo /Volumes/Archive/documents --name before-upgrade
```

Omit `--name` to automatically generate a timestamp-based snapshot name:

```sh
foldback backup ~/Documents --repo /Volumes/Archive/documents
```

### 2. List snapshots

View all committed snapshots with their file counts and total byte sizes:

```sh
foldback list --repo /Volumes/Archive/documents
```

### 3. Verify repository integrity

Verify every snapshot manifest and audit every content object against its cryptographic digest:

```sh
foldback verify --repo /Volumes/Archive/documents
```

### 4. Restore a snapshot

Restore a snapshot into a new or empty target directory:

```sh
foldback restore before-upgrade ./recovered --repo /Volumes/Archive/documents
```

Run `foldback --help` for the full command summary.

## Filesystem Semantics

- **Files and directories**: Snapshots regular file contents, directory hierarchy, and empty directories.
- **Symlinks**: Symbolic links are recorded verbatim as links, rather than followed.
- **Hard links**: Hard-linked files are recorded and restored as separate directory entries whose file content remains deduplicated in the object store.
- **Safety checks**: Special files (sockets, devices, FIFOs) cause backup to halt with an error. Restore refuses non-empty targets and paths that overlap with the repository itself. Reusing an existing snapshot name is also refused.
- **Concurrency**: Foldback does not lock the source tree; files modified during backup may reflect different moments in time.

## Testing

Run the integration and regression test suite:

```sh
cabal test
```

The test suite exercises the public command interface (`backup`, `list`, `verify`, `restore`), negative argument validation, corruption detection, and the core algebraic fold seam.

For an end-to-end run through the public CLI, see the [Foldback CLI exploratory report](docs/exploratory-testing/2026-09-26-foldback-cli.md).

### Coverage-Guided Property Testing (CGPT)

```sh
cabal build exe:foldback
cabal build exe:foldback --enable-coverage --builddir dist-cov
cabal run foldback-cgpt -- [--generations N] [--seed N] [--replay SEED]
```

The `foldback-cgpt` executable drives the real, HPC-instrumented `foldback` binary with seeded, stateful scenarios: generated filesystem trees, mutations between snapshots, symlinks, empty files and directories, 64 KiB chunk boundaries, and negative checks. After every backup step it asserts receipts, list summaries, deduplication invariants, repository verification, and round-trip restore fidelity.

---

## Interested in the roots of this project?

Well, it's actually rooted in a pretty cool application of algebraic coding theory and functional programming.

At its core, Foldback treats filesystem trees and backup operations through the lens of initial algebra semantics and the Bird-Meertens formalism.

### The Algebraic Derivation

The derivation starts with a polynomial base functor `FsF` for an unfixed filesystem tree:

```haskell
data FsF a
  = DirectoryF FilePath [a]
  | RegularFileF FilePath Digest Integer
  | SymbolicLinkF FilePath FilePath

newtype Fix f = Fix (f (Fix f))
```

For any functor `f`, category theory gives the unique homomorphism (a *catamorphism*, or fold) from its initial algebra:

```text
cata phi . Fix = phi . fmap (cata phi)
```

We choose an algebra `phi` that prepends one node's manifest entry and combines the summaries of its children:

```text
phi (DirectoryF p xs)      = directory(p) <> fold(xs)
phi (RegularFileF p h n)   = file(p, h, n)
phi (SymbolicLinkF p dest) = link(p, dest)
```

Here `<>` is the product monoid of pre-order entry lists, total file count, total byte count, and the set of content digests. Associativity means arbitrary subtrees can be summarized independently; the empty directory supplies the monoidal identity. The implementation in `Foldback.Algebra` is this exact equation directly transcribed into Haskell.

The operational backup pipeline factors cleanly as:

```text
backup = commit . cata phi <=< scan-and-store
```

- **`scan-and-store`** is the effectful coalgebraic edge: it traverses physical directory structure and streams regular files into content-addressed object storage.
- **`cata phi`** is the pure mathematical center: it eliminates recursion while deriving the complete manifest and accounting totals in one pass.
- **`commit`** is the effectful closing edge: it atomically writes and installs the resulting snapshot manifest.

### Content Addressing as a Homomorphism

Content addressing emerges directly from the same homomorphism. The object contribution of a file is the singleton set containing its digest; the directory contribution is set union over its children. By idempotence of set union (`A ∪ A = A`), identical file bodies collapse without requiring a distinct deduplication pass:

```text
objects (join subtrees) = union (map objects subtrees)
```

That is the practical payoff of the algebraic view:
- Snapshot structure is a **list homomorphism**.
- Storage demand is a **set homomorphism**.
- File and byte accounting is a **numeric homomorphism**.

All three properties are computed simultaneously by a single fold over the same recursive value.
