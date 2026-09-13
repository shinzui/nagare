{-# LANGUAGE OverloadedStrings #-}

-- | Persisted, resumable platform-upgrade transactions.
module Nagare.Platform.Upgrade
  ( UpgradePhase (..)
  , PhaseState (..)
  , PhaseRecord (..)
  , TransactionState (..)
  , UpgradeTransaction (..)
  , UpgradeOps (..)
  , previewPhases
  , applyPhases
  , phaseToken
  , newUpgradeTransaction
  , planUpgrade
  , applyUpgrade
  , writeUpgradeTransaction
  , readUpgradeTransaction
  , renderUpgradeTransaction
  )
where

import Control.Exception (IOException, try)
import Data.Aeson ((.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath (takeDirectory)

data UpgradePhase
  = NixEvaluate
  | PulumiPreview
  | KubernetesDiff
  | PulumiApply
  | HostApply
  | KubernetesApply
  | ClusterStamp
  | ContextCommit
  deriving stock (Eq, Ord, Show)

data PhaseState = Pending | Succeeded | Failed
  deriving stock (Eq, Show)

data PhaseRecord = PhaseRecord
  { name :: !UpgradePhase
  , state :: !PhaseState
  , evidence :: !(Maybe Text)
  , updatedAt :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data TransactionState = Planning | Planned | Applying | TransactionFailed | Completed
  deriving stock (Eq, Show)

data UpgradeTransaction = UpgradeTransaction
  { schemaVersion :: !Int
  , id :: !Text
  , context :: !Text
  , previousVersion :: !(Maybe Text)
  , targetVersion :: !Text
  , payloadId :: !Text
  , payloadDigest :: !Text
  , workspaceRoot :: !FilePath
  , stagedHostRoot :: !FilePath
  , rollbackSupported :: !Bool
  , state :: !TransactionState
  , createdAt :: !Text
  , updatedAt :: !Text
  , phases :: ![PhaseRecord]
  }
  deriving stock (Generic, Eq, Show)

data UpgradeOps = UpgradeOps
  { runUpgradePhase :: !(UpgradePhase -> IO (Either Text Text))
  , upgradePhaseSatisfied :: !(UpgradePhase -> IO Bool)
  , saveUpgradeTransaction :: !(UpgradeTransaction -> IO ())
  , upgradeNow :: !(IO Text)
  }
  deriving stock (Generic)

previewPhases :: [UpgradePhase]
previewPhases = [NixEvaluate, PulumiPreview, KubernetesDiff]

applyPhases :: [UpgradePhase]
applyPhases = [PulumiApply, HostApply, KubernetesApply, ClusterStamp, ContextCommit]

phaseToken :: UpgradePhase -> Text
phaseToken NixEvaluate = "nix-evaluate"
phaseToken PulumiPreview = "pulumi-preview"
phaseToken KubernetesDiff = "kubernetes-diff"
phaseToken PulumiApply = "pulumi-apply"
phaseToken HostApply = "host-apply"
phaseToken KubernetesApply = "kubernetes-apply"
phaseToken ClusterStamp = "cluster-stamp"
phaseToken ContextCommit = "context-commit"

parsePhase :: Text -> Parser UpgradePhase
parsePhase value = case find ((== value) . phaseToken) (previewPhases <> applyPhases) of
  Just phase -> pure phase
  Nothing -> fail ("unknown upgrade phase: " <> T.unpack value)

stateToken :: TransactionState -> Text
stateToken Planning = "planning"
stateToken Planned = "planned"
stateToken Applying = "applying"
stateToken TransactionFailed = "failed"
stateToken Completed = "completed"

parseState :: Text -> Parser TransactionState
parseState "planning" = pure Planning
parseState "planned" = pure Planned
parseState "applying" = pure Applying
parseState "failed" = pure TransactionFailed
parseState "completed" = pure Completed
parseState other = fail ("unknown upgrade transaction state: " <> T.unpack other)

phaseStateToken :: PhaseState -> Text
phaseStateToken Pending = "pending"
phaseStateToken Succeeded = "succeeded"
phaseStateToken Failed = "failed"

parsePhaseState :: Text -> Parser PhaseState
parsePhaseState "pending" = pure Pending
parsePhaseState "succeeded" = pure Succeeded
parsePhaseState "failed" = pure Failed
parsePhaseState other = fail ("unknown upgrade phase state: " <> T.unpack other)

instance Aeson.ToJSON PhaseRecord where
  toJSON phase =
    Aeson.object
      [ "name" Aeson..= phaseToken (phase ^. #name)
      , "state" Aeson..= phaseStateToken (phase ^. #state)
      , "evidence" Aeson..= (phase ^. #evidence)
      , "updatedAt" Aeson..= (phase ^. #updatedAt)
      ]

instance Aeson.FromJSON PhaseRecord where
  parseJSON = Aeson.withObject "PhaseRecord" $ \o ->
    PhaseRecord
      <$> (o .: "name" >>= parsePhase)
      <*> (o .: "state" >>= parsePhaseState)
      <*> o .:? "evidence"
      <*> o .:? "updatedAt"

instance Aeson.ToJSON UpgradeTransaction where
  toJSON tx =
    Aeson.object
      [ "schemaVersion" Aeson..= (tx ^. #schemaVersion)
      , "id" Aeson..= (tx ^. #id)
      , "context" Aeson..= (tx ^. #context)
      , "previousVersion" Aeson..= (tx ^. #previousVersion)
      , "targetVersion" Aeson..= (tx ^. #targetVersion)
      , "payloadId" Aeson..= (tx ^. #payloadId)
      , "payloadDigest" Aeson..= (tx ^. #payloadDigest)
      , "workspaceRoot" Aeson..= (tx ^. #workspaceRoot)
      , "stagedHostRoot" Aeson..= (tx ^. #stagedHostRoot)
      , "rollbackSupported" Aeson..= (tx ^. #rollbackSupported)
      , "state" Aeson..= stateToken (tx ^. #state)
      , "createdAt" Aeson..= (tx ^. #createdAt)
      , "updatedAt" Aeson..= (tx ^. #updatedAt)
      , "phases" Aeson..= (tx ^. #phases)
      ]

instance Aeson.FromJSON UpgradeTransaction where
  parseJSON = Aeson.withObject "UpgradeTransaction" $ \o ->
    UpgradeTransaction
      <$> o .: "schemaVersion"
      <*> o .: "id"
      <*> o .: "context"
      <*> o .:? "previousVersion"
      <*> o .: "targetVersion"
      <*> o .: "payloadId"
      <*> o .: "payloadDigest"
      <*> o .: "workspaceRoot"
      <*> o .: "stagedHostRoot"
      <*> o .: "rollbackSupported"
      <*> (o .: "state" >>= parseState)
      <*> o .: "createdAt"
      <*> o .: "updatedAt"
      <*> o .: "phases"

newUpgradeTransaction :: Text -> Text -> Maybe Text -> Text -> Text -> Text -> FilePath -> FilePath -> Bool -> Text -> UpgradeTransaction
newUpgradeTransaction txId context oldVersion newVersion newPayloadId digest workspace hostRoot supportsRollback now =
  UpgradeTransaction
    { schemaVersion = 1
    , id = txId
    , context = context
    , previousVersion = oldVersion
    , targetVersion = newVersion
    , payloadId = newPayloadId
    , payloadDigest = digest
    , workspaceRoot = workspace
    , stagedHostRoot = hostRoot
    , rollbackSupported = supportsRollback
    , state = Planning
    , createdAt = now
    , updatedAt = now
    , phases = map (\name -> PhaseRecord name Pending Nothing Nothing) (previewPhases <> applyPhases)
    }

planUpgrade :: UpgradeOps -> UpgradeTransaction -> IO (Either Text UpgradeTransaction)
planUpgrade ops tx = runPhases False ops (tx & #state .~ Planning) previewPhases Planned

applyUpgrade :: Bool -> UpgradeOps -> UpgradeTransaction -> IO (Either Text UpgradeTransaction)
applyUpgrade resume ops tx
  | tx ^. #state == Completed = pure (Right tx)
  | not (all (phaseSucceeded tx) previewPhases) = pure (Left "upgrade has no successful plan; run the plan phase before --apply")
  | otherwise = runPhases resume ops (tx & #state .~ Applying) applyPhases Completed

phaseSucceeded :: UpgradeTransaction -> UpgradePhase -> Bool
phaseSucceeded tx wanted = case find (\phase -> phase ^. #name == wanted) (tx ^. #phases) of
  Just phase -> phase ^. #state == Succeeded
  Nothing -> False

runPhases :: Bool -> UpgradeOps -> UpgradeTransaction -> [UpgradePhase] -> TransactionState -> IO (Either Text UpgradeTransaction)
runPhases resume ops initial phases finalState = do
  started <- touchState ops initial (initial ^. #state)
  go started phases
  where
    go tx [] = Right <$> touchState ops tx finalState
    go tx (name : rest) = do
      satisfied <- if resume && phaseSucceeded tx name then (ops ^. #upgradePhaseSatisfied) name else pure False
      if satisfied
        then go tx rest
        else do
          result <- (ops ^. #runUpgradePhase) name
          now <- ops ^. #upgradeNow
          case result of
            Left err -> do
              let failed = updatePhase name Failed (Just err) now (tx & #state .~ TransactionFailed & #updatedAt .~ now)
              (ops ^. #saveUpgradeTransaction) failed
              pure (Left (phaseToken name <> " failed: " <> err))
            Right evidence -> do
              let succeeded = updatePhase name Succeeded (nonEmpty evidence) now (tx & #updatedAt .~ now)
              (ops ^. #saveUpgradeTransaction) succeeded
              go succeeded rest
    nonEmpty value = if T.null (T.strip value) then Nothing else Just (T.take 4096 value)

touchState :: UpgradeOps -> UpgradeTransaction -> TransactionState -> IO UpgradeTransaction
touchState ops tx newState = do
  now <- ops ^. #upgradeNow
  let updated = tx & #state .~ newState & #updatedAt .~ now
  (ops ^. #saveUpgradeTransaction) updated
  pure updated

updatePhase :: UpgradePhase -> PhaseState -> Maybe Text -> Text -> UpgradeTransaction -> UpgradeTransaction
updatePhase wanted state evidence now tx =
  tx & #phases %~ map update
  where
    update phase
      | phase ^. #name == wanted = phase & #state .~ state & #evidence .~ evidence & #updatedAt ?~ now
      | otherwise = phase

writeUpgradeTransaction :: FilePath -> UpgradeTransaction -> IO ()
writeUpgradeTransaction path tx = do
  createDirectoryIfMissing True (takeDirectory path)
  let temporary = path <> ".tmp"
  LBS.writeFile temporary (Aeson.encode tx)
  renameFile temporary path

readUpgradeTransaction :: FilePath -> IO (Either Text UpgradeTransaction)
readUpgradeTransaction path = do
  result <- try (BS.readFile path)
  pure $ case result of
    Left (err :: IOException) -> Left ("could not read upgrade transaction " <> T.pack path <> ": " <> T.pack (show err))
    Right bytes -> case Aeson.eitherDecodeStrict' bytes of
      Left err -> Left ("invalid upgrade transaction " <> T.pack path <> ": " <> T.pack err)
      Right tx
        | tx ^. #schemaVersion /= 1 -> Left ("unsupported upgrade transaction schema " <> T.pack (show (tx ^. #schemaVersion)))
        | otherwise -> Right tx

renderUpgradeTransaction :: UpgradeTransaction -> Text
renderUpgradeTransaction tx =
  T.unlines $
    [ "Upgrade " <> tx ^. #id <> " (" <> tx ^. #context <> ")"
    , "State: " <> stateToken (tx ^. #state)
    , "Version: " <> maybe "legacy" (\value -> value) (tx ^. #previousVersion) <> " -> " <> tx ^. #targetVersion
    , "Workspace: " <> T.pack (tx ^. #workspaceRoot)
    , "Host stage: " <> T.pack (tx ^. #stagedHostRoot)
    , "Rollback: " <> if tx ^. #rollbackSupported then "release selection supported" else "manual only"
    , "Phases:"
    ]
      <> map renderPhase (tx ^. #phases)
  where
    renderPhase phase =
      "  "
        <> phaseToken (phase ^. #name)
        <> ": "
        <> phaseStateToken (phase ^. #state)
        <> maybe "" (" — " <>) (phase ^. #evidence)
