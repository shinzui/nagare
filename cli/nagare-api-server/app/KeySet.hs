-- | @nagare-keyset@ (EP-286): one run of a key set's rotator, from its
-- CronJob, with the CronJob's own ServiceAccount. It exits non-zero when the
-- run did not complete, so the next run retries and the Job records why.
module Main (main) where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Nagare.Contract.Prelude
import Nagare.Dsl.KeySet (mkKeySetName)
import Nagare.KeySet (RotationEvent (..))
import Nagare.KeySet.Rotator (RotationRun (..), generateKeyPair, inClusterObjects, rotateOnce)
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (stderr)

data Options = Options
  { namespace :: !Text
  , keySet :: !Text
  }

options :: Parser Options
options =
  Options
    <$> strOption (long "namespace" <> metavar "NAMESPACE" <> help "The key set's namespace")
    <*> strOption (long "key-set" <> metavar "NAME" <> help "The key set's name")

main :: IO ()
main = do
  Options {namespace = namespace', keySet = keySet'} <- execParser (info (options <**> helper) (fullDesc <> progDesc "Rotate one Nagare signing key set"))
  name <- either fail' pure (mkKeySetName keySet')
  kube <- inClusterObjects >>= either fail' pure
  now <- getCurrentTime
  fresh <- sequence [generateKeyPair, generateKeyPair]
  rotateOnce kube now fresh namespace' name >>= \case
    Left reason -> fail' reason
    Right Unchanged -> TIO.putStrLn (keySet' <> ": current")
    Right PublicRestored -> TIO.putStrLn (keySet' <> ": public file restored from the Secret")
    Right (Rotated events) -> TIO.putStrLn (keySet' <> ": " <> T.intercalate ", " (map describe events))
  where
    fail' reason = TIO.hPutStrLn stderr ("nagare-keyset: " <> reason) >> exitFailure
    describe = \case
      Generated kid -> "generated " <> kid
      Activated kid -> "activated " <> kid
      Superseded kid -> "superseded " <> kid
      Withdrawn kid -> "withdrew " <> kid
