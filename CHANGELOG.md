# Revision history for foldback

## 0.1.2.0 -- 2026-09-22

* Reduce memory use: stop per-entry re-hashing of deduplicated content, index
  object names once in verify, and load each committed snapshot once behind a
  read-side loader seam.
* Harden manifest validation: index manifest descent checks in validatePaths.

## 0.1.1.0 -- 2026-09-20

* Harden path, symlink, and restore safety: reject paths that descend through
  symlinks, refuse restore targets beneath symlinked ancestors or with a trailing
  separator on a symlink, reject dot-suffixed symlink source roots, and reject
  symlinked content objects in verify, restore, and backup.
* Fix CLI option handling: parse `--repo` values correctly, reject empty
  repository paths before filesystem access, and reject `--name` on non-backup
  commands.
* Strengthen integrity and atomicity: digest snapshot manifests, bound streaming
  memory to chunk size, stage digest sidecars atomically before the snapshot
  manifest, read snapshot metadata strictly, validate manifest directory-tree
  coherence, prevent concurrent backups from overwriting the same snapshot name,
  and ignore POSIX temp-file leftovers during discovery.
* Add GitHub Actions CI for package checks and testing.

## 0.1.0.0 -- 2026-09-11

* Initial release of Foldback content-addressed filesystem backup CLI.
* Content-addressed storage with SHA-256 deduplication.
* Snapshots support regular files, directory hierarchies, empty directories, and symbolic links.
* Atomic snapshot manifest installation and temporary staging.
* Public command interface: `backup`, `list`, `verify`, and `restore`.
* Algebraic manifest derivation based on initial algebra catamorphism over filesystem folds.
* Coverage-guided property testing harness (`foldback-cgpt`).
