module Foldback.Error (FoldbackError (..), renderError) where

import Control.Exception (Exception (displayException))

data FoldbackError
  = EmptyRepositoryPath
  | NotARepository FilePath
  | UnsupportedRepositoryFormat
  | EmptySource
  | SourceNotDirectory FilePath
  | RepositoryOverlapsSource
  | SnapshotAlreadyExists String
  | InvalidSnapshotName
  | SnapshotNameStartsWithDashOrDot
  | EmptyRestoreTarget
  | RestoreTargetOverlapsRepository
  | RestoreTargetNotEmpty FilePath
  | RestoreTargetNotDirectory FilePath
  | UnsupportedFilesystemEntry FilePath
  | ConflictingObjectSizes String
  | InvalidObjectName String
  | ObjectNotRegularFile String
  | CorruptObject String
  | MissingObject String
  | WrongObjectSize String
  | MissingManifestDigest String
  | CorruptSnapshotManifest String
  | SnapshotDoesNotExist String
  | InvalidSnapshot FilePath
  | SnapshotNameMismatch String
  | UnsupportedSnapshotFormat
  | EmptySnapshotName
  | SnapshotInvalidDigest
  | SnapshotNegativeFileSize
  | SnapshotFileCountInconsistent
  | SnapshotByteCountInconsistent
  | SnapshotMissingRootDirectory
  | UnsafeSnapshotPath FilePath
  | DuplicateSnapshotPath FilePath
  | SnapshotPathThroughSymlink FilePath
  | SnapshotPathThroughRegularFile FilePath
  | SnapshotMissingParentDirectory FilePath
  deriving stock (Eq, Show)

renderError :: FoldbackError -> String
renderError problem = case problem of
  EmptyRepositoryPath -> "repository path cannot be empty"
  NotARepository p -> "not a foldback repository: " <> p
  UnsupportedRepositoryFormat -> "unsupported repository format"
  EmptySource -> "source cannot be empty"
  SourceNotDirectory p -> "source is not a directory: " <> p
  RepositoryOverlapsSource -> "repository must be outside the source tree"
  SnapshotAlreadyExists p -> "snapshot already exists: " <> p
  InvalidSnapshotName -> "snapshot names may contain only letters, digits, '.', '_' and '-'"
  SnapshotNameStartsWithDashOrDot -> "snapshot names may not begin with '-' or '.'"
  EmptyRestoreTarget -> "restore target cannot be empty"
  RestoreTargetOverlapsRepository -> "restore target must be outside the repository"
  RestoreTargetNotEmpty p -> "restore target is not empty: " <> p
  RestoreTargetNotDirectory p -> "restore target is not a directory: " <> p
  UnsupportedFilesystemEntry p -> "unsupported filesystem entry: " <> p
  ConflictingObjectSizes p -> "object has conflicting sizes: " <> p
  InvalidObjectName p -> "invalid object name: " <> p
  ObjectNotRegularFile p -> "object is not a regular file: " <> p
  CorruptObject p -> "corrupt object: " <> p
  MissingObject p -> "missing object: " <> p
  WrongObjectSize p -> "wrong object size: " <> p
  MissingManifestDigest p -> "corrupt snapshot manifest: no integrity digest for " <> p
  CorruptSnapshotManifest p -> "corrupt snapshot manifest: " <> p
  SnapshotDoesNotExist p -> "snapshot does not exist: " <> p
  InvalidSnapshot p -> "invalid snapshot: " <> p
  SnapshotNameMismatch p -> "snapshot name does not match filename: " <> p
  UnsupportedSnapshotFormat -> "unsupported snapshot format"
  EmptySnapshotName -> "invalid empty snapshot name"
  SnapshotInvalidDigest -> "snapshot contains an invalid digest"
  SnapshotNegativeFileSize -> "snapshot contains a negative file size"
  SnapshotFileCountInconsistent -> "snapshot file count is inconsistent"
  SnapshotByteCountInconsistent -> "snapshot byte count is inconsistent"
  SnapshotMissingRootDirectory -> "snapshot must begin with its root directory"
  UnsafeSnapshotPath p -> "unsafe snapshot path: " <> p
  DuplicateSnapshotPath p -> "duplicate snapshot path: " <> p
  SnapshotPathThroughSymlink p -> "path descends through a symlink: " <> p
  SnapshotPathThroughRegularFile p -> "path descends through a regular file: " <> p
  SnapshotMissingParentDirectory p -> "missing parent directory: " <> p

instance Exception FoldbackError where
  displayException = renderError
