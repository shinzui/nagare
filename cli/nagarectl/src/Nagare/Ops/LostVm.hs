-- | Record that the context's VM is gone. Pulumi only learns this from a refresh,
-- so until then every reviewed read keeps reporting the VM as converged (F142).
module Nagare.Ops.LostVm
  ( LostVmOps (..)
  , VmPresence (..)
  , forgetLostVm
  , instanceUrn
  , refreshDropsOnly
  , vmPresenceFromGcloud
  )
where

import Data.Aeson (FromJSON (parseJSON), eitherDecodeStrict', withObject, (.!=), (.:), (.:?))
import Data.ByteString (ByteString)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import System.Exit (ExitCode (ExitSuccess))

data VmPresence = VmPresent | VmConfirmedAbsent
  deriving stock (Eq, Show)

data LostVmOps = LostVmOps
  { lostVmPresence :: !(IO (Either Text VmPresence))
  , lostVmStackExport :: !(IO (Either Text ByteString))
  , lostVmRefreshPreview :: !(Text -> IO (Either Text ByteString))
  , lostVmRefresh :: !(Text -> IO (Either Text ()))
  }

-- | Only gcloud's own not-found is a loss: a failed or denied read proves nothing.
vmPresenceFromGcloud :: ExitCode -> Text -> Either Text VmPresence
vmPresenceFromGcloud ExitSuccess _ = Right VmPresent
vmPresenceFromGcloud _ err
  | "was not found" `T.isInfixOf` err = Right VmConfirmedAbsent
  | otherwise = Left ("could not read the VM: " <> err)

newtype StackExport = StackExport [StackResource]

data StackResource = StackResource !Text !Text

instance FromJSON StackExport where
  parseJSON = withObject "stack export" $ \value -> do
    deployment <- value .: "deployment"
    StackExport <$> (deployment .:? "resources" .!= [])

instance FromJSON StackResource where
  parseJSON = withObject "stack resource" $ \value -> StackResource <$> value .: "type" <*> value .: "urn"

-- | The stack's one record of this instance.
instanceUrn :: Text -> ByteString -> Either Text (Maybe Text)
instanceUrn instanceName exported = do
  StackExport resources <- first T.pack (eitherDecodeStrict' exported)
  case [urn | StackResource kind urn <- resources, kind == "gcp:compute/instance:Instance", ("::" <> instanceName) `T.isSuffixOf` urn] of
    [] -> Right Nothing
    [urn] -> Right (Just urn)
    _ -> Left ("the stack records more than one instance named " <> instanceName)

newtype RefreshPreview = RefreshPreview [RefreshStep]

data RefreshStep = RefreshStep !Text !Text

instance FromJSON RefreshPreview where
  parseJSON = withObject "refresh preview" $ \value -> RefreshPreview <$> value .:? "steps" .!= []

instance FromJSON RefreshStep where
  parseJSON = withObject "refresh step" $ \value -> RefreshStep <$> value .: "op" <*> value .: "urn"

-- | A refresh may drop the VM and nothing else: the data disk's record must survive.
refreshDropsOnly :: Text -> ByteString -> Either Text ()
refreshDropsOnly urn previewed = do
  RefreshPreview steps <- first T.pack (eitherDecodeStrict' previewed)
  let changes = [(action, target) | RefreshStep action target <- steps, action `notElem` ["same", "refresh"]]
  if changes == [("delete", urn)]
    then Right ()
    else Left ("the refresh would change more than the lost VM: " <> T.pack (show changes))

-- | Refuses unless GCP confirms the VM is gone and the refresh touches only its record.
-- Writes Pulumi state only, so nothing in the project changes.
forgetLostVm :: LostVmOps -> Text -> IO (Either Text Text)
forgetLostVm ops instanceName =
  lostVmPresence ops >>= \case
    Left err -> pure (Left err)
    Right VmPresent -> pure (Left (instanceName <> " still exists; nothing is lost"))
    Right VmConfirmedAbsent ->
      lostVmStackExport ops >>= \case
        Left err -> pure (Left err)
        Right exported -> case instanceUrn instanceName exported of
          Left err -> pure (Left err)
          Right Nothing -> pure (Right (instanceName <> " is already gone from the stack"))
          Right (Just urn) ->
            lostVmRefreshPreview ops urn >>= \case
              Left err -> pure (Left err)
              Right previewed -> case refreshDropsOnly urn previewed of
                Left err -> pure (Left err)
                Right () ->
                  fmap (const (instanceName <> " is gone from the stack")) <$> lostVmRefresh ops urn
