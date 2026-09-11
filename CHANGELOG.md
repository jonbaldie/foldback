# Revision history for foldback

## 0.1.0.0 -- 2026-09-11

* Initial release of Foldback content-addressed filesystem backup CLI.
* Content-addressed storage with SHA-256 deduplication.
* Snapshots support regular files, directory hierarchies, empty directories, and symbolic links.
* Atomic snapshot manifest installation and temporary staging.
* Public command interface: `backup`, `list`, `verify`, and `restore`.
* Algebraic manifest derivation based on initial algebra catamorphism over filesystem folds.
* Coverage-guided property testing harness (`foldback-cgpt`).
