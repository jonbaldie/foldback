module Foldback.Repository
  ( BackupReceipt (..)
  , SnapshotInfo (..)
  , Verification (..)
  , backup
  , listSnapshots
  , restore
  , verifyRepository
  ) where

import Control.Exception (bracket)
import Control.Monad (foldM, unless, void, when)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as ByteString
import Data.Char (isAlphaNum, isDigit, isHexDigit, isLower)
import Data.List (isPrefixOf, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Word (Word8)
import Foldback.Algebra
import Numeric (showHex)
import System.Directory
  ( canonicalizePath
  , copyFile
  , createDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , doesPathExist
  , getFileSize
  , listDirectory
  , makeAbsolute
  , removeFile
  , renameFile
  )
import System.FilePath
  ( addTrailingPathSeparator
  , dropTrailingPathSeparator
  , isAbsolute
  , normalise
  , splitDirectories
  , takeDirectory
  , (</>)
  )
import System.IO
  ( Handle
  , IOMode (ReadMode)
  , hClose
  , openBinaryTempFile
  , withBinaryFile
  )
import System.IO.Error (tryIOError)
import qualified System.Posix.Files as Posix
import Text.Read (readMaybe)

data BackupReceipt = BackupReceipt
  { receiptName :: String
  , receiptFileCount :: Int
  , receiptTotalBytes :: Integer
  }
  deriving stock (Eq, Show)

data SnapshotInfo = SnapshotInfo
  { infoName :: String
  , infoFileCount :: Int
  , infoTotalBytes :: Integer
  }
  deriving stock (Eq, Show)

data Verification = Verification
  { verifiedSnapshots :: Int
  , verifiedObjects :: Int
  }
  deriving stock (Eq, Show)

data Snapshot = Snapshot
  { snapshotFormat :: Int
  , snapshotName :: String
  , snapshotCreatedAt :: Integer
  , snapshotEntries :: [ManifestEntry]
  , snapshotFileCount :: Int
  , snapshotTotalBytes :: Integer
  }
  deriving stock (Eq, Read, Show)

backup :: FilePath -> Maybe String -> FilePath -> IO BackupReceipt
backup repository requestedName unnormalisedSource = do
  -- A trailing separator resolves the final path component, so lstat would
  -- report the link's target and the symlink check below would pass. Drop it
  -- before inspecting the path; real directories with a slash are unaffected.
  let source = dropTrailingPathSeparator unnormalisedSource
  sourceExists <- doesDirectoryExist source
  unless sourceExists (ioError (userError ("source is not a directory: " <> source)))
  sourceStatus <- Posix.getSymbolicLinkStatus source
  when (Posix.isSymbolicLink sourceStatus) (ioError (userError ("source is not a directory: " <> source)))
  ensureDisjoint "repository must be outside the source tree" source repository
  initializeRepository repository
  ensureRepository repository
  name <- maybe generatedSnapshotName pure requestedName
  validateCreatedSnapshotName name
  let snapshotPath = repository </> "snapshots" </> name
  collision <- doesPathExist snapshotPath
  when collision (ioError (userError ("snapshot already exists: " <> name)))
  tree <- scanTree repository source "."
  let summary = deriveManifest tree
  createdAt <- floor <$> getPOSIXTime
  let snapshot =
        Snapshot
          { snapshotFormat = 1
          , snapshotName = name
          , snapshotCreatedAt = createdAt
          , snapshotEntries = entries summary
          , snapshotFileCount = fileCount summary
          , snapshotTotalBytes = totalBytes summary
          }
  writeSnapshot snapshotPath snapshot
  writeManifestDigest snapshotPath
  pure
    BackupReceipt
      { receiptName = name
      , receiptFileCount = fileCount summary
      , receiptTotalBytes = totalBytes summary
      }

restore :: FilePath -> String -> FilePath -> IO ()
restore repository name target = do
  validateSnapshotName name
  ensureRepository repository
  ensureDisjoint "restore target must be outside the repository" repository target
  snapshot <- readNamedSnapshot repository name
  validateSnapshot snapshot
  prepareTarget target
  mapM_ (restoreEntry repository target) (snapshotEntries snapshot)

listSnapshots :: FilePath -> IO [SnapshotInfo]
listSnapshots repository = do
  ensureRepository repository
  names <- sort . filter (not . isForeignArtifact) <$> listDirectory (repository </> "snapshots")
  mapM loadInfo names
 where
  loadInfo name = do
    validateSnapshotName name
    snapshot <- readNamedSnapshot repository name
    validateSnapshot snapshot
    pure
      SnapshotInfo
        { infoName = name
        , infoFileCount = snapshotFileCount snapshot
        , infoTotalBytes = snapshotTotalBytes snapshot
        }

verifyRepository :: FilePath -> IO Verification
verifyRepository repository = do
  snapshots <- loadSnapshots
  objectNames <-
    sort . filter (not . isForeignArtifact) <$> listDirectory (repository </> "objects")
  mapM_ verifyObjectName objectNames
  let expectedSizeSets = foldMap referencedObjects snapshots
  expectedObjects <- mapM uniqueExpectedSize (Map.toList expectedSizeSets)
  mapM_ (verifyReference objectNames) expectedObjects
  pure
    Verification
      { verifiedSnapshots = length snapshots
      , verifiedObjects = length objectNames
      }
 where
  loadSnapshots = do
    infos <- listSnapshots repository
    mapM (readNamedSnapshot repository . infoName) infos

  referencedObjects snapshot =
    Map.fromListWith Set.union
      [ (unDigest digest, Set.singleton size)
      | RegularFile _ digest size <- snapshotEntries snapshot
      ]

  uniqueExpectedSize (name, sizes) = case Set.toList sizes of
    [size] -> pure (name, size)
    _ -> ioError (userError ("object has conflicting sizes: " <> name))

  verifyObjectName name = do
    unless (validDigest name) (ioError (userError ("invalid object name: " <> name)))
    let path = repository </> "objects" </> name
    isFile <- doesFileExist path
    unless isFile (ioError (userError ("object is not a regular file: " <> name)))
    actual <- hashFile path
    unless (unDigest actual == name) (ioError (userError ("corrupt object: " <> name)))

  verifyReference objectNames (name, expectedSize) = do
    unless (name `elem` objectNames) (ioError (userError ("missing object: " <> name)))
    actualSize <- getFileSize (repository </> "objects" </> name)
    unless (actualSize == expectedSize) (ioError (userError ("wrong object size: " <> name)))

initializeRepository :: FilePath -> IO ()
initializeRepository repository = do
  createDirectoryIfMissing True (repository </> "objects")
  createDirectoryIfMissing True (repository </> "snapshots")
  writeFileIfMissing (repository </> "FORMAT") "foldback 1\n"

ensureRepository :: FilePath -> IO ()
ensureRepository repository = do
  formatExists <- doesFileExist (repository </> "FORMAT")
  unless formatExists (ioError (userError ("not a foldback repository: " <> repository)))
  format <- readFile (repository </> "FORMAT")
  unless (format == "foldback 1\n") (ioError (userError "unsupported repository format"))

writeFileIfMissing :: FilePath -> String -> IO ()
writeFileIfMissing path content = do
  exists <- doesPathExist path
  unless exists (writeFile path content)

generatedSnapshotName :: IO String
generatedSnapshotName = formatTime defaultTimeLocale "%Y%m%dT%H%M%S%qZ" <$> getCurrentTime

validateSnapshotName :: String -> IO ()
validateSnapshotName name =
  unless valid (ioError (userError "snapshot names may contain only letters, digits, '.', '_' and '-'"))
 where
  valid =
    not (null name)
      && name /= "."
      && name /= ".."
      && all (\character -> isAlphaNum character || character `elem` ("._-" :: String)) name

-- Names are refused at creation time when no command could ever address them:
-- the argument parser treats a leading dash as an option, so such a snapshot
-- would be listed and verified but never restorable. Read paths keep accepting
-- the looser charset so repositories from before this check stay navigable.
validateCreatedSnapshotName :: String -> IO ()
validateCreatedSnapshotName name = do
  validateSnapshotName name
  when
    (take 1 name `elem` ["-", "."])
    (ioError (userError "snapshot names may not begin with '-' or '.'"))

-- Dotfiles and staging leftovers (".snapshot-", ".incoming-") in the live
-- directories are not repository artifacts; directory scans ignore them.
isForeignArtifact :: String -> Bool
isForeignArtifact name = take 1 name == "."

scanTree :: FilePath -> FilePath -> FilePath -> IO (Fix FsF)
scanTree repository source relative = do
  let absolute = if relative == "." then source else source </> relative
  status <- Posix.getSymbolicLinkStatus absolute
  if Posix.isSymbolicLink status
    then Fix . SymbolicLinkF relative <$> Posix.readSymbolicLink absolute
    else
      if Posix.isDirectory status
        then do
          childNames <- sort <$> listDirectory absolute
          children <- mapM (scanTree repository source . childPath relative) childNames
          pure (Fix (DirectoryF relative children))
        else
          if Posix.isRegularFile status
            then do
              (digest, size) <- storeObject repository absolute
              pure (Fix (RegularFileF relative digest size))
            else ioError (userError ("unsupported filesystem entry: " <> absolute))

childPath :: FilePath -> FilePath -> FilePath
childPath "." child = child
childPath parent child = parent </> child

storeObject :: FilePath -> FilePath -> IO (Digest, Integer)
storeObject repository source = do
  let temporaryDirectory = repository </> "objects"
  bracket
    (openBinaryTempFile temporaryDirectory ".incoming-")
    cleanupTemporaryFile
    (writeAndInstall temporaryDirectory)
 where
  writeAndInstall objectDirectory (temporaryPath, output) = do
    (context, size) <- withBinaryFile source ReadMode (copyAndHash output SHA256.init 0)
    hClose output
    let digest = Digest (hexEncode (SHA256.finalize context))
        destination = objectDirectory </> unDigest digest
    exists <- doesFileExist destination
    if exists
      then do
        existingDigest <- hashFile destination
        unless (existingDigest == digest) (ioError (userError ("corrupt object: " <> destination)))
        removeFile temporaryPath
      else renameFile temporaryPath destination
    pure (digest, size)

copyAndHash :: Handle -> SHA256.Ctx -> Integer -> Handle -> IO (SHA256.Ctx, Integer)
copyAndHash output context size input = do
  chunk <- ByteString.hGetSome input (64 * 1024)
  if ByteString.null chunk
    then pure (context, size)
    else do
      ByteString.hPut output chunk
      copyAndHash output (SHA256.update context chunk) (size + fromIntegral (ByteString.length chunk)) input

hashFile :: FilePath -> IO Digest
hashFile path = do
  context <- withBinaryFile path ReadMode (hashChunks SHA256.init)
  pure (Digest (hexEncode (SHA256.finalize context)))
 where
  hashChunks context input = do
    chunk <- ByteString.hGetSome input (64 * 1024)
    if ByteString.null chunk
      then pure context
      else hashChunks (SHA256.update context chunk) input

hexEncode :: ByteString.ByteString -> String
hexEncode = concatMap hexByte . ByteString.unpack
 where
  hexByte :: Word8 -> String
  hexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

writeSnapshot :: FilePath -> Snapshot -> IO ()
writeSnapshot destination snapshot =
  bracket
    (openBinaryTempFile (takeDirectory destination) ".snapshot-")
    cleanupTemporaryFile
    (\(temporaryPath, handle) -> do
      ByteString.hPut handle (ByteString.pack (map (fromIntegral . fromEnum) (show snapshot <> "\n")))
      hClose handle
      renameFile temporaryPath destination
    )

-- A manifest damaged in a well-formed way (e.g. a renamed entry path) passes
-- every structural check, so its serialized bytes are digested at commit time
-- and re-checked whenever the record is read back. The sidecar lives beside
-- the record under a dot name, which directory scans ignore as a non-artifact.
writeManifestDigest :: FilePath -> IO ()
writeManifestDigest destination = do
  digest <- hashFile destination
  let sidecarPath = manifestDigestPath destination
  ByteString.writeFile sidecarPath (ByteString.pack (map (fromIntegral . fromEnum) (unDigest digest <> "\n")))

manifestDigestPath :: FilePath -> FilePath
manifestDigestPath manifestPath = takeDirectory manifestPath </> ("." <> takeName manifestPath <> ".digest")
 where
  takeName = reverse . takeWhile (/= '/') . reverse

readManifestDigest :: FilePath -> IO Digest
readManifestDigest manifestPath = do
  exists <- doesFileExist sidecarPath
  unless exists (ioError (userError ("corrupt snapshot manifest: no integrity digest for " <> takeName manifestPath)))
  content <- readFile sidecarPath
  let digest = takeWhile (/= '\n') content
  unless (validDigest digest) (ioError (userError ("corrupt snapshot manifest: " <> takeName manifestPath)))
  pure (Digest digest)
 where
  sidecarPath = manifestDigestPath manifestPath
  takeName = reverse . takeWhile (/= '/') . reverse

cleanupTemporaryFile :: (FilePath, Handle) -> IO ()
cleanupTemporaryFile (path, handle) = do
  void (tryIOError (hClose handle))
  exists <- doesFileExist path
  when exists (removeFile path)

readSnapshot :: FilePath -> IO Snapshot
readSnapshot path = do
  exists <- doesFileExist path
  unless exists (ioError (userError ("snapshot does not exist: " <> takeName path)))
  content <- readFile path
  case readMaybe content of
    Nothing -> ioError (userError ("invalid snapshot: " <> path))
    Just snapshot -> pure snapshot
 where
  takeName = reverse . takeWhile (/= '/') . reverse

readNamedSnapshot :: FilePath -> String -> IO Snapshot
readNamedSnapshot repository name = do
  let manifestPath = repository </> "snapshots" </> name
  snapshot <- readSnapshot manifestPath
  unless (snapshotName snapshot == name) (ioError (userError ("snapshot name does not match filename: " <> name)))
  expectedDigest <- readManifestDigest manifestPath
  actualDigest <- hashFile manifestPath
  unless (actualDigest == expectedDigest) (ioError (userError ("corrupt snapshot manifest: " <> name)))
  pure snapshot

validateSnapshot :: Snapshot -> IO ()
validateSnapshot snapshot = do
  unless (snapshotFormat snapshot == 1) (ioError (userError "unsupported snapshot format"))
  unless (snapshotName snapshot /= "") (ioError (userError "invalid empty snapshot name"))
  case snapshotEntries snapshot of
    Directory "." : rest -> do
      validatePaths rest
      let regularFiles = [(digest, size) | RegularFile _ digest size <- rest]
      unless (all (validDigest . unDigest . fst) regularFiles) (ioError (userError "snapshot contains an invalid digest"))
      unless (all ((>= 0) . snd) regularFiles) (ioError (userError "snapshot contains a negative file size"))
      unless (snapshotFileCount snapshot == length regularFiles) (ioError (userError "snapshot file count is inconsistent"))
      unless (snapshotTotalBytes snapshot == sum (map snd regularFiles)) (ioError (userError "snapshot byte count is inconsistent"))
    _ -> ioError (userError "snapshot must begin with its root directory")

validDigest :: String -> Bool
validDigest digest =
  length digest == 64
    && all (\character -> isDigit character || (isHexDigit character && isLower character)) digest

validatePaths :: [ManifestEntry] -> IO ()
validatePaths manifestEntries = void (foldM validate (Set.empty, []) manifestEntries)
 where
  validate (seen, symlinks) entry = do
    let path = entryPath entry
    unless (safeRelativePath path) (ioError (userError ("unsafe snapshot path: " <> path)))
    when (Set.member path seen) (ioError (userError ("duplicate snapshot path: " <> path)))
    when (any (`isPathPrefixOf` path) symlinks) (ioError (userError ("path descends through a symlink: " <> path)))
    let nextSymlinks = case entry of
          SymbolicLink {} -> path : symlinks
          _ -> symlinks
    pure (Set.insert path seen, nextSymlinks)

entryPath :: ManifestEntry -> FilePath
entryPath (Directory path) = path
entryPath (RegularFile path _ _) = path
entryPath (SymbolicLink path _) = path

safeRelativePath :: FilePath -> Bool
safeRelativePath path =
  path /= "."
    && not (null path)
    && not (isAbsolute path)
    && normalise path == path
    && all (\part -> part /= ".." && part /= ".") (splitDirectories path)

isPathPrefixOf :: FilePath -> FilePath -> Bool
isPathPrefixOf parent child = addTrailingPathSeparator parent `isPrefixOf` child

prepareTarget :: FilePath -> IO ()
prepareTarget target = do
  -- An empty target passes every following check vacuously and makes each
  -- restored entry resolve against the working directory, silently
  -- overwriting matching files there.
  when (null target) (ioError (userError "restore target cannot be empty"))
  -- Inspect the node itself, not what a symlink would resolve to: a dangling
  -- symlink fails a following stat, and a link to a directory is not a
  -- directory this command may write through.
  targetStatus <- tryIOError (Posix.getSymbolicLinkStatus target)
  case targetStatus of
    Right status | Posix.isDirectory status -> do
      contents <- listDirectory target
      unless (null contents) (ioError (userError ("restore target is not empty: " <> target)))
    Right _ -> ioError (userError ("restore target is not a directory: " <> target))
    Left _ -> createDirectoryIfMissing True target

restoreEntry :: FilePath -> FilePath -> ManifestEntry -> IO ()
restoreEntry _ _ (Directory ".") = pure ()
restoreEntry _ target (Directory path) = createDirectory (target </> path)
restoreEntry repository target (RegularFile path expectedDigest expectedSize) = do
  let object = repository </> "objects" </> unDigest expectedDigest
  exists <- doesFileExist object
  unless exists (ioError (userError ("missing object: " <> unDigest expectedDigest)))
  actualDigest <- hashFile object
  unless (actualDigest == expectedDigest) (ioError (userError ("corrupt object: " <> unDigest expectedDigest)))
  actualSize <- getFileSize object
  unless (actualSize == expectedSize) (ioError (userError ("wrong object size: " <> unDigest expectedDigest)))
  createDirectoryIfMissing True (takeDirectory (target </> path))
  copyFile object (target </> path)
restoreEntry _ target (SymbolicLink path linkTarget) = do
  createDirectoryIfMissing True (takeDirectory (target </> path))
  Posix.createSymbolicLink linkTarget (target </> path)

ensureDisjoint :: String -> FilePath -> FilePath -> IO ()
ensureDisjoint problem first second = do
  canonicalFirst <- canonicalizeLoose first
  canonicalSecond <- canonicalizeLoose second
  when
    ( canonicalFirst == canonicalSecond
        || isPathPrefixOf canonicalFirst canonicalSecond
        || isPathPrefixOf canonicalSecond canonicalFirst
    )
    (ioError (userError problem))

canonicalizeLoose :: FilePath -> IO FilePath
canonicalizeLoose path = do
  absolute <- makeAbsolute path
  exists <- doesPathExist absolute
  if exists
    then normalise <$> canonicalizePath absolute
    else do
      canonicalParent <- canonicalizePath (takeDirectory absolute)
      pure (normalise (canonicalParent </> last (splitDirectories absolute)))
