module Main where

import Control.Concurrent
import Control.Exception
import Data.List (isInfixOf)
import Foldback.Repository
import System.Directory
import System.Exit
import System.FilePath
import System.IO

main :: IO ()
main = do
  parent <- getTemporaryDirectory
  (path, tempHandle) <- openTempFile parent "foldback-publication-repro"
  hClose tempHandle
  removeFile path
  bracket_ (createDirectory path) (removePathForcibly path) (run path)

run :: FilePath -> IO ()
run root = do
  let sourceA = root </> "a"
      sourceB = root </> "b"
  createDirectory sourceA
  createDirectory sourceB
  writeFile (sourceA </> "a.txt") "first source"
  writeFile (sourceB </> "b.txt") "second source"
  let repositoryPath = root </> "repo"
  repository <- createOrOpenRepository repositoryPath
  loop repositoryPath repository sourceA sourceB 1
 where
  loop repositoryPath repository sourceA sourceB attempt
    | attempt > (1000 :: Int) = do
        putStrLn "NOT REPRODUCED: no invalid manifest observed in 1,000 attempts."
        exitFailure
    | otherwise = do
        let name = "same-" ++ show attempt
        gate <- newEmptyMVar
        resultA <- newEmptyMVar
        resultB <- newEmptyMVar
        let worker source result = forkIO $ do
              readMVar gate
              outcome <- try (backup repositoryPath (Just name) source) :: IO (Either SomeException BackupReceipt)
              putMVar result outcome
        _ <- worker sourceA resultA
        _ <- worker sourceB resultB
        putMVar gate ()
        a <- takeMVar resultA
        b <- takeMVar resultB
        loaded <- try (loadCommittedSnapshot repository name) :: IO (Either SomeException Snapshot)
        case loaded of
          Left problem
            | isInfixOf "corrupt snapshot manifest" (displayException problem) -> do
                putStrLn ("REPRODUCED on attempt " ++ show attempt ++ ": " ++ displayException problem)
                putStrLn ("backup A: " ++ either displayException show a)
                putStrLn ("backup B: " ++ either displayException show b)
            | otherwise -> throwIO problem
          Right _
            | attempt < (1000 :: Int) -> loop repositoryPath repository sourceA sourceB (attempt + 1)
            | otherwise -> do
                putStrLn "NOT REPRODUCED: no invalid manifest observed in 1,000 attempts."
                exitFailure
