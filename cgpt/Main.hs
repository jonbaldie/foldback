-- | Coverage-guided, property-based campaign harness for the foldback
-- executable.
--
-- The system under test is the real, coverage-instrumented @foldback@ binary
-- (build it with @cabal build foldback --enable-coverage --builddir dist-cov@).
-- Each scenario is a seeded, stateful sequence of backups over a generated and
-- mutated filesystem tree. Properties checked after every backup:
--
--  * receipts: @backup@ reports the name, file count, and byte total of the
--    snapshot, and @list@ agrees with every snapshot's manifest;
--  * content addressing: the object store holds exactly one object per
--    distinct file content, and its set only ever grows;
--  * snapshot immutability: @verify@ passes after every step;
--  * round trips: restoring a snapshot reproduces the tree exactly.
--
-- Every executable invocation runs with its working directory pointed at a
-- scratch folder, so GHC's HPC leaves a @.tix@ file there. The campaign uses
-- newly discovered ticks as fitness: seeds that reach uncovered code are kept
-- and mutated for later generations.
--
-- Failures are shrunk (knob by knob) and the minimal failure is replayed three
-- times in fresh temporary directories; only failures stable across all three
-- replays are reported.
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception
  ( Exception
  , SomeException
  , displayException
  , throwIO
  , try
  )
import Control.Monad (filterM, foldM, forM_, replicateM, unless, void, when)
import Data.Bits (complement, shiftR, xor, (.&.))
import qualified Data.ByteString as ByteString
import Data.IORef
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Data.Word (Word64)
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , createFileLink
  , doesPathExist
  , getFileSize
  , getTemporaryDirectory
  , listDirectory
  , makeAbsolute
  , removePathForcibly
  )
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>), joinPath, takeDirectory)
import qualified System.Posix.Files as Posix
import System.Posix.Process (getProcessID)
import System.IO.Unsafe (unsafePerformIO)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Text.Read (readMaybe)
import Trace.Hpc.Tix (Tix (..), TixModule (..), readTix)

-- | Positional accessors for 'TixModule', which has no record fields.
moduleTicks :: TixModule -> [Integer]
moduleTicks (TixModule _ _ _ ticks) = ticks

moduleName :: TixModule -> String
moduleName (TixModule name _ _ _) = name

main :: IO ()
main = do
  options <- parseOptions <$> getArgs
  case optionReplay options of
    Just seed -> replayOne options seed
    Nothing -> runFullCampaign options

replayOne :: Options -> Word64 -> IO ()
replayOne options seed = do
  binary <- findReplayBinary options
  putStrLn ("SUT: " <> binary)
  withScratch "replay-single" $ \root -> do
    let tixDir = root </> "tix"
    createDirectoryIfMissing True tixDir
    outcome <- attemptScenario binary tixDir seed (genLevels seed)
    putStrLn ("seed " <> show seed <> ": " <> outcomeMessage outcome)

runFullCampaign :: Options -> IO ()
runFullCampaign options = do
  binary <- findCoverageBinary options
  putStrLn ("SUT: " <> binary)
  normalBinary <- findNormalBinary
  putStrLn ("normal build: " <> normalBinary)
  withScratch "campaign" $ \root -> do
    negative <- runNegativeChecks binary (root </> "negative")
    mapM_ (putStrLn . ("negative: " <>)) negative
    negativeTicks <- collectTix (root </> "negative")
    let covered0 = snd (mergeTicks Map.empty negativeTicks)
    (failures, covered) <- runCampaign binary normalBinary options (root </> "runs") covered0
    reportCoverage covered
    if null negative && null failures
      then putStrLn "CGPT campaign: no stable failures"
      else do
        mapM_ (putStrLn . ("NEGATIVE CHECK FAILURE: " <>)) negative
        mapM_ (putStrLn . renderFailure) failures
        exitFailure

-- ---------------------------------------------------------------------------
-- Options and SUT discovery
-- ---------------------------------------------------------------------------

data Options = Options
  { optionGenerations :: Int
  , optionSeed :: Word64
  , optionBinary :: Maybe FilePath
  , optionReplay :: Maybe Word64
  }

parseOptions :: [String] -> Options
parseOptions arguments = go arguments (Options 16 20260910 Nothing Nothing)
 where
  go [] options = options
  go ("--generations" : value : rest) options = go rest options {optionGenerations = read value}
  go ("--seed" : value : rest) options = go rest options {optionSeed = read value}
  go ("--binary" : value : rest) options = go rest options {optionBinary = Just value}
  go ("--replay" : value : rest) options = go rest options {optionReplay = Just (read value)}
  go _ _ = error "usage: foldback-cgpt [--generations N] [--seed N] [--binary PATH] [--replay SEED]"

-- | The binary a reported failure is replayed against: an explicit override,
-- else the normal build, else the coverage build.
findReplayBinary :: Options -> IO FilePath
findReplayBinary options = do
  fromEnvironment <- lookupEnv "FOLDBACK_BIN"
  case optionBinary options of
    Just path -> makeAbsolute path
    Nothing -> case fromEnvironment of
      Just path -> makeAbsolute path
      Nothing -> do
        normal <- findBinaryInBuildRoot 10 "dist-newstyle/build"
        maybe (findCoverageBinary options) makeAbsolute normal

findCoverageBinary :: Options -> IO FilePath
findCoverageBinary options =
  case optionBinary options of
    Just path -> makeAbsolute path
    Nothing -> do
      fromEnvironment <- lookupEnv "FOLDBACK_BIN"
      case fromEnvironment of
        Just path -> makeAbsolute path
        Nothing -> do
          found <- findBinaryInBuildRoot 10 "dist-cov/build"
          makeAbsolute (maybe (error missingBinary) id found)
 where
  missingBinary =
    "coverage-instrumented SUT not found. Build it with:\n"
      <> "  cabal build exe:foldback --enable-coverage --builddir dist-cov\n"
      <> "or pass --binary / set FOLDBACK_BIN."

findNormalBinary :: IO FilePath
findNormalBinary = do
  found <- findBinaryInBuildRoot 10 "dist-newstyle/build"
  makeAbsolute (maybe (error missingBinary) id found)
 where
  missingBinary =
    "normal foldback executable not found; run: cabal build exe:foldback"

-- | Depth-limited search for the foldback executable under a build tree.
findBinaryInBuildRoot :: Int -> FilePath -> IO (Maybe FilePath)
findBinaryInBuildRoot depth directory
  | depth <= (0 :: Int) = pure Nothing
  | otherwise = do
      entries <- listDirectory directory
      let candidates = (directory </>) <$> entries
      regularFiles <- filterM (\path -> not <$> isDirectoryPath path) candidates
      case filter ((== "foldback") . lastFileName) regularFiles of
        (found : _) -> pure (Just found)
        [] -> do
          directoryCandidates <- filterM isDirectoryPath candidates
          firstJustM (findBinaryInBuildRoot (depth - 1)) directoryCandidates

lastFileName :: FilePath -> String
lastFileName = reverse . takeWhile (/= '/') . reverse

firstJustM :: (a -> IO (Maybe b)) -> [a] -> IO (Maybe b)
firstJustM _ [] = pure Nothing
firstJustM action (value : rest) = do
  found <- action value
  maybe (firstJustM action rest) (pure . Just) found

isDirectoryPath :: FilePath -> IO Bool
isDirectoryPath path = do
  status <- Posix.getSymbolicLinkStatus path
  pure (Posix.isDirectory status)

-- ---------------------------------------------------------------------------
-- SplitMix64 PRNG
-- ---------------------------------------------------------------------------

newtype Rng = Rng Word64

rngStep :: Rng -> (Word64, Rng)
rngStep (Rng state) = (mix64 (state + 0x9E3779B97F4A7C15), Rng (state + 0x9E3779B97F4A7C15))

mix64 :: Word64 -> Word64
mix64 z0 =
  let z1 = (z0 `xor` (z0 `shiftR` 33)) * 0xff51afd7ed558ccd
      z2 = (z1 `xor` (z1 `shiftR` 33)) * 0xc4ceb9fe1a85ec53
      z3 = z2 `xor` (z2 `shiftR` 33)
   in z3

rngBelow :: Int -> Rng -> (Int, Rng)
rngBelow bound generator = case rngStep generator of
  (word, next) -> (fromIntegral (word `mod` fromIntegral bound), next)

rngPick :: [a] -> Rng -> (a, Rng)
rngPick values generator = case rngBelow (length values) generator of
  (index, next) -> (values !! index, next)

rngCoin :: Rng -> (Bool, Rng)
rngCoin generator = case rngBelow 2 generator of
  (0, next) -> (True, next)
  (_, next) -> (False, next)

-- ---------------------------------------------------------------------------
-- Content and trees
-- ---------------------------------------------------------------------------

-- | File content identified by a seed and a length; identical identifiers are
-- identical bytes, which is what the deduplication property relies on.
data Content = Content !Word64 !Int
  deriving (Eq, Ord)

-- | Lengths chosen to cross the SUT's 64 KiB copy boundaries.
lengthChoices :: [Int]
lengthChoices = [0, 1, 2, 17, 255, 4096, 65536, 65537, 131072]

contentBytes :: Content -> ByteString.ByteString
contentBytes (Content seed len) = ByteString.take len (ByteString.concat (replicate blocks block))
 where
  block = ByteString.pack (take 4096 (byteStream (Rng (seed `xor` 0x5DEECE66D))))
  blocks = max 1 ((len `div` 4096) + 1)
  byteStream generator = case rngStep generator of
    (word, next) -> fromIntegral (word .&. 0xFF) : byteStream next

type RelPath = [String]

data Node
  = FileNode !Content
  | LinkNode !FilePath
  deriving (Eq, Ord)

data Tree = Tree
  { treeDirs :: Set.Set RelPath
  , treeNodes :: Map.Map RelPath Node
  }

emptyTree :: Tree
emptyTree = Tree Set.empty Map.empty

manifestOf :: Tree -> (Int, Integer)
manifestOf tree =
  let contents = [content | FileNode content <- Map.elems (treeNodes tree)]
   in (length contents, sum (map (\(Content _ len) -> fromIntegral len) contents))

-- | Link target string exactly as the tool stores and restores it.
linkTargetString :: RelPath -> RelPath -> FilePath
linkTargetString link target =
  let depth = length link - 1
   in if depth <= (0 :: Int)
        then joinPath target
        else
          if take depth link == take depth target
            then joinPath (drop depth target)
            else joinPath (replicate depth ".." ++ target)

isEmptyDir :: Tree -> RelPath -> Bool
isEmptyDir tree directory =
  not (any (\(path, _) -> take (length directory) path == directory) (Map.toList (treeNodes tree)))
    && not
      ( any
          (\path -> take (length directory) path == directory && path /= directory)
          (Set.toList (treeDirs tree))
      )

-- ---------------------------------------------------------------------------
-- Scenario knobs
-- ---------------------------------------------------------------------------

data Levels = Levels
  { lvFiles :: !Int
  , lvDirs :: !Int
  , lvLinks :: !Int
  , lvSteps :: !Int
  , lvPool :: !Int
  , lvBig :: !Int
  , lvUnnamed :: !Bool
  , lvCorrupt :: !Bool
  }
  deriving (Show)

knobFiles :: Levels -> Int
knobFiles = (1 +) . lvFiles

knobDirs :: Levels -> Int
knobDirs = (1 +) . lvDirs

-- | At least two backups so at least one mutation is exercised.
knobSteps :: Levels -> Int
knobSteps = (2 +) . lvSteps

knobPool :: Levels -> Int
knobPool = (1 +) . lvPool

minimalLevels :: Levels
minimalLevels = Levels 0 0 0 0 0 0 False False

-- | Knobs are derived from one seed, so any reported seed replays exactly:
-- scenario tree, mutations, and this record all come from 'genLevels'.
genLevels :: Word64 -> Levels
genLevels seed = Levels files dirs links steps pool big unnamed corrupt
 where
  (files, r1) = rngBelow 10 (Rng (seed `xor` 0xC0FFEE))
  (dirs, r2) = rngBelow 3 r1
  (links, r3) = rngBelow 4 r2
  (steps, r4) = rngBelow 4 r3
  (pool, r5) = rngBelow 4 r4
  (big, r6) = rngBelow (length lengthChoices) r5
  (unnamed, r7) = rngCoin r6
  (corrupt, _) = rngCoin r7

-- | One knob reduction each; the fully minimal variant leads.
shrinkVariants :: Levels -> [Levels]
shrinkVariants levels =
  [minimalLevels]
    <> [ levels {lvFiles = 0}
       , levels {lvSteps = 0}
       , levels {lvLinks = 0}
       , levels {lvBig = 0}
       , levels {lvPool = 0}
       , levels {lvDirs = 0}
       , levels {lvUnnamed = False}
       , levels {lvCorrupt = False}
       ]

-- ---------------------------------------------------------------------------
-- Scenario generation
-- ---------------------------------------------------------------------------

data State = State
  { stateTree :: Tree
  , stateRng :: Rng
  , stateHistory :: [(String, Tree)]
  , stateContents :: Set.Set ByteString.ByteString
  , stateObjects :: Set.Set String
  , stateCounter :: Int
  , statePool :: [Content]
  }

-- | Generate the content pool and initial tree for a scenario.
generateScenario :: Word64 -> Levels -> ([Content], Tree, Rng)
generateScenario seed levels = (pool, tree, rng3)
 where
  rng0 = Rng (seed `xor` 0x5DEECE66D)
  (pool, rng1) = drawPool (knobPool levels) rng0 []
  drawPool 0 generator accumulated = (accumulated, generator)
  drawPool remaining generator accumulated =
    let (word, r1) = rngStep generator
        (lenIndex, r2) = rngBelow (lvBig levels + 1) r1
     in drawPool (remaining - 1) r2 (Content word (lengthChoices !! lenIndex) : accumulated)
  (tree, rng3) = drawFiles 0 rng1 emptyTree
  drawFiles index generator current
    | index >= knobFiles levels = drawDirs 0 generator current
    | otherwise =
        let (seedWord, r1) = rngStep generator
            (lenIndex, r2) = rngBelow (lvBig levels + 1) r1
            fresh = Content seedWord (lengthChoices !! lenIndex)
            (fromPool, r3) = rngCoin r2
            (content, r4) =
              if fromPool && not (null pool) then rngPick pool r3 else (fresh, r3)
            (directory, r5) = pickDirectory current r4
            path = directory ++ ["f" <> show index]
            tree' = current {treeNodes = Map.insert path (FileNode content) (treeNodes current)}
         in drawFiles (index + 1) r5 tree'
  drawDirs index generator current
    | index >= knobDirs levels - 1 = (current, generator)
    | otherwise =
        let (directory, r1) = pickDirectory current generator
            path = directory ++ ["d" <> show index]
            tree' = current {treeDirs = Set.insert path (treeDirs current)}
         in drawDirs (index + 1) r1 tree'

pickDirectory :: Tree -> Rng -> (RelPath, Rng)
pickDirectory tree generator = case Set.toList (treeDirs tree) of
  [] -> ([], generator)
  directories -> rngPick directories generator

-- | Mutate the virtual tree between backups. Deletions never shrink the
-- accumulated content or object sets.
mutateTree :: Levels -> State -> State
mutateTree levels state0 = case choice of
  0 -> case files of
    [] -> addFile
    _ ->
      let ((path, _), rng2) = rngPick files rng1
          (content, rng3) = drawContent rng2
          updated =
            state0
              { stateTree = tree {treeNodes = Map.insert path (FileNode content) (treeNodes tree)}
              , stateRng = rng3
              }
       in updated {stateContents = Set.insert (contentBytes content) (stateContents updated)}
  1 -> addFile
  2 -> case files of
    [] -> addFile
    _ ->
      let ((path, _), rng2) = rngPick files rng1
       in state0 {stateTree = tree {treeNodes = Map.delete path (treeNodes tree)}, stateRng = rng2}
  3 ->
    let path = parentPath ++ ["d" <> freshName]
     in state0
          { stateTree = tree {treeDirs = Set.insert path (treeDirs tree)}
          , stateRng = rng1
          , stateCounter = nextCounter
          }
  4 -> case emptyDirs of
    [] -> addFile
    _ ->
      let (path, rng2) = rngPick emptyDirs rng1
       in state0 {stateTree = tree {treeDirs = Set.delete path (treeDirs tree)}, stateRng = rng2}
  _ -> case files of
    [] -> state0 {stateRng = rng1}
    _ ->
      let ((target, _), rng2) = rngPick files rng1
          path = parentPath ++ ["l" <> freshName]
          tree' = tree {treeNodes = Map.insert path (LinkNode (linkTargetString path target)) (treeNodes tree)}
       in state0 {stateTree = tree', stateRng = rng2, stateCounter = nextCounter}
 where
  tree = stateTree state0
  files = Map.toList (treeNodes tree)
  emptyDirs = [d | d <- Set.toList (treeDirs tree), isEmptyDir tree d]
  (choice, rng0) = rngBelow 6 (stateRng state0)
  (parentPath, rng1) = pickDirectory tree rng0
  freshName = "n" <> show (stateCounter state0)
  nextCounter = stateCounter state0 + 1
  addFile =
    let path = parentPath ++ ["f" <> freshName]
        (content, rng2) = drawContent rng1
        updated =
          state0
            { stateTree = tree {treeNodes = Map.insert path (FileNode content) (treeNodes tree)}
            , stateRng = rng2
            , stateCounter = nextCounter
            }
     in updated {stateContents = Set.insert (contentBytes content) (stateContents updated)}
  drawContent generator =
    let (fromPool, r1) = rngCoin generator
     in if fromPool && not (null (statePool state0))
          then rngPick (statePool state0) r1
          else
            let (word, r2) = rngStep r1
                (lenIndex, r3) = rngBelow (lvBig levels + 1) r2
             in (Content word (lengthChoices !! lenIndex), r3)

materialize :: FilePath -> Tree -> IO ()
materialize root tree = do
  exists <- doesPathExist root
  when exists (removePathForcibly root)
  createDirectoryIfMissing True root
  forM_ (Set.toList (treeDirs tree)) $ \path ->
    createDirectoryIfMissing True (root </> joinPath path)
  forM_ (Map.toList (treeNodes tree)) $ \(path, node) -> do
    let absolute = root </> joinPath path
    createDirectoryIfMissing True (takeDirectory absolute)
    case node of
      FileNode content -> ByteString.writeFile absolute (contentBytes content)
      LinkNode target -> createFileLink target absolute

-- ---------------------------------------------------------------------------
-- SUT invocation and failures
-- ---------------------------------------------------------------------------

data SutResult = SutResult
  { sutCode :: ExitCode
  , sutOut :: String
  , sutErr :: String
  }

runSut :: FilePath -> FilePath -> [String] -> IO SutResult
runSut binary tixDir arguments = do
  -- Each invocation gets a fresh working directory so HPC starts a clean tix
  -- file (merging into an existing one triggers a deprecation warning).
  count <- atomicModifyIORef invocationCounter (\n -> (n + 1, n))
  let invocationDirectory = tixDir </> ("inv" <> show count)
  createDirectoryIfMissing True invocationDirectory
  (code, out, err) <-
    readCreateProcessWithExitCode ((proc binary arguments) {cwd = Just invocationDirectory}) ""
  pure (SutResult code out err)

{-# NOINLINE invocationCounter #-}
invocationCounter :: IORef Int
invocationCounter = unsafePerformIO (newIORef 0)

expectSut :: String -> SutResult -> IO ()
expectSut what result =
  unless (sutCode result == ExitSuccess) $
    propertyFailure
      ( what
          <> " exited with "
          <> show (sutCode result)
          <> "; stderr: "
          <> sutErr result
          <> "; stdout: "
          <> sutOut result
      )

newtype PropertyFailure = PropertyFailure String

instance Exception PropertyFailure

instance Show PropertyFailure where
  show (PropertyFailure message) = "property failure: " <> message

propertyFailure :: String -> IO a
propertyFailure = throwIO . PropertyFailure

data Failure = Failure
  { failureSeed :: Word64
  , failureLevels :: Levels
  , failureMessage :: String
  }

renderFailure :: Failure -> String
renderFailure failure =
  "STABLE FAILURE seed=" <> show (failureSeed failure)
    <> " levels=" <> show (failureLevels failure)
    <> "\n  " <> failureMessage failure

-- ---------------------------------------------------------------------------
-- Scenario execution
-- ---------------------------------------------------------------------------

data Env = Env
  { envBinary :: FilePath
  , envTixDir :: FilePath
  , envRoot :: FilePath
  , envLevels :: Levels
  }

-- | Run one stateful scenario in a fresh scratch directory. Throws on any
-- property violation.
scenarioBody :: FilePath -> FilePath -> Word64 -> Levels -> IO ()
scenarioBody binary tixDir seed levels =
  withScratch ("scenario-" <> show seed) $ \root -> do
    let env = Env binary tixDir root levels
        (pool, tree, rng) = generateScenario seed levels
        initialContents = [content | FileNode content <- Map.elems (treeNodes tree)]
        state = State tree rng [] (Set.fromList (map contentBytes initialContents)) Set.empty 0 pool
    void (foldM (step env) state [1 .. knobSteps levels])

step :: Env -> State -> Int -> IO State
step env state0 index = do
  let state = if index == 1 then state0 else mutateTree (envLevels env) state0
      root = envRoot env
      source = root </> "source"
      repository = root </> "repository"
      named = index < knobSteps (envLevels env) || not (lvUnnamed (envLevels env))
      name = "s" <> pad2 index
  materialize source (stateTree state)
  backup <- runSut (envBinary env) (envTixDir env) (backupArguments named name source repository)
  expectSut ("backup " <> name) backup
  actualName <-
    if named
      then pure name
      else do
        unless ("snapshot " `isPrefixOf` sutOut backup) $
          propertyFailure ("backup receipt missing snapshot name: " <> sutOut backup)
        pure (takeWhile (/= ':') (drop (length ("snapshot " :: String)) (sutOut backup)))
  let (fileCount, totalBytes) = manifestOf (stateTree state)
      noun = if fileCount == 1 then "file" else "files"
      expectedReceipt =
        "snapshot " <> actualName <> ": " <> show fileCount <> " " <> noun <> ", " <> show totalBytes <> " bytes\n"
  unless (sutOut backup == expectedReceipt) $
    propertyFailure ("backup receipt mismatch for " <> actualName <> ": " <> sutOut backup)
  objectNames <- listDirectory (repository </> "objects")
  let objects = Set.fromList objectNames
  unless (stateObjects state `Set.isSubsetOf` objects)
    (propertyFailure ("objects disappeared after backup " <> actualName))
  unless (Set.size objects == Set.size (stateContents state))
    ( propertyFailure
        ( "dedup mismatch after backup "
            <> actualName
            <> ": "
            <> show (Set.size objects)
            <> " objects vs "
            <> show (Set.size (stateContents state))
            <> " distinct contents"
        )
    )
  verify <- runSut (envBinary env) (envTixDir env) ["verify", "--repo", repository]
  expectSut ("verify after " <> actualName) verify
  listing <- runSut (envBinary env) (envTixDir env) ["list", "--repo", repository]
  expectSut ("list after " <> actualName) listing
  checkList (sutOut listing) (stateHistory state ++ [(actualName, stateTree state)])
  checkRestore env index actualName (stateTree state)
  when (index == knobSteps (envLevels env)) $ do
    case sortOn fst (stateHistory state) of
      ((earliestName, earliestTree) : _) -> checkRestore env index earliestName earliestTree
      [] -> propertyFailure "history is empty at the final step"
    when (lvCorrupt (envLevels env)) (corruptProbe env)
  pure
    state
      { stateRng = stateRng state
      , stateHistory = stateHistory state ++ [(actualName, stateTree state)]
      , stateObjects = objects
      }

backupArguments :: Bool -> String -> FilePath -> FilePath -> [String]
backupArguments named name source repository
  | named = ["backup", source, "--repo", repository, "--name", name]
  | otherwise = ["backup", source, "--repo", repository]

checkList :: String -> [(String, Tree)] -> IO ()
checkList output history = do
  rows <- case mapM parseLine (filter (not . null) (lines output)) of
    Just parsed -> pure parsed
    Nothing -> propertyFailure ("unparseable list output: " <> output)
  let expected = sortOn fst history
  unless (map (\(name, _, _) -> name) rows == map fst expected)
    ( propertyFailure
        ("list names mismatch: " <> show (map (\(name, _, _) -> name) rows) <> " vs " <> show (map fst expected))
    )
  forM_ (zip rows expected) $ \((name, rowCount, rowBytes), (_, tree)) -> do
    let (fileCount, totalBytes) = manifestOf tree
    unless (rowCount == fileCount && rowBytes == totalBytes)
      ( propertyFailure
          ( "list totals mismatch for "
              <> name
              <> ": "
              <> show (rowCount, rowBytes)
              <> " vs "
              <> show (fileCount, totalBytes)
          )
      )

parseLine :: String -> Maybe (String, Int, Integer)
parseLine row = case break (== '\t') row of
  (name, rest) -> case words (drop 1 rest) of
    [countWord, "files", bytesWord, "bytes"] -> do
      rowCount <- readMaybe countWord :: Maybe Int
      rowBytes <- readMaybe bytesWord :: Maybe Integer
      pure (name, rowCount, rowBytes)
    _ -> Nothing

checkRestore :: Env -> Int -> String -> Tree -> IO ()
checkRestore env index name expected = do
  let target = envRoot env </> ("restore-" <> pad2 index <> "-" <> name)
  result <-
    runSut (envBinary env) (envTixDir env) ["restore", name, target, "--repo", envRoot env </> "repository"]
  expectSut ("restore " <> name) result
  actual <- collectActualTree target
  compareTrees expected actual

data ActualNode = ActualFile ByteString.ByteString | ActualLink FilePath
  deriving (Eq, Ord)

type ActualTree = (Set.Set RelPath, Map.Map RelPath ActualNode)

collectActualTree :: FilePath -> IO ActualTree
collectActualTree root = go [] (Set.empty, Map.empty)
 where
  go relative accumulated = do
    children <- listDirectory (foldl' (</>) root relative)
    foldM (visit relative) accumulated (sort children)
  visit relative (directories, nodes) child = do
    let path = relative ++ [child]
        absolute = foldl' (</>) root path
    status <- Posix.getSymbolicLinkStatus absolute
    if Posix.isSymbolicLink status
      then do
        linkTarget <- Posix.readSymbolicLink absolute
        pure (directories, Map.insert path (ActualLink linkTarget) nodes)
      else
        if Posix.isDirectory status
          then go path (Set.insert path directories, nodes)
          else do
            bytes <- ByteString.readFile absolute
            pure (directories, Map.insert path (ActualFile bytes) nodes)

compareTrees :: Tree -> ActualTree -> IO ()
compareTrees expected (directories, nodes) = do
  unless
    (treeDirs expected == directories)
    ( propertyFailure
        ("restored directory set differs: " <> show (Set.toList (treeDirs expected)) <> " vs " <> show (Set.toList directories))
    )
  unless (Map.size (treeNodes expected) == Map.size nodes)
    (propertyFailure "restored entry set differs in size")
  forM_ (Map.toList (treeNodes expected)) $ \(path, node) ->
    case (node, Map.lookup path nodes) of
      (FileNode content, Just (ActualFile bytes)) ->
        unless
          (bytes == contentBytes content)
          (propertyFailure ("restored content differs at " <> joinPath path))
      (LinkNode linkTarget, Just (ActualLink restored)) ->
        unless
          (restored == linkTarget)
          (propertyFailure ("restored link target differs at " <> joinPath path))
      (FileNode _, _) -> propertyFailure ("restored entry is not a file: " <> joinPath path)
      (LinkNode _, _) -> propertyFailure ("restored entry is not a link: " <> joinPath path)

-- ---------------------------------------------------------------------------
-- Scratch directories
-- ---------------------------------------------------------------------------

-- | Deliberately corrupt one non-empty stored object; the SUT must reject the
-- repository afterwards instead of silently accepting it.
corruptProbe :: Env -> IO ()
corruptProbe env = do
  let objectsDirectory = envRoot env </> "repository" </> "objects"
  objectNames <- listDirectory objectsDirectory
  nonEmpty <-
    filterM (\name -> (> 0) <$> getFileSize (objectsDirectory </> name)) objectNames
  case nonEmpty of
    [] -> pure ()
    (victim : _) -> do
      bytes <- ByteString.readFile (objectsDirectory </> victim)
      let corrupted = case ByteString.unpack bytes of
            (first : rest) -> ByteString.pack (complement first : rest)
            [] -> bytes
      ByteString.writeFile (objectsDirectory </> victim) corrupted
      verify <- runSut (envBinary env) (envTixDir env) ["verify", "--repo", envRoot env </> "repository"]
      unless (sutCode verify /= ExitSuccess) $
        propertyFailure ("verify accepted a corrupted object: " <> victim)
      unless ("corrupt object" `isInfixOf` sutErr verify) $
        propertyFailure ("verify rejected corruption with an unexpected error: " <> sutErr verify)

withScratch :: forall a. String -> (FilePath -> IO a) -> IO a
withScratch label action = do
  temporary <- getTemporaryDirectory
  processId <- getProcessID
  path <- freshDirectory temporary (label <> "-" <> show processId)
  createDirectory path
  result <- try (action path) :: IO (Either SomeException a)
  _ <- try (removePathForcibly path) :: IO (Either SomeException ())
  either throwIO pure result
 where
  freshDirectory base baseName = go (0 :: Int)
   where
    go count = do
      let candidate = base </> (baseName <> "-" <> show count)
      taken <- doesPathExist candidate
      if taken then go (count + 1) else pure candidate

-- ---------------------------------------------------------------------------
-- HPC coverage bookkeeping
-- ---------------------------------------------------------------------------

collectTix :: FilePath -> IO [TixModule]
collectTix directory = do
  entries <- listDirectory directory
  let paths = (directory </>) <$> entries
  directories <- filterM isDirectoryPath paths
  tixes <- mapM readTix [path | path <- paths, isSuffixOf ".tix" path]
  nested <- mapM collectTix directories
  pure (concat [modules | Just (Tix modules) <- tixes] <> concat nested)

-- | Merge ticks into a max-per-position map; returns how many positions went
-- from zero to nonzero (newly covered ticks).
mergeTicks :: Map.Map String [Integer] -> [TixModule] -> (Int, Map.Map String [Integer])
mergeTicks covered modules = foldl' merge (0, covered) modules
 where
  merge (newlyCovered, accumulated) module' =
    let name = moduleName module'
        ticks = moduleTicks module'
        existing = Map.findWithDefault (replicate (length ticks) 0) name accumulated
        newly =
          length
            [ ()
            | (existingTick, tick) <- zip existing ticks
            , existingTick == 0
            , tick > 0
            ]
     in (newlyCovered + newly, Map.insert name (zipWith max existing ticks) accumulated)

isFoldbackModule :: String -> Bool
isFoldbackModule name = "Foldback" `isInfixOf` name || "foldback" `isInfixOf` name

coverageSummary :: Map.Map String [Integer] -> String
coverageSummary covered =
  show coveredTicks <> "/" <> show totalTicks <> " foldback ticks"
 where
  modules = [ticks | (name, ticks) <- Map.toList covered, isFoldbackModule name]
  coveredTicks = sum (map (length . filter (> 0)) modules)
  totalTicks = sum (map length modules)

reportCoverage :: Map.Map String [Integer] -> IO ()
reportCoverage covered = do
  putStrLn ("coverage: " <> coverageSummary covered)
  forM_ (Map.toList covered) $ \(name, ticks) ->
    when (isFoldbackModule name) $
      putStrLn
        ( "  " <> name <> ": "
            <> show (length (filter (> 0) ticks))
            <> "/"
            <> show (length ticks)
        )

-- ---------------------------------------------------------------------------
-- Campaign
-- ---------------------------------------------------------------------------

-- | Upper bound on one scenario run, so a hung SUT fails the scenario instead
-- of hanging the campaign.
scenarioTimeout :: Int
scenarioTimeout = 10 * 60 * 1000000

-- | Run one scenario with a timeout; a timeout counts as a failure.
attemptScenario :: FilePath -> FilePath -> Word64 -> Levels -> IO (Either SomeException (Maybe ()))
attemptScenario binary tixDir seed levels =
  try (timeout scenarioTimeout (scenarioBody binary tixDir seed levels))

outcomeMessage :: Either SomeException (Maybe ()) -> String
outcomeMessage (Left exception) = displayException exception
outcomeMessage (Right Nothing) = "scenario timed out after 600 seconds"
outcomeMessage (Right (Just ())) = "no failure"

runCampaign
  :: FilePath
  -> FilePath
  -> Options
  -> FilePath
  -> Map.Map String [Integer]
  -> IO ([Failure], Map.Map String [Integer])
runCampaign binary normalBinary options root covered0 = do
  coveredRef <- newIORef covered0
  archiveRef <- newIORef ([] :: [Word64])
  failuresRef <- newIORef ([] :: [Failure])
  forM_ [1 .. optionGenerations options] $ \generation -> do
    archive <- readIORef archiveRef
    let baseSeed = optionSeed options + fromIntegral generation
        seed =
          if generation `mod` 4 == 0 || null archive
            then baseSeed
            else
              let eliteSeed = archive !! ((generation * 7919) `mod` length archive)
               in eliteSeed `xor` (fromIntegral generation * 0x9E3779B97F4A7C15)
        levels = genLevels seed
        origin = if seed == baseSeed then "fresh" else "elite"
    let tixDir = root </> ("gen" <> pad2 generation)
    createDirectoryIfMissing True tixDir
    outcome <- attemptScenario binary tixDir seed levels
    ticks <- collectTix tixDir
    coveredCurrent <- readIORef coveredRef
    let (newlyCovered, merged) = mergeTicks coveredCurrent ticks
    writeIORef coveredRef merged
    case outcome of
      Right (Just ()) -> do
        when (newlyCovered > 0) (modifyIORef archiveRef (<> [seed]))
        putStrLn
          ( "gen " <> show generation <> " " <> origin <> " seed=" <> show seed
              <> " newTicks=" <> show newlyCovered
              <> " " <> coverageSummary merged
          )
      _ -> do
        putStrLn
          ( "gen " <> show generation <> " " <> origin <> " seed=" <> show seed
              <> " FAILURE: " <> outcomeMessage outcome
          )
        minimal <- shrinkScenario normalBinary (root </> "shrink") seed
        putStrLn ("  shrunk to levels=" <> show minimal)
        stable <- replayStable normalBinary (root </> "replay") seed minimal
        case stable of
          Just message -> modifyIORef failuresRef (<> [Failure seed minimal message])
          Nothing -> putStrLn "  failure did not replay 3/3; ignored"
  failures <- readIORef failuresRef
  covered <- readIORef coveredRef
  pure (failures, covered)

shrinkScenario :: FilePath -> FilePath -> Word64 -> IO Levels
shrinkScenario binary tixDir seed = go (0 :: Int) (genLevels seed)
 where
  createDirectories = createDirectoryIfMissing True tixDir
  go depth levels
    | depth >= 8 = pure levels
    | otherwise = do
        reduced <-
          firstJustM
            (\variant -> do
               failure <- variantFails variant
               pure (if failure then Just variant else Nothing))
            (shrinkVariants levels)
        case reduced of
          Just better -> go (depth + 1) better
          Nothing -> pure levels
  variantFails variant = do
    createDirectories
    outcome <- attemptScenario binary tixDir seed variant
    pure (case outcome of
      Right (Just ()) -> False
      _ -> True)

replayStable :: FilePath -> FilePath -> Word64 -> Levels -> IO (Maybe String)
replayStable binary tixDir seed levels = do
  createDirectoryIfMissing True tixDir
  results <- replicateM 3 (attemptScenario binary tixDir seed levels)
  pure $ case map outcomeMessage results of
    (first : _ : _ : []) -> Just first
    _ -> Nothing

-- ---------------------------------------------------------------------------
-- Naming
-- ---------------------------------------------------------------------------

pad2 :: Int -> String
pad2 n =
  let rendered = show n
   in if length rendered < 2 then '0' : rendered else rendered

-- ---------------------------------------------------------------------------
-- Negative CLI checks
-- ---------------------------------------------------------------------------

runNegativeChecks :: FilePath -> FilePath -> IO [String]
runNegativeChecks binary work = do
  let source = work </> "source"
      repository = work </> "repo"
  createDirectoryIfMissing True source
  ByteString.writeFile (source </> "a.txt") (ByteString.pack (map (fromIntegral . fromEnum) ("hello" :: String)))
  let run = runSut binary work
      check label expectSuccess needle arguments = do
        result <- run arguments
        let message = sutErr result <> sutOut result
            ok = (sutCode result == ExitSuccess) == expectSuccess && needle `isInfixOf` message
        pure (if ok then Nothing else Just (label <> ": " <> show (sutCode result) <> " " <> message))
  early <-
    sequence
      [ check "no arguments" False "usage:" []
      , check "backup without --repo" False "--repo is required" ["backup", source]
      , check "unknown option" False "unknown option" ["list", "--repo", repository, "--wat"]
      , check "double --repo" False "may only be supplied once" ["list", "--repo", repository, "--repo", repository]
      , check
          "restore with --name"
          False
          "unknown option: --name"
          ["restore", "x", work </> "target", "--repo", repository, "--name", "x"]
      , check "list positional" False "accepts no positional arguments" ["list", "--repo", repository, "extra"]
      , check "missing source" False "source is not a directory" ["backup", work </> "nope", "--repo", repository]
      , check "help" True "usage:" ["--help"]
      , check "version" True "foldback" ["--version"]
      ]
  initial <- runSut binary work ["backup", source, "--repo", repository, "--name", "neg1"]
  expectSut "negative setup backup" initial
  createDirectoryIfMissing True (work </> "nest")
  ByteString.writeFile (work </> "nest" </> "b.txt") (ByteString.pack (map (fromIntegral . fromEnum) ("nested" :: String)))
  late <-
    sequence
      [ check
          "duplicate snapshot name"
          False
          "snapshot already exists"
          ["backup", source, "--repo", repository, "--name", "neg1"]
      , check
          "invalid snapshot name"
          False
          "snapshot names may contain"
          ["backup", source, "--repo", repository, "--name", "a/b"]
      , check
          "restore missing snapshot"
          False
          "snapshot does not exist"
          ["restore", "nope", work </> "target2", "--repo", repository]
      , check
          "verify non-repository"
          False
          "not a foldback repository"
          ["verify", "--repo", work </> "notrepo"]
      , check
          "repo inside source"
          False
          "outside the source tree"
          ["backup", work </> "nest", "--repo", work </> "nest" </> "inner"]
      ]
  pure (catMaybes (early <> late))