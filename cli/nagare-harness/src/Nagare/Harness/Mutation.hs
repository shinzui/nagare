-- | Mutation records (EP-180 M8). Each record under
-- @cli/nagarectl/test/mutations/@ reverts one guard, and @records.json@ names
-- the suite and test pattern that must fail once it is applied. A record whose
-- test no longer fails proves nothing, so the records are checked mechanically:
-- that each one still applies and names a test that exists (the fast gate),
-- and that each one still fails its tests (proved on the remote builder).
module Nagare.Harness.Mutation
  ( Expectation (..)
  , MutationRecord (..)
  , Outcome (..)
  , ProofResult (..)
  , Suite (..)
  , checkPatterns
  , checkRecords
  , classifyProof
  , loadRecords
  , proveRecords
  , recordsDirectory
  , selectRecords
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_, finally)
import Data.Aeson (FromJSON (..), eitherDecodeFileStrict, withObject, withText, (.:))
import Data.Generics.Labels ()
import Data.List (nub, sort, (\\))
import Data.Text qualified as T
import Nagare.Harness.Prelude
import System.Directory (getTemporaryDirectory, listDirectory, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath (dropExtension, takeExtension, (</>))
import System.IO (hClose, openTempFile)
import System.IO.Error (catchIOError)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)

-- | The test suite a record is proved against.
data Suite = Nagarectl | NagareDsl
  deriving stock (Eq, Ord, Show, Generic)

instance FromJSON Suite where
  parseJSON = withText "suite" $ \case
    "nagarectl" -> pure Nagarectl
    "nagare-dsl" -> pure NagareDsl
    other -> fail ("unknown suite " <> T.unpack other)

-- | What applying a record must do: make a test fail, or stop the build.
data Expectation = TestFails | BuildFails
  deriving stock (Eq, Show, Generic)

instance FromJSON Expectation where
  parseJSON = withText "expectation" $ \case
    "test-fails" -> pure TestFails
    "build-fails" -> pure BuildFails
    other -> fail ("unknown expectation " <> T.unpack other)

data MutationRecord = MutationRecord
  { record :: !Text
  , suite :: !Suite
  , pattern :: !Text
  , expect :: !Expectation
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON MutationRecord where
  parseJSON = withObject "mutation record" $ \o ->
    MutationRecord <$> o .: "record" <*> o .: "suite" <*> o .: "pattern" <*> o .: "expect"

recordsDirectory :: FilePath
recordsDirectory = "cli/nagarectl/test/mutations"

suiteDirectory :: Suite -> FilePath
suiteDirectory = \case
  Nagarectl -> "cli/nagarectl"
  NagareDsl -> "cli/nagare-dsl"

suiteTest :: Suite -> String
suiteTest = \case
  Nagarectl -> "nagarectl-test"
  NagareDsl -> "nagare-dsl-test"

suiteName :: Suite -> String
suiteName = \case
  Nagarectl -> "nagarectl"
  NagareDsl -> "nagare-dsl"

diffPath :: MutationRecord -> FilePath
diffPath entry = recordsDirectory </> (T.unpack (entry ^. #record) <> ".diff")

loadRecords :: FilePath -> IO (Either Text [MutationRecord])
loadRecords root = first T.pack <$> eitherDecodeFileStrict (root </> recordsDirectory </> "records.json")

-- | Every diff has exactly one manifest entry, every entry names a diff, and
-- every diff applies to the working tree. The problems found, if any.
checkRecords :: FilePath -> IO [Text]
checkRecords root = do
  loaded <- loadRecords root
  case loaded of
    Left reason -> pure ["records.json: " <> reason]
    Right entries -> do
      files <- listDirectory (root </> recordsDirectory)
      let diffs = sort [T.pack (dropExtension file) | file <- files, takeExtension file == ".diff"]
          named = map (^. #record) entries
          duplicated = nub (named \\ nub named)
      applying <- forM entries $ \entry -> do
        (code, _, err) <- capture root "git" ["apply", "--check", diffPath entry]
        pure [entry ^. #record <> " does not apply: " <> T.strip err | code /= ExitSuccess, entry ^. #record `elem` diffs]
      pure $
        [name <> ".diff has no entry in records.json" | name <- diffs, name `notElem` named]
          <> [name <> " in records.json has no diff" | name <- nub named, name `notElem` diffs]
          <> [name <> " appears more than once in records.json" | name <- duplicated]
          <> concat applying

-- | Every record's pattern selects at least one test of its suite's built test
-- binary. A pattern that selects nothing would make the record pass
-- vacuously, as twelve did while a test group was missing from the suite (F76).
checkPatterns :: FilePath -> IO [Text]
checkPatterns root = do
  loaded <- loadRecords root
  case loaded of
    Left reason -> pure ["records.json: " <> reason]
    Right entries -> fmap concat . forM (nub (map (^. #suite) entries)) $ \selected -> do
      let workdir = root </> suiteDirectory selected
      (found, binary, err) <- capture workdir "cabal" ["list-bin", "-v0", suiteTest selected]
      if found /= ExitSuccess
        then pure [T.pack (suiteTest selected) <> ": no built test binary: " <> T.strip err]
        else
          forM
            [entry | entry <- entries, entry ^. #suite == selected, entry ^. #expect == TestFails]
            ( \entry -> do
                (code, listed, listErr) <- capture workdir (T.unpack (T.strip binary)) ["--list-tests", "-p", T.unpack (entry ^. #pattern)]
                pure $
                  if code /= ExitSuccess
                    then Just (entry ^. #record <> ": pattern " <> entry ^. #pattern <> " is invalid: " <> T.strip listErr)
                    else
                      if null (filter (not . T.null . T.strip) (T.lines listed))
                        then Just (entry ^. #record <> ": pattern " <> entry ^. #pattern <> " selects no test")
                        else Nothing
            )
            <&> catMaybesList
  where
    catMaybesList values = [value | Just value <- values]

-- | The records a proof run covers: all of them, or those a range of commits
-- could have affected (a record changed in the range, or a diff touching a
-- file changed in it).
selectRecords :: FilePath -> Maybe (Text, Text) -> [MutationRecord] -> IO [MutationRecord]
selectRecords _ Nothing entries = pure entries
selectRecords root (Just (base, rev)) entries = do
  (_, changedText, _) <- capture root "git" ["diff", "--name-only", T.unpack base, T.unpack rev]
  let changed = map T.unpack (T.lines changedText)
  fmap concat . forM entries $ \entry -> do
    (_, touchedText, _) <- capture root "git" ["apply", "--numstat", diffPath entry]
    let touched = [T.unpack path | line <- T.lines touchedText, path : _ <- [reverse (T.words line)]]
        affected = diffPath entry `elem` changed || any (`elem` changed) touched || (recordsDirectory </> "records.json") `elem` changed
    pure [entry | affected]

data Outcome
  = -- | The record failed as it must: the record still proves its guard.
    Killed
  | -- | The record's tests passed: the record no longer proves anything.
    Survived
  | -- | The record built when it must not, or failed to build when it must.
    WrongStage
  | -- | The record no longer applies to the revision.
    Stale
  deriving stock (Eq, Show, Generic)

data ProofResult = ProofResult
  { record :: !Text
  , outcome :: !Outcome
  , detail :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | Classify a remote test run of a record's proof commit from its exit code
-- and whether the build produced logs.
classifyProof :: Expectation -> ExitCode -> Bool -> Outcome
classifyProof expectation code built = case (expectation, code, built) of
  (TestFails, ExitFailure _, True) -> Killed
  (TestFails, ExitSuccess, _) -> Survived
  (TestFails, ExitFailure _, False) -> WrongStage
  (BuildFails, ExitFailure _, False) -> Killed
  (BuildFails, _, True) -> WrongStage
  (BuildFails, ExitSuccess, False) -> WrongStage

-- | Prove each record on the remote builder, at most @width@ at a time: build
-- a detached commit of the revision with the record applied, behind a
-- temporary branch so the flake fetch resolves it, and run its suite's pattern
-- through @just test-remote@.
proveRecords :: FilePath -> Int -> Text -> [MutationRecord] -> IO [ProofResult]
proveRecords root width rev entries = do
  gate <- newQSem (max 1 width)
  boxes <- forM entries $ \entry -> do
    box <- newEmptyMVar
    _ <- forkIO (bracket_ (waitQSem gate) (signalQSem gate) (proveOne root rev entry) >>= putMVar box)
    pure box
  forM boxes takeMVar

proveOne :: FilePath -> Text -> MutationRecord -> IO ProofResult
proveOne root rev entry = do
  proof <- proofCommit root rev entry
  case proof of
    Left reason -> pure (ProofResult (entry ^. #record) Stale reason)
    Right (commit, branch) -> do
      (code, out, err) <-
        capture root "just" ["test-remote", T.unpack commit, T.unpack (entry ^. #pattern), "0/1", "false", suiteName (entry ^. #suite)]
          `finally` capture root "git" ["branch", "-D", T.unpack branch]
      let built = "test-remote: logs in" `T.isInfixOf` out
          logs = [line | line <- T.lines out, "test-remote: logs in" `T.isPrefixOf` line]
      pure
        ProofResult
          { record = entry ^. #record
          , outcome = classifyProof (entry ^. #expect) code built
          , detail = T.intercalate "; " (logs <> [T.strip (T.unlines (lastLines 3 err)) | not built])
          }
  where
    lastLines n = reverse . take n . reverse . T.lines

-- | The revision's tree with the record applied, committed on a temporary
-- branch. The working tree and the real index are untouched.
proofCommit :: FilePath -> Text -> MutationRecord -> IO (Either Text (Text, Text))
proofCommit root rev entry = do
  temporary <- getTemporaryDirectory
  (indexPath, handle) <- openTempFile temporary "nagare-mutation-index"
  hClose handle
  removeFile indexPath
  let runIndexed program arguments = do
        (code, out, err) <- readCreateProcessWithExitCode (proc program arguments) {cwd = Just root, env = Nothing} ""
        pure (code, T.strip (T.pack out), T.strip (T.pack err))
      git arguments = runIndexed "env" (("GIT_INDEX_FILE=" <> indexPath) : "git" : arguments)
  result <- do
    (readCode, _, readErr) <- git ["read-tree", T.unpack rev]
    (applyCode, _, applyErr) <- git ["apply", "--cached", diffPath entry]
    (treeCode, tree, treeErr) <- git ["write-tree"]
    case () of
      _
        | readCode /= ExitSuccess -> pure (Left ("read-tree failed: " <> readErr))
        | applyCode /= ExitSuccess -> pure (Left ("does not apply at " <> rev <> ": " <> applyErr))
        | treeCode /= ExitSuccess -> pure (Left ("write-tree failed: " <> treeErr))
        | otherwise -> do
            (commitCode, commit, commitErr) <- git ["commit-tree", T.unpack tree, "-p", T.unpack rev, "-m", "mutation proof: " <> T.unpack (entry ^. #record)]
            let branch = "mutation-proof/" <> entry ^. #record <> "-" <> T.take 8 commit
            (branchCode, _, branchErr) <- git ["branch", "-f", T.unpack branch, T.unpack commit]
            pure $
              if commitCode /= ExitSuccess
                then Left ("commit-tree failed: " <> commitErr)
                else
                  if branchCode /= ExitSuccess
                    then Left ("branch failed: " <> branchErr)
                    else Right (commit, branch)
  removeFile indexPath `catchIOError` const (pure ())
  pure result

capture :: FilePath -> FilePath -> [String] -> IO (ExitCode, Text, Text)
capture workdir program arguments = do
  (code, out, err) <- readCreateProcessWithExitCode (proc program arguments) {cwd = Just workdir} ""
  pure (code, T.pack out, T.pack err)
