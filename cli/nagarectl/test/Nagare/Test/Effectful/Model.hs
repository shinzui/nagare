-- | A persisted external-world model. It models only requests used by this
-- restore scenario and refuses every other request. It is not a Kubernetes emulator.
module Nagare.Test.Effectful.Model
  ( Fault (..)
  , World (..)
  , seedWorld
  , readWorld
  , writeWorld
  , modelRequest
  , completeDownload
  , runDownload
  , field
  , textField
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Generics (Generic)
import Nagare.Dsl.Prelude hiding (set, (.=), (<.>))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.KubernetesTransport
import Nagare.Resource.Inventory (ManagedResource (..))
import Nagare.Resource.Types
import Nagare.Test.Effectful.Fixture
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)

data Fault = NoFault | BeforeWrite | AfterWrite | WaitTimeout
  deriving stock (Eq, Show)

data World = World
  { objects :: !(Map Text Value)
  , createCount :: !Int
  , requests :: ![[String]]
  , virtualSeconds :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

field :: Text -> Value -> Value
field key (Object values) = maybe Null id (KM.lookup (Key.fromText key) values)
field _ _ = Null

textField :: Text -> Value -> Text
textField key value = case field key value of
  String text -> text
  _ -> error ("missing text field " <> T.unpack key)

set :: Text -> Value -> Value -> Value
set key value (Object values) = Object (KM.insert (Key.fromText key) value values)
set _ _ _ = error "expected an object"

readWorld :: FilePath -> IO World
readWorld root = checked . eitherDecodeStrict <$> BS.readFile (root </> "world.json")

writeWorld :: FilePath -> World -> IO ()
writeWorld root = BL.writeFile (root </> "world.json") . encode

seedWorld :: FilePath -> RestoreFixture -> IO ()
seedWorld root fixture = do
  createDirectoryIfMissing True root
  BS.writeFile (root </> "archive.gz") (fixtureArchive fixture)
  BS.writeFile (root </> "receipt.json") (fixtureReceipt fixture)
  writeWorld root (World (Map.fromList (map seeded (Map.elems (fixtureNative fixture)))) 0 [] 0)
  where
    seeded (member, bytes) =
      let value = checked (eitherDecodeStrict bytes)
          metadata = field "metadata" value
          name = textField "name" metadata
          kind = textField "kind" value
          uid
            | kind == "StatefulSet" = "stateful-uid"
            | kind == "PersistentVolumeClaim" = "pvc-uid"
            | otherwise = name <> "-uid"
          annotations = case field "annotations" metadata of
            Object values -> values
            _ -> KM.empty
          stamps =
            KM.fromList
              [ ("nagare.dev/context-id", String "effectful-restore")
              , ("nagare.dev/resource-id", String (resourceIdText (member ^. #identity)))
              , ("nagare.dev/spec-digest", String (digestText (contentDigest bytes)))
              ]
          stampedMetadata =
            set "uid" (String uid) $
              set "resourceVersion" (String "10") $
                set "generation" (Number 1) $
                  set "annotations" (Object (KM.union stamps annotations)) metadata
          stamped = set "metadata" stampedMetadata value
          ready =
            set
              "status"
              ( object
                  [ "observedGeneration" .= (1 :: Int)
                  , "readyReplicas" .= (1 :: Int)
                  , "updatedReplicas" .= (1 :: Int)
                  ]
              )
              stamped
       in (T.toLower kind <> "/" <> name, ready)

modelRequest :: FilePath -> Fault -> KubectlRequest -> IO KubectlResult
modelRequest root fault request = do
  unless (request ^. #context == "effectful-local") (fail "unexpected Kubernetes context")
  initial <- readWorld root
  let args = request ^. #arguments
      world = initial {requests = requests initial <> [args]}
      success value = Right (ExitSuccess, T.unpack (TE.decodeUtf8 (BL.toStrict (encode value))), "")
      failure message = Right (ExitFailure 1, "", message)
  writeWorld root world
  case args of
    ["get", kind, name, "--namespace", "default", "-o", "json", "--ignore-not-found"]
      | kind `elem` ["job.batch", "statefulset.apps", "persistentvolumeclaim"] -> do
          let key = T.pack (takeWhile (/= '.') kind <> "/" <> name)
          pure (maybe (Right (ExitSuccess, "", "")) success (Map.lookup key (objects world)))
    ["create", "--field-manager=nagare-inventory", "-f", "-"] -> do
      let native = checked (eitherDecodeStrict (TE.encodeUtf8 (T.pack (request ^. #input))))
          metadata = field "metadata" native
          key = "job/" <> textField "name" metadata
          owned =
            set
              "metadata"
              ( set
                  "uid"
                  (String "restore-job-uid")
                  (set "resourceVersion" (String "11") metadata)
              )
              native
      unless (field "kind" native == String "Job") (fail "unexpected resource creation")
      if Map.member key (objects world)
        then pure (failure "AlreadyExists")
        else
          if fault == BeforeWrite
            then pure (Left "injected failure before write")
            else do
              writeWorld root world {objects = Map.insert key owned (objects world), createCount = createCount world + 1}
              if fault == AfterWrite
                then pure (Left "write committed; acknowledgement lost")
                else pure (success owned)
    ["wait", "--for=condition=complete", token, "--namespace", "default", "--timeout=300s"] -> do
      -- Waiting advances virtual time; it does not fabricate completion.
      writeWorld root world {virtualSeconds = virtualSeconds world + 300}
      if fault == WaitTimeout
        then pure (failure "injected readiness timeout")
        else pure $ case Map.lookup (T.pack token) (objects world) of
          Just value
            | field "conditions" (field "status" value)
                == toJSON [object ["type" .= ("Complete" :: Text), "status" .= ("True" :: Text)]] ->
                success value
          _ -> failure "Job is present but has not completed"
    _ -> fail ("unsupported modeled request: " <> show args)

-- The workload model finishes only after the ACTUAL rendered download command
-- has run with its declared environment and produced the expected SQL bytes.
-- PostgreSQL loading is outside this model and requires native integration.
completeDownload :: FilePath -> IO ()
completeDownload root = do
  world <- readWorld root
  let jobs = [(key, value) | (key, value) <- Map.toList (objects world), "job/" `T.isPrefixOf` key]
  case jobs of
    [(key, job)] -> do
      code <- runDownload root job
      unless (code == ExitSuccess) (fail "rendered download failed")
      actual <- BS.readFile (root </> "dump/backup.sql")
      unless (actual == "CREATE TABLE restored (id integer);\n") (fail "download content changed")
      let done =
            set
              "status"
              ( object
                  [ "conditions"
                      .= [object ["type" .= ("Complete" :: Text), "status" .= ("True" :: Text)]]
                  ]
              )
              job
      writeWorld root world {objects = Map.insert key done (objects world)}
    _ -> fail "one isolated restore Job expected; producer Job must be absent"

runDownload :: FilePath -> Value -> IO ExitCode
runDownload root job = do
  let containers = case field "initContainers" (field "spec" (field "template" (field "spec" job))) of
        Array values -> toList values
        _ -> []
      download = case filter ((== String "download") . field "name") containers of
        [one] -> one
        _ -> error "one rendered download container expected"
      strings (Array values) = [T.unpack value | String value <- toList values]
      strings _ = error "expected rendered command array"
      variables = case field "env" download of
        Array values ->
          [ (T.unpack (textField "name" entry), T.unpack value)
          | entry <- toList values
          , String value <- [field "value" entry]
          ]
        _ -> []
      command = strings (field "command" download)
      args =
        map
          (T.unpack . T.replace "/dump/" (T.pack (root </> "dump/")) . T.pack)
          (strings (field "args" download))
  createDirectoryIfMissing True (root </> "bin")
  createDirectoryIfMissing True (root </> "dump")
  -- Exact URL/generation matching is independent of the generated environment.
  writeFile (root </> "bin/gcloud") $
    unlines
      [ "#!/bin/sh"
      , "set -eu"
      , "[ \"$1\" = storage ] && [ \"$2\" = cp ] && [ \"$3\" = --do-not-decompress ] || exit 91"
      , "case \"$4\" in"
      , "gs://bucket/manual-databases/default/pg-main/run-001.sql.gz#11) [ \"$5\" = \"$FIXTURE_ROOT/dump/backup.gz\" ] || exit 92; cp \"$FIXTURE_ROOT/archive.gz\" \"$5\";;"
      , "gs://bucket/manual-databases/default/pg-main/run-001.sql.gz.receipt.json#12) [ \"$5\" = \"$FIXTURE_ROOT/dump/backup.receipt.json\" ] || exit 92; cp \"$FIXTURE_ROOT/receipt.json\" \"$5\";;"
      , "*) exit 93;;"
      , "esac"
      ]
  setFileMode (root </> "bin/gcloud") 0o700
  parent <- getEnvironment
  let environment =
        variables
          <> [ ("PATH", root </> "bin" <> ":" <> maybe "" id (lookup "PATH" parent))
             , ("FIXTURE_ROOT", root)
             , ("HOME", root)
             ]
  case command of
    executable : options -> do
      (code, _, _) <-
        readCreateProcessWithExitCode
          ((proc executable (options <> args)) {env = Just environment})
          ""
      pure code
    _ -> fail "empty rendered command"
