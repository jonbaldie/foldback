# Foldback CLI exploratory pass

Date: 2026-10-29. Tested commit `3cf20fb` on Linux in the capped development container with GHC 9.12.2 and Foldback 0.1.8.0. The source, repository, and restore destinations were isolated in the worktree. The container used no published ports or named volumes.

The project has no Cabal freeze file or other dependency lockfile. The documented Docker build ran `cabal update` and installed dependencies at Hackage index state `2026-10-28T23:27:22Z`. The subsequent build and test used `--offline`. This is not a locked install, so another build can resolve different versions.

## Journeys and outcomes

The [command transcript](evidence/2026-10-29-cli-transcript.txt) and [driving script](evidence/2026-10-29-cli-journeys.sh) capture the commands and checks. The script starts by deleting its own `.explore-data` directory. Run it only in a disposable checkout and the documented development container.

- **Back up and list snapshots.** A tree contained two identical files, a symlink, and an empty directory. The first backup listed two files and stored one object. After changing one file, the second snapshot listed two files and the repository contained two objects. Reusing the first name failed. The first snapshot was subsequently restored with its original content.
- **Restore a snapshot.** Restoring the first snapshot reproduced both file contents, the symlink target, and the empty directory. Restoring the second snapshot into that nonempty destination failed and left the checked file unchanged. Restoring it into a new destination returned the changed content.
- **Verify integrity.** Verification reported two snapshots and two objects. After overwriting one object with `corrupt`, verification reported that object's digest as corrupt. The object selected happened not to belong to the first snapshot, which still restored successfully. Restore of the affected second snapshot was not tested.

The standalone `foldback-test` suite also passed in the container. The pass found no confirmed bugs and filed no issues. The issue list, including closed and `wontfix` entries, was inspected before the pass. No suspected failure required replay.

## Limits and cleanup

The pass did not exercise concurrent operations, interrupted backups, permissions, large data, or other operating systems. The output confirms the selected paths, not all possible filesystem combinations. No usability defect was observed in these journeys.

The first pass recorded the container and image names before startup but did not install an exit trap. Normal teardown removed both. The root-owned test data required `sudo` for deletion. No named volume was created.

The pass was repeated at commit `b7a6003` with an [exit-trap cleanup script](evidence/2026-10-29-cleanup-harness.sh) registered before the image build. The script uses the original worktree path and requires passwordless `sudo` to remove container-owned data. It registers the container and image names before startup and handles normal exit, interrupt, and termination. The [repeat transcript](evidence/2026-10-29-cleanup-repeat.txt) records the same successful journeys, no published ports, and cleanup checks. The container init PID was absent after teardown, as were matching container, image, volume, process name, and PID-owned listening port entries. No browser was started. The run did not remove shared Docker build cache or unrelated images.
