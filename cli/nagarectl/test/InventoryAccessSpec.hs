module InventoryAccessSpec (inventoryAccessTests) where

import Control.Monad (forM_, void)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Access.Grants (accessTuple)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Access
import Nagare.Inventory.AccessRuntime
import Nagare.Inventory.Adapter
import Nagare.Inventory.BackendMap (compileContributedBackendMaps, compileContributedShomeiSettings)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Plan (loadInventoryHistory)
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

inventoryAccessTests :: TestTree
inventoryAccessTests =
  testGroup
    "reviewed access"
    [ testCase "compiler selects one tuple without altering accepted auth and neighboring apps" $ do
        let scope = ok (compileAccessScope snapshot "ONE.EXAMPLE.TEST." "alice" "http://localhost:8090" True)
            candidate = ok (composeInventory snapshot (ReplaceScope scope :| []))
            originals = Map.map snd (snapshotScopes snapshot)
        Map.restrictKeys (inventoryScopes (candidateInventory candidate)) (Map.keysSet originals) @?= originals
        void (either (fail . show) pure (decodeScope (encodeCanonicalScope scope)))
        let resource = accessResource (accessBinding True)
            reserved =
              ok
                ( mkScopeSnapshot
                    (snapshotBinding snapshot)
                    (snapshotScopes snapshot)
                    ( Map.singleton
                        (canonicalClaim (resource ^. #address))
                        (ClaimHolder (resource ^. #owner) (resource ^. #identity) physical ResourceInventory.RetainedIncarnation)
                    )
                )
            input = CandidateInput reserved (ReplaceScope scope :| [])
        let encoded = ok (canonicalValue (candidateInputValue input))
        decoded <- either (fail . show) pure (decodeCandidateInput encoded)
        ok (canonicalValue (candidateInputValue decoded)) @?= encoded
        case decoded of
          CandidateInput decodedSnapshot _ ->
            snapshotReservations decodedSnapshot @?= snapshotReservations reserved
        assertBool
          "secret endpoint accepted"
          ( either
              (const True)
              (const False)
              (compileAccessScope snapshot "one.example.test" "alice" "https://key@secret.test" True)
          )
        assertBool
          "unknown protected hostname accepted"
          ( either
              (const True)
              (const False)
              (compileAccessScope snapshot "foreign.example.test" "alice" "http://localhost:8090" True)
          )
    , testCase "portal synchronization rolls exactly both accepted startup readers" $ do
        let owner = ok (mkScopeId Platform "auth")
            scope = maybe (error "auth fixture absent") snd (Map.lookup owner (snapshotScopes snapshot))
            readers = [fixtureShomei, fixtureEnforcer]
            (revised, rollout) = ok (compilePortalSyncScope scope readers "bounded-sync")
        scopeId revised @?= owner
        Map.keysSet rollout @?= Set.fromList [resource ^. #identity | (resource, _) <- readers]
        forM_ readers $ \(original, _) -> do
          let (changed, _) = rollout Map.! (original ^. #identity)
          (changed & #spec .~ (original ^. #spec) & #dependencies .~ (original ^. #dependencies)) @?= original
          assertBool "backend-map dependency missing" (OrderedAfter (backendMapResourceId owner) `elem` (changed ^. #dependencies))
          assertBool "Shomei-settings dependency missing" (OrderedAfter (shomeiSettingsResourceId owner) `elem` (changed ^. #dependencies))
        forM_
          [ [fixtureShomei]
          , [fixtureShomei, fixtureShomei]
          , [fixtureShomei, (fst fixtureEnforcer, "changed-image")]
          , [fixtureShomei, (fst fixtureEnforcer & #owner .~ ok (mkScopeId Application "foreign"), snd fixtureEnforcer)]
          ]
          $ \invalid ->
            assertBool
              "foreign, missing, duplicate or changed reader accepted"
              (either (const True) (const False) (compilePortalSyncScope scope invalid "bounded-sync"))
    , testCase "atomic wire uses exact direct-subject filter and fully consistent observation" $ do
        let binding = accessBinding True
            before = AccessFact physical False
        accessQuery binding
          @?= object
            ["consistency" .= object ["mode" .= ("fullyConsistent" :: Text)], "filter" .= exactFilter]
        accessMutation binding before
          @?= object
            [ "tuples" .= [accessTuple "one.example.test" "alice"]
            , "deletes" .= ([] :: [Value])
            , "preconditions" .= [object ["kind" .= ("mustNotExist" :: Text), "filter" .= exactFilter]]
            ]
    , testCase "tuple query refuses caveats, usersets and incomplete pages" $ do
        let binding = accessBinding True
            page nodes more =
              ok
                ( canonicalValue
                    ( object
                        [ "edges" .= [object ["node" .= n] | n <- nodes]
                        , "pageInfo" .= object ["hasNextPage" .= more]
                        ]
                    )
                )
            tuple = toJSON (accessTuple "one.example.test" "alice")
        parseAccessPage binding (page [tuple] False) @?= Right True
        parseAccessPage binding (page ([] :: [Value]) False) @?= Right False
        forM_ [page [tuple] True, page [tuple, tuple] False, page [object []] False] $ \bytes ->
          assertBool "foreign/incomplete query accepted" (either (const True) (const False) (parseAccessPage binding bytes))
    , testCase "old tuple API without atomic preconditions refuses" $ do
        parseAccessCapabilities "{}" @?= Left "access API lacks reviewed atomic tuple preconditions"
        parseAccessCapabilities
          ( ok
              ( canonicalValue
                  ( object
                      [ "components"
                          .= object
                            [ "schemas"
                                .= object
                                  ["WriteTuplesRequestWire" .= object ["properties" .= object ["preconditions" .= object [], "deletes" .= object []]]]
                            ]
                      ]
                  )
              )
          )
          @?= Right ()
    , testCase "lost grant response recovers observed completion; foreign owner or missing effect refuses" $ do
        state <- newIORef (AccessFact physical False)
        effects <- newIORef (0 :: Int)
        let binding = accessBinding True
            adapter =
              mkAccessAdapter
                Map.empty
                (Map.singleton (accessResource binding ^. #identity) binding)
                AccessOps
                  { accessInspect = \_ -> Right <$> readIORef state
                  , accessWrite = \_ before -> do
                      modifyIORef' effects (+ 1)
                      writeIORef state (before {accessPresent = True})
                      pure (AdapterEffectAmbiguous "lost response")
                  }
            op = operation binding CreateResource
        prepared <- adapterPrepare adapter op >>= either (fail . show) pure
        adapterExecute adapter op prepared >>= (@?= AdapterEffectAmbiguous "lost response")
        adapterRecover adapter op prepared >>= \case RecoveryProvedComplete _ -> pure (); other -> assertFailure (show other)
        readIORef effects >>= (@?= 1)
        writeIORef state (AccessFact (ok (mkPhysicalIdentity "foreign-owner")) True)
        adapterRecover adapter op prepared >>= \case RecoveryUnresolved _ -> pure (); other -> assertFailure (show other)
        writeIORef state (AccessFact physical False)
        adapterRecover adapter op prepared >>= \case RecoveryUnresolved _ -> pure (); other -> assertFailure (show other)
    , testCase "revoke and stale tuple refuse without touching a different grant" $ do
        state <- newIORef (AccessFact physical True)
        effects <- newIORef (0 :: Int)
        let binding = accessBinding False
            accepted = accessResource (accessBinding True)
            adapter =
              mkAccessAdapter
                (Map.singleton (accepted ^. #identity) accepted)
                (Map.singleton (accessResource binding ^. #identity) binding)
                AccessOps
                  { accessInspect = \_ -> Right <$> readIORef state
                  , accessWrite = \_ before ->
                      modifyIORef' effects (+ 1)
                        >> writeIORef state (before {accessPresent = False})
                        >> pure AdapterEffectCompleted
                  }
            op = operation binding UpdateResource
        prepared <- adapterPrepare adapter op >>= either (fail . show) pure
        adapterExecute adapter op prepared >>= (@?= AdapterEffectCompleted)
        adapterRecover adapter op prepared >>= \case RecoveryProvedComplete _ -> pure (); other -> assertFailure (show other)
        adapterPreflight adapter op prepared >>= \result -> assertBool "stale tuple passed preflight" (either (const True) (const False) result)
        readIORef effects >>= (@?= 1)
    , testCase "seed complete public command fixture from typed declarations" $
        lookupEnv "MP23_ACCESS_FIXTURE_ROOT"
          >>= maybe
            (withSystemTempDirectory "access-public-seed" writeFixture)
            writeFixture
    ]
  where
    physical = ok (mkPhysicalIdentity "access-owner://en-uid/one-route-uid")
    exactFilter =
      object
        [ "objectType" .= ("app" :: Text)
        , "objectId" .= ("one.example.test" :: Text)
        , "relation" .= ("viewer" :: Text)
        , "subjectType" .= ("user" :: Text)
        , "subjectId" .= ("alice" :: Text)
        , "subjectRelation" .= object ["match" .= ("none" :: Text)]
        ]
    operation binding action =
      PlannedOperation
        (ok (mkOperationId "op-access"))
        action
        AccessExecutor
        (accessResource binding ^. #identity :| [])
        (contentDigest "review")
        []
        VerifyBeforeRetry

accessBinding :: Bool -> AccessBinding
accessBinding granted =
  let scope = ok (compileAccessScope snapshot "one.example.test" "alice" "http://localhost:8090" granted)
      candidate = ok (composeInventory snapshot (ReplaceScope scope :| []))
   in head (Map.elems (ok (accessBindings (inventoryDeclarations (candidateInventory candidate)))))

snapshot :: ScopeSnapshot
snapshot = ok (mkScopeSnapshot context (Map.fromList [(scopeId scope, (generation, scope)) | scope <- fixtures]) Map.empty)

context :: ContextBinding
context = ContextBinding (ok (mkContextId "access-test")) (ok (mkName "project"))

generation :: ScopeGeneration
generation = ok (mkScopeGeneration 1)

fixtures :: [ScopeDeclaration]
fixtures = [clusterScope, authScope, bootstrapScope, app "one", app "two"]
  where
    cluster = ok (mkResourceId "platform:cluster/cluster/local")
    clusterOwner = ok (mkScopeId Platform "cluster")
    clusterScope =
      ok
        ( mkScopeDeclaration
            clusterOwner
            [ ResourceBundle
                [External cluster (Artifact (ok (mkName "local-cluster")) (contentDigest "cluster")) [] source]
                []
                []
                []
                []
                []
            ]
        )
    authOwner = ok (mkScopeId Platform "auth")
    authId = ok (mkResourceId "platform:auth/en/service")
    auth =
      ManagedResource
        authId
        authOwner
        KubernetesExecutor
        (ok (kubernetesAddress cluster "v1" "Service" (Just "nagare-system") "en"))
        []
        (NativeObject (contentDigest "en-service"))
        Protect
        Stateless
        Public
        [OrderedAfter cluster]
        []
        source
    authScope =
      ok
        ( mkScopeDeclaration
            authOwner
            [ ResourceBundle
                [Managed auth, Managed (fst fixtureShomei), Managed (fst fixtureEnforcer)]
                []
                []
                []
                []
                [BackendMapGrant cluster, ShomeiSettingsGrant cluster (ok (mkName "example.test"))]
            ]
        )
    -- An admitted bootstrap marker remains in ordinary application/access
    -- reviews. Its presence alone must not select a new bootstrap verification.
    bootstrapOwner = ok (mkScopeId Platform "bootstrap-stamp")
    bootstrapId = mintResourceId bootstrapOwner (ok (mkLogicalKey "bootstrap")) (ok (mkName "version"))
    bootstrapObject =
      object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("ConfigMap" :: Text)
        , "metadata" .= object ["name" .= ("nagare-platform-version" :: Text), "namespace" .= ("nagare-system" :: Text)]
        ]
    bootstrapResource =
      fst
        ( ok
            ( bindKubernetesObject
                KubernetesInput
                  { resourceId = bootstrapId
                  , ownerScope = bootstrapOwner
                  , clusterId = cluster
                  , inputObject = bootstrapObject
                  , objectDigest = contentDigest (ok (canonicalValue bootstrapObject))
                  , lifecyclePolicy = Retain
                  , inputDataPolicy = Stateless
                  , inputSensitivity = Public
                  , sourceLocation = SourceLocation "generated:bootstrap" "platform-version"
                  }
            )
        )
    bootstrapScope =
      ok
        ( mkScopeDeclaration
            bootstrapOwner
            [ResourceBundle [Managed (bootstrapResource {dependencies = [OrderedAfter authId]})] [] [] [] [] []]
        )
    app label =
      let owner = ok (mkScopeId Application label)
          host = ok (mkName (label <> ".example.test"))
          key = ok (mkLogicalKey "web")
          route =
            ManagedResource
              (mintResourceId owner key (ok (mkName "route")))
              owner
              KubernetesExecutor
              (ok (kubernetesAddress cluster "serving.knative.dev/v1beta1" "DomainMapping" (Just "nagare-system") (nameText host)))
              [Hostname host]
              (NativeObject (contentDigest ("route-" <> TE.encodeUtf8 label)))
              Retain
              Stateless
              Public
              [OrderedAfter cluster, OrderedAfter (backendMapResourceId authOwner)]
              []
              source
       in ok
            ( mkScopeDeclaration
                owner
                [ ResourceBundle
                    [Managed route]
                    []
                    []
                    ( [RegisterBackend authOwner cluster host ("http://" <> label <> ".svc") ProtectedBackend key]
                        <> [ RegisterBackend
                               authOwner
                               cluster
                               (ok (mkName "portal.example.test"))
                               "http://portal.svc"
                               PortalBackend
                               key
                           | label == "two"
                           ]
                    )
                    []
                    []
                ]
            )
    source = SourceLocation "fixture" "access"

fixtureShomei :: (ManagedResource, BS.ByteString)
fixtureShomei =
  ok
    ( bindKubernetesObject
        KubernetesInput
          { resourceId = ok (mkResourceId "platform:auth/shomei/deployment")
          , ownerScope = ok (mkScopeId Platform "auth")
          , clusterId = ok (mkResourceId "platform:cluster/cluster/local")
          , inputObject = value
          , objectDigest = contentDigest bytes
          , lifecyclePolicy = Protect
          , inputDataPolicy = Stateless
          , inputSensitivity = Public
          , sourceLocation = SourceLocation "fixture" "shomei"
          }
    )
  where
    bytes = ok (canonicalValue value)
    value =
      object
        [ "apiVersion" .= ("apps/v1" :: Text)
        , "kind" .= ("Deployment" :: Text)
        , "metadata" .= object ["name" .= ("shomei" :: Text), "namespace" .= ("nagare-system" :: Text)]
        , "spec"
            .= object
              [ "replicas" .= (1 :: Int)
              , "selector" .= object ["matchLabels" .= object ["app" .= ("shomei" :: Text)]]
              , "template" .= template
              ]
        ]
    template =
      object
        [ "metadata" .= object ["labels" .= object ["app" .= ("shomei" :: Text)]]
        , "spec" .= object ["containers" .= [container]]
        ]
    container =
      object
        [ "name" .= ("shomei" :: Text)
        , "image" .= ("fixture-only/shomei:bound" :: Text)
        , "env"
            .= [ setting "SHOMEI_WEBAUTHN_ORIGINS" "webauthn-origins"
               , setting "SHOMEI_PUBLIC_BASE_URL" "public-base-url"
               ]
        ]
    setting :: Text -> Text -> Value
    setting variable key =
      object
        [ "name" .= variable
        , "valueFrom"
            .= object
              [ "configMapKeyRef"
                  .= object
                    ["name" .= ("nagare-shomei-settings" :: Text), "key" .= key]
              ]
        ]

fixtureEnforcer :: (ManagedResource, BS.ByteString)
fixtureEnforcer =
  ok
    ( bindKubernetesObject
        KubernetesInput
          { resourceId = ok (mkResourceId "platform:auth/nagare-access/service")
          , ownerScope = ok (mkScopeId Platform "auth")
          , clusterId = ok (mkResourceId "platform:cluster/cluster/local")
          , inputObject = value
          , objectDigest = contentDigest bytes
          , lifecyclePolicy = Protect
          , inputDataPolicy = Stateless
          , inputSensitivity = Public
          , sourceLocation = SourceLocation "fixture" "nagare-access"
          }
    )
  where
    bytes = ok (canonicalValue value)
    value =
      object
        [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
        , "kind" .= ("Service" :: Text)
        , "metadata" .= object ["name" .= ("nagare-access" :: Text), "namespace" .= ("nagare-system" :: Text)]
        , "spec"
            .= object
              [ "template"
                  .= object
                    [ "metadata" .= object ["annotations" .= object []]
                    , "spec" .= object ["containers" .= [object ["image" .= ("fixture-enforcer:accepted" :: Text)]]]
                    ]
              ]
        ]

writeFixture :: FilePath -> IO ()
writeFixture root = do
  createDirectoryIfMissing True root
  store <- openFilesystemStore (root </> "state/nagare/access-test/inventory") >>= either (fail . show) pure
  initial <- initializeStore store context "access-fixture" >>= either (fail . show) pure
  let revision scope = ScopeRevision generation (contentDigest (encodeCanonicalScope scope))
      revisions = Map.fromList [(scopeId scope, revision scope) | scope <- fixtures]
  forM_ fixtures $ \scope ->
    void
      ( publishIfAbsent
          store
          (scopeKey (revisionDigest (revision scope)))
          (encodeCanonicalScope scope)
          >>= either (fail . show) pure
      )
  forM_ [fixtureShomei, fixtureEnforcer] $ \(_, bytes) ->
    void
      ( publishIfAbsent store (objectKeyFor "native" (contentDigest bytes)) bytes
          >>= either (fail . show) pure
      )
  void
    ( replaceHeadIfGenerationMatches
        store
        (Just (headGeneration initial))
        initial
          { headGeneration = headGeneration initial + 1
          , headAccepted = revisions
          , headConverged = revisions
          }
        >>= either (fail . show) pure
    )
  let inventory = ok (composeSnapshot snapshot)
      objects =
        [ object
            [ "kind" .= kind
            , "name" .= name
            , "namespace" .= namespace
            , "resource" .= (resource ^. #identity)
            , "digest" .= digest
            ]
        | Managed resource <- inventoryDeclarations inventory
        , Kubernetes _ _ kind (Just namespace) name <- [resource ^. #address]
        , NativeObject digest <- [resource ^. #spec]
        ]
  BS.writeFile (root </> "owners.json") (ok (canonicalValue (toJSON objects)))
  let native =
        Map.union
          (ok (compileContributedBackendMaps (inventoryDeclarations inventory)))
          (ok (compileContributedShomeiSettings (inventoryDeclarations inventory)))
  BS.writeFile
    (root </> "maps.json")
    ( ok
        ( canonicalValue
            ( toJSON
                [ object ["resource" .= resourceId, "native" .= TE.decodeUtf8 bytes]
                | (resourceId, (_, bytes)) <-
                    Map.toAscList
                      ( Map.union
                          (Map.fromList [(resource ^. #identity, member) | member@(resource, _) <- [fixtureShomei, fixtureEnforcer]])
                          native
                      )
                ]
            )
        )
    )
  void (loadInventoryHistory store >>= either (fail . show) pure)

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
