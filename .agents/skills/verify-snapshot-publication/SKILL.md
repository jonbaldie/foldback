---
name: verify-snapshot-publication
description: Check that every visible snapshot manifest agrees with its digest sidecar during concurrent backup and process failure.
---

# Verify snapshot publication

Run this skill when changing snapshot creation, its name reservation lock, manifest or digest publication, or committed snapshot reads.

## Property

At every visible repository state, either the named manifest is absent or its digest equals the snapshot digest in the sidecar:

    manifest = absent OR manifest.digest = sidecar.digest

If this breaks, a committed snapshot can become unreadable. Foldback rejects a manifest whose digest does not match its sidecar.

## Check

Run the model checker from the repository root:

    ./.agents/skills/verify-snapshot-publication/scripts/check

The checker needs Python 3, Java 11 or later, and network access on the first run. It verifies the pinned TLC 1.7.4 download and caches it under ~/.cache/foldback-tlc. Set TLA2TOOLS to an existing copy to use an offline cache.

The checker reads the publication order from the two adjacent calls in backup. It accepts either order and rejects other source drift by comparing a normalized fingerprint of Repository.hs. Do not update model/source.sha256 until the source mapping and model have been reviewed together.

The configurations cover one writer, two separate processes, and two threads sharing a process. Each configuration checks the same invariant. A current shared-process violation is expected to make the command exit 1; treat a clean exit as all three cases passing. A source or tool error exits 2.

## Replay the shared-process case

Foldback's development instructions require compiling and running Haskell inside its capped Docker container. After building exe:foldback there, run:

    ./.agents/skills/verify-snapshot-publication/scripts/repro-shared

The harness races two real backup calls from separate Haskell threads against one name, then reads the resulting snapshot. It exits successfully when it observes the corrupt-manifest error, and exits 1 if 1,000 attempts do not reproduce it.

## Coverage and limits

The model covers the code path through backup, withSnapshotNameReservation, writeManifestDigest, writeSnapshot, and readNamedSnapshot. It models two writers, one name, distinct digest identities, same-process versus separate-process lock ownership, successful file operations, and process crashes between abstract actions. Staging and tree scanning are represented as a single work phase.

The model assumes distinct snapshot digests and no external repository mutation. It checks the visible manifest/sidecar invariant, not power-loss durability, fsync behavior, every filesystem failure, or every reader interleaving. It does not prove SHA-256 collision resistance. A source fingerprint match confirms the mapped source text, not all repository behavior.

Use /statechart to read a TLC trace and produce a state chart. Replay any new counterexample against the real code before treating it as a finding. Use /maintain-formal-verification-skill after changes to this code path.
