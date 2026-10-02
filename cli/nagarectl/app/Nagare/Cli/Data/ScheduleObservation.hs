-- | Data / ScheduleObservation. Executable-private CLI boundary.
module Nagare.Cli.Data.ScheduleObservation
  ( scheduledProducerInFlight
  )
where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as AesonMap
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Dsl.Prelude
import Nagare.Resource.Types qualified as Resource
import System.Exit (ExitCode (ExitSuccess))
import System.Process (readProcessWithExitCode)

scheduledProducerInFlight :: Text -> Text -> Resource.PhysicalIdentity -> IO Bool
scheduledProducerInFlight contextName namespaceName cronUid = do
  outcome <-
    try
      ( readProcessWithExitCode
          "kubectl"
          [ "--context"
          , T.unpack contextName
          , "-n"
          , T.unpack namespaceName
          , "get"
          , "jobs"
          , "-o"
          , "json"
          ]
          ""
      ) ::
      IO (Either IOException (ExitCode, String, String))
  body <- case outcome of
    Right (ExitSuccess, output, _) -> pure (BC.pack output)
    _ -> dieT "cannot inspect scheduled backup producer Jobs"
  jobs <- case Aeson.eitherDecodeStrict body of
    Right (Aeson.Object root)
      | Just (Aeson.Array items) <- AesonMap.lookup "items" root ->
          pure (foldr (:) [] items)
    _ -> dieT "scheduled backup producer Job listing is malformed"
  let ownerId = Resource.physicalIdentityText cronUid
      owned (Aeson.Object item) = case AesonMap.lookup "metadata" item of
        Just (Aeson.Object metadata) -> case AesonMap.lookup "ownerReferences" metadata of
          Just (Aeson.Array references) ->
            any
              ( \case
                  Aeson.Object reference ->
                    AesonMap.lookup "uid" reference
                      == Just (Aeson.String ownerId)
                  _ -> False
              )
              references
          _ -> False
        _ -> False
      owned _ = False
      unfinished (Aeson.Object item) = case AesonMap.lookup "status" item of
        Just (Aeson.Object status) ->
          let succeeded = case AesonMap.lookup "succeeded" status of
                Just (Aeson.Number count) -> count > 0
                _ -> False
              activeCount = case AesonMap.lookup "active" status of
                Just (Aeson.Number count) -> count > 0
                _ -> False
           in not succeeded || activeCount
        _ -> True
      unfinished _ = True
  pure (any (\job -> owned job && unfinished job) jobs)
