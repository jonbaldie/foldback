# Foldback

Foldback is an immutable, content-addressed filesystem backup CLI written in Haskell. It turns a directory tree into a snapshot manifest by a catamorphism, stores each distinct file body once under its SHA-256 digest, and restores snapshots without following source symlinks.

The repository is deliberately inspectable:

```text
repository/
|-- FORMAT
|-- objects/
|   `-- <sha256>
`-- snapshots/
    `-- <name>
```

## Build

Foldback requires GHC 9.6 or newer and Cabal.

```sh
cabal build
cabal install exe:foldback
```

The Cabal package builds a native `foldback` executable.

## Use

Create a named snapshot. The repository is initialized on the first backup and must be outside the source tree.

```sh
foldback backup ~/Documents --repo /Volumes/Archive/documents --name before-upgrade
```

Omit `--name` to generate a timestamp-based name.

List snapshots:

```sh
foldback list --repo /Volumes/Archive/documents
```

Verify every manifest and content object:

```sh
foldback verify --repo /Volumes/Archive/documents
```

Restore into a new or empty directory:

```sh
foldback restore before-upgrade ./recovered --repo /Volumes/Archive/documents
```

Run `foldback --help` for the command summary.

## Filesystem Semantics

Version 0.1 snapshots regular-file contents, directory structure, empty directories, and symbolic-link targets. Symlinks are recorded rather than followed. Hard-linked files are restored as separate files whose content remains deduplicated in the repository.

File ownership, permissions, extended attributes, ACLs, sparse extents, and modification times are not yet recorded. Special files such as sockets, devices, and FIFOs cause backup to stop with an error. Restore refuses non-empty targets and paths overlapping the repository. Reusing a snapshot name is also refused.

An individual file is streamed once into a temporary object while its digest is calculated. The completed object and snapshot manifest are installed by rename, so an exception cannot expose a partially written object under a valid digest. Foldback does not lock the source; concurrent source changes can therefore produce a snapshot containing files from different instants.

## The Functional Pearl

The derivation starts with the base functor for a filesystem tree:

```haskell
data FsF a
  = DirectoryF FilePath [a]
  | RegularFileF FilePath Digest Integer
  | SymbolicLinkF FilePath FilePath

newtype Fix f = Fix (f (Fix f))
```

For any functor `f`, Bird-Meertens notation gives the unique homomorphism from its initial algebra:

```text
cata phi . Fix = phi . fmap (cata phi)
```

Choose `phi` to prepend one node's manifest entry and combine the summaries of its children:

```text
phi (DirectoryF p xs)      = directory(p) <> fold(xs)
phi (RegularFileF p h n)   = file(p, h, n)
phi (SymbolicLinkF p dest) = link(p, dest)
```

Here `<>` is the product monoid of pre-order entries, file count, total byte count, and the set of content digests. Associativity means subtrees can be summarized independently; the empty directory supplies the identity. The implementation in `Foldback.Algebra` is the equation directly transcribed into Haskell.

The operational program is then factored as:

```text
backup = commit . cata phi <=< scan-and-store
```

`scan-and-store` is the effectful coalgebra-like edge: it observes directory shape and streams regular files into the object store. `cata phi` is the pure center: it forgets recursion while deriving the complete manifest and totals. `commit` is the other effectful edge: it atomically publishes that value as a snapshot. This factorization keeps filesystem effects at the perimeter and makes the derivation independently testable with a worked tree.

Content addressing follows from the same homomorphism. The object contribution of a file is the singleton set containing its digest; the directory contribution is set union over its children. By idempotence of set union, equal file bodies collapse without a separate deduplication pass:

```text
objects (join subtrees) = union (map objects subtrees)
```

That is the practical payoff of the Bird-Meertens view: snapshot shape is a list homomorphism, storage demand is a set homomorphism, and accounting is a numeric homomorphism, all derived by one fold over the same recursive value.

## Test

```sh
cabal test
```

The suite exercises the public command seam for backup, list, verify, and restore, plus the exported fold seam with a fixed worked example.
