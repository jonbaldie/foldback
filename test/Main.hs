module Main (main) where

import Control.Exception (SomeException, bracket, displayException, try)
import Foldback.Algebra
import Data.List (isInfixOf)
import qualified Data.Set as Set
import System.Directory
  ( createDirectory
  , createDirectoryLink
  , createDirectoryIfMissing
  , createFileLink
  , doesPathExist
  , getSymbolicLinkTarget
  , getTemporaryDirectory
  , listDirectory
  , removeFile
  , removePathForcibly
  )
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
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

assertLeftContaining :: String -> String -> Either String a -> IO ()
assertLeftContaining label expected result = case result of
  Left actual | expected `isInfixOf` actual -> pure ()
  _ -> error (label <> "\nexpected Left containing: " <> show expected)

assertRightContaining :: String -> String -> Either a String -> IO ()
assertRightContaining label expected result = case result of
  Right actual | expected `isInfixOf` actual -> pure ()
  _ -> error (label <> "\nexpected Right containing: " <> show expected)
