module Main (main) where

import Control.Concurrent (forkIO, killThread)
import Control.Exception (SomeException, bracket, displayException, try)
import Control.Monad (forM_, unless, when)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.ByteString as BS
import qualified Data.Set as Set
import Foldback.Algebra
import Foldback.Repository
  ( Snapshot (..)
  , manifestDigestPath
  , snapshotDigest
  , validatePaths
  , writeManifestDigest
  , writeSnapshot
  )
import Numeric (showHex)
import qualified System.Posix.Files as Posix
import System.Directory
  ( canonicalizePath
  , createDirectory
  , createDirectoryLink
  , createDirectoryIfMissing
  , createFileLink
  , doesDirectoryExist
  , doesFileExist
  , doesPathExist
  , getCurrentDirectory
  , getSymbolicLinkTarget
  , getTemporaryDirectory
  , listDirectory
  , removeFile
  , removePathForcibly
  , setCurrentDirectory
  )
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hClose, openTempFile, withBinaryFile)
import System.Process (readProcessWithExitCode)

main :: IO ()
main = do
  outcomes <- traverse runTest tests
  if and outcomes then pure () else exitFailure

tests :: [(String, IO ())]
tests =
  [ ("derive manifest", testDerivesManifest)
  , ("backup and restore", testBackupAndRestore)
  , ("list and verify", testListAndVerify)
  , ("list and verify many snapshots", testListAndVerifyManySnapshots)
  , ("detect corruption", testDetectsCorruption)
  , ("reject symlink source roots", testRejectsSymlinkSourceRoot)
  , ("reject optionlike snapshot name", testRejectsOptionlikeSnapshotName)
  , ("reject optionlike repository value", testRejectsOptionlikeRepositoryValue)
  , ("reject symlink restore targets", testRejectsSymlinkRestoreTarget)
  , ("reject symlink restore target ancestors", testRejectsSymlinkAncestorRestoreTarget)
  , ("reject empty restore target", testRejectsEmptyRestoreTarget)
  , ("reject empty repository path", testRejectsEmptyRepositoryPath)
  , ("reject --name outside backup", testRejectsNameOutsideBackup)
  , ("tolerate foreign metadata files", testToleratesForeignMetadataFiles)
  , ("detect manifest tampering", testDetectsManifestTampering)
  , ("bounds streaming memory", testBoundsStreamingMemory)
  , ("sidecar installed before manifest", testSidecarInstalledBeforeManifest)
  , ("tolerate incomplete snapshot leftovers", testIncompleteSnapshotTolerated)
  , ("atomic digest sidecar staging", testDigestSidecarAtomicStaging)
  , ("reject symlink traversal order independent", testRejectsSymlinkTraversalOrderIndependent)
  , ("reject incoherent directory trees", testRejectsIncoherentDirectoryTrees)
  , ("help", testHelp)
  ]

runTest :: (String, IO ()) -> IO Bool
runTest (name, action) = do
  result <- try action
  case result of
    Left exception -> do
      putStrLn ("FAIL " <> name <> ": " <> displayException (exception :: SomeException))
      pure False
    Right () -> do
      putStrLn ("PASS " <> name)
      pure True

testDerivesManifest :: IO ()
testDerivesManifest =
  assertEqual
    "a filesystem fold derives pre-order entries and totals"
    ( Summary
        { entries =
            [ Directory "."
            , Directory "docs"
            , RegularFile "docs/guide.txt" (Digest "abc") 12
            , SymbolicLink "latest" "docs/guide.txt"
            ]
        , fileCount = 1
        , totalBytes = 12
        , objects = Set.singleton (Digest "abc")
        }
    )
    ( deriveManifest
        ( Fix
            ( DirectoryF
                "."
                [ Fix
                    ( DirectoryF
                        "docs"
                        [Fix (RegularFileF "docs/guide.txt" (Digest "abc") 12)]
                    )
                , Fix (SymbolicLinkF "latest" "docs/guide.txt")
                ]
            )
        )
    )

testBackupAndRestore :: IO ()
testBackupAndRestore = withTemporaryDirectory "foldback-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
      restored = sandbox </> "restored"
  createDirectory source
  createDirectory (source </> "docs")
  writeFile (source </> "hello.txt") "hello"
  writeFile (source </> "docs" </> "copy.txt") "hello"
  createFileLink "docs/copy.txt" (source </> "latest")

  backupResult <- runExecutable ["backup", source, "--repo", repository, "--name", "first"]
  assertEqual
    "backup reports the committed snapshot"
    (Right "snapshot first: 2 files, 10 bytes\n")
    backupResult

  restoreResult <- runExecutable ["restore", "first", restored, "--repo", repository]
  assertEqual "restore reports its target" (Right ("restored first to " <> restored <> "\n")) restoreResult
  restoredHello <- readFile (restored </> "hello.txt")
  restoredCopy <- readFile (restored </> "docs" </> "copy.txt")
  restoredLink <- getSymbolicLinkTarget (restored </> "latest")
  assertEqual "restored first file content" "hello" restoredHello
  assertEqual "restored duplicate file content" "hello" restoredCopy
  assertEqual "restored symlink target" "docs/copy.txt" restoredLink

  let restoredSlashed = sandbox </> "restored-slashed" <> "/"
  restoreSlashedResult <- runExecutable ["restore", "first", restoredSlashed, "--repo", repository]
  assertEqual "restore reports its slashed target" (Right ("restored first to " <> restoredSlashed <> "\n")) restoreSlashedResult
  restoredSlashedHello <- readFile (sandbox </> "restored-slashed" </> "hello.txt")
  assertEqual "restored file content from slash-suffixed target" "hello" restoredSlashedHello

testListAndVerify :: IO ()
testListAndVerify = withTemporaryDirectory "foldback-list-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
  createDirectory source
  writeFile (source </> "one.txt") "same"
  writeFile (source </> "two.txt") "same"
  _ <- runExecutable ["backup", source, "--repo", repository, "--name", "first"]
  writeFile (source </> "two.txt") "changed"
  _ <- runExecutable ["backup", source, "--repo", repository, "--name", "second"]

  listResult <- runExecutable ["list", "--repo", repository]
  assertEqual
    "list shows stable snapshot summaries"
    (Right "first\t2 files\t8 bytes\nsecond\t2 files\t11 bytes\n")
    listResult

  verifyResult <- runExecutable ["verify", "--repo", repository]
  assertEqual
    "verify reports snapshots and unique content objects"
    (Right "verified 2 snapshots, 2 objects\n")
    verifyResult

testListAndVerifyManySnapshots :: IO ()
testListAndVerifyManySnapshots = withTemporaryDirectory "foldback-many-snapshots-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
      snapshotCount = 300 :: Int
      descriptorLimit = 256
      lastSnapshotName = "s" <> zeroPad 3 (snapshotCount - 1)
  createDirectory source
  writeFile (source </> "data.txt") "data"
  firstBackup <- runExecutable ["backup", source, "--repo", repository, "--name", "s000"]
  assertEqual "many-snapshot fixture starts with one snapshot" (Right "snapshot s000: 1 file, 4 bytes\n") firstBackup

  template <- readFile (repository </> "snapshots" </> "s000")
  length template `seq` forM_ [1 .. snapshotCount - 1] (writeSnapshotFixture repository template)

  listResult <- runExecutableWithDescriptorLimit descriptorLimit ["list", "--repo", repository]
  verifyResult <- runExecutableWithDescriptorLimit descriptorLimit ["verify", "--repo", repository]
  case listResult of
    Right output -> assertBool "list handles many snapshots within the descriptor limit" ((lastSnapshotName <> "\t1 files\t4 bytes\n") `isInfixOf` output)
    Left message -> error ("list handles many snapshots within the descriptor limit: " <> message)

  assertEqual
    "verify handles many snapshots within the descriptor limit"
    (Right ("verified " <> show snapshotCount <> " snapshots, 1 objects\n"))
    verifyResult
 where
  writeSnapshotFixture repository template number = do
    let name = "s" <> zeroPad 3 number
        manifestPath = repository </> "snapshots" </> name
        sidecarPath = repository </> "snapshots" </> ("." <> name <> ".digest")
        needle = "snapshotName = \"s000\""
        replacement = "snapshotName = \"" <> name <> "\""
        manifest = replaceFirst needle replacement template
        digest = sha256Hex manifest
    length manifest `seq` writeFile manifestPath manifest
    BS.writeFile sidecarPath (BS.pack (map (fromIntegral . fromEnum) (digest <> "\n")))

  zeroPad width number = replicate (width - length digits) '0' <> digits
   where
    digits = show number

  sha256Hex content = concatMap hexByte (BS.unpack (SHA256.hash (BS.pack (map (fromIntegral . fromEnum) content))))

  hexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

  replaceFirst needle replacement content = case breakOnFirst needle content of
    Nothing -> error ("many-snapshot fixture could not find " <> show needle)
    Just (before, after) -> before <> replacement <> after

testDetectsCorruption :: IO ()
testDetectsCorruption = withTemporaryDirectory "foldback-corruption-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
  createDirectory source
  writeFile (source </> "valuable.txt") "intact"
  _ <- runExecutable ["backup", source, "--repo", repository, "--name", "before"]
  objectNames <- listDirectory (repository </> "objects")
  case objectNames of
    [objectName] -> writeFile (repository </> "objects" </> objectName) "damaged"
    _ -> error "worked example should produce exactly one object"

  verifyResult <- runExecutable ["verify", "--repo", repository]
  assertLeftContaining "verify identifies a corrupt content object" "corrupt object:" verifyResult

testRejectsSymlinkSourceRoot :: IO ()
testRejectsSymlinkSourceRoot = withTemporaryDirectory "foldback-symlink-root-test" $ \sandbox -> do
  let source = sandbox </> "source"
      sourceLink = sandbox </> "source-link"
      repository = sandbox </> "repository"
  createDirectory source
  createDirectoryLink source sourceLink
  backupResult <- runExecutable ["backup", sourceLink, "--repo", repository, "--name", "invalid"]
  assertLeftContaining "backup requires a real directory root" "source is not a directory:" backupResult

  backupSlashedResult <- runExecutable ["backup", sourceLink <> "/", "--repo", repository, "--name", "invalid"]
  assertLeftContaining
    "backup requires a real directory root, slash-suffixed"
    "source is not a directory:"
    backupSlashedResult

  backupDottedResult <- runExecutable ["backup", sourceLink <> "/.", "--repo", repository, "--name", "invalid"]
  assertLeftContaining
    "backup requires a real directory root, dot-suffixed"
    "source is not a directory:"
    backupDottedResult

  backupDotSlashedResult <- runExecutable ["backup", sourceLink <> "/./", "--repo", repository, "--name", "invalid"]
  assertLeftContaining
    "backup requires a real directory root, dot-and-slash-suffixed"
    "source is not a directory:"
    backupDotSlashedResult

  dotBackupResult <- runExecutable ["backup", source <> "/.", "--repo", repository, "--name", "dotted"]
  assertRightContaining "backup accepts a real directory with a dot suffix" "snapshot dotted" dotBackupResult

testRejectsOptionlikeSnapshotName :: IO ()
testRejectsOptionlikeSnapshotName = withTemporaryDirectory "foldback-optionlike-name-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
  createDirectory source
  writeFile (source </> "a.txt") "data"

  dashNamed <- runExecutable ["backup", source, "--repo", repository, "--name", "-w"]
  assertLeftContaining "backup refuses a leading-dash snapshot name" "snapshot name" dashNamed
  snapshotNames <- listDirectory (repository </> "snapshots")
  assertEqual "no snapshot is created for a refused name" (0 :: Int) (length snapshotNames)

  dashInside <- runExecutable ["backup", source, "--repo", repository, "--name", "my-backup"]
  assertEqual "dash inside the name is still accepted" (Right "snapshot my-backup: 1 file, 4 bytes\n") dashInside
  restoreResult <- runExecutable ["restore", "my-backup", sandbox </> "restored", "--repo", repository]
  assertRightContaining "dash-inside names restore cleanly" "restored my-backup" restoreResult

testRejectsOptionlikeRepositoryValue :: IO ()
testRejectsOptionlikeRepositoryValue = withTemporaryDirectory "foldback-optionlike-repo-test" $ \sandbox -> do
  let source = sandbox </> "source"
      workingDirectory = sandbox </> "work"
      repository = sandbox </> "repository"
      invalidArguments =
        [ ["backup", source, "--repo", "--name"]
        , ["backup", source, "--repo", "--name", "my-snap"]
        , ["backup", source, "--repo", "--repo", repository]
        ]
  createDirectory source
  createDirectory workingDirectory
  writeFile (source </> "a.txt") "data"

  results <- bracket getCurrentDirectory setCurrentDirectory $ \_ -> do
    setCurrentDirectory workingDirectory
    traverse runExecutable invalidArguments
  forM_ results (assertLeftContaining "--repo rejects an option-like value" "--repo requires a value")
  contents <- listDirectory workingDirectory
  assertEqual "an option-like repository value does not create a flag-named directory" (0 :: Int) (length contents)

testRejectsSymlinkRestoreTarget :: IO ()
testRejectsSymlinkRestoreTarget = withTemporaryDirectory "foldback-symlink-target-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
      brokenTarget = sandbox </> "broken-target"
  createDirectory source
  createDirectory (sandbox </> "empty-target-directory")
  writeFile (source </> "a.txt") "data"
  _ <- runExecutable ["backup", source, "--repo", repository, "--name", "s1"]
  createFileLink (sandbox </> "missing-target") brokenTarget

  brokenResult <- runExecutable ["restore", "s1", brokenTarget, "--repo", repository]
  assertLeftContaining
    "restore refuses a dangling symlink target"
    "restore target is not a directory:"
    brokenResult

  brokenSlashedResult <- runExecutable ["restore", "s1", brokenTarget <> "/", "--repo", repository]
  assertLeftContaining
    "restore refuses a dangling symlink target, slash-suffixed"
    "restore target is not a directory:"
    brokenSlashedResult

  createFileLink (sandbox </> "empty-target-directory") (sandbox </> "valid-target")
  linkedResult <- runExecutable ["restore", "s1", sandbox </> "valid-target", "--repo", repository]
  assertLeftContaining
    "restore refuses a symlink target pointing at a real directory"
    "restore target is not a directory:"
    linkedResult
  contents <- listDirectory (sandbox </> "empty-target-directory")
  assertEqual "nothing was written through the refused symlink target" (0 :: Int) (length contents)

  linkedSlashedResult <- runExecutable ["restore", "s1", (sandbox </> "valid-target") <> "/", "--repo", repository]
  assertLeftContaining
    "restore refuses a symlink target pointing at a real directory, slash-suffixed"
    "restore target is not a directory:"
    linkedSlashedResult
  contentsAfterSlashed <- listDirectory (sandbox </> "empty-target-directory")
  assertEqual "nothing was written through the refused slashed symlink target" (0 :: Int) (length contentsAfterSlashed)

testRejectsSymlinkAncestorRestoreTarget :: IO ()
testRejectsSymlinkAncestorRestoreTarget = withTemporaryDirectory "foldback-symlink-ancestor-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
      outside = sandbox </> "outside"
  createDirectory source
  createDirectory outside
  writeFile (source </> "a.txt") "data"
  _ <- runExecutable ["backup", source, "--repo", repository, "--name", "s1"]
  createDirectoryLink outside (sandbox </> "linked-parent")

  newTargetResult <- runExecutable ["restore", "s1", sandbox </> "linked-parent" </> "new-target", "--repo", repository]
  assertLeftContaining
    "restore refuses a new target beneath a symlink ancestor"
    "restore target is not a directory:"
    newTargetResult
  contents <- listDirectory outside
  assertEqual "nothing was written through the symlink ancestor" (0 :: Int) (length contents)

  createDirectory (sandbox </> "linked-parent" </> "existing-empty")
  existingResult <- runExecutable ["restore", "s1", sandbox </> "linked-parent" </> "existing-empty", "--repo", repository]
  assertLeftContaining
    "restore refuses an existing target beneath a symlink ancestor"
    "restore target is not a directory:"
    existingResult
  contentsAfterExisting <- listDirectory outside
  assertEqual
    "only the fixture directory exists behind the refused existing target"
    (["existing-empty"] :: [String])
    contentsAfterExisting

  realResult <- runExecutable ["restore", "s1", sandbox </> "real-parent" </> "new-target", "--repo", repository]
  assertRightContaining "restore beneath a real ancestor still works" "restored s1" realResult
  restoredContent <- readFile (sandbox </> "real-parent" </> "new-target" </> "a.txt")
  assertEqual "restored content beneath a real ancestor" "data" restoredContent

testRejectsEmptyRestoreTarget :: IO ()
testRejectsEmptyRestoreTarget = withTemporaryDirectory "foldback-empty-target-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
      workingDirectory = sandbox </> "work"
  createDirectory source
  createDirectory workingDirectory
  writeFile (source </> "data.txt") "from-backup"
  writeFile (workingDirectory </> "data.txt") "precious-local"
  writeFile (workingDirectory </> "other.txt") "unrelated-local"
  _ <- runExecutable ["backup", source, "--repo", repository, "--name", "s1"]

  previousDirectory <- getCurrentDirectory
  setCurrentDirectory workingDirectory
  emptyResult <- try (runExecutable ["restore", "s1", "", "--repo", repository])
  setCurrentDirectory previousDirectory
  case emptyResult of
    Right (Right output) -> error ("restore accepted an empty target: " <> show output)
    Right (Left message)
      | "restore target" `isInfixOf` message -> pure ()
      | otherwise -> error ("restore failed with an unexpected message: " <> message)
    Left exception -> error ("restore failed unexpectedly: " <> show (exception :: SomeException))

  surviving <- readFile (workingDirectory </> "data.txt")
  assertEqual "a matching local file survives an refused empty target" "precious-local" surviving
  untouched <- readFile (workingDirectory </> "other.txt")
  assertEqual "unrelated local files survive" "unrelated-local" untouched

testRejectsEmptyRepositoryPath :: IO ()
testRejectsEmptyRepositoryPath = withTemporaryDirectory "foldback-empty-repository-test" $ \sandbox -> do
  let source = sandbox </> "source"
      workingDirectory = sandbox </> "work"
  createDirectory source
  createDirectory workingDirectory
  writeFile (source </> "data.txt") "from-backup"

  result <- bracket getCurrentDirectory setCurrentDirectory $ \_ -> do
    setCurrentDirectory workingDirectory
    runExecutable ["backup", source, "--repo", "", "--name", "s1"]
  assertLeftContaining "backup rejects an empty repository path" "--repo cannot be empty" result
  contents <- listDirectory workingDirectory
  assertEqual "an empty repository path does not modify the working directory" (0 :: Int) (length contents)

testRejectsNameOutsideBackup :: IO ()
testRejectsNameOutsideBackup = withTemporaryDirectory "foldback-name-outside-backup-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
  createDirectory source
  writeFile (source </> "a.txt") "data"

  let rejectedArguments =
        [ ["restore", "snapshot", sandbox </> "restored", "--repo", repository, "--name", "first"]
        , ["restore", "snapshot", sandbox </> "restored", "--repo", repository, "--name"]
        , ["list", "--repo", repository, "--name", "first"]
        , ["list", "--repo", repository, "--name"]
        , ["verify", "--repo", repository, "--name", "first"]
        , ["verify", "--repo", repository, "--name"]
        ]
  results <- traverse runExecutable rejectedArguments
  forM_ results (assertLeftContaining "--name is refused outside backup" "--name is only valid for backup")

  namedResult <- runExecutable ["backup", source, "--repo", repository, "--name", "first"]
  assertEqual "backup still accepts a named snapshot" (Right "snapshot first: 1 file, 4 bytes\n") namedResult

  unnamedResult <- runExecutable ["backup", source, "--repo", repository, "--name"]
  assertLeftContaining "backup still reports a missing name value" "--name requires a value" unnamedResult

  duplicateResult <- runExecutable ["backup", source, "--repo", repository, "--name", "second", "--name", "third"]
  assertLeftContaining "backup still reports a repeated name flag" "--name may only be supplied once" duplicateResult

testToleratesForeignMetadataFiles :: IO ()
testToleratesForeignMetadataFiles = withTemporaryDirectory "foldback-foreign-metadata-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
  createDirectory source
  writeFile (source </> "a.txt") "important data"
  _ <- runExecutable ["backup", source, "--repo", repository, "--name", "s1"]

  writeFile (repository </> "snapshots" </> ".DS_Store") "\0\0\0\1Bud1\0\0\16\0"
  writeFile (repository </> "objects" </> ".DS_Store") "\0\0\0\1Bud1\0\0\16\0"
  writeFile (repository </> "snapshots" </> ".snapshot-leftover") "abandoned staging file"
  writeFile (repository </> "objects" </> ".incoming-abandoned") "abandoned staging file"

  listResult <- runExecutable ["list", "--repo", repository]
  assertEqual "list ignores foreign files in snapshots" (Right "s1\t1 files\t14 bytes\n") listResult

  verifyResult <- runExecutable ["verify", "--repo", repository]
  assertEqual "verify counts only real artifacts" (Right "verified 1 snapshots, 1 objects\n") verifyResult

  dotNamedBackup <- runExecutable ["backup", source, "--repo", repository, "--name", ".hidden"]
  assertLeftContaining "backup refuses a leading-dot snapshot name" "snapshot name" dotNamedBackup

  restoreResult <- runExecutable ["restore", "s1", sandbox </> "restored", "--repo", repository]
  assertRightContaining "restore of a real snapshot is unaffected" "restored s1" restoreResult

testDetectsManifestTampering :: IO ()
testDetectsManifestTampering = withTemporaryDirectory "foldback-manifest-tamper-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
  createDirectory source
  writeFile (source </> "a.txt") "precious data"
  _ <- runExecutable ["backup", source, "--repo", repository, "--name", "s"]

  rewriteManifestEntryName repository "s" "a.txt" "z.txt"

  verifyResult <- runExecutable ["verify", "--repo", repository]
  assertLeftContaining "verify identifies a damaged manifest" "corrupt snapshot" verifyResult

  restoreResult <- runExecutable ["restore", "s", sandbox </> "restored", "--repo", repository]
  assertLeftContaining "restore refuses a damaged manifest" "corrupt snapshot" restoreResult

-- Rewrites a manifest entry's path in place while keeping the record
-- well-formed, simulating on-disk damage the record layer alone cannot see.
rewriteManifestEntryName :: FilePath -> String -> String -> String -> IO ()
rewriteManifestEntryName repository name from to = do
  let manifestPath = repository </> "snapshots" </> name
  content <- readFile manifestPath
  damaged <- case breakOnFirst ('"' : from ++ "\"") content of
    Nothing -> error ("test fixture could not find " <> show from <> " in the manifest")
    Just (before, after) -> pure (before <> ('"' : to ++ "\"" <> after))
  length damaged `seq` writeFile manifestPath damaged

breakOnFirst :: String -> String -> Maybe (String, String)
breakOnFirst needle = go ""
 where
  go _ [] = Nothing
  go acc rest@(character : characters)
    | needle `isPrefixOf` rest = Just (reverse acc, drop (length needle) rest)
    | otherwise = go (character : acc) characters

testBoundsStreamingMemory :: IO ()
testBoundsStreamingMemory = withTemporaryDirectory "foldback-memory-bound-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
      restored = sandbox </> "restored"
      megabyte = 1024 * 1024
      size = 128 * megabyte
      bound = 30 * megabyte
  createDirectory source
  writeFilledFile (source </> "big.bin") size

  backupResidency <- measureResidency ["backup", source, "--repo", repository, "--name", "s1"]
  verifyResidency <- measureResidency ["verify", "--repo", repository]
  restoreResidency <- measureResidency ["restore", "s1", restored, "--repo", repository]

  forM_
    [ ("backup", backupResidency)
    , ("verify", verifyResidency)
    , ("restore", restoreResidency)
    ]
    (\(command, residency) ->
      assertBool
        (command <> " peak residency " <> show residency <> " exceeds the " <> show bound <> " bound")
        (residency <= bound))
 where
  measureResidency arguments = do
    (_, _, statistics) <- readProcessWithExitCode "foldback" (arguments <> ["+RTS", "-s"]) ""
    case [line | line <- lines statistics, "maximum residency" `isInfixOf` line] of
      (line : _) -> case words line of
        (number : _) -> pure (read (filter (/= ',') number))
        [] -> error ("no residency figure in RTS statistics: " <> line)
      [] -> error ("the executable did not report RTS statistics; is -rtsopts enabled? output: " <> statistics)

  writeFilledFile path size = withBinaryFile path WriteMode (fill chunk)
   where
    chunk = BS.replicate 1024 120
    fill block handle =
      forM_ [1 .. size `div` BS.length block] (\_ -> BS.hPut handle block)

testSidecarInstalledBeforeManifest :: IO ()
testSidecarInstalledBeforeManifest = withTemporaryDirectory "foldback-order-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
  createDirectory source
  forM_ [1 .. 50 :: Int] $ \i ->
    writeFile (source </> ("f" <> show i <> ".txt")) (replicate 2000 'a')
  let snapshotsDir = repository </> "snapshots"
  seenInversionRef <- newIORef False
  stopRef <- newIORef False
  let watcher = do
        stop <- readIORef stopRef
        unless stop $ do
          exists <- doesDirectoryExist snapshotsDir
          when exists $ do
            manifestExists <- doesFileExist (snapshotsDir </> "snap")
            sidecarExists <- doesFileExist (snapshotsDir </> ".snap.digest")
            when (manifestExists && not sidecarExists) $
              writeIORef seenInversionRef True
          watcher
  bracket (forkIO watcher) killThread $ \_ -> do
    backupResult <- runExecutable ["backup", source, "--repo", repository, "--name", "snap"]
    assertRightContaining "backup succeeds" "snapshot snap:" backupResult
    writeIORef stopRef True
  inversion <- readIORef seenInversionRef
  assertBool "digest sidecar must be installed before snapshot manifest is published" (not inversion)

testIncompleteSnapshotTolerated :: IO ()
testIncompleteSnapshotTolerated = withTemporaryDirectory "foldback-incomplete-test" $ \sandbox -> do
  let source = sandbox </> "source"
      repository = sandbox </> "repository"
  createDirectory source
  writeFile (source </> "a.txt") "first snapshot"
  backup1 <- runExecutable ["backup", source, "--repo", repository, "--name", "s1"]
  assertEqual "first backup succeeds" (Right "snapshot s1: 1 file, 14 bytes\n") backup1

  -- Simulate an interrupted backup of "s2" before the snapshot manifest is published.
  -- Only hidden/temporary files were created:
  -- 1. The digest sidecar staged and installed (.s2.digest)
  -- 2. Leftover staging temporary dotfiles (.snapshot-incomplete, .digest-incomplete)
  let snapshotsDir = repository </> "snapshots"
      incompleteSidecar = snapshotsDir </> ".s2.digest"
      incompleteSnapshotTemp = snapshotsDir </> ".snapshot-incomplete"
      incompleteDigestTemp = snapshotsDir </> ".digest-incomplete"
      incompleteObjectTemp = repository </> "objects" </> ".incoming-incomplete"
  writeFile incompleteSidecar "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef\n"
  writeFile incompleteSnapshotTemp "unfinalized snapshot manifest"
  writeFile incompleteDigestTemp "unfinalized digest content"
  writeFile incompleteObjectTemp "unfinalized object content"

  -- listSnapshots must ignore all foreign/dot files and list only s1 cleanly
  listResult <- runExecutable ["list", "--repo", repository]
  assertEqual "list ignores incomplete snapshot dotfiles" (Right "s1\t1 files\t14 bytes\n") listResult

  -- verifyRepository must ignore all foreign/dot files and verify s1 cleanly
  verifyResult <- runExecutable ["verify", "--repo", repository]
  assertEqual "verify ignores incomplete snapshot dotfiles" (Right "verified 1 snapshots, 1 objects\n") verifyResult

  -- Now complete a clean backup of s2
  writeFile (source </> "b.txt") "second snapshot"
  backup2 <- runExecutable ["backup", source, "--repo", repository, "--name", "s2"]
  assertEqual "subsequent backup of s2 succeeds" (Right "snapshot s2: 2 files, 29 bytes\n") backup2

  listAfter <- runExecutable ["list", "--repo", repository]
  assertEqual "list reports both snapshots" (Right "s1\t1 files\t14 bytes\ns2\t2 files\t29 bytes\n") listAfter

  verifyAfter <- runExecutable ["verify", "--repo", repository]
  assertEqual "verify reports both snapshots" (Right "verified 2 snapshots, 2 objects\n") verifyAfter

testDigestSidecarAtomicStaging :: IO ()
testDigestSidecarAtomicStaging = withTemporaryDirectory "foldback-staging-test" $ \sandbox -> do
  let snapshotsDir = sandbox </> "snapshots"
      manifestPath = snapshotsDir </> "snap1"
      sidecarPath = manifestDigestPath manifestPath
      initialDigest = Digest "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      updatedDigest = Digest "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
  createDirectory snapshotsDir

  -- 1. writeManifestDigest creates and installs the sidecar
  writeManifestDigest manifestPath initialDigest
  initialContent <- readFile sidecarPath
  assertEqual "sidecar contains formatted initial digest" (unDigest initialDigest <> "\n") initialContent
  fileStatus1 <- Posix.getFileStatus sidecarPath
  let initialInode = Posix.fileID fileStatus1

  -- Verify no leftover staging temporary files
  entriesAfterInitial <- listDirectory snapshotsDir
  let stagingFiles = filter (\name -> ".digest-" `isPrefixOf` name) entriesAfterInitial
  assertEqual "no staging temp files remain after successful write" ([] :: [String]) stagingFiles

  -- 2. writeManifestDigest atomically updates an existing sidecar with a new inode
  writeManifestDigest manifestPath updatedDigest
  updatedContent <- readFile sidecarPath
  assertEqual "sidecar contains atomically updated digest" (unDigest updatedDigest <> "\n") updatedContent
  fileStatus2 <- Posix.getFileStatus sidecarPath
  let updatedInode = Posix.fileID fileStatus2
  assertBool "atomic staging via rename allocates a new inode" (initialInode /= updatedInode)

  entriesAfterUpdate <- listDirectory snapshotsDir
  assertEqual "no staging temp files remain after atomic update" ([] :: [String]) (filter (\name -> ".digest-" `isPrefixOf` name) entriesAfterUpdate)

testRejectsSymlinkTraversalOrderIndependent :: IO ()
testRejectsSymlinkTraversalOrderIndependent = do
  let dummyDigest = Digest (replicate 64 'a')
      linkEntry = SymbolicLink "link" "target"
      childFile = RegularFile "link/child" dummyDigest 10
      childDir = Directory "link/sub"
      siblingFile = RegularFile "link_sibling" dummyDigest 10
      siblingDir = Directory "link_other"

  -- 1. Sibling paths with symlinks must pass validation regardless of order
  validatePaths [linkEntry, siblingFile, siblingDir]
  validatePaths [siblingFile, linkEntry, siblingDir]
  validatePaths [siblingFile, siblingDir, linkEntry]

  -- 2. Child after symlink must fail with "path descends through a symlink: <path>"
  resultAfterFile <- try (validatePaths [linkEntry, childFile])
  case resultAfterFile of
    Left (e :: SomeException) ->
      assertBool "child file after symlink error message" ("path descends through a symlink: link/child" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when child file is after symlink, but it passed"

  -- 3. Child before symlink must fail with "path descends through a symlink: <path>"
  resultBeforeFile <- try (validatePaths [childFile, linkEntry])
  case resultBeforeFile of
    Left (e :: SomeException) ->
      assertBool "child file before symlink error message" ("path descends through a symlink: link/child" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when child file is before symlink, but it passed"

  -- 4. Child directory before symlink must fail with "path descends through a symlink: <path>"
  resultBeforeDir <- try (validatePaths [childDir, linkEntry])
  case resultBeforeDir of
    Left (e :: SomeException) ->
      assertBool "child dir before symlink error message" ("path descends through a symlink: link/sub" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when child dir is before symlink, but it passed"

  -- 5. Symlink descending through another symlink must fail regardless of order
  let nestedLink = SymbolicLink "link/nested" "target2"
  resultNestedAfter <- try (validatePaths [linkEntry, nestedLink])
  case resultNestedAfter of
    Left (e :: SomeException) ->
      assertBool "nested symlink after error message" ("path descends through a symlink: link/nested" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when nested symlink is after symlink, but it passed"

  resultNestedBefore <- try (validatePaths [nestedLink, linkEntry])
  case resultNestedBefore of
    Left (e :: SomeException) ->
      assertBool "nested symlink before error message" ("path descends through a symlink: link/nested" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when nested symlink is before symlink, but it passed"

  -- 6. End-to-end repository restore and verify reject out-of-order manifest entries upfront
  withTemporaryDirectory "foldback-order-independent-test" $ \sandbox -> do
    let source = sandbox </> "source"
        repository = sandbox </> "repository"
        restored = sandbox </> "restored"
    createDirectory source
    writeFile (source </> "dummy.txt") "content"
    _ <- runExecutable ["backup", source, "--repo", repository, "--name", "base"]

    let badSnapshot =
          Snapshot
            { snapshotFormat = 1
            , snapshotName = "bad"
            , snapshotCreatedAt = 1234567890
            , snapshotFileCount = 1
            , snapshotTotalBytes = 10
            , snapshotEntries =
                [ Directory "."
                , RegularFile "link/child" dummyDigest 10
                , SymbolicLink "link" "target"
                ]
            }
        manifestPath = repository </> "snapshots" </> "bad"
    writeSnapshot manifestPath badSnapshot
    writeManifestDigest manifestPath (snapshotDigest badSnapshot)

    restoreResult <- runExecutable ["restore", "bad", restored, "--repo", repository]
    assertLeftContaining "restore rejects manifest where child precedes symlink" "path descends through a symlink: link/child" restoreResult

    restoredExists <- doesPathExist restored
    assertBool "restore must fail upfront before creating the target directory" (not restoredExists)

    verifyResult <- runExecutable ["verify", "--repo", repository]
    assertLeftContaining "verify rejects manifest where child precedes symlink" "path descends through a symlink: link/child" verifyResult

testRejectsIncoherentDirectoryTrees :: IO ()
testRejectsIncoherentDirectoryTrees = do
  let dummyDigest = Digest (replicate 64 'a')

  -- 1. Nested file path without parent Directory entry must fail validation
  resultMissingParentFile <- try (validatePaths [RegularFile "docs/guide.txt" dummyDigest 10])
  case resultMissingParentFile of
    Left (e :: SomeException) ->
      assertBool "missing parent for file error" ("missing parent directory" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when file parent directory is missing, but it passed"

  -- 2. Nested directory path without parent Directory entry must fail validation
  resultMissingParentDir <- try (validatePaths [Directory "docs/sub"])
  case resultMissingParentDir of
    Left (e :: SomeException) ->
      assertBool "missing parent for dir error" ("missing parent directory" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when dir parent directory is missing, but it passed"

  -- 3. Out-of-order Directory entry appearing after its child must fail validation
  resultOutOfOrder <- try (validatePaths [Directory "docs/sub", Directory "docs"])
  case resultOutOfOrder of
    Left (e :: SomeException) ->
      assertBool "out of order directory error" ("missing parent directory" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when directory appears after child, but it passed"

  -- 4. RegularFile as an ancestor prefix of a Directory must fail validation (both orders)
  resultFilePrefixDir <- try (validatePaths [RegularFile "docs" dummyDigest 10, Directory "docs/sub"])
  case resultFilePrefixDir of
    Left (e :: SomeException) ->
      assertBool "regular file prefix of dir error" ("path descends through a regular file: docs/sub" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when regular file is ancestor of dir, but it passed"

  resultFilePrefixDirRev <- try (validatePaths [Directory "docs/sub", RegularFile "docs" dummyDigest 10])
  case resultFilePrefixDirRev of
    Left (e :: SomeException) ->
      assertBool "out of order regular file prefix of dir error" ("path descends through a regular file: docs/sub" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when dir precedes regular file ancestor, but it passed"

  -- 5. RegularFile as an ancestor prefix of another RegularFile must fail validation (both orders)
  resultFilePrefixFile <- try (validatePaths [RegularFile "docs" dummyDigest 10, RegularFile "docs/child.txt" dummyDigest 5])
  case resultFilePrefixFile of
    Left (e :: SomeException) ->
      assertBool "regular file prefix of file error" ("path descends through a regular file: docs/child.txt" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when regular file is ancestor of file, but it passed"

  resultFilePrefixFileRev <- try (validatePaths [RegularFile "docs/child.txt" dummyDigest 5, RegularFile "docs" dummyDigest 10])
  case resultFilePrefixFileRev of
    Left (e :: SomeException) ->
      assertBool "out of order regular file prefix of file error" ("path descends through a regular file: docs/child.txt" `isInfixOf` displayException e)
    Right () ->
      error "expected validation failure when file precedes regular file ancestor, but it passed"

  -- 6. End-to-end repository verify and restore reject incoherent directory trees upfront
  withTemporaryDirectory "foldback-incoherent-tree-test" $ \sandbox -> do
    let source = sandbox </> "source"
        repository = sandbox </> "repository"
        restored = sandbox </> "restored"
    createDirectory source
    writeFile (source </> "dummy.txt") "content"
    _ <- runExecutable ["backup", source, "--repo", repository, "--name", "base"]

    -- (a) Missing parent directory snapshot
    let missingParentSnap =
          Snapshot
            { snapshotFormat = 1
            , snapshotName = "missing-parent"
            , snapshotCreatedAt = 1234567890
            , snapshotFileCount = 1
            , snapshotTotalBytes = 10
            , snapshotEntries =
                [ Directory "."
                , RegularFile "docs/child" dummyDigest 10
                ]
            }
        missingParentPath = repository </> "snapshots" </> "missing-parent"
    writeSnapshot missingParentPath missingParentSnap
    writeManifestDigest missingParentPath (snapshotDigest missingParentSnap)

    verifyMissingParent <- runExecutable ["verify", "--repo", repository]
    assertLeftContaining "verify rejects manifest with missing parent directory" "missing parent directory: docs" verifyMissingParent

    restoreMissingParent <- runExecutable ["restore", "missing-parent", restored, "--repo", repository]
    assertLeftContaining "restore rejects manifest with missing parent directory" "missing parent directory: docs" restoreMissingParent

    restoredExists1 <- doesPathExist restored
    assertBool "restore must fail upfront before creating the target directory" (not restoredExists1)

    -- (b) Out-of-order directory snapshot
    let outOfOrderSnap =
          Snapshot
            { snapshotFormat = 1
            , snapshotName = "out-of-order"
            , snapshotCreatedAt = 1234567891
            , snapshotFileCount = 0
            , snapshotTotalBytes = 0
            , snapshotEntries =
                [ Directory "."
                , Directory "docs/sub"
                , Directory "docs"
                ]
            }
        outOfOrderPath = repository </> "snapshots" </> "out-of-order"
    writeSnapshot outOfOrderPath outOfOrderSnap
    writeManifestDigest outOfOrderPath (snapshotDigest outOfOrderSnap)

    verifyOutOfOrder <- runExecutable ["verify", "--repo", repository]
    assertLeftContaining "verify rejects manifest with out-of-order directory" "missing parent directory: docs" verifyOutOfOrder

    restoreOutOfOrder <- runExecutable ["restore", "out-of-order", restored, "--repo", repository]
    assertLeftContaining "restore rejects manifest with out-of-order directory" "missing parent directory: docs" restoreOutOfOrder

    restoredExists2 <- doesPathExist restored
    assertBool "restore out-of-order must fail upfront before creating target" (not restoredExists2)

    -- (c) File prefix collision snapshot
    let fileCollisionSnap =
          Snapshot
            { snapshotFormat = 1
            , snapshotName = "file-collision"
            , snapshotCreatedAt = 1234567892
            , snapshotFileCount = 1
            , snapshotTotalBytes = 10
            , snapshotEntries =
                [ Directory "."
                , RegularFile "docs" dummyDigest 10
                , Directory "docs/sub"
                ]
            }
        fileCollisionPath = repository </> "snapshots" </> "file-collision"
    writeSnapshot fileCollisionPath fileCollisionSnap
    writeManifestDigest fileCollisionPath (snapshotDigest fileCollisionSnap)

    verifyFileCollision <- runExecutable ["verify", "--repo", repository]
    assertLeftContaining "verify rejects manifest with file-prefix collision" "path descends through a regular file: docs/sub" verifyFileCollision

    restoreFileCollision <- runExecutable ["restore", "file-collision", restored, "--repo", repository]
    assertLeftContaining "restore rejects manifest with file-prefix collision" "path descends through a regular file: docs/sub" restoreFileCollision

    restoredExists3 <- doesPathExist restored
    assertBool "restore file-collision must fail upfront before creating target" (not restoredExists3)

testHelp :: IO ()
testHelp = do
  helpResult <- runExecutable ["--help"]
  assertRightContaining "help explains backup usage" "foldback backup SOURCE" helpResult

runExecutable :: [String] -> IO (Either String String)
runExecutable arguments = do
  (exitCode, standardOutput, standardError) <- readProcessWithExitCode "foldback" arguments ""
  pure $ case exitCode of
    ExitSuccess -> Right standardOutput
    ExitFailure _ -> Left standardError

runExecutableWithDescriptorLimit :: Int -> [String] -> IO (Either String String)
runExecutableWithDescriptorLimit limit arguments = do
  let script = "ulimit -n " <> show limit <> " && exec foldback \"$@\""
  (exitCode, standardOutput, standardError) <-
    readProcessWithExitCode "sh" (["-c", script, "foldback"] <> arguments) ""
  pure $ case exitCode of
    ExitSuccess -> Right standardOutput
    ExitFailure _ -> Left standardError

withTemporaryDirectory :: String -> (FilePath -> IO a) -> IO a
withTemporaryDirectory template = bracket acquire cleanup
 where
  acquire = do
    temporaryRoot <- getTemporaryDirectory
    -- The system temporary directory may itself sit behind a symlink (e.g.
    -- /var -> /private/var on macOS), which restore now refuses to traverse.
    -- Work from the canonical root so tests exercise ordinary hierarchies.
    canonicalRoot <- canonicalizePath temporaryRoot
    (path, handle) <- openTempFile canonicalRoot template
    hClose handle
    removeFile path
    createDirectoryIfMissing True path
    pure path

  cleanup path = do
    exists <- doesPathExist path
    if exists then removePathForcibly path else pure ()

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = error (label <> "\nexpected: " <> show expected <> "\n but got: " <> show actual)

assertBool :: String -> Bool -> IO ()
assertBool label condition = unless condition (error label)

assertLeftContaining :: String -> String -> Either String a -> IO ()
assertLeftContaining label expected result = case result of
  Left actual | expected `isInfixOf` actual -> pure ()
  _ -> error (label <> "\nexpected Left containing: " <> show expected)

assertRightContaining :: String -> String -> Either a String -> IO ()
assertRightContaining label expected result = case result of
  Right actual | expected `isInfixOf` actual -> pure ()
  _ -> error (label <> "\nexpected Right containing: " <> show expected)
