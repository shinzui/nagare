{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- Synthetic accepted database and completed manual backup for the public CLI
-- fixture. It writes only to the caller's disposable filesystem store.
module Main where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cluster.GcsJob (MinioRef (..), StoreBackend (MinioBackend))
import Nagare.Dsl.Database (Database (Database), Engine (Postgres), defaultEngineVersion, mkDatabaseName)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types qualified as Dsl
import Nagare.Inventory.Backup (ManualBackupRequest (..), compileManualBackupScope)
import Nagare.Inventory.DataService (compileStandaloneDatabase)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Store
import Nagare.Resource.Database (DatabaseDirectInput (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), RecoveryIntent (..), Sensitivity (Private), mkSecretRef)
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue, encodeCanonicalScope)
import System.Environment (getArgs)
import System.FilePath ((</>))

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

must :: (Show e) => IO (Either e a) -> IO a
must action = either (error . show) id <$> action

metadataValues :: Value -> [Text]
metadataValues (Object fields) =
    [ value
    | KM.lookup "name" fields == Just (String "BACKUP_RECEIPT_METADATA")
    , Just (String value) <- [KM.lookup "value" fields]
    ]
        <> concatMap metadataValues (KM.elems fields)
metadataValues (Array values) = concatMap metadataValues (toList values)
metadataValues _ = []

main :: IO ()
main = do
    [storePath, output] <- getArgs
    let context = ok (mkContextId "manual-receipt-fixture")
        binding = ContextBinding context (ok (mkName "project"))
        dbOwner = ok (mkScopeId Standalone "database-pg-main")
        platform = ok (mkScopeId Platform "foundation")
        clusterOwner = ok (mkScopeId Platform "cluster")
        cluster = mintResourceId clusterOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
        namespaceId =
            mintResourceId
                platform
                (ok (mkLogicalKey "foundation"))
                (ok (mkName "namespace-default"))
        namespaceValue =
            object
                [ "apiVersion" .= ("v1" :: Text)
                , "kind" .= ("Namespace" :: Text)
                , "metadata" .= object ["name" .= ("default" :: Text)]
                ]
        namespaceBytes = ok (canonicalValue namespaceValue)
        namespaceMember =
            ok
                ( bindKubernetesObject
                    ( KubernetesInput
                        namespaceId
                        platform
                        cluster
                        namespaceValue
                        (contentDigest namespaceBytes)
                        Retain
                        Stateless
                        Private
                        (SourceLocation "foundation" "fixture")
                    )
                )
        foundationScope =
            ok
                ( mkScopeDeclaration
                    platform
                    [ResourceBundle [Managed (fst namespaceMember)] [] [] [] [] []]
                )
        neighborOwner = ok (mkScopeId Standalone "neighbor")
        neighborId =
            mintResourceId
                neighborOwner
                (ok (mkLogicalKey "neighbor"))
                (ok (mkName "configmap"))
        neighborValue =
            object
                [ "apiVersion" .= ("v1" :: Text)
                , "kind" .= ("ConfigMap" :: Text)
                , "metadata"
                    .= object
                        [ "name" .= ("neighbor" :: Text)
                        , "namespace" .= ("default" :: Text)
                        ]
                , "data" .= object ["value" .= ("unchanged" :: Text)]
                ]
        neighborBytes = ok (canonicalValue neighborValue)
        neighborMember =
            ok
                ( bindKubernetesObject
                    ( KubernetesInput
                        neighborId
                        neighborOwner
                        cluster
                        neighborValue
                        (contentDigest neighborBytes)
                        Retain
                        Stateless
                        Private
                        (SourceLocation "neighbor" "fixture")
                    )
                )
        neighborScope =
            ok
                ( mkScopeDeclaration
                    neighborOwner
                    [ResourceBundle [Managed (fst neighborMember)] [] [] [] [] []]
                )
        database =
            Database
                (ok (mkDatabaseName "pg-main"))
                Nothing
                Postgres
                (defaultEngineVersion Postgres)
                (ok (Dsl.mkNamespace "default"))
                (ok (Dsl.mkQuantity "10Gi"))
                Nothing
                Dsl.Retain
        recovery =
            RecoveryIntent
                (ok (mkName "backup"))
                (mkSecretRef (ok (mkName "db-password")) (ok (mkName "v1")) :| [])
        direct =
            DatabaseDirectInput
                database
                dbOwner
                cluster
                Nothing
                recovery
                (SourceLocation "database" "fixture")
        backend =
            MinioBackend
                ( MinioRef
                    "http://minio.nagare-system.svc.cluster.local:9000"
                    "bucket"
                    "minio-credentials"
                )
        (databaseScope, databaseNative) = ok (compileStandaloneDatabase direct backend)
        foundationNative = Map.singleton namespaceId namespaceMember
        neighborNative = Map.singleton neighborId neighborMember
        databaseRevision =
            ScopeRevision
                (ok (mkScopeGeneration 1))
                (contentDigest (encodeCanonicalScope databaseScope))
        request =
            ManualBackupRequest
                { databaseName = "pg-main"
                , namespaceName = "default"
                , backupId = "run-001"
                , expiresAt = Nothing
                , sourceRevision = databaseRevision
                , sourceStatefulUid = ok (mkPhysicalIdentity "stateful-uid")
                , sourcePvcUid = ok (mkPhysicalIdentity "pvc-uid")
                , storageBackend = backend
                , backupSource = SourceLocation "db backup" "run-001"
                }
        (backupScope, backupNative) =
            ok
                (compileManualBackupScope request databaseScope databaseNative)
        backupRevision =
            ScopeRevision
                (ok (mkScopeGeneration 1))
                (contentDigest (encodeCanonicalScope backupScope))
        (backupJob, jobBytes) = case Map.elems backupNative of
            [entry] -> entry
            _ -> error "fixture needs one backup Job"
        metadataJson = case metadataValues (ok (eitherDecodeStrict jobBytes)) of
            [one] -> one
            _ -> error "fixture Job lacks one receipt metadata value"
        archive = BC.pack "accepted-manual-archive-fixture"
        checksum = digestText (contentDigest archive)
        receipt =
            BL.toStrict
                ( encode
                    ( object
                        [ "version" .= (1 :: Int)
                        , "sha256" .= checksum
                        , "backup" .= (ok (eitherDecodeStrict (TE.encodeUtf8 metadataJson)) :: Value)
                        ]
                    )
                )
        native = Map.unions [foundationNative, neighborNative, databaseNative, backupNative]
    store <- must (openFilesystemStore storePath)
    initial <- must (initializeStore store binding "manual-fixture")
    forM_ [foundationScope, neighborScope, databaseScope, backupScope] $ \scope -> do
        let bytes = encodeCanonicalScope scope
        _ <- must (publishIfAbsent store (scopeKey (contentDigest bytes)) bytes)
        pure ()
    forM_ (Map.elems native) $ \(_, bytes) -> do
        _ <- must (publishIfAbsent store (objectKeyFor "native" (contentDigest bytes)) bytes)
        pure ()
    let accepted =
            Map.fromList
                [
                    ( scopeId foundationScope
                    , ScopeRevision
                        (ok (mkScopeGeneration 1))
                        (contentDigest (encodeCanonicalScope foundationScope))
                    )
                ,
                    ( scopeId neighborScope
                    , ScopeRevision
                        (ok (mkScopeGeneration 1))
                        (contentDigest (encodeCanonicalScope neighborScope))
                    )
                , (scopeId databaseScope, databaseRevision)
                , (scopeId backupScope, backupRevision)
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
    BS.writeFile (output </> "archive") archive
    BS.writeFile (output </> "receipt.json") receipt
    BS.writeFile
        (output </> "native.json")
        ( BL.toStrict
            ( encode
                [ object
                    [ "resource" .= resourceIdText (member ^. #identity)
                    , "digest" .= digestText (contentDigest bytes)
                    , "native" .= (ok (eitherDecodeStrict bytes) :: Value)
                    ]
                | (member, bytes) <- Map.elems native
                ]
            )
        )
    BS.writeFile
        (output </> "fixture.json")
        ( BL.toStrict
            ( encode
                ( object
                    [ "backupJob" .= resourceIdText (backupJob ^. #identity)
                    , "backupJobUid" .= ("backup-job-uid" :: Text)
                    , "backupObject" .= (scopeOverrides backupScope Map.! "backup.object")
                    , "backupReceipt" .= (scopeOverrides backupScope Map.! "backup.receipt")
                    , "databaseScope" .= scopeIdText (scopeId databaseScope)
                    , "backupScope" .= scopeIdText (scopeId backupScope)
                    , "neighborScope" .= scopeIdText (scopeId neighborScope)
                    ]
                )
            )
        )
