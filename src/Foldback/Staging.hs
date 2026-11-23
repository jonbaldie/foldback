-- The one place that decides how repository files are staged before they are
-- published, and therefore which names an interrupted writer can leave behind.
-- Writers and directory discovery both read the 'Staging' list below, so a new
-- or renamed template cannot drift away from leftover recognition (#30).
module Foldback.Staging
  ( Staging (..)
  , isStagingLeftover
  , withStagedFile
  ) where

import Control.Exception (bracket)
import Control.Monad (void, when)
import Data.Char (isDigit)
import Data.List (isPrefixOf)
import System.Directory (doesFileExist, removeFile)
import System.IO (Handle, hClose, openBinaryTempFile)
import System.IO.Error (tryIOError)

data Staging
  = StagingFormat
  | StagingObject
  | StagingSnapshot
  | StagingDigest
  deriving stock (Bounded, Enum, Eq, Show)

-- Changing a template changes the names left by interrupted writers; existing
-- repositories may still hold leftovers under the old name.
stagingTemplate :: Staging -> String
stagingTemplate StagingFormat = ".format-"
stagingTemplate StagingObject = ".incoming-"
stagingTemplate StagingSnapshot = ".snapshot-"
stagingTemplate StagingDigest = ".digest-"

-- Stage content into a temporary file in the given directory, close it, and
-- hand its path to the publish step (rename, hard link, or discard). The
-- temporary file is removed afterwards whether publishing succeeded or not;
-- only a killed process leaves it behind.
withStagedFile :: Staging -> FilePath -> (Handle -> IO a) -> (FilePath -> a -> IO b) -> IO b
withStagedFile staging directory write publish =
  bracket
    (openBinaryTempFile directory (stagingTemplate staging))
    cleanupTemporaryFile
    ( \(temporaryPath, handle) -> do
        written <- write handle
        hClose handle
        publish temporaryPath written
    )

cleanupTemporaryFile :: (FilePath, Handle) -> IO ()
cleanupTemporaryFile (path, handle) = do
  void (tryIOError (hClose handle))
  exists <- doesFileExist path
  when exists (removeFile path)

-- True for the names 'withStagedFile' can leave behind after a crash. On
-- POSIX, openBinaryTempFile puts a pid/counter pair before the template, so
-- ".incoming-" arrives as e.g. "123-0.incoming-" rather than as a dotfile.
-- Committed snapshots may legitimately share this shape, so discovery treats
-- a match as a candidate leftover, not proof of one.
isStagingLeftover :: String -> Bool
isStagingLeftover name =
  case span isDigit name of
    (pid, '-' : rest)
      | not (null pid) ->
          case span isDigit rest of
            (counter, template@('.' : _))
              | not (null counter) ->
                  any ((`isPrefixOf` template) . stagingTemplate) [minBound .. maxBound]
            _ -> False
    _ -> False
