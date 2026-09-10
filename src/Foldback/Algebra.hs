module Foldback.Algebra
  ( Digest (..)
  , FsF (..)
  , Fix (..)
  , ManifestEntry (..)
  , Summary (..)
  , cata
  , deriveManifest
  ) where

import qualified Data.Set as Set

newtype Digest = Digest {unDigest :: String}
  deriving stock (Eq, Ord, Read, Show)

data FsF a
  = DirectoryF FilePath [a]
  | RegularFileF FilePath Digest Integer
  | SymbolicLinkF FilePath FilePath
  deriving stock (Eq, Read, Show, Functor)

newtype Fix f = Fix {unFix :: f (Fix f)}

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

cata :: Functor f => (f a -> a) -> Fix f -> a
cata algebra = algebra . fmap (cata algebra) . unFix

deriveManifest :: Fix FsF -> Summary
deriveManifest = cata summarize
 where
  summarize (DirectoryF path children) =
    Summary
      { entries = Directory path : concatMap entries children
      , fileCount = sum (map fileCount children)
      , totalBytes = sum (map totalBytes children)
      , objects = Set.unions (map objects children)
      }
  summarize (RegularFileF path digest size) =
    Summary
      { entries = [RegularFile path digest size]
      , fileCount = 1
      , totalBytes = size
      , objects = Set.singleton digest
      }
  summarize (SymbolicLinkF path target) =
    Summary
      { entries = [SymbolicLink path target]
      , fileCount = 0
      , totalBytes = 0
      , objects = Set.empty
      }
