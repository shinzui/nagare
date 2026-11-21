{-# OPTIONS_GHC -Werror=unused-imports #-}

-- | EP-229: the recording fake transport the release runner's tests interpret
-- its commands with, and the documents its fake nagarectl answers.
module ReleaseFake
  ( Call (..)
  , World (..)
  , Responder
  , fixedTime
  , fake
  , noPython
  , withoutPython
  , recorded
  , rendered
  , lines'
  , refused
  , assertMentions
  , fieldAt
  , encodeText
  , outcomeDocument
  , versionDocument
  , writeSummary
  , fixtureReview
  , writeReview
  , version'
  , rev
  )
where

import Control.Exception (try)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Nagare.Contract.Schema (ContractVersion (..), DocumentName (..), nullable)
import Nagare.Contract.V1 (Outcome (..), TransactionOutcome (..), VersionInfo (..))
import Nagare.Harness.Prelude hiding ((.=))
import Nagare.Harness.Release.Process
import Nagare.Harness.Release.Review
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeFileName, (</>))
import Test.Tasty.HUnit

-- | What the fake records of one invocation: never a variable's value.
data Call = Call
  { program :: !FilePath
  , arguments :: ![String]
  , directory :: !(Maybe FilePath)
  , names :: ![String]
  , background :: !Bool
  }
  deriving stock (Eq, Show, Generic)

data World = World
  { calls :: !(IORef [Call])
  , said :: !(IORef [Text])
  , pauses :: !(IORef [Int])
  }
  deriving stock (Generic)

type Responder = Invocation -> IO (Int, Text)

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 10 29) 50698

-- | A runtime whose transport records each call, answers it with
-- @respond@, and honours the call's sinks with the answer's text.
fake :: [(String, String)] -> Responder -> IO (Runtime, World)
fake environment' respond = do
  calls' <- newIORef []
  said' <- newIORef []
  pauses' <- newIORef []
  let record isBackground command =
        modifyIORef' calls' (Call (command ^. #program) (command ^. #arguments) (command ^. #directory) (variableNames (command ^. #environment)) isBackground :)
      answer command = do
        (code, out) <- respond command
        let bytes = TE.encodeUtf8 out
        case command ^. #stdoutTo of
          WriteTo path -> BS.writeFile path bytes
          AppendTo path -> BS.appendFile path bytes
          Tee path -> BS.writeFile path bytes
          _ -> pure ()
        -- a separate stderr file holds the progress lines
        case command ^. #stderrTo of
          WriteTo path -> BS.writeFile path "progress\n"
          AppendTo path -> BS.appendFile path "progress\n"
          _ -> pure ()
        pure (Result code (if command ^. #stdoutTo == Capture then bytes else ""))
      transport' =
        Transport
          { run = \command -> noPython command >> record False command >> answer command
          , spawn = \command -> do
              noPython command
              record True command
              result <- answer command
              pure Background {finished = pure (result ^. #exit), stop = pure ()}
          }
  pure
    ( Runtime
        { transport = transport'
        , now = pure fixedTime
        , pause = \seconds -> modifyIORef' pauses' (seconds :)
        , say = \line -> modifyIORef' said' (line :)
        , warn = const (pure ())
        , variables = environment'
        , harness = "/harness/bin/nagare-harness"
        , locate = \_ -> pure (Just "/usr/bin/container")
        }
    , World calls' said' pauses'
    )
  where
    variableNames = \case
      Inherited -> []
      Extended extra -> map fst extra
      Exactly exact -> map fst exact

-- | M3: the release path starts no Python interpreter, by name, by absolute
-- path, through @env@ or inside a shell command line.
noPython :: Invocation -> IO ()
noPython command =
  when (any python (command ^. #program : command ^. #arguments)) $
    assertFailure ("a Python interpreter was launched: " <> unwords (command ^. #program : command ^. #arguments))
  where
    python word = any (\token -> "python" `isPrefixOf` takeFileName token) (words word)

-- | A search path with no Python on it, for the commands' own lookups.
withoutPython :: FilePath -> IO [(String, String)]
withoutPython root' = do
  createDirectoryIfMissing True (root' </> "bin")
  found <- searchPath (root' </> "bin") "python3"
  found @?= Nothing
  pure [("PATH", root' </> "bin")]

recorded :: World -> IO [Call]
recorded world = reverse <$> readIORef (world ^. #calls)

-- | Each call as its command line, with the test root shown as @$T@.
rendered :: FilePath -> [Call] -> [String]
rendered root = map (\call -> T.unpack (T.replace (T.pack root) "$T" (T.pack (unwords (call ^. #program : call ^. #arguments)))))

lines' :: World -> IO [Text]
lines' world = reverse <$> readIORef (world ^. #said)

refused :: IO () -> IO Text
refused action =
  try action >>= \case
    Left (Refusal reason) -> pure reason
    Right () -> assertFailure "expected a refusal" >> pure ""

assertMentions :: Text -> Text -> Assertion
assertMentions needle haystack = assertBool (T.unpack ("expected \"" <> needle <> "\" in: " <> haystack)) (needle `T.isInfixOf` haystack)

-- | The value at a path of object keys.
fieldAt :: Value -> [Text] -> Maybe Value
fieldAt = foldl (\value key -> case value of Just (Aeson.Object fields) -> KeyMap.lookup (Key.fromText key) fields; _ -> Nothing) . Just

encodeText :: Value -> Text
encodeText = TE.decodeUtf8 . BL.toStrict . Aeson.encode

-- | The @--contract 1@ outcome an apply or resume prints.
outcomeDocument :: Outcome -> Text -> Maybe Text -> Text
outcomeDocument outcome' transaction' detail' =
  encodeText . Aeson.toJSON $
    TransactionOutcome
      { contractVersion = ContractVersion1
      , document = DocumentName
      , outcome = outcome'
      , transaction = nullable (Just transaction')
      , operation = nullable (if outcome' == OutcomeConverged then Nothing else Just "op-1")
      , failureClass = nullable Nothing
      , barriers = []
      , detail = nullable detail'
      , problem = nullable Nothing
      }

-- | @version --json@ of a build.
versionDocument :: Text -> Text -> Text
versionDocument version'' revision'' = encodeText (Aeson.toJSON (VersionInfo version'' version'' (Just revision'') Nothing [1]))

-- | What @platform transition plan --summary@ writes for a review.
writeSummary :: FilePath -> FilePath -> IO ()
writeSummary review path = do
  counts <- readReviewCounts review >>= either (assertFailure . T.unpack) pure
  BL.writeFile path . Aeson.encode $
    object
      [ "schemaVersion" .= (1 :: Int)
      , "review" .= review
      , "operations" .= Map.fromListWith (+) [(tag, 1 :: Int) | tag <- counts ^. #actions]
      , "operationCount" .= length (counts ^. #actions)
      , "reaccepted" .= ["platform:scope-" <> T.pack (show i) | i <- [1 .. counts ^. #reaccepted]]
      ]

fixtureReview :: Int -> FilePath
fixtureReview n = "test/fixtures/release/v0.11.1-intranet/stage-" <> show n <> ".review.json"

writeReview :: FilePath -> [Text] -> Int -> IO ()
writeReview out tags reaccepts = do
  createDirectoryIfMissing True out
  let scope i = object ["kind" .= ("Platform" :: Text), "name" .= ("scope-" <> show i)]
      entry i generation = object ["scope" .= scope i, "revision" .= object ["generation" .= (generation :: Int), "digest" .= ("d" :: Text)]]
  BL.writeFile
    (out </> "review.json")
    ( Aeson.encode
        ( object
            [ "operations" .= [object ["operation" .= object ["action" .= object ["tag" .= tag]]] | tag <- tags]
            , "baseRevisions" .= [entry i 1 | i <- [1 .. reaccepts]]
            , "desiredRevisions" .= [entry i 2 | i <- [1 .. reaccepts]]
            ]
        )
    )

version' :: Text
version' = "9.8.7"

rev :: Text
rev = "0123456789abcdef0123456789abcdef01234567"
