-- | Real declaration compilers and persisted accepted input for the interpreter pilot.
module Nagare.Test.Effectful.Fixture
  ( RestoreFixture (..)
  , restoreFixture
  , seedFixture
  , seedAccepted
  , checked
  , must
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (forM_, toList)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Dsl.Database (Database (Database), Engine (Postgres), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Backup (ManualBackupRequest (..), compileManualBackupScope, manualBackupSourceIds)
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (..))
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Database (DatabaseBackupTarget (DatabaseBackupTarget))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.ManualReceipt (ManualReceiptEvidence (..), compileManualReceiptScope)
import Nagare.Inventory.Restore (ManualRestoreRequest (..), compileManualRestoreScope)
import Nagare.Inventory.Store
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue, encodeCanonicalScope)

data RestoreFixture = RestoreFixture
  { fixtureBinding :: !ContextBinding
  , fixtureAccepted :: ![ScopeDeclaration]
  , fixtureNative :: !(Map ResourceId (ManagedResource, ByteString))
  , fixtureRestore :: !ScopeDeclaration
  , fixtureRestoreNative :: !(Map ResourceId (ManagedResource, ByteString))
  , fixtureArchive :: !ByteString
  , fixtureReceipt :: !ByteString
  }

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

must :: (Show e) => IO (Either e a) -> IO a
must action = either (fail . show) pure =<< action

restoreFixture :: RestoreFixture
restoreFixture =
  RestoreFixture
    binding
    [foundation, databaseScope, record, neighbor]
    (Map.unions [foundationNative, databaseNative, neighborNative])
    restored
    restoredNative
    archive
    receipt
  where
    context = checked (mkContextId "effectful-restore")
    binding = ContextBinding context (checked (mkName "project"))
    platform = checked (mkScopeId Platform "foundation")
    clusterOwner = checked (mkScopeId Platform "cluster")
    cluster = mintResourceId clusterOwner (checked (mkLogicalKey "cluster")) (checked (mkName "cluster"))
    single owner key role value =
      let identity = mintResourceId owner (checked (mkLogicalKey key)) (checked (mkName role))
          bytes = checked (canonicalValue value)
          entry =
            checked
              ( bindKubernetesObject
                  ( KubernetesInput
                      identity
                      owner
                      cluster
                      value
                      (contentDigest bytes)
                      Retain
                      Stateless
                      Private
                      (SourceLocation "effectful-fixture" role)
                  )
              )
       in ( checked (mkScopeDeclaration owner [ResourceBundle [Managed (fst entry)] [] [] [] [] []])
          , Map.singleton identity entry
          )
    (foundation, foundationNative) =
      single
        platform
        "foundation"
        "namespace-default"
        ( object
            [ "apiVersion" .= ("v1" :: Text)
            , "kind" .= ("Namespace" :: Text)
            , "metadata" .= object ["name" .= ("default" :: Text)]
            ]
        )
    neighborOwner = checked (mkScopeId Standalone "neighbor")
    (neighbor, neighborNative) =
      single
        neighborOwner
        "neighbor"
        "configmap"
        ( object
            [ "apiVersion" .= ("v1" :: Text)
            , "kind" .= ("ConfigMap" :: Text)
            , "metadata" .= object ["name" .= ("neighbor" :: Text), "namespace" .= ("default" :: Text)]
            , "data" .= object ["row" .= ("unchanged" :: Text)]
            ]
        )
    owner = checked (mkScopeId Standalone "database-pg-main")
    database =
      Database
        (checked (mkDatabaseName "pg-main"))
        Nothing
        Postgres
        (defaultEngineVersion Postgres)
        (checked (Dsl.mkNamespace "default"))
        (checked (Dsl.mkQuantity "1Gi"))
        Nothing
        Dsl.Retain
    recovery =
      RecoveryIntent
        (checked (mkName "backup"))
        (mkSecretRef (checked (mkName "db-password")) (checked (mkName "v1")) :| [])
    backend = GcsBackend "project" "bucket"
    (databaseScope, databaseNative) =
      checked
        ( compileStandaloneDatabase
            (DatabaseDirectInput database owner cluster Nothing recovery (SourceLocation "fixture" "postgres"))
            (DatabaseBackupTarget backend HourlyRecoveryPoint)
        )
    revision scope = ScopeRevision (checked (mkScopeGeneration 1)) (contentDigest (encodeCanonicalScope scope))
    backupRequest =
      ManualBackupRequest
        "pg-main"
        "default"
        "run-001"
        Nothing
        (revision databaseScope)
        (checked (mkPhysicalIdentity "stateful-uid"))
        (checked (mkPhysicalIdentity "pvc-uid"))
        backend
        (SourceLocation "fixture" "backup")
        (maybe Map.empty (\(stateful, pvc) -> Map.fromList [(stateful, checked (mkPhysicalIdentity "stateful-uid")), (pvc, checked (mkPhysicalIdentity "pvc-uid"))]) (manualBackupSourceIds "pg-main" "default" databaseScope))
    (backup, backupNative) = checked (compileManualBackupScope backupRequest databaseScope databaseNative)
    metadataValues (Object fields) =
      [ value
      | KM.lookup "name" fields == Just (String "BACKUP_RECEIPT_METADATA")
      , Just (String value) <- [KM.lookup "value" fields]
      ]
        <> concatMap metadataValues (KM.elems fields)
    metadataValues (Array fields) = concatMap metadataValues (toList fields)
    metadataValues _ = []
    metadata = case concatMap (metadataValues . checked . eitherDecodeStrict . snd) (Map.elems backupNative) of
      [value] -> checked (eitherDecodeStrict (TE.encodeUtf8 value)) :: Value
      _ -> error "one backup receipt metadata expected"
    -- Deterministic gzip of CREATE TABLE restored (id integer);\n.
    archive = BS.pack [31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 115, 14, 114, 117, 12, 113, 85, 8, 113, 116, 242, 113, 85, 40, 74, 45, 46, 201, 47, 74, 77, 81, 208, 200, 76, 81, 200, 204, 43, 73, 77, 79, 45, 210, 180, 230, 2, 0, 73, 76, 183, 9, 36, 0, 0, 0]
    receipt =
      BL.toStrict
        ( encode
            ( object
                [ "version" .= (1 :: Int)
                , "sha256" .= digestText (contentDigest archive)
                , "backup" .= metadata
                ]
            )
        )
    record =
      checked
        ( compileManualReceiptScope
            (revision backup)
            backup
            backupNative
            ( ManualReceiptEvidence
                (checked (mkPhysicalIdentity "backup-job-uid"))
                "11"
                (fromIntegral (BS.length archive))
                (digestText (contentDigest archive))
                "12"
                (fromIntegral (BS.length receipt))
                receipt
            )
        )
    request =
      ManualRestoreRequest
        "pg-main"
        "default"
        "effectful-r1"
        record
        (revision record)
        receipt
        (revision databaseScope)
        (sourceStatefulUid backupRequest)
        (sourcePvcUid backupRequest)
        backend
        (SourceLocation "fixture" "restore")
    (restored, restoredNative) = checked (compileManualRestoreScope request databaseScope databaseNative)

seedFixture :: InventoryStore -> RestoreFixture -> IO ()
seedFixture store fixture = seedAccepted store (fixtureBinding fixture) (fixtureAccepted fixture) (fixtureNative fixture)

seedAccepted :: InventoryStore -> ContextBinding -> [ScopeDeclaration] -> Map ResourceId (ManagedResource, ByteString) -> IO ()
seedAccepted store binding scopes native = do
  initial <- must (initializeStore store binding "effectful-fixture")
  forM_ scopes $ \scope -> do
    let bytes = encodeCanonicalScope scope
    _ <- must (publishIfAbsent store (scopeKey (contentDigest bytes)) bytes)
    pure ()
  forM_ (Map.elems native) $ \(_, bytes) -> do
    _ <- must (publishIfAbsent store (objectKeyFor "native" (contentDigest bytes)) bytes)
    pure ()
  let accepted =
        Map.fromList
          [ ( scopeId scope
            , ScopeRevision
                (checked (mkScopeGeneration 1))
                (contentDigest (encodeCanonicalScope scope))
            )
          | scope <- scopes
          ]
  _ <-
    must
      ( replaceHeadIfGenerationMatches
          store
          (Just (headGeneration initial))
          initial
            { headGeneration = headGeneration initial + 1
            , headAccepted = accepted
            , headConverged = accepted
            }
      )
  pure ()
