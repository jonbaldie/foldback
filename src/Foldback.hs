module Foldback
  ( runCommand
  ) where

import Control.Exception (IOException, displayException, try)
import Foldback.Repository
  ( BackupReceipt (..)
  , SnapshotInfo (..)
  , Verification (..)
  , backup
  , listSnapshots
  , restore
  , verifyRepository
  )
import Data.Version (showVersion)
import Paths_foldback (version)

runCommand :: [String] -> IO (Either String String)
runCommand arguments =
  case parseCommand arguments of
    Left problem -> pure (Left problem)
    Right command -> do
      result <- try (execute command)
      pure (either (Left . displayException) Right (result :: Either IOException String))

data Command
  = Backup FilePath FilePath (Maybe String)
  | Restore FilePath String FilePath
  | List FilePath
  | Verify FilePath
  | Help
  | Version

execute :: Command -> IO String
execute (Backup repository source requestedName) = do
  receipt <- backup repository requestedName source
  let noun = if receiptFileCount receipt == 1 then "file" else "files"
  pure
    ( "snapshot "
        <> receiptName receipt
        <> ": "
        <> show (receiptFileCount receipt)
        <> " "
        <> noun
        <> ", "
        <> show (receiptTotalBytes receipt)
        <> " bytes\n"
    )
execute (Restore repository snapshot target) = do
  restore repository snapshot target
  pure ("restored " <> snapshot <> " to " <> target <> "\n")
execute (List repository) = do
  snapshots <- listSnapshots repository
  pure (concatMap renderSnapshot snapshots)
 where
  renderSnapshot snapshot =
    infoName snapshot
      <> "\t"
      <> show (infoFileCount snapshot)
      <> " files\t"
      <> show (infoTotalBytes snapshot)
      <> " bytes\n"
execute (Verify repository) = do
  verification <- verifyRepository repository
  pure
    ( "verified "
        <> show (verifiedSnapshots verification)
        <> " snapshots, "
        <> show (verifiedObjects verification)
        <> " objects\n"
    )
execute Help = pure usage
execute Version = pure ("foldback " <> showVersion version <> "\n")

parseCommand :: [String] -> Either String Command
parseCommand ("backup" : arguments) = do
  (positionals, repository, requestedName) <- parseArguments True arguments
  source <- exactlyOne "backup requires one SOURCE" positionals
  repo <- requireRepository repository
  pure (Backup repo source requestedName)
parseCommand ("restore" : arguments) = do
  (positionals, repository, _) <- parseArguments False arguments
  case positionals of
    [snapshot, target] -> Restore <$> requireRepository repository <*> pure snapshot <*> pure target
    _ -> Left "restore requires SNAPSHOT and TARGET"
parseCommand ("list" : arguments) = parseRepositoryCommand List arguments
parseCommand ("verify" : arguments) = parseRepositoryCommand Verify arguments
parseCommand ["--help"] = Right Help
parseCommand ["-h"] = Right Help
parseCommand ["--version"] = Right Version
parseCommand [] = Left usage
parseCommand _ = Left usage

parseRepositoryCommand :: (FilePath -> Command) -> [String] -> Either String Command
parseRepositoryCommand constructor arguments = do
  (positionals, repository, _) <- parseArguments False arguments
  unlessEmpty positionals
  constructor <$> requireRepository repository

unlessEmpty :: [a] -> Either String ()
unlessEmpty [] = Right ()
unlessEmpty _ = Left "this command accepts no positional arguments"

parseArguments :: Bool -> [String] -> Either String ([String], Maybe FilePath, Maybe String)
parseArguments allowName = go [] Nothing Nothing
 where
  go positionals repository requestedName [] = Right (reverse positionals, repository, requestedName)
  go _ Nothing _ ("--repo" : value : _)
    | take 1 value == "-" = Left "--repo requires a value"
  go positionals Nothing requestedName ("--repo" : value : rest) =
    go positionals (Just value) requestedName rest
  go _ (Just _) _ ("--repo" : _ : _) = Left "--repo may only be supplied once"
  go _ _ _ ("--name" : _)
    | not allowName = Left "--name is only valid for backup"
  go positionals repository Nothing ("--name" : value : rest)
    | allowName = go positionals repository (Just value) rest
  go _ _ (Just _) ("--name" : _ : _)
    | allowName = Left "--name may only be supplied once"
  go _ _ _ ["--repo"] = Left "--repo requires a value"
  go _ _ _ ["--name"] = Left "--name requires a value"
  go _ _ _ (option : _)
    | take 1 option == "-" = Left ("unknown option: " <> option)
  go positionals repository requestedName (value : rest) =
    go (value : positionals) repository requestedName rest

exactlyOne :: String -> [a] -> Either String a
exactlyOne _ [value] = Right value
exactlyOne problem _ = Left problem

requireRepository :: Maybe FilePath -> Either String FilePath
requireRepository Nothing = Left "--repo is required"
requireRepository (Just repository)
  | null repository = Left "--repo cannot be empty"
  | otherwise = Right repository

usage :: String
usage = unlines
  [ "usage:"
  , "  foldback backup SOURCE --repo REPOSITORY [--name NAME]"
  , "  foldback restore SNAPSHOT TARGET --repo REPOSITORY"
  , "  foldback list --repo REPOSITORY"
  , "  foldback verify --repo REPOSITORY"
  ]
