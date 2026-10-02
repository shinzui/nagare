-- | Recovery responsibilities; internal implementation behind Nagare.Inventory.Application.
module Nagare.Inventory.Application.Recovery
  ( applicationVolumeRecoveryBindings
  , databaseRecoveryBindings
  , standaloneWorkerVolumeRecoveryBindings
  )
where

import Data.Generics.Labels ()
import Data.List (find)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Application (Application)
import Nagare.Dsl.Database (dbSecretName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types
  ( DatabaseName
  , VolumeName
  , databaseNameText
  , serviceNameText
  , volumeNameText
  )
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Dsl.Worker (Worker (..))
import Nagare.Resource.Application
  ( applicationScopeId
  , volumeResourceId
  )
import Nagare.Resource.Policy (RecoveryIntent (..), mkSecretRef)
import Nagare.Resource.Types
  ( ResourceId
  , ScopeId
  , logicalKeyText
  , mkLogicalKey
  , mkName
  )

-- | Require one explicit recovery binding for every application-owned
-- database. The credential name is derived from the typed database identity;
-- the operator supplies only the backup identity and key version.
databaseRecoveryBindings :: Application -> [T.Text] -> Either T.Text (Map DatabaseName RecoveryIntent)
databaseRecoveryBindings app raw = do
  pairs <- traverse parseOne raw
  let bindings = Map.fromList pairs
      declared = Set.fromList (map (^. #name) (app ^. #databases))
  unless
    (length pairs == Map.size bindings)
    (Left "database recovery bindings repeat a database")
  unless
    (Map.keysSet bindings == declared)
    (Left "database recovery bindings must cover exactly the declared databases")
  pure bindings
  where
    parseOne value = case (T.splitOn "=" value) of
      [databaseText, recoveryText] -> case T.splitOn ":" recoveryText of
        [backupText, versionText] -> do
          database <-
            maybe
              (Left "database recovery names an undeclared database")
              Right
              (find ((== databaseText) . databaseNameText . (^. #name)) (app ^. #databases))
          backup <- mkName backupText
          version <- mkName versionText
          credential <- mkName (dbSecretName databaseText)
          pure (database ^. #name, RecoveryIntent backup (mkSecretRef credential version NE.:| []))
        _ -> Left "database recovery must be NAME=BACKUP:KEY_VERSION"
      _ -> Left "database recovery must be NAME=BACKUP:KEY_VERSION"

-- | Bind retained PVC recovery by typed Service volume name and by each
-- worker volume's stable ResourceId. Throwaway volumes cannot borrow a
-- recovery decision, and a missing retained volume refuses planning.
applicationVolumeRecoveryBindings ::
  Application ->
  [T.Text] ->
  [T.Text] ->
  Either T.Text (Map VolumeName RecoveryIntent, Map ResourceId RecoveryIntent)
applicationVolumeRecoveryBindings app serviceRaw workerRaw = do
  owner <- applicationScopeId app
  servicePairs <- traverse parseService serviceRaw
  workerPairs <- traverse (parseWorker owner) workerRaw
  let serviceBindings = Map.fromList servicePairs
      workerBindings = Map.fromList workerPairs
      serviceExpected =
        Set.fromList
          [ volume ^. #name
          | service <- maybe [] pure (app ^. #service)
          , volume <- service ^. #volumes
          , volume ^. #retention == Dsl.Retain
          ]
  workerExpected <-
    Set.fromList
      <$> traverse
        (workerVolumeId owner)
        [ (worker, volume)
        | worker <- app ^. #workers
        , volume <- worker ^. #volumes
        , volume ^. #retention == Dsl.Retain
        ]
  unless
    ( length servicePairs == Map.size serviceBindings
        && Map.keysSet serviceBindings == serviceExpected
    )
    (Left "service volume recovery must cover exactly the retained volumes")
  unless
    ( length workerPairs == Map.size workerBindings
        && Map.keysSet workerBindings == workerExpected
    )
    (Left "worker volume recovery must cover exactly the retained volumes")
  pure (serviceBindings, workerBindings)
  where
    parseRecovery value = case T.splitOn ":" value of
      [backupText, keyText, versionText] -> do
        backup <- mkName backupText
        key <- mkName keyText
        version <- mkName versionText
        pure (RecoveryIntent backup (mkSecretRef key version NE.:| []))
      _ -> Left "volume recovery must be BACKUP:KEY:VERSION"
    parseService value = case T.splitOn "=" value of
      [volumeText, recoveryText] -> do
        volume <-
          maybe
            (Left "service volume recovery names an undeclared volume")
            Right
            ( find
                ((== volumeText) . volumeNameText . (^. #name))
                (maybe [] (^. #volumes) (app ^. #service))
            )
        recovery <- parseRecovery recoveryText
        pure (volume ^. #name, recovery)
      _ -> Left "service volume recovery must be VOLUME=BACKUP:KEY:VERSION"
    parseWorker owner value = case T.splitOn "=" value of
      [workloadText, recoveryText] -> case T.splitOn "/" workloadText of
        [workerText, volumeText] -> do
          worker <-
            maybe
              (Left "worker volume recovery names an undeclared worker")
              Right
              (find ((== workerText) . serviceNameText . (^. #name)) (app ^. #workers))
          volume <-
            maybe
              (Left "worker volume recovery names an undeclared volume")
              Right
              (find ((== volumeText) . volumeNameText . (^. #name)) (worker ^. #volumes))
          resourceId <- workerVolumeId owner (worker, volume)
          recovery <- parseRecovery recoveryText
          pure (resourceId, recovery)
        _ -> Left "worker volume recovery must be WORKER/VOLUME=BACKUP:KEY:VERSION"
      _ -> Left "worker volume recovery must be WORKER/VOLUME=BACKUP:KEY:VERSION"
    workerVolumeId owner (worker, volume) = do
      workerKey <-
        maybe
          (mkLogicalKey (serviceNameText (worker ^. #name)))
          Right
          (worker ^. #logicalKey)
      role <- mkName ("worker-" <> logicalKeyText workerKey <> "-pvc")
      volumeResourceId owner role volume

standaloneWorkerVolumeRecoveryBindings ::
  ScopeId -> Worker -> [T.Text] -> Either T.Text (Map ResourceId RecoveryIntent)
standaloneWorkerVolumeRecoveryBindings owner worker raw = do
  workerKey <-
    maybe
      (mkLogicalKey (serviceNameText (worker ^. #name)))
      Right
      (worker ^. #logicalKey)
  role <- mkName ("worker-" <> logicalKeyText workerKey <> "-pvc")
  pairs <- traverse (parseOne role) raw
  expected <-
    Set.fromList
      <$> traverse
        (volumeResourceId owner role)
        [volume | volume <- worker ^. #volumes, volume ^. #retention == Dsl.Retain]
  let bindings = Map.fromList pairs
  unless
    (length pairs == Map.size bindings && Map.keysSet bindings == expected)
    (Left "standalone worker recovery must cover exactly the retained volumes")
  pure bindings
  where
    parseOne role value = case T.splitOn "=" value of
      [volumeText, recoveryText] -> case T.splitOn ":" recoveryText of
        [backupText, keyText, versionText] -> do
          volume <-
            maybe
              (Left "worker recovery names an undeclared volume")
              Right
              (find ((== volumeText) . volumeNameText . (^. #name)) (worker ^. #volumes))
          unless
            (volume ^. #retention == Dsl.Retain)
            (Left "throwaway worker volume cannot have recovery intent")
          resourceId <- volumeResourceId owner role volume
          backup <- mkName backupText
          key <- mkName keyText
          version <- mkName versionText
          pure (resourceId, RecoveryIntent backup (mkSecretRef key version NE.:| []))
        _ -> Left "worker recovery must be VOLUME=BACKUP:KEY:VERSION"
      _ -> Left "worker recovery must be VOLUME=BACKUP:KEY:VERSION"
