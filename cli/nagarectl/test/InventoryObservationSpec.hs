module InventoryObservationSpec (inventoryObservationTests, prepare, binding) where

import Control.Monad (forM_)
import Data.Aeson (eitherDecodeStrict', object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import InventoryObjectOpsSpec (fakeObjectOps)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Helm
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.BackendMap (renderBackendMapNative, renderShomeiSettingsNative)
import Nagare.Inventory.Components.Observability
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.ObservationNative
import Nagare.Inventory.Plan
import Nagare.Inventory.Status (loadAcceptedNativeSelected)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (Delegation (..), DelegatedOperation (RefreshCredential))
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import Test.Tasty
import Test.Tasty.HUnit

inventoryObservationTests :: TestTree
inventoryObservationTests =
  testGroup
    "selected native observation"
    [ testCase "execution source selection ignores missing siblings and corrupt unrelated reviews" (executionSourceRead "present")
    , testCase "legacy execution source still reconstructs its original private envelope" (executionSourceRead "missing")
    , testCase "corrupt execution source refuses without legacy fallback" (executionSourceRead "corrupt")
    , testCase "missing execution source cannot mask corruption in another selected source" (executionSourceRead "mixed")
    , testCase "two real resources cost two reads despite 500 unrelated reviews and 50 sibling natives" $
        forM_ [0, 50] $ \width -> forM_ [0, 500] $ \count -> do
          base <- fakeObjectOps
          store <- must (newObjectStore base binding "fixture" Nothing)
          _ <- must (initializeStore store binding "fixture")
          _ <- prepare store width
          forM_ [1 .. count :: Int] $ \i -> do
            -- A malformed unrelated review must not be decoded by observation.
            let bytes = "unrelated invalid review " <> encodeNumber i
            _ <- must (publishIfAbsent store (reviewKey (contentDigest bytes)) bytes)
            pure ()
          gets <- newIORef []
          lists <- newIORef (0 :: Int)
          let counted =
                base
                  { getObject = \key -> modifyIORef' gets (<> [key]) >> getObject base key
                  , listObjects = \prefix -> modifyIORef' lists (+ 1) >> listObjects base prefix
                  }
          fresh <- must (newObjectStore counted binding "reader" Nothing)
          writeIORef gets []
          result <- must (loadObservationNative fresh [fst selected, fst helm])
          Map.elems (observationKubernetes result) @?= [selected]
          Map.elems (observationHelm result) @?= [helm]
          actual <- readIORef gets
          length actual @?= 2
          Set.fromList actual @?= Set.fromList (map (ObjectName . T.pack . objectKeyFor "native" . contentDigest . snd) [selected, helm])
          readIORef lists >>= (@?= 0)
    , testCase "empty selection performs no object reads or listing" $ do
        base <- fakeObjectOps
        store <- must (newObjectStore base binding "fixture" Nothing)
        let refuse =
              base
                { getObject = \key ->
                    if key == ObjectName "format.json"
                      then getObject base key
                      else assertFailure "empty request read an object" >> error "unreachable"
                , listObjects = \_ -> assertFailure "empty request listed objects" >> error "unreachable"
                }
        -- Construct first using valid ops; uninitialized stores are sufficient.
        _ <- must (loadObservationNative store [])
        fresh <- must (openObjectStoreReadOnly refuse binding "reader" Nothing)
        _ <- must (loadObservationNative fresh [])
        pure ()
    , testCase "selected missing or corrupt native evidence refuses without review scan" $ do
        base <- fakeObjectOps
        store <- must (newObjectStore base binding "fixture" Nothing)
        _ <- must (initializeStore store binding "fixture")
        _ <- prepare store 0
        forM_ [ObjectAbsent, ObjectFound (Generation 90) "corrupt"] $ \failure -> do
          let broken =
                base
                  { getObject = \key ->
                      if key == ObjectName (T.pack (objectKeyFor "native" (contentDigest (snd selected))))
                        then pure failure
                        else getObject base key
                  , listObjects = \_ -> assertFailure "missing evidence triggered a scan" >> error "unreachable"
                  }
          fresh <- must (newObjectStore broken binding "reader" Nothing)
          loaded <- loadObservationNative fresh [fst selected]
          case loaded of
            Left _ -> pure ()
            Right _ -> assertFailure "bad selected evidence was accepted"
    , testCase "source-only revision reuses exact bytes but changed address or spec refuses" $ do
        store <- newMemoryStore
        _ <- must (initializeStore store binding "fixture")
        _ <- prepare store 0
        let member = fst selected
            revised = member
              { source = SourceLocation "new.yaml" "document[7]"
              , delegations = [Delegation (member ^. #identity)
                  (name "registry-pull-reference" :| []) (RefreshCredential :| [])]
              }
        result <- must (loadObservationNative store [revised])
        Map.elems (observationKubernetes result) @?= [(revised, snd selected)]
        let moved = member {address = Kubernetes fixtureCluster "" (name "configmap") (Just (name "personal")) (name "other")}
        changed <- loadObservationNative store [moved]
        case changed of
          Left _ -> pure ()
          Right _ -> assertFailure "different native address was accepted"
        changedSpec <- loadObservationNative store [member {spec = NativeObject (contentDigest "different")}]
        case changedSpec of
          Left _ -> pure ()
          Right _ -> assertFailure "different native incarnation was accepted"
    , testCase "generated namespace backend map and Shomei settings reconstruct exactly without stored members" $ do
        store <- newMemoryStore
        let namespaceBytes =
              ok
                ( canonicalValue
                    ( object
                        [ "apiVersion" .= ("v1" :: Text)
                        , "kind" .= ("Namespace" :: Text)
                        , "metadata"
                            .= object
                              [ "name" .= ("generated" :: Text)
                              , "labels" .= object ["nagare.dev/app-namespace" .= ("true" :: Text)]
                              ]
                        ]
                    )
                )
            inputs =
              [ ("namespace", NamespaceSpec Nothing, namespaceBytes)
              , ("backends", BackendMapSpec [], ok (renderBackendMapNative []))
              ,
                ( "settings"
                , ShomeiSettingsSpec (name "example.test") Nothing
                , ok (renderShomeiSettingsNative (name "example.test") Nothing)
                )
              ]
        forM_ inputs $ \(key, desired, bytes) -> do
          let (member, _) =
                ok
                  ( bindKubernetesObject
                      ( KubernetesInput
                          (rid key)
                          fixtureOwner
                          fixtureCluster
                          (ok (eitherDecodeStrict' bytes))
                          (contentDigest bytes)
                          Retain
                          Stateless
                          Private
                          (SourceLocation "contribution" "generated")
                      )
                  )
              generated = member {spec = desired}
          loaded <- must (loadObservationNative store [generated])
          Map.elems (observationKubernetes loaded) @?= [(generated, bytes)]
    , testCase "historical materialization is idempotent and never changes head" $ do
        store <- newMemoryStore
        _ <- must (initializeStore store binding "fixture")
        bundle <- prepare store 0
        before <- must (readHead store)
        _ <- must (publishObservationMembers store bundle)
        _ <- must (publishObservationMembers store bundle)
        must (readHead store) >>= (@?= before)
        loaded <- must (loadPublishedReview store (reviewDigest bundle))
        loaded @?= bundle
    ]

-- The admitted review remains untouched. Only private source lookup changes.
executionSourceRead :: Text -> IO ()
executionSourceRead mode = do
  base <- fakeObjectOps
  store <- must (newObjectStore base binding "fixture" Nothing)
  initial <- must (initializeStore store binding "fixture")
  bundle <- prepare store 1
  _ <-
    must
      ( replaceHeadIfGenerationMatches
          store
          (Just (headGeneration initial))
          initial
            { headGeneration = headGeneration initial + 1
            , headAccepted = reviewDesiredRevisions (reviewBundleDocument bundle)
            }
      )
  history <- must (loadInventoryHistory store)
  let snapshot =
        ok
          ( mkScopeSnapshot
              binding
              ( Map.map
                  (\(revision, scope) -> (revisionGeneration revision, scope))
                  (historyAccepted history)
              )
              Map.empty
          )
      inventory = ok (composeSnapshot snapshot)
      sourceKey = ObjectName (T.pack (objectKeyFor "native" (contentDigest (snd selected))))
      siblingKey = ObjectName (T.pack (objectKeyFor "native" (contentDigest (snd (kube "sibling-1")))))
  when (mode /= "missing") $ do
    _ <- must (publishIfAbsent store (reviewKey (contentDigest "unrelated invalid review")) "unrelated invalid review")
    pure ()
  lists <- newIORef (0 :: Int)
  gets <- newIORef []
  let ops =
        base
          { getObject = \key -> do
              modifyIORef' gets (<> [key])
              if key == siblingKey
                then assertFailure "unselected sibling was read" >> pure ObjectAbsent
                else
                  if key == sourceKey && mode `elem` ["missing", "mixed"]
                    then pure ObjectAbsent
                    else
                      if key == sourceKey && mode == "corrupt"
                        then pure (ObjectFound (Generation 90) "corrupt")
                        else
                          if mode == "mixed" && key == ObjectName (T.pack (objectKeyFor "native" (contentDigest (snd helm))))
                            then pure (ObjectFound (Generation 90) "corrupt")
                            else getObject base key
          , listObjects = \prefix -> modifyIORef' lists (+ 1) >> listObjects base prefix
          }
  fresh <- must (openObjectStoreReadOnly ops binding "reader" Nothing)
  writeIORef gets []
  result <- loadAcceptedNativeSelected (Set.fromList (rid "selected" : [rid "helm" | mode == "mixed"])) fresh history inventory
  if mode `elem` ["corrupt", "mixed"]
    then case result of
      Left _ -> pure ()
      Right _ -> assertFailure "corrupt source was accepted"
    else do
      (native, helms) <- must (pure result)
      Map.elems native @?= [selected]
      helms @?= Map.empty
  readIORef lists >>= (@?= if mode == "missing" then 1 else 0)
  when (mode `notElem` ["missing", "mixed"]) $ readIORef gets >>= (@?= [sourceKey])

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

must :: (Show e) => IO (Either e a) -> IO a
must action = action >>= either (assertFailure . show) pure

encodeNumber :: Int -> ByteString
encodeNumber = BC.pack . show

binding :: ContextBinding
binding = ContextBinding (ok (mkContextId "observation-fixture")) (name "project")

name :: Text -> Name
name = ok . mkName

fixtureOwner :: ScopeId
fixtureOwner = ok (mkScopeId Platform "observation")

rid :: Text -> ResourceId
rid key = mintResourceId fixtureOwner (ok (mkLogicalKey key)) (name "resource")

fixtureCluster :: ResourceId
fixtureCluster = rid "cluster"

selected :: (ManagedResource, ByteString)
selected = kube "selected"

kube :: Text -> (ManagedResource, ByteString)
kube key =
  ok
    ( bindKubernetesObject
        ( KubernetesInput
            (rid key)
            fixtureOwner
            fixtureCluster
            value
            (contentDigest bytes)
            Retain
            Stateless
            Private
            (SourceLocation "fixture.yaml" "document[0]")
        )
    )
  where
    value =
      object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("ConfigMap" :: Text)
        , "metadata" .= object ["name" .= key, "namespace" .= ("personal" :: Text)]
        ]
    bytes = ok (canonicalValue value)

helm :: (ManagedResource, ByteString)
helm =
  ok
    ( compileRenderedRelease
        ObservabilityReleaseInput
          { releaseId = rid "helm"
          , releaseOwner = fixtureOwner
          , releaseCluster = fixtureCluster
          , releaseNamespace = name "monitoring"
          , releaseName = name "metrics"
          , releaseChartPath = "fixture.tgz"
          , releaseChartBytes = "pinned chart"
          , releaseValuesPath = "values.yaml"
          , releaseValuesBytes = "pinned values"
          , releaseRenderedBytes = "apiVersion: v1\nkind: Service\nmetadata:\n  name: metrics\n"
          , releaseCrdsBytes = Nothing
          , releaseKubeVersion = "v1.32.0"
          , releaseHelmVersion = "v4.2.4"
          , releaseApiVersions = []
          , releaseDependencies = []
          }
    )

prepare :: InventoryStore -> Int -> IO ReviewBundle
prepare store width = do
  let kubes =
        Map.fromList
          [ (member ^. #identity, (member, bytes))
          | (member, bytes) <-
              selected : [kube ("sibling-" <> T.pack (show n)) | n <- [1 .. width]]
          ]
      helms = Map.singleton (rid "helm") helm
      registry =
        ok
          ( mkAdapterRegistry
              [ mkKubernetesAdapter
                  kubes
                  KubernetesAdapterOps
                    { kubernetesContext = binding ^. #identity
                    , kubernetesObserve = \_ -> pure (KubernetesAbsent (contentDigest "absent"))
                    , kubernetesMutateConditional = \_ -> assertFailure "fixture mutated Kubernetes" >> error "unreachable"
                    }
              , mkHelmAdapter
                  helms
                  HelmAdapterOps
                    { helmObserve = \_ -> pure (HelmAbsent (contentDigest "absent"))
                    , helmMutateConditional = \_ -> assertFailure "fixture mutated Helm" >> error "unreachable"
                    }
              ]
          )
      declared =
        ok
          ( mkScopeDeclaration
              fixtureOwner
              [ ResourceBundle
                  [Managed member | (member, _) <- Map.elems kubes <> Map.elems helms]
                  []
                  []
                  []
                  []
                  []
              ]
          )
      candidate = ok (composeInventory (ok (mkScopeSnapshot binding Map.empty Map.empty)) (ReplaceScope declared :| []))
      observed = ok (observationSet [(resource, ConfirmedAbsent (contentDigest "absent")) | resource <- Map.keys kubes <> Map.keys helms])
  history <- must (loadInventoryHistory store)
  snapshot <- must (readStoreSnapshot store)
  bundle <- must (prepareReview registry snapshot (ok (planChanges candidate noLifecycleDecisions history observed)))
  _ <- must (publishReview store bundle)
  pure bundle
