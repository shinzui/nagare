-- | Runtime / Process. Executable-private CLI boundary.
module Nagare.Cli.Runtime.Process
  ( currentTimestamp
  , runExternal
  , withEnvironment
  , withEnvironmentValues
  )
where

import Control.Exception (IOException, bracket, catch)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Nagare.Dsl.Prelude
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode)
import System.Process (readProcessWithExitCode)

runExternal :: [ExitCode] -> FilePath -> [String] -> String -> IO (Either Text Text)
runExternal accepted executable arguments input = do
  result <- catch (Right <$> readProcessWithExitCode executable arguments input) (pure . Left)
  pure $ case result of
    Left (err :: IOException) -> Left ("could not run " <> T.pack executable <> ": " <> T.pack (show err))
    Right (code, out, err)
      | code `elem` accepted -> Right (T.strip (T.pack (out <> err)))
      | otherwise -> Left (T.pack executable <> " exited " <> T.pack (show code) <> ": " <> T.strip (T.pack (err <> out)))

currentTimestamp :: IO Text
currentTimestamp = T.pack . iso8601Show <$> getCurrentTime

withEnvironment :: String -> String -> IO a -> IO a
withEnvironment name envValue ioAction =
  bracket
    (lookupEnv name <* setEnv name envValue)
    (\saved -> maybe (unsetEnv name) (setEnv name) saved)
    (const ioAction)

withEnvironmentValues :: [(String, String)] -> IO a -> IO a
withEnvironmentValues variables ioAction =
  foldr (\(name, envValue) next -> withEnvironment name envValue next) ioAction variables
