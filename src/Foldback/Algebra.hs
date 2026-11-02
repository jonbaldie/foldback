module Foldback.Algebra
  ( Digest (..)
  , ManifestEntry (..)
  , Summary (..)
  ) where

import qualified Data.Set as Set

newtype Digest = Digest {unDigest :: String}
  deriving stock (Eq, Ord, Read, Show)

data ManifestEntry
  = Directory FilePath
  | RegularFile FilePath Digest Integer
  | SymbolicLink FilePath FilePath
  deriving stock (Eq, Read, Show)

data Summary = Summary
  { entries :: [ManifestEntry]
  , fileCount :: Int
  , totalBytes :: Integer
  , objects :: Set.Set Digest
  }
  deriving stock (Eq, Read, Show)
