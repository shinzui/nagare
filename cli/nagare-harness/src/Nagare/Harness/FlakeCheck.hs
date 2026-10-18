-- | The full gate's flake check (EP-184 M2). It runs with @--keep-going@, so a
-- failing check no longer cancels the others, and alongside the local suites,
-- so its failures are known within minutes. Because it keeps going, its exit
-- comes only when every check has finished; the gate follows its log instead
-- and reports each failing check as it appears.
module Nagare.Harness.FlakeCheck
  ( FlakeFailure (..)
  , builderLostOnly
  , flakeCheckStep
  , flakeFailures
  , LogFollower
  , newLogFollower
  , followLog
  , renderFailure
  , summaryFailures
  )
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Containers.ListUtils (nubOrd)
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Harness.Prelude
import Nagare.Harness.Step (Step (..))
import System.IO (IOMode (ReadMode), SeekMode (AbsoluteSeek), hFileSize, hSeek, withBinaryFile)

flakeCheckStep :: Step
flakeCheckStep = Step "nix-flake-check" "." "nix" ["flake", "check", "--all-systems", "--keep-going", "--print-build-logs"]

-- | One failure a flake check's output names. The end-of-run summary names
-- each failed check attribute; while the run goes on, only the derivation
-- whose builder failed is named.
data FlakeFailure
  = FailedCheck !Text
  | FailedDerivation !Text
  deriving stock (Eq, Ord, Show, Generic)

renderFailure :: FlakeFailure -> Text
renderFailure = \case
  FailedCheck attribute -> attribute
  FailedDerivation derivation -> "derivation " <> derivation

-- | Every failure the output names, in first-seen order, each once.
flakeFailures :: Text -> [FlakeFailure]
flakeFailures = nubOrd . mapMaybe (failure . stripEscapes) . T.lines
  where
    failure line = markedCheck line <|> builderFailed line
    markedCheck line = case T.breakOn "\x274C " line of
      (_, rest)
        | not (T.null rest)
        , attribute : _ <- T.words (T.drop 2 rest) ->
            Just (FailedCheck attribute)
      _ -> Nothing
    builderFailed line =
      FailedDerivation . derivationName
        <$> (quotedAfter "Cannot build '" line <|> quotedAfter "error: builder for '" line)
    quotedAfter marker line = case T.breakOn marker line of
      (_, rest) | not (T.null rest) -> Just (T.takeWhile (/= '\'') (T.drop (T.length marker) rest))
      _ -> Nothing
    -- @/nix/store/<hash>-<name>.drv@ to @<name>@.
    derivationName path =
      let base = T.takeWhileEnd (/= '/') path
          named = T.drop 1 (T.dropWhile (/= '-') base)
       in fromMaybe named (T.stripSuffix ".drv" named)

-- | Whether a failed flake check lost its remote builder and nothing else
-- failed: Nix found no machine for a remote build, or a build on the builder
-- failed before its builder ran (its inputs did not arrive: "N dependencies
-- failed", "does not exist, and substitution is disabled"), and no builder
-- exited with an error. A build or test failure always shows as "failed with
-- exit code" while the run goes on, so it is never mistaken for a lost
-- builder; the error Nix repeats under a failed check's @❌@ line says so too
-- for a lost builder, and is not read (2026-10-14: an SSH timeout to the
-- builder, 2026-10-17: a copy to it, each turned a run whose every build
-- passed into a red full gate).
builderLostOnly :: Text -> Bool
builderLostOnly output = any lost reports && not (any failed reports)
  where
    reports = filter (not . buildLogLine) (withoutCheckErrors (map stripEscapes (T.lines output)))
    lost line =
      any (`T.isInfixOf` line) ["Failed to find a machine for remote build", "failed to start SSH connection"]
        || ("error: build of '" `T.isPrefixOf` line && "on 'ssh://" `T.isInfixOf` line)
    failed line = any (`T.isInfixOf` line) ["failed with exit code", "failed to produce output path"]
    withoutCheckErrors = \case
      [] -> []
      line : rest
        | "\x274C " `T.isPrefixOf` line
        , next : more <- rest
        , "error: Cannot build " `T.isPrefixOf` next ->
            withoutCheckErrors (dropWhile (" " `T.isPrefixOf`) more)
        | otherwise -> line : withoutCheckErrors rest
    -- A builder's own output, @<name>> ...@.
    buildLogLine line = case T.breakOn "> " line of
      (name, rest) -> not (T.null name) && not (T.null rest) && not (T.any (== ' ') name)

-- | Drop ANSI escape sequences (@ESC [ ... letter@).
stripEscapes :: Text -> Text
stripEscapes text = case T.breakOn "\ESC[" text of
  (before, rest)
    | T.null rest -> before
    | otherwise -> before <> stripEscapes (T.drop 1 (T.dropWhile (not . isLetter) (T.drop 2 rest)))
  where
    isLetter c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

-- | The failures a finished run reports: the summary's failed check
-- attributes when it printed them, otherwise every failed derivation.
summaryFailures :: [FlakeFailure] -> [FlakeFailure]
summaryFailures found = case [failure | failure@(FailedCheck _) <- found] of
  [] -> found
  checks -> checks

-- | Follows a growing log: the bytes already read, the bytes of the
-- unfinished last line (kept undecoded, so a character split across two reads
-- survives), and the failures already reported.
data LogFollower = LogFollower
  { path :: !FilePath
  , state :: !(IORef (Integer, BS.ByteString, Set.Set FlakeFailure))
  }
  deriving stock (Generic)

newLogFollower :: FilePath -> IO LogFollower
newLogFollower logPath = LogFollower logPath <$> newIORef (0, BS.empty, Set.empty)

-- | Read what the log gained since the last call and return the failures not
-- reported before. A log not yet created reads as empty.
followLog :: LogFollower -> IO [FlakeFailure]
followLog follower = do
  (offset, carry, seen) <- readIORef (follower ^. #state)
  grown <- try @IOException $ withBinaryFile (follower ^. #path) ReadMode $ \handle -> do
    size <- hFileSize handle
    if size <= offset
      then pure (offset, BS.empty)
      else do
        hSeek handle AbsoluteSeek offset
        chunk <- BS.hGet handle (fromIntegral (size - offset))
        pure (size, chunk)
  case grown of
    Left _ -> pure []
    Right (offset', chunk) -> do
      let (complete, unfinished) = BS.breakEnd (== 10) (carry <> chunk)
          fresh = [failure | failure <- flakeFailures (TE.decodeUtf8Lenient complete), not (Set.member failure seen)]
      writeIORef (follower ^. #state) (offset', unfinished, foldr Set.insert seen fresh)
      pure fresh
