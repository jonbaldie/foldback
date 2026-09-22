module Properties
  ( propertyTests
  ) where

import Control.Exception (IOException, bracket, displayException, try)
import Control.Monad (unless, void)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as ByteString
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Set as Set
import Data.Word (Word8)
import Foldback.Algebra
import Foldback.Repository
  ( Snapshot (..)
  , loadCommittedSnapshot
  , manifestDigestPath
  , snapshotDigest
  , writeManifestDigest
  , writeSnapshot
  )
import System.Directory
  ( createDirectory
  , getTemporaryDirectory
  , removeFile
  , removePathForcibly
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.QuickCheck
import Text.Read (readMaybe)

data Rose
  = RDir FilePath [Rose]
  | RFile FilePath Digest Integer
  | RLink FilePath FilePath
  deriving stock (Eq, Show)

data Piece
  = PDir String [Piece]
  | PFile String Integer String
  | PLink String String
  deriving stock (Eq, Show)

data Corruption
  = BadFormat
  | EmptyName
  | MissingRoot
  | BadCount
  | BadBytes
  | NegativeSize
  | BadDigest
  | DuplicatePath
  | UnsafeDotDot
  | UnsafeAbsolute
  | MissingParent
  | DescendFile
  | DescendSymlink
  deriving stock (Bounded, Enum, Eq, Show)

propertyTests :: IO ()
propertyTests =
  mapM_
    (uncurry runProperty)
    [ ("prop_literalManifestExpectations", prop_literalManifestExpectations)
    , ("prop_manifestMatchesTally", prop_manifestMatchesTally)
    , ("prop_snapshotShowRead", prop_snapshotShowRead)
    , ("prop_snapshotDigestMatchesBytes", prop_snapshotDigestMatchesBytes)
    , ("prop_fixtureDigest", prop_fixtureDigest)
    , ("prop_manifestDigestPath", prop_manifestDigestPath)
    , ("prop_writeSnapshotMatchesShownBytes", prop_writeSnapshotMatchesShownBytes)
    , ("prop_acceptsCoherentSnapshot", prop_acceptsCoherentSnapshot)
    , ("prop_rejectsCorruption", prop_rejectsCorruption)
    ]

runProperty :: String -> Property -> IO ()
runProperty name testProperty = do
  result <-
    quickCheckWithResult
      stdArgs
        { maxSuccess = 100
        , maxSize = 25
        , chatty = False
        }
      testProperty
  unless (isSuccess result) (ioError (userError (name <> "\n" <> output result)))

prop_literalManifestExpectations :: Property
prop_literalManifestExpectations =
  conjoin
    [ counterexample "empty root directory" $
        property $
          deriveManifest (Fix (DirectoryF "." []))
            == Summary
              { entries = [Directory "."]
              , fileCount = 0
              , totalBytes = 0
              , objects = Set.empty
              }
    , counterexample "two files sharing an object" $
        property $
          deriveManifest
            ( Fix
                ( DirectoryF
                    "."
                    [ Fix (RegularFileF "a" (Digest "d") 3)
                    , Fix (RegularFileF "b" (Digest "d") 4)
                    ]
                )
            )
            == Summary
              { entries =
                  [ Directory "."
                  , RegularFile "a" (Digest "d") 3
                  , RegularFile "b" (Digest "d") 4
                  ]
              , fileCount = 2
              , totalBytes = 7
              , objects = Set.singleton (Digest "d")
              }
    , counterexample "negative file size remains in the algebra" $
        property $
          deriveManifest (Fix (RegularFileF "a" (Digest "d") (-5)))
            == Summary
              { entries = [RegularFile "a" (Digest "d") (-5)]
              , fileCount = 1
              , totalBytes = -5
              , objects = Set.singleton (Digest "d")
              }
    ]

prop_manifestMatchesTally :: Property
prop_manifestMatchesTally =
  forAllShrink genRose shrinkRose $ \rose ->
    deriveManifest (toFix rose) === tallyRose rose

genRose :: Gen Rose
genRose = sized (genRoseAt . min 4)

genRoseAt :: Int -> Gen Rose
genRoseAt depth
  | depth <= 0 = oneof [genEmptyDirectory, genRoseFile, genRoseLink]
  | otherwise =
      frequency
        [ (3, genRoseDirectory depth)
        , (3, genRoseFile)
        , (2, genRoseLink)
        ]

genEmptyDirectory :: Gen Rose
genEmptyDirectory = RDir <$> genRosePath <*> pure []

genRoseDirectory :: Int -> Gen Rose
genRoseDirectory depth = do
  path <- genRosePath
  childCount <- chooseInt (0, 3)
  children <- vectorOf childCount (genRoseAt (depth - 1))
  pure (RDir path children)

genRoseFile :: Gen Rose
genRoseFile =
  RFile
    <$> genRosePath
    <*> (Digest <$> resize 4 (listOf (elements ("abc012" :: String))))
    <*> chooseInteger (-20, 20)

genRoseLink :: Gen Rose
genRoseLink = RLink <$> genRosePath <*> genRosePath

genRosePath :: Gen FilePath
genRosePath = resize 6 (listOf (elements ("ab/._" :: String)))

shrinkRose :: Rose -> [Rose]
shrinkRose (RDir path children) =
  children
    <> [RDir smallerPath children | smallerPath <- shrink path]
    <> [RDir path smallerChildren | smallerChildren <- shrinkList shrinkRose children]
shrinkRose (RFile path (Digest digest) size) =
  [RFile smallerPath (Digest digest) size | smallerPath <- shrink path]
    <> [RFile path (Digest smallerDigest) size | smallerDigest <- shrink digest]
    <> [RFile path (Digest digest) smallerSize | smallerSize <- shrink size]
shrinkRose (RLink path target) =
  [RLink smallerPath target | smallerPath <- shrink path]
    <> [RLink path smallerTarget | smallerTarget <- shrink target]

toFix :: Rose -> Fix FsF
toFix (RDir path children) = Fix (DirectoryF path (map toFix children))
toFix (RFile path digest size) = Fix (RegularFileF path digest size)
toFix (RLink path target) = Fix (SymbolicLinkF path target)

tallyRose :: Rose -> Summary
tallyRose rose =
  let tally = walkRose rose
  in Summary
      { entries = tallyEntries tally
      , fileCount = tallyFiles tally
      , totalBytes = tallyBytes tally
      , objects = tallyObjects tally
      }

data Tally = Tally
  { tallyEntries :: [ManifestEntry]
  , tallyFiles :: Int
  , tallyBytes :: Integer
  , tallyObjects :: Set.Set Digest
  }

walkRose :: Rose -> Tally
walkRose (RDir path children) =
  let childTallies = map walkRose children
  in Tally
      { tallyEntries = Directory path : concatMap tallyEntries childTallies
      , tallyFiles = sum (map tallyFiles childTallies)
      , tallyBytes = sum (map tallyBytes childTallies)
      , tallyObjects = Set.unions (map tallyObjects childTallies)
      }
walkRose (RFile path digest size) =
  Tally
    { tallyEntries = [RegularFile path digest size]
    , tallyFiles = 1
    , tallyBytes = size
    , tallyObjects = Set.singleton digest
    }
walkRose (RLink path target) =
  Tally
    { tallyEntries = [SymbolicLink path target]
    , tallyFiles = 0
    , tallyBytes = 0
    , tallyObjects = Set.empty
    }

prop_snapshotShowRead :: Property
prop_snapshotShowRead =
  forAllShrink genSnapshot shrinkSnapshot $ \snapshot ->
    readMaybe (show snapshot <> "\n") === Just snapshot

prop_snapshotDigestMatchesBytes :: Property
prop_snapshotDigestMatchesBytes =
  forAllShrink genSnapshot shrinkSnapshot $ \snapshot ->
    snapshotDigest snapshot === digestSnapshotInTest snapshot

prop_fixtureDigest :: Property
prop_fixtureDigest =
  snapshotDigest digestFixture
    === Digest "55f1f6e5ca977991abbf09dff9e1cdc4fb3266709b04b4c7d3dfc0e5d45a175e"

genSnapshot :: Gen Snapshot
genSnapshot = sized $ \size -> do
  format <- arbitrary
  name <- genMessyString
  createdAt <- arbitrary
  manifestEntries <- resize (min 12 size) (listOf genManifestEntry)
  regularFileCount <- arbitrary
  byteCount <- arbitrary
  pure
    Snapshot
      { snapshotFormat = format
      , snapshotName = name
      , snapshotCreatedAt = createdAt
      , snapshotEntries = manifestEntries
      , snapshotFileCount = regularFileCount
      , snapshotTotalBytes = byteCount
      }

genManifestEntry :: Gen ManifestEntry
genManifestEntry =
  oneof
    [ Directory <$> genMessyString
    , RegularFile <$> genMessyString <*> (Digest <$> genMessyString) <*> arbitrary
    , SymbolicLink <$> genMessyString <*> genMessyString
    ]

genMessyString :: Gen String
genMessyString = resize 8 arbitrary

shrinkSnapshot :: Snapshot -> [Snapshot]
shrinkSnapshot snapshot =
  [snapshot {snapshotFormat = smaller} | smaller <- shrink (snapshotFormat snapshot)]
    <> [snapshot {snapshotName = smaller} | smaller <- shrink (snapshotName snapshot)]
    <> [snapshot {snapshotCreatedAt = smaller} | smaller <- shrink (snapshotCreatedAt snapshot)]
    <> [snapshot {snapshotEntries = smaller} | smaller <- shrinkList shrinkManifestEntry (snapshotEntries snapshot)]
    <> [snapshot {snapshotFileCount = smaller} | smaller <- shrink (snapshotFileCount snapshot)]
    <> [snapshot {snapshotTotalBytes = smaller} | smaller <- shrink (snapshotTotalBytes snapshot)]

shrinkManifestEntry :: ManifestEntry -> [ManifestEntry]
shrinkManifestEntry (Directory path) =
  [Directory smaller | smaller <- shrink path]
shrinkManifestEntry (RegularFile path (Digest digest) size) =
  [RegularFile smallerPath (Digest digest) size | smallerPath <- shrink path]
    <> [RegularFile path (Digest smallerDigest) size | smallerDigest <- shrink digest]
    <> [RegularFile path (Digest digest) smallerSize | smallerSize <- shrink size]
shrinkManifestEntry (SymbolicLink path target) =
  [SymbolicLink smallerPath target | smallerPath <- shrink path]
    <> [SymbolicLink path smallerTarget | smallerTarget <- shrink target]

digestSnapshotInTest :: Snapshot -> Digest
digestSnapshotInTest snapshot =
  Digest (hexEncode (SHA256.hash (snapshotBytesInTest snapshot)))

snapshotBytesInTest :: Snapshot -> ByteString.ByteString
snapshotBytesInTest =
  ByteString.pack . map (fromIntegral . fromEnum) . (<> "\n") . show

hexEncode :: ByteString.ByteString -> String
hexEncode = concatMap hexByte . ByteString.unpack

hexByte :: Word8 -> String
hexByte byte = [nibble (byte `div` 16), nibble (byte `mod` 16)]
 where
  nibble value = "0123456789abcdef" !! fromIntegral value

digestFixture :: Snapshot
digestFixture =
  Snapshot
    { snapshotFormat = 1
    , snapshotName = "s"
    , snapshotCreatedAt = 0
    , snapshotEntries = [Directory "."]
    , snapshotFileCount = 0
    , snapshotTotalBytes = 0
    }

prop_manifestDigestPath :: Property
prop_manifestDigestPath =
  forAll genSegment $ \directory ->
    forAll genSegment $ \base ->
      conjoin
        [ manifestDigestPath (directory ++ "/" ++ base)
            === directory ++ "/." ++ base ++ ".digest"
        , manifestDigestPath base
            === "./." ++ base ++ ".digest"
        ]

genSegment :: Gen String
genSegment = listOf1 (arbitrary `suchThat` (/= '/'))

prop_writeSnapshotMatchesShownBytes :: Property
prop_writeSnapshotMatchesShownBytes =
  forAllShrink genSnapshot shrinkSnapshot $ \snapshot ->
    ioProperty $
      withScratch $ \directory -> do
        let manifestPath = directory </> "manifest"
        writeSnapshot manifestPath snapshot
        written <- ByteString.readFile manifestPath
        pure (written == snapshotBytesInTest snapshot)

prop_acceptsCoherentSnapshot :: Property
prop_acceptsCoherentSnapshot =
  forAllShrink genCoherentSnapshot shrinkCoherentSnapshot $ \snapshot ->
    ioProperty (probeSnapshot snapshot >> pure True)

prop_rejectsCorruption :: Property
prop_rejectsCorruption =
  forAllShrink genCoherentSnapshot shrinkCoherentSnapshot $ \snapshot ->
    conjoin [rejectsCorruption corruption snapshot | corruption <- allCorruptions]

genCoherentSnapshot :: Gen Snapshot
genCoherentSnapshot = do
  pieceTree <- genPieceTree
  tailEntries <- flattenPieceTree pieceTree
  createdAt <- arbitrary
  pure $
    rebuildSnapshot
      Snapshot
        { snapshotFormat = 1
        , snapshotName = "generated"
        , snapshotCreatedAt = createdAt
        , snapshotEntries = []
        , snapshotFileCount = 0
        , snapshotTotalBytes = 0
        }
      (Directory "." : tailEntries)

genPieceTree :: Gen Piece
genPieceTree = sized $ \size -> do
  childCount <- chooseInt (0, min 3 size)
  let childBudget
        | childCount == 0 = 0
        | otherwise = max 0 ((size - childCount) `div` childCount)
  (children, _) <- genPieces childCount childBudget 0
  pure (PDir "." children)

genPieces :: Int -> Int -> Int -> Gen ([Piece], Int)
genPieces count budget nextIndex
  | count <= 0 = pure ([], nextIndex)
  | otherwise = do
      (piece, followingIndex) <- genPiece budget nextIndex
      (pieces, finalIndex) <- genPieces (count - 1) budget followingIndex
      pure (piece : pieces, finalIndex)

genPiece :: Int -> Int -> Gen (Piece, Int)
genPiece budget index = do
  let name = "s" <> show index
  kind <-
    if budget <= 0
      then elements [0 :: Int, 1, 2]
      else frequency [(3, pure 0), (3, pure 1), (2, pure 2)]
  case kind of
    0 -> do
      childCount <- chooseInt (0, min 3 budget)
      let childBudget
            | childCount == 0 = 0
            | otherwise = max 0 ((budget - 1) `div` childCount)
      (children, followingIndex) <- genPieces childCount childBudget (index + 1)
      pure (PDir name children, followingIndex)
    1 -> do
      size <- chooseInteger (0, 1000)
      digest <- vectorOf 64 (elements ("0123456789abcdef" :: String))
      pure (PFile name size digest, index + 1)
    _ -> do
      target <- resize 8 arbitrary
      pure (PLink name target, index + 1)

flattenPieceTree :: Piece -> Gen [ManifestEntry]
flattenPieceTree (PDir "." children) = do
  shuffledChildren <- shuffle children
  concat <$> traverse (flattenPiece ".") shuffledChildren
flattenPieceTree _ = error "coherent piece tree must have a root directory"

flattenPiece :: FilePath -> Piece -> Gen [ManifestEntry]
flattenPiece parent (PDir name children) = do
  let path = piecePath parent name
  shuffledChildren <- shuffle children
  childEntries <- concat <$> traverse (flattenPiece path) shuffledChildren
  pure (Directory path : childEntries)
flattenPiece parent (PFile name size digest) =
  pure [RegularFile (piecePath parent name) (Digest digest) size]
flattenPiece parent (PLink name target) =
  pure [SymbolicLink (piecePath parent name) target]

piecePath :: FilePath -> String -> FilePath
piecePath "." name = name
piecePath parent name = parent <> "/" <> name

shrinkCoherentSnapshot :: Snapshot -> [Snapshot]
shrinkCoherentSnapshot snapshot =
  [ rebuildSnapshot snapshot (Directory "." : before <> after)
  | (before, entry : after) <- splits (drop 1 (snapshotEntries snapshot))
  , isLeafEntry entry (drop 1 (snapshotEntries snapshot))
  ]

splits :: [a] -> [([a], [a])]
splits values = [splitAt index values | index <- [0 .. length values - 1]]

isLeafEntry :: ManifestEntry -> [ManifestEntry] -> Bool
isLeafEntry entry manifestEntries =
  not
    ( any
        ((entryPathInTest entry <> "/") `isPrefixOf`)
        [entryPathInTest candidate | candidate <- manifestEntries, candidate /= entry]
    )

entryPathInTest :: ManifestEntry -> FilePath
entryPathInTest (Directory path) = path
entryPathInTest (RegularFile path _ _) = path
entryPathInTest (SymbolicLink path _) = path

rebuildSnapshot :: Snapshot -> [ManifestEntry] -> Snapshot
rebuildSnapshot snapshot manifestEntries =
  snapshot
    { snapshotEntries = manifestEntries
    , snapshotFileCount = length regularFiles
    , snapshotTotalBytes = sum [size | (_, size) <- regularFiles]
    }
 where
  regularFiles =
    [ (digest, size)
    | RegularFile _ digest size <- manifestEntries
    ]

allCorruptions :: [Corruption]
allCorruptions = [minBound .. maxBound]

rejectsCorruption :: Corruption -> Snapshot -> Property
rejectsCorruption corruption snapshot =
  let (corrupted, expectedMessage) = applyCorruption corruption snapshot
  in counterexample ("corruption: " <> show corruption) $
      ioProperty $ do
        result <- try (probeCorruption corruption corrupted)
        pure $
          case result of
            Left exception ->
              counterexample
                ("expected exception containing " <> show expectedMessage <> ", got " <> displayException exception)
                (expectedMessage `isInfixOf` displayException (exception :: IOException))
            Right () ->
              counterexample "loadCommittedSnapshot accepted the corrupted snapshot" False

probeCorruption :: Corruption -> Snapshot -> IO ()
probeCorruption EmptyName _ = void (loadCommittedSnapshot "unused" "")
probeCorruption _ snapshot = probeSnapshot snapshot

probeSnapshot :: Snapshot -> IO ()
probeSnapshot snapshot =
  withScratch $ \repository -> do
    createDirectory (repository </> "snapshots")
    let manifestPath = repository </> "snapshots" </> snapshotName snapshot
    writeSnapshot manifestPath snapshot
    writeManifestDigest manifestPath (snapshotDigest snapshot)
    void (loadCommittedSnapshot repository (snapshotName snapshot))

withScratch :: (FilePath -> IO a) -> IO a
withScratch action =
  bracket acquire removePathForcibly action
 where
  acquire = do
    root <- getTemporaryDirectory
    (path, handle) <- openTempFile root "foldback-prop"
    hClose handle
    removeFile path
    createDirectory path
    pure path

applyCorruption :: Corruption -> Snapshot -> (Snapshot, String)
applyCorruption corruption snapshot =
  case corruption of
    BadFormat ->
      ( snapshot {snapshotFormat = 2}
      , "unsupported snapshot format"
      )
    EmptyName ->
      ( snapshot
      , "snapshot names may contain only letters, digits, '.', '_' and '-'"
      )
    MissingRoot ->
      ( snapshot {snapshotEntries = drop 1 (snapshotEntries snapshot)}
      , "snapshot must begin with its root directory"
      )
    BadCount ->
      ( snapshot {snapshotFileCount = snapshotFileCount snapshot + 1}
      , "snapshot file count is inconsistent"
      )
    BadBytes ->
      ( snapshot {snapshotTotalBytes = snapshotTotalBytes snapshot + 1}
      , "snapshot byte count is inconsistent"
      )
    NegativeSize ->
      ( negativeSizeSnapshot snapshot
      , "snapshot contains a negative file size"
      )
    BadDigest ->
      ( badDigestSnapshot snapshot
      , "snapshot contains an invalid digest"
      )
    DuplicatePath ->
      ( duplicatePathSnapshot snapshot
      , "duplicate snapshot path: "
      )
    UnsafeDotDot ->
      ( appendEntries
          [RegularFile "foo/../bar" validTestDigest 0]
          snapshot
      , "unsafe snapshot path: "
      )
    UnsafeAbsolute ->
      ( appendEntries
          [RegularFile "/abs" validTestDigest 0]
          snapshot
      , "unsafe snapshot path: "
      )
    MissingParent ->
      ( appendEntries
          [RegularFile "missing/child" validTestDigest 0]
          snapshot
      , "missing parent directory: "
      )
    DescendFile ->
      ( appendEntries
          [ RegularFile "zzfile" validTestDigest 0
          , RegularFile "zzfile/child" validTestDigest 0
          ]
          snapshot
      , "path descends through a regular file: "
      )
    DescendSymlink ->
      ( appendEntries
          [ SymbolicLink "zzlink" "target"
          , RegularFile "zzlink/child" validTestDigest 0
          ]
          snapshot
      , "path descends through a symlink: "
      )

negativeSizeSnapshot :: Snapshot -> Snapshot
negativeSizeSnapshot snapshot =
  case replaceFirstRegular (\path digest _ -> RegularFile path digest (-1)) (snapshotEntries snapshot) of
    Just manifestEntries ->
      snapshot
        { snapshotEntries = manifestEntries
        , snapshotTotalBytes = sumRegularFileSizes manifestEntries
        }
    Nothing ->
      snapshot
        { snapshotEntries =
            insertAfterRoot
              (RegularFile "neg" validTestDigest (-1))
              (snapshotEntries snapshot)
        , snapshotFileCount = 1
        , snapshotTotalBytes = -1
        }

badDigestSnapshot :: Snapshot -> Snapshot
badDigestSnapshot snapshot =
  case replaceFirstRegular (\path _ size -> RegularFile path (Digest "ABC") size) (snapshotEntries snapshot) of
    Just manifestEntries ->
      snapshot {snapshotEntries = manifestEntries}
    Nothing ->
      snapshot
        { snapshotEntries =
            insertAfterRoot
              (RegularFile "neg" (Digest "ABC") 0)
              (snapshotEntries snapshot)
        , snapshotFileCount = 1
        , snapshotTotalBytes = 0
        }

duplicatePathSnapshot :: Snapshot -> Snapshot
duplicatePathSnapshot snapshot =
  case drop 1 (snapshotEntries snapshot) of
    entry : _ -> appendEntries [entry] snapshot
    [] -> appendEntries [Directory "dup", Directory "dup"] snapshot

replaceFirstRegular ::
  (FilePath -> Digest -> Integer -> ManifestEntry) ->
  [ManifestEntry] ->
  Maybe [ManifestEntry]
replaceFirstRegular _ [] = Nothing
replaceFirstRegular replacement (RegularFile path digest size : rest) =
  Just (replacement path digest size : rest)
replaceFirstRegular replacement (entry : rest) =
  (entry :) <$> replaceFirstRegular replacement rest

sumRegularFileSizes :: [ManifestEntry] -> Integer
sumRegularFileSizes manifestEntries =
  sum [size | RegularFile _ _ size <- manifestEntries]

insertAfterRoot :: ManifestEntry -> [ManifestEntry] -> [ManifestEntry]
insertAfterRoot entry (root : rest) = root : entry : rest
insertAfterRoot entry [] = [entry]

appendEntries :: [ManifestEntry] -> Snapshot -> Snapshot
appendEntries manifestEntries snapshot =
  snapshot
    { snapshotEntries = snapshotEntries snapshot <> manifestEntries
    }

validTestDigest :: Digest
validTestDigest = Digest (replicate 64 'a')
