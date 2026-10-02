{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- Seed a disposable accepted legacy web scope and an independent data scope.
module Main where

import Control.Monad (forM_)
import Data.Aeson (Value, eitherDecodeStrict, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..), parseKubernetesManifest)
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (..), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (CandidateInput (..), candidateInputValue, canonicalValue, encodeCanonicalScope)
import System.Environment (getArgs)
import System.FilePath ((</>))

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

must :: (Show e) => IO (Either e a) -> IO a
must action = either (error . show) id <$> action

main :: IO ()
main = do
    [storePath, output, manifestPath, mode] <- getArgs
    let partial = mode /= "whole" && mode /= "knative-whole"
        knative = mode == "knative-whole" || mode == "knative-retain-data" || mode == "knative-partial"
    let context = ok (mkContextId "web-cleanup-fixture")
        binding = ContextBinding context (ok (mkName "project"))
        owner = ok (mkScopeId Application "web-cleanup")
        dataOwner = if partial then owner else ok (mkScopeId Standalone "web-cleanup-data")
        clusterOwner = ok (mkScopeId Platform "cluster")
        neighborScope = ok (mkScopeDeclaration clusterOwner [ResourceBundle [] [] [] [] [] []])
        cluster = mintResourceId clusterOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
        webKey = ok (mkLogicalKey "web")
        dataKey = ok (mkLogicalKey "database")
        serviceId = mintResourceId owner webKey (ok (mkName "service"))
        historyId = mintResourceId owner webKey (ok (mkName "release-history"))
        routeId = mintResourceId owner webKey (ok (mkName "domain-mapping"))
        databaseId = mintResourceId dataOwner dataKey (ok (mkName "statefulset"))
        pvcId = mintResourceId dataOwner dataKey (ok (mkName "pvc"))
        backupId = mintResourceId dataOwner dataKey (ok (mkName "backup-job"))
        source =
            SourceLocation
                (if knative then "scripts/fixtures/knative-web-cleanup-native.yaml" else "scripts/fixtures/web-cleanup-native.yaml")
                "web-cleanup"
        bind selectedOwner selectedId location value policy =
            let bytes = ok (canonicalValue value)
                declaration =
                    ok
                        ( bindKubernetesObject
                            ( KubernetesInput
                                selectedId
                                selectedOwner
                                cluster
                                value
                                (contentDigest bytes)
                                policy
                                Stateless
                                Private
                                location
                            )
                        )
             in declaration
    manifest <- BS.readFile manifestPath
    let documents = ok (parseKubernetesManifest source manifest)
        [ (serviceLocation, serviceValue)
            , (historyLocation, historyValue)
            , (routeLocation, routeValue)
            , (databaseLocation, databaseValue)
            , (pvcLocation, pvcValue)
            , (backupLocation, backupValue)
            ] = documents
        database = bind dataOwner databaseId databaseLocation databaseValue Retain
        pvc = bind dataOwner pvcId pvcLocation pvcValue Retain
        backup = bind dataOwner backupId backupLocation backupValue Retain
        dataScope =
            ok
                ( mkScopeDeclaration
                    dataOwner
                    [ResourceBundle (map (Managed . fst) [database, pvc, backup]) [] [] [] [] []]
                )
        service = bind owner serviceId serviceLocation serviceValue DeleteWhenUnreferenced
        history = bind owner historyId historyLocation historyValue Retain
        route = bind owner routeId routeLocation routeValue DeleteWhenUnreferenced
        withDependency (member, bytes) = (member{dependencies = [OrderedAfter serviceId]}, bytes)
        oldHistory = withDependency history
        newHistory = ((fst oldHistory){lifecycle = DeleteWhenUnreferenced}, snd oldHistory)
        routeMember = withDependency route
        scopeFor selectedHistory =
            ok
                ( mkScopeDeclaration
                    owner
                    [ ResourceBundle
                        ( map
                            (Managed . fst)
                            ([service, selectedHistory, routeMember] <> [d | partial, d <- [database, pvc, backup]])
                        )
                        []
                        []
                        []
                        []
                        []
                    ]
                )
        oldScope = scopeFor oldHistory
        newScope = scopeFor newHistory
        native =
            Map.fromList
                [ (member ^. #identity, (member, bytes))
                | (member, bytes) <-
                    [service, oldHistory, routeMember, database, pvc, backup]
                ]
        revision scope =
            ScopeRevision
                (ok (mkScopeGeneration 1))
                (contentDigest (encodeCanonicalScope scope))
        accepted =
            Map.fromList
                ([(owner, revision oldScope), (clusterOwner, revision neighborScope)] <> [(dataOwner, revision dataScope) | not partial])
        snapshot =
            ok
                ( mkScopeSnapshot
                    binding
                    ( Map.fromList
                        ( [(owner, (ok (mkScopeGeneration 1), oldScope)), (clusterOwner, (ok (mkScopeGeneration 1), neighborScope))]
                            <> [(dataOwner, (ok (mkScopeGeneration 1), dataScope)) | not partial]
                        )
                    )
                    Map.empty
                )
        candidate =
            ok
                ( canonicalValue
                    ( candidateInputValue
                        (CandidateInput snapshot (ReplaceScope newScope :| []))
                    )
                )
    store <- must (openFilesystemStore storePath)
    initial <- must (initializeStore store binding "web-cleanup-fixture")
    forM_ [oldScope, dataScope, neighborScope] $ \scope -> do
        let bytes = encodeCanonicalScope scope
        _ <- must (publishIfAbsent store (scopeKey (contentDigest bytes)) bytes)
        pure ()
    forM_ (Map.elems native) $ \(_, bytes) -> do
        _ <- must (publishIfAbsent store (objectKeyFor "native" (contentDigest bytes)) bytes)
        pure ()
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
    BS.writeFile (output </> "candidate-input.json") candidate
    BS.writeFile
        (output </> "native.json")
        ( BL.toStrict
            ( encode
                [ object
                    [ "resource" .= resourceIdText selectedId
                    , "digest" .= digestText (contentDigest bytes)
                    , "native" .= (ok (eitherDecodeStrict bytes) :: Value)
                    ]
                | (selectedId, (_, bytes)) <- Map.toList native
                ]
            )
        )
    BS.writeFile
        (output </> "fixture.json")
        ( BL.toStrict
            ( encode
                ( object
                    [ "service" .= resourceIdText serviceId
                    , "history" .= resourceIdText historyId
                    , "route" .= resourceIdText routeId
                    , "dataScope" .= scopeIdText dataOwner
                    , "webScope" .= scopeIdText owner
                    ]
                )
            )
        )
