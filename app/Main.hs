module Main (main) where

import Foldback (runCommand)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  result <- getArgs >>= runCommand
  either die putStr result
