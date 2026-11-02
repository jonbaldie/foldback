module Foldback.TreeScanner
  ( scanSourceTree
  ) where

import Control.Monad (foldM)
import Data.List (sort)
import qualified Data.Set as Set
import Foldback.Algebra (Digest, ManifestEntry (..), Summary (..))
import System.Directory (listDirectory)
import System.FilePath ((</>))
import qualified System.Posix.Files as Posix

scanSourceTree :: FilePath -> (FilePath -> IO (Digest, Integer)) -> IO Summary
scanSourceTree source ingest = do
  summary <- scan "." (Summary [] 0 0 Set.empty)
  pure summary {entries = reverse (entries summary)}
 where
  scan relative summary = do
    let absolute = if relative == "." then source else source </> relative
    status <- Posix.getSymbolicLinkStatus absolute
    if Posix.isSymbolicLink status
      then do
        target <- Posix.readSymbolicLink absolute
        pure summary {entries = SymbolicLink relative target : entries summary}
      else if Posix.isDirectory status
        then do
          names <- sort <$> listDirectory absolute
          let withDirectory = summary {entries = Directory relative : entries summary}
          foldM (\acc name -> scan (childPath relative name) acc) withDirectory names
        else if Posix.isRegularFile status
          then do
            (digest, size) <- ingest absolute
            let !count = fileCount summary + 1
                !bytes = totalBytes summary + size
                !digests = Set.insert digest (objects summary)
            pure summary
              { entries = RegularFile relative digest size : entries summary
              , fileCount = count
              , totalBytes = bytes
              , objects = digests
              }
          else ioError (userError ("unsupported filesystem entry: " <> absolute))

  childPath "." child = child
  childPath parent child = parent </> child
