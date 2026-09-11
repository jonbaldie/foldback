module Main (main) where

import Control.Exception (SomeException, bracket, displayException, try)
import Control.Monad (forM_, unless)
import Foldback.Algebra
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.ByteString as BS
import qualified Data.Set as Set
import System.Directory
  ( createDirectory
  , createDirectoryLink
  , createDirectoryIfMissing
  , createFileLink
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
  , ("detect corruption", testDetectsCorruption)
  , ("reject symlink source roots", testRejectsSymlinkSourceRoot)
  , ("reject optionlike snapshot name", testRejectsOptionlikeSnapshotName)
  , ("reject symlink restore targets", testRejectsSymlinkRestoreTarget)
  , ("reject empty restore target", testRejectsEmptyRestoreTarget)
  , ("tolerate foreign metadata files", testToleratesForeignMetadataFiles)
  , ("detect manifest tampering", testDetectsManifestTampering)
  , ("bounds streaming memory", testBoundsStreamingMemory)
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

  createFileLink (sandbox </> "empty-target-directory") (sandbox </> "valid-target")
  linkedResult <- runExecutable ["restore", "s1", sandbox </> "valid-target", "--repo", repository]
  assertLeftContaining
    "restore refuses a symlink target pointing at a real directory"
    "restore target is not a directory:"
    linkedResult
  contents <- listDirectory (sandbox </> "empty-target-directory")
  assertEqual "nothing was written through the refused symlink target" (0 :: Int) (length contents)

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

withTemporaryDirectory :: String -> (FilePath -> IO a) -> IO a
withTemporaryDirectory template = bracket acquire cleanup
 where
  acquire = do
    temporaryRoot <- getTemporaryDirectory
    (path, handle) <- openTempFile temporaryRoot template
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
