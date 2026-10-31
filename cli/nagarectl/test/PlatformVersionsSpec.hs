-- | EP-236: the platform-versions collector, writer and reader against
-- adversarial fake providers. Every case runs the real assembly and, where
-- it publishes, the real store; no case reaches a cluster.
module PlatformVersionsSpec (platformVersionsTests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Nagare.Contract.Schema (Nullable (..))
import Nagare.Contract.Versions
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Platform.Versions
import Nagare.Platform.Versions.Assemble
import Nagare.Platform.Versions.Collect
import Nagare.Platform.Versions.Store
import Nagare.Resource.Types (ContextBinding (..), mkContextId, mkName)
import System.Directory (doesDirectoryExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

platformVersionsTests :: TestTree
platformVersionsTests =
  testGroup
    "platform versions (EP-236)"
    [ testCase "a complete collection reports installed, host, component and every database engine" $ do
        providers <- worldProviders
        snapshot <- collected providers
        let installedRelease = unNullable (snapshot ^. #installed)
        fmap (value' . (^. #version)) installedRelease @?= Just (Just "0.13.0")
        fmap (reason' . (^. #payloadId)) installedRelease @?= Just (Just "not_recorded")
        [host ^. #nixos . #nixpkgsRevision . #value | host <- snapshot ^. #hosts] @?= [Nullable (Just "eaad0894")]
        [(database ^. #engine, value' (database ^. #declaredVersion), [value' (instance' ^. #reportedVersion) | instance' <- database ^. #instances]) | database <- snapshot ^. #databases]
          @?= [ ("redis", Just "8", [Just "8.2.1"])
              , ("clickhouse", Just "25.8.2.29", [Just "25.8.2.29"])
              , ("postgres", Just "18", [Just "PostgreSQL 18.1 on aarch64-unknown-linux-gnu"])
              ]
        [value' (instance' ^. #imageDigest) | database <- snapshot ^. #databases, instance' <- database ^. #instances]
          @?= [Just "sha256:redis", Just "sha256:ch", Just "sha256:pg"]
        snapshot ^. #inventoryRevision @?= Nullable (Just "rev-1")
    , testCase "a mixed rollout keeps both digests; a Helm release reports its vendored chart version" $ do
        snapshot <- worldProviders >>= collected
        let byName name' = [component | component <- snapshot ^. #components, component ^. #name == name']
        [value' (container ^. #imageDigest) | component <- byName "controller", workload <- component ^. #workloads, container <- workload ^. #containers]
          @?= [Just "sha256:old", Just "sha256:new"]
        [value' (component ^. #declaredChartVersion) | component <- byName "grafana"] @?= [Just "9.3.1"]
        [map (^. #pod) (component ^. #workloads) | component <- byName "grafana"] @?= [["grafana-0"]]
        [reason' (component ^. #declaredVersion) | component <- byName "broken"] @?= [Just "probe_unsupported"]
        assertBool "a ConfigMap became a component" (null (byName "settings"))
    , testCase "a platform-owned database server is a database, not a component" $ do
        providers <- worldProviders
        snapshot <- collected providers {loadAccepted = fmap (fmap (<> [KubernetesMember "platform:auth" "platform:auth/en-db/statefulset" (workload "StatefulSet" "databases" "en-db" [("nagare.dev/engine", "postgres")] [("nagare.dev/database", "en-db")] ["postgres:18"])])) <$> loadAccepted providers}
        [database ^. #scope | database <- snapshot ^. #databases] @?= ["application:cache", "platform:auth", "standalone:labs-clickhouse", "standalone:labs-postgres"]
        assertBool "a database server was also reported as a component" (all ((/= "en-db") . (^. #name)) (snapshot ^. #components))
    , testCase "a backup Job's pod carrying the server's labels is not an instance" $ do
        providers <- worldProviders
        let owned kind' name' value = case value of
              Object fields -> Object (alterF' fields)
              other -> other
              where
                withOwner = \case
                  Object meta -> Object (KeyMap.insert "ownerReferences" (toJSON [object ["kind" .= (kind' :: Text), "name" .= (name' :: Text), "controller" .= True]]) meta)
                  other -> other
                alterF' fields = maybe fields (\meta -> KeyMap.insert "metadata" (withOwner meta) fields) (KeyMap.lookup "metadata" fields)
            pods' =
              [ owned "StatefulSet" "labs-postgres" (podValue "labs-postgres-0" "uid-pg" [("nagare.dev/database", "labs-postgres")] "sha256:pg")
              , owned "Job" "nagare-dbbackup-labs-postgres-1" (podValue "nagare-dbbackup-labs-postgres-1-x" "uid-job" [("nagare.dev/database", "labs-postgres")] "sha256:pg")
              ]
        snapshot <- collected providers {readPods = \namespace' -> if namespace' == "databases" then pure (Right (podsJson pods')) else readPods providers namespace'}
        [map (^. #pod) (database ^. #instances) | database <- snapshot ^. #databases, database ^. #server == "labs-postgres"] @?= [["labs-postgres-0"]]
    , testCase "a denied node read leaves hosts unavailable and every other section intact" $ do
        providers <- worldProviders
        snapshot <- collected providers {readNodes = pure (Left ProviderDenied)}
        (snapshot ^. #hosts, snapshot ^. #hostsReason) @?= ([], Nullable (Just "denied"))
        length (snapshot ^. #databases) @?= 3
        assertBool "the stamp was lost" (isJust (unNullable (snapshot ^. #installed)))
    , testCase "a host without the identity ConfigMap is not_recorded; a non-NixOS node is not_applicable" $ do
        providers <- worldProviders
        missing <- collected providers {readHostIdentity = pure (Left ProviderMissing)}
        [reason' (host ^. #nixos . #release) | host <- missing ^. #hosts] @?= [Just "not_recorded"]
        k3d <- collected providers {readNodes = pure (Right (nodesJson "k3d-local-server-0" "K3s v1.33.4+k3s1"))}
        [reason' (host ^. #nixos . #nixpkgsRevision) | host <- k3d ^. #hosts] @?= [Just "not_applicable"]
        [value' (host ^. #osImage) | host <- k3d ^. #hosts] @?= [Just "K3s v1.33.4+k3s1"]
    , testCase "a stopped server keeps its declared facts with no instances" $ do
        providers <- worldProviders
        snapshot <- collected providers {readPods = \namespace' -> if namespace' == "databases" then pure (Right (podsJson [])) else readPods providers namespace'}
        [(database ^. #engine, value' (database ^. #declaredImage), length (database ^. #instances), database ^. #instancesReason) | database <- snapshot ^. #databases]
          @?= [ ("redis", Just "redis:8", 0, Nullable Nothing)
              , ("clickhouse", Just "clickhouse/clickhouse-server:25.8.2.29", 0, Nullable Nothing)
              , ("postgres", Just "postgres:18", 0, Nullable Nothing)
              ]
    , testCase "a pod replaced during its probe is identity_changed; other servers keep their versions" $ do
        providers <- worldProviders
        snapshot <- collected providers {readPodUid = \namespace' pod -> if pod == "labs-postgres-0" then pure (Right "uid-replaced") else readPodUid providers namespace' pod}
        [(database ^. #engine, reason' (instance' ^. #reportedVersion)) | database <- snapshot ^. #databases, instance' <- database ^. #instances]
          @?= [("redis", Nothing), ("clickhouse", Nothing), ("postgres", Just "identity_changed")]
    , testCase "a hung probe is collection_deadline within the budget and never cancels another" $ do
        providers <- worldProviders
        started <- getCurrentTime
        snapshot <-
          collectedWith
            300000
            providers {runEngine = \engine' namespace' pod command -> if engine' == "redis" then threadDelay 10000000 >> pure (Right "") else runEngine providers engine' namespace' pod command}
        finished <- getCurrentTime
        assertBool "the collection outlived its budget" (diffUTCTime finished started < 3)
        [(database ^. #engine, reason' (instance' ^. #reportedVersion)) | database <- snapshot ^. #databases, instance' <- database ^. #instances]
          @?= [("redis", Just "collection_deadline"), ("clickhouse", Nothing), ("postgres", Nothing)]
    , testCase "a failing engine is probe_failed; denied pods are denied for that namespace only" $ do
        providers <- worldProviders
        snapshot <-
          collected
            providers
              { runEngine = \engine' namespace' pod command -> if engine' == "postgres" then pure (Left ProviderUnreadable) else runEngine providers engine' namespace' pod command
              , readPods = \namespace' -> if namespace' == "observability" then pure (Left ProviderDenied) else readPods providers namespace'
              }
        [reason' (instance' ^. #reportedVersion) | database <- snapshot ^. #databases, database ^. #engine == "postgres", instance' <- database ^. #instances] @?= [Just "probe_failed"]
        [component ^. #workloadsReason | component <- snapshot ^. #components, component ^. #name == "grafana"] @?= [Nullable (Just "denied")]
        [component ^. #workloadsReason | component <- snapshot ^. #components, component ^. #name == "controller"] @?= [Nullable Nothing]
    , testCase "a head that changes once is collected again; one that keeps changing is inventory_changed" $ do
        providers <- worldProviders
        once <- newIORef ["rev-2", "rev-1", "rev-1"]
        settled <- collected providers {currentRevision = Right <$> pop once}
        settled ^. #reason @?= Nullable Nothing
        churn <- newIORef (0 :: Int)
        let churning = Right . ("rev-churn-" <>) . T.pack . show <$> atomicModifyIORef' churn (\n -> (n + 1, n))
        changed <- collected providers {currentRevision = churning}
        (changed ^. #reason, changed ^. #databases, changed ^. #databasesReason) @?= (Nullable (Just "inventory_changed"), [], Nullable (Just "inventory_changed"))
    , testCase "secrets in native objects and provider failures never reach a snapshot" $ do
        providers <- worldProviders
        snapshot <- collected providers {readStamp = pure (Right (configMap [("version", "0.13.0"), ("token", "SECRET-SENTINEL")]))}
        assertBool "a sentinel leaked into the snapshot" (not ("SENTINEL" `BS.isInfixOf` LBS.toStrict (encode snapshot)))
    , testCase "publication is atomic, keeps a newer snapshot, survives concurrency and is read back bound" $ withStore $ \store -> do
        snapshot <- worldProviders >>= collected
        publishVersionSnapshot store snapshot >>= (@?= Right Published)
        readVersionSnapshot store binding >>= (@?= Right snapshot)
        publishVersionSnapshot store snapshot {completedAt = "2026-10-31T15:00:00Z"} >>= (@?= Right KeptNewer)
        (left, right) <-
          concurrently
            (publishVersionSnapshot store snapshot {completedAt = "2026-10-31T18:00:00Z"})
            (publishVersionSnapshot store snapshot {completedAt = "2026-10-31T17:00:00Z"})
        assertBool "a concurrent publication failed" (all isRight' [left, right])
        fmap (^. #completedAt) <$> readVersionSnapshot store binding >>= (@?= Right "2026-10-31T18:00:00Z")
        readVersionSnapshot store binding {project = ok (mkName "other")} >>= (@?= Left "snapshot_foreign")
        publishVersionSnapshot store snapshot {project = "other"} >>= assertBool "a foreign snapshot was published" . not . isRight'
        listObjectKeys store >>= \case
          Right keys -> assertBool "the snapshot appeared in the inventory listing" (all (not . T.isPrefixOf "versions/" . T.pack) keys)
          Left failure -> assertFailure (show failure)
    , testCase "a remote publication is generation-conditional and a missing snapshot reads as missing" $ do
        ops <- memoryObjectOps
        store <- newObjectStore ops binding "client" Nothing >>= either (fail . show) pure
        _ <- initializeStore store binding "client" >>= either (fail . show) pure
        readVersionSnapshot store binding >>= (@?= Left "snapshot_missing")
        snapshot <- worldProviders >>= collected
        publishVersionSnapshot store snapshot >>= (@?= Right Published)
        publishVersionSnapshot store snapshot {completedAt = "2026-10-31T19:00:00Z"} >>= (@?= Right Published)
        fmap (^. #completedAt) <$> readVersionSnapshot store binding >>= (@?= Right "2026-10-31T19:00:00Z")
    , testCase "an older snapshot schema or an oversized object is refused with its reason" $ do
        snapshot <- worldProviders >>= collected
        validateSnapshot binding (Just (LBS.toStrict (encode snapshot {snapshotSchema = 2}))) @?= Left "snapshot_invalid"
        validateSnapshot binding (Just (BS.replicate (snapshotByteLimit + 1) 32)) @?= Left "snapshot_oversized"
        validateSnapshot binding Nothing @?= Left "snapshot_missing"
    ]
  where
    isRight' = either (const False) (const True)

binding :: ContextBinding
binding = ContextBinding (ok (mkContextId "fixture")) (ok (mkName "project"))

collected :: VersionProviders -> IO VersionSnapshot
collected = collectedWith 5000000

collectedWith :: Int -> VersionProviders -> IO VersionSnapshot
collectedWith budget providers =
  collectVersions (CollectSettings "fixture" "project" Nothing budget 4) providers >>= either (fail . T.unpack) pure

withStore :: (InventoryStore -> IO ()) -> IO ()
withStore action = withSystemTempDirectory "versions-store" $ \directory -> do
  store <- openFilesystemStore (directory </> "inventory") >>= either (fail . show) pure
  _ <- initializeStore store binding "client" >>= either (fail . show) pure
  action store
  doesDirectoryExist (directory </> "inventory" </> "versions") >>= assertBool "no versions directory"

-- | The fixture installation: Knative's controller mid-rollout, a broken
-- Deployment, a ConfigMap, a vendored Grafana release, and one server of
-- each engine. Every provider answers; tests replace one at a time.
worldProviders :: IO VersionProviders
worldProviders = do
  ticks <- newIORef (0 :: Int)
  pure
    VersionProviders
      { loadAccepted = pure (Right ("rev-1", members))
      , currentRevision = pure (Right "rev-1")
      , readStamp = pure (Right (configMap [("version", "0.13.0"), ("revision", "0123456789abcdef"), ("installedAt", "2026-10-30T09:00:00Z")]))
      , readHostIdentity = pure (Right (configMap [("release", "26.11"), ("codeName", "Zebra"), ("version", "26.11.20261020.eaad089"), ("revision", "eaad0894"), ("hostname", "nagare-01")]))
      , readNodes = pure (Right (nodesJson "nagare-01" "NixOS 26.11 (Zebra)"))
      , readPods = \case
          "knative-serving" -> pure (Right (podsJson [podValue "controller-a" "uid-a" [("app", "controller")] "sha256:old", podValue "controller-b" "uid-b" [("app", "controller")] "sha256:new"]))
          "observability" -> pure (Right (podsJson [podValue "grafana-0" "uid-g" [("app.kubernetes.io/instance", "grafana")] "sha256:grafana"]))
          "databases" ->
            pure
              ( Right
                  ( podsJson
                      [ podValue "labs-postgres-0" "uid-pg" [("nagare.dev/database", "labs-postgres")] "sha256:pg"
                      , podValue "labs-clickhouse-0" "uid-ch" [("nagare.dev/database", "labs-clickhouse")] "sha256:ch"
                      , podValue "labs-redis-0" "uid-redis" [("nagare.dev/database", "labs-redis")] "sha256:redis"
                      ]
                  )
              )
          _ -> pure (Right (podsJson []))
      , runEngine = \engine' _ _ _ -> pure . Right $ case engine' of
          "postgres" -> "PostgreSQL 18.1 on aarch64-unknown-linux-gnu\n"
          "clickhouse" -> "25.8.2.29\n"
          _ -> "# Server\r\nredis_version:8.2.1\r\nredis_mode:standalone\r\n"
      , readPodUid = \_ podName -> pure . Right $ case podName of
          "labs-postgres-0" -> "uid-pg"
          "labs-clickhouse-0" -> "uid-ch"
          _ -> "uid-redis"
      , clock = (\n -> "2026-10-31T16:00:" <> T.justifyRight 2 '0' (T.pack (show (n `mod` 60))) <> "Z") <$> atomicModifyIORef' ticks (\n -> (n + 1, n))
      }
  where
    members =
      [ KubernetesMember "platform:upstream" "platform:upstream/controller/deployment" (workload "Deployment" "knative-serving" "controller" [("app", "controller"), ("app.kubernetes.io/version", "1.19.0")] [("app", "controller")] ["gcr.io/knative-releases/controller@sha256:new"])
      , KubernetesMember "platform:upstream" "platform:upstream/broken/deployment" (workload "Deployment" "knative-serving" "broken" [] [("app", "broken")] [])
      , KubernetesMember "platform:upstream" "platform:upstream/settings/configmap" (bytesOf (object ["kind" .= ("ConfigMap" :: Text), "metadata" .= object ["name" .= ("settings" :: Text), "namespace" .= ("knative-serving" :: Text)]]))
      , HelmMember "platform:observability" "platform:observability/grafana/release" "observability" "grafana" (bytesOf (object ["chartPath" .= ("cluster/observability/vendor/grafana-9.3.1.tgz" :: Text), "valuesDigest" .= ("SECRET-SENTINEL" :: Text)]))
      , KubernetesMember "standalone:labs-postgres" "standalone:labs-postgres/server/statefulset" (server "labs-postgres" "postgres" "postgres:18")
      , KubernetesMember "standalone:labs-clickhouse" "standalone:labs-clickhouse/server/statefulset" (server "labs-clickhouse" "clickhouse" "clickhouse/clickhouse-server:25.8.2.29")
      , KubernetesMember "application:cache" "application:cache/labs-redis/statefulset" (server "labs-redis" "redis" "redis:8")
      ]
    server name' engine' image = workload "StatefulSet" "databases" name' [("nagare.dev/engine", engine'), ("nagare.dev/database", name')] [("nagare.dev/database", name')] [image]

workload :: Text -> Text -> Text -> [(Text, Text)] -> [(Text, Text)] -> [Text] -> ByteString
workload kind' namespace' name' labels selector images =
  bytesOf
    ( object
        [ "kind" .= kind'
        , "metadata" .= object ["name" .= name', "namespace" .= namespace', "labels" .= Map.fromList labels]
        , "spec"
            .= object
              [ "selector" .= object ["matchLabels" .= Map.fromList selector]
              , "template"
                  .= object
                    [ "metadata" .= object ["labels" .= Map.fromList selector]
                    , "spec" .= object ["containers" .= [object ["name" .= ("main" :: Text), "image" .= image, "env" .= [object ["name" .= ("PASSWORD" :: Text), "value" .= ("SECRET-SENTINEL" :: Text)]]] | image <- images]]
                    ]
              ]
        ]
    )

podValue :: Text -> Text -> [(Text, Text)] -> Text -> Value
podValue name' uid' labels digest =
  object
    [ "metadata" .= object ["name" .= name', "uid" .= uid', "labels" .= Map.fromList labels]
    , "status" .= object ["phase" .= ("Running" :: Text), "containerStatuses" .= [object ["name" .= ("main" :: Text), "image" .= ("image-of-" <> name'), "imageID" .= ("registry.example/" <> name' <> "@" <> digest)]]]
    ]

podsJson :: [Value] -> ByteString
podsJson items = bytesOf (object ["items" .= items])

nodesJson :: Text -> Text -> ByteString
nodesJson name' osImage' =
  bytesOf
    ( object
        [ "items"
            .= [ object
                   [ "metadata" .= object ["name" .= name', "uid" .= ("node-uid" :: Text)]
                   , "status" .= object ["nodeInfo" .= object ["osImage" .= osImage', "kernelVersion" .= ("6.12.40" :: Text), "kubeletVersion" .= ("v1.33.4+k3s1" :: Text)]]
                   ]
               ]
        ]
    )

configMap :: [(Text, Text)] -> ByteString
configMap fields = bytesOf (object ["data" .= Map.fromList fields])

bytesOf :: Value -> ByteString
bytesOf = LBS.toStrict . encode

-- | An in-memory object transport with generations, like GCS.
memoryObjectOps :: IO ObjectOps
memoryObjectOps = do
  state <- newIORef (0 :: Integer, Map.empty :: Map.Map ObjectName (Generation, ByteString))
  let get name = maybe ObjectAbsent (uncurry ObjectFound) . Map.lookup name . snd <$> readIORef state
  pure
    ObjectOps
      { getObject = get
      , getImmutableObject = fmap immutableGet . get
      , getObjects = \_ -> pure (Left "no listing")
      , putObject = \condition name bytes -> atomicModifyIORef' state $ \(lastGeneration, objects) ->
          let existing = Map.lookup name objects
              matches = case condition of
                IfAbsent -> isNothing existing
                IfGenerationMatches expected -> maybe False ((== expected) . fst) existing
           in if matches
                then ((lastGeneration + 1, Map.insert name (Generation (lastGeneration + 1), bytes) objects), PutWritten (Generation (lastGeneration + 1)))
                else ((lastGeneration, objects), PutPreconditionFailed)
      , listObjects = \_ -> Right . Map.keys . snd <$> readIORef state
      , pauseBeforeRetry = threadDelay
      }

pop :: IORef [Text] -> IO Text
pop ref = atomicModifyIORef' ref $ \case
  [only] -> ([only], only)
  next : rest -> (rest, next)
  [] -> ([], "")

value' :: Fact -> Maybe Text
value' fact = unNullable (fact ^. #value)

reason' :: Fact -> Maybe Text
reason' fact = unNullable (fact ^. #reason)

unNullable :: Nullable a -> Maybe a
unNullable (Nullable present) = present

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
