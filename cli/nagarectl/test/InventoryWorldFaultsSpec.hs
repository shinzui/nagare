-- | EP-182 M3: every world fault acts where it should, records that it did,
-- and records nothing where it changes nothing. Each case seeds the fake
-- cluster, schedules one fault at the first boundary of its call, sends the
-- request the production runtime would send, and checks the effect.
module InventoryWorldFaultsSpec (inventoryWorldFaultsTests) where

import Control.Exception (try)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.KubernetesTransport (KubectlRequest (..), KubectlResult)
import Nagare.Resource.Types (digestText)
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.World.Adversary
import Nagare.Test.World.ApiServer
import Nagare.Test.World.Cluster
import System.Exit (ExitCode (..))
import Test.Tasty
import Test.Tasty.HUnit

inventoryWorldFaultsTests :: TestTree
inventoryWorldFaultsTests =
  testGroup
    "world faults"
    [ testCase "fault acts: LostAcknowledgement (the write lands, kubectl reports a transport error)" $ do
        (cluster, result) <- once [history "v1"] MutateCall LostAcknowledgement (apply (history "v2"))
        exitOf result @?= Just (ExitFailure 1)
        dataOf cluster historyKey >>= (@?= Just "v2")
        assertActed cluster LostAcknowledgement
    , testCase "fault acts: RefusedBeforeEffect (a 4xx refusal, nothing written)" $ do
        (cluster, result) <- once [history "v1"] MutateCall RefusedBeforeEffect (apply (history "v2"))
        stderrOf result >>= assertBool "a Forbidden refusal" . ("Error from server (Forbidden)" `T.isPrefixOf`)
        dataOf cluster historyKey >>= (@?= Just "v1")
        assertActed cluster RefusedBeforeEffect
    , testCase "fault acts: LandsUnready (the written revision never becomes Ready)" $ do
        (cluster, result) <- once [service "v1"] MutateCall LandsUnready (apply (service "v2"))
        exitOf result @?= Just ExitSuccess
        readyOf cluster serviceKey >>= (@?= Just "False")
        assertActed cluster LandsUnready
    , testCase "fault does not act: LandsUnready on a kind without readiness" $ do
        (cluster, _) <- once [history "v1"] MutateCall LandsUnready (apply (history "v2"))
        assertNotActed cluster LandsUnready
    , testCase "fault acts: LandsFailed (a Job fails terminally)" $ do
        (cluster, _) <- once [] MutateCall LandsFailed (createRequest job)
        conditionsOf cluster jobKey >>= assertBool "Failed=True" . elem ("Failed", "True")
        assertActed cluster LandsFailed
    , testCase "fault acts: StatusChurn (a controller writes status just before the write)" $ do
        -- The runtime writes with the resourceVersion it just observed; the
        -- controller's status write moves it first, so the write conflicts.
        cluster <- seeded [service "v1"] [(Boundary MutateCall 1, StatusChurn)]
        observed <- (>>= textOf . field "resourceVersion" . field "metadata") <$> live cluster serviceKey
        result <- clusterAnswer cluster (apply (stamp observed (service "v2")))
        stderrOf result >>= assertBool "the moved resourceVersion is refused" . ("error: Operation cannot be fulfilled" `T.isPrefixOf`)
        assertActed cluster StatusChurn
    , testCase "fault does not act: StatusChurn on a kind without a status subresource" $ do
        (cluster, _) <- once [history "v1"] MutateCall StatusChurn (apply (history "v2"))
        assertNotActed cluster StatusChurn
    , testCase "fault acts: ForeignManager (another writer takes a reviewed field)" $ do
        (cluster, _) <- once [history "v1"] MutateCall ForeignManager (apply (history "v2"))
        writersOf cluster historyKey >>= assertBool "kubectl-edit owns a field" . elem "kubectl-edit"
        assertActed cluster ForeignManager
    , testCase "fault acts: Interrupt (the executor dies after the write lands)" $ do
        cluster <- seeded [history "v1"] [(Boundary MutateCall 1, Interrupt)]
        outcome <- try (clusterAnswer cluster (apply (history "v2")))
        case outcome of
          Left Interrupted -> pure ()
          Right _ -> assertFailure "the executor was not interrupted"
        dataOf cluster historyKey >>= (@?= Just "v2")
        assertActed cluster Interrupt
    , testCase "fault acts: ChurnAlways (a ResourceQuota's status moves before every observation)" $ do
        cluster <- seeded [quota] [(Boundary ObserveCall 1, ChurnAlways)]
        first' <- versionAfter cluster (get' quotaKey)
        second' <- versionAfter cluster (get' quotaKey)
        assertBool "resourceVersion moved between observations" (first' /= second')
        assertActed cluster ChurnAlways
    , testCase "fault does not act: ChurnAlways on a Knative Service, which does not churn at steady state (RES-4 E10)" $ do
        cluster <- seeded [service "v1"] [(Boundary ObserveCall 1, ChurnAlways)]
        first' <- versionAfter cluster (get' serviceKey)
        second' <- versionAfter cluster (get' serviceKey)
        first' @?= second'
        assertNotActed cluster ChurnAlways
    , testCase "fault acts: ForeignObject (an unowned object at an empty address)" $ do
        (cluster, result) <- once [] ObserveCall ForeignObject (get' historyKey)
        stdoutOf result >>= assertBool "the observation finds an object" . not . T.null
        stampOf cluster historyKey >>= (@?= Nothing)
        assertActed cluster ForeignObject
    , testCase "fault does not act: ForeignObject on an occupied address" $ do
        (cluster, _) <- once [history "v1"] ObserveCall ForeignObject (get' historyKey)
        stampOf cluster historyKey >>= assertBool "Nagare's object is untouched" . isJust
        assertNotActed cluster ForeignObject
    , testCase "fault acts: Replaced (deleted and recreated with the same stamp and a new UID)" $ do
        cluster <- seeded [history "v1"] [(Boundary ObserveCall 1, Replaced)]
        before <- uidOf cluster historyKey
        _ <- clusterAnswer cluster (get' historyKey)
        after' <- uidOf cluster historyKey
        assertBool "a new UID" (isJust after' && after' /= before)
        stampOf cluster historyKey >>= assertBool "the stamp was copied" . isJust
        assertActed cluster Replaced
    , testCase "fault acts: Deleted (deleted out of band; a PVC in use stays Terminating)" $ do
        (cluster, _) <- once [history "v1"] ObserveCall Deleted (get' historyKey)
        uidOf cluster historyKey >>= (@?= Nothing)
        assertActed cluster Deleted
        claim <- seeded [volume] [(Boundary ObserveCall 1, Deleted)]
        modifyIORef' (server claim) (mountClaim volumeKey)
        _ <- clusterAnswer claim (get' volumeKey)
        held <- get False volumeKey <$> readIORef (server claim)
        (field "deletionTimestamp" . field "metadata" <$> held) /= Nothing @? "the claim is Terminating"
        assertActed claim Deleted
    , testCase "fault acts: TransientReadFailure (one observation cannot be read)" $ do
        (cluster, result) <- once [history "v1"] ObserveCall TransientReadFailure (get' historyKey)
        exitOf result @?= Just (ExitFailure 1)
        assertActed cluster TransientReadFailure
    , testCase "fault acts: ControllerLag (Ready stays from the previous generation until the next write)" $ do
        (cluster, _) <- once [service "v1"] MutateCall ControllerLag (apply (service "v2"))
        stale <- get False serviceKey <$> readIORef (server cluster)
        (generationOf stale, observedOf stale, readyOf' stale) @?= (Just 2, Just 1, Just "True")
        assertActed cluster ControllerLag
        -- Observing does not wake the controller; only the next write does.
        _ <- clusterAnswer cluster (get' serviceKey)
        observed <- get False serviceKey <$> readIORef (server cluster)
        (generationOf observed, observedOf observed) @?= (Just 2, Just 1)
        _ <- clusterAnswer cluster (apply (service "v3"))
        caught <- get False serviceKey <$> readIORef (server cluster)
        (generationOf caught, observedOf caught) @?= (Just 3, Just 3)
    , testCase "world rule: a StatefulSet correction stays stuck until its unready pod is deleted (RES-4 E6)" $ do
        cluster <- seeded [statefulSet "good"] []
        modifyIORef' (server cluster) (#outcomes %~ Map.insert (digestOf (statefulSet "broken")) Unready)
        _ <- clusterAnswer cluster (apply (statefulSet "broken"))
        _ <- clusterAnswer cluster (apply (statefulSet "fixed"))
        stuck <- get False statefulKey <$> readIORef (server cluster)
        (readyReplicasOf stuck, revisionsEqualOf stuck) @?= (Nothing, Just False)
        pod <- getPod (Just "personal") "db-0" <$> readIORef (server cluster)
        let uid' = field "uid" . field "metadata" <$> pod
        result <- clusterAnswer cluster (deletePodRequest uid')
        exitOf result @?= Just ExitSuccess
        rolled <- get False statefulKey <$> readIORef (server cluster)
        (readyReplicasOf rolled, revisionsEqualOf rolled) @?= (Just 1, Just True)
    ]

-- * Fixtures

modelContext :: Text
modelContext = "model-context"

-- | A manifest as the adapter writes it: stamped as this member's, at the
-- digest of its unstamped bytes.
stamp :: Maybe Text -> Value -> Value
stamp version value = case value of
  Object root ->
    let metadata = objectOf (field "metadata" value)
        annotations =
          KM.fromList
            [ ("nagare.dev/context-id", String modelContext)
            , ("nagare.dev/resource-id", String ("model/" <> fromMaybe "" (textOf (field "name" (field "metadata" value)))))
            , ("nagare.dev/spec-digest", String (digestOf value))
            ]
        metadata' = KM.insert "annotations" (Object annotations) (maybe metadata (\v -> KM.insert "resourceVersion" (String v) metadata) version)
     in Object (KM.insert "metadata" (Object metadata') root)
  other -> other

digestOf :: Value -> Text
digestOf value = either (const "") (digestText . contentDigest) (canonicalValue value)

named :: Text -> Text -> Text -> [(Key.Key, Value)] -> Value
named apiVersion kindName name' rest = object (["apiVersion" .= apiVersion, "kind" .= kindName, "metadata" .= object ["name" .= name', "namespace" .= ("personal" :: Text)]] <> map (uncurry (.=)) rest)

history :: Text -> Value
history v = named "v1" "ConfigMap" "web-history" [("data", object ["current" .= v])]

service :: Text -> Value
service v = named "serving.knative.dev/v1" "Service" "web" [("spec", object ["template" .= object ["spec" .= object ["containers" .= [object ["image" .= ("registry.example/web:" <> v)]]]]])]

quota :: Value
quota = named "v1" "ResourceQuota" "web-quota" [("spec", object ["hard" .= object ["pods" .= ("10" :: Text)]])]

volume :: Value
volume = named "v1" "PersistentVolumeClaim" "web-uploads" [("spec", object ["accessModes" .= ["ReadWriteOnce" :: Text], "resources" .= object ["requests" .= object ["storage" .= ("1Gi" :: Text)]]])]

job :: Value
job = named "batch/v1" "Job" "backup" [("spec", object ["template" .= object ["spec" .= object ["restartPolicy" .= ("Never" :: Text), "containers" .= [object ["image" .= ("registry.example/backup" :: Text)]]]]])]

statefulSet :: Text -> Value
statefulSet v = named "apps/v1" "StatefulSet" "db" [("spec", object ["replicas" .= (1 :: Int), "serviceName" .= ("db" :: Text), "template" .= object ["metadata" .= object ["annotations" .= object ["v" .= v]], "spec" .= object ["containers" .= [object ["image" .= ("postgres:18" :: Text)]]]]])]

historyKey, serviceKey, quotaKey, volumeKey, jobKey, statefulKey :: ObjectKey
historyKey = ObjectKey "" "configmap" (Just "personal") "web-history"
serviceKey = ObjectKey "serving.knative.dev" "service" (Just "personal") "web"
quotaKey = ObjectKey "" "resourcequota" (Just "personal") "web-quota"
volumeKey = ObjectKey "" "persistentvolumeclaim" (Just "personal") "web-uploads"
jobKey = ObjectKey "batch" "job" (Just "personal") "backup"
statefulKey = ObjectKey "apps" "statefulset" (Just "personal") "db"

-- * Requests, as the production runtime sends them

apply :: Value -> KubectlRequest
apply value = KubectlRequest "world" ["apply", "--server-side", "--force-conflicts", "--field-manager=nagare-inventory", "-f", "-", "-o", "json"] (LBS8.unpack (encode (stampIfBare value)))
  where
    stampIfBare v = if isJust (specDigestOf v) then v else stamp Nothing v

createRequest :: Value -> KubectlRequest
createRequest value = KubectlRequest "world" ["create", "--field-manager=nagare-inventory", "-f", "-", "-o", "json"] (LBS8.unpack (encode (stamp Nothing value)))

get' :: ObjectKey -> KubectlRequest
get' key = KubectlRequest "world" (["get", token key, T.unpack (key ^. #name)] <> ["--namespace" | isJust (key ^. #namespace)] <> maybe [] (pure . T.unpack) (key ^. #namespace) <> ["-o", "json", "--ignore-not-found"]) ""
  where
    token k = T.unpack (if k ^. #group == "" then k ^. #kind else k ^. #kind <> "." <> k ^. #group)

deletePodRequest :: Maybe Value -> KubectlRequest
deletePodRequest uid' =
  KubectlRequest "world" ["delete", "--raw", "/api/v1/namespaces/personal/pods/db-0", "-f", "-"] (LBS8.unpack (encode (object ["apiVersion" .= ("meta.k8s.io/v1" :: Text), "kind" .= ("DeleteOptions" :: Text), "preconditions" .= object ["uid" .= uid']])))

-- * Running

seeded :: [Value] -> [(Boundary, Fault)] -> IO Cluster
seeded objects' schedule' = do
  adversary' <- newAdversary schedule'
  let initial = foldl' (\s v -> either (const s) fst (applyServerSide "nagare-inventory" True (stamp Nothing v) s)) emptyServer objects'
  newCluster initial adversary'

once :: [Value] -> Call -> Fault -> KubectlRequest -> IO (Cluster, KubectlResult)
once objects' call fault request = do
  cluster <- seeded objects' [(Boundary call 1, fault)]
  result <- clusterAnswer cluster request
  pure (cluster, result)

assertActed :: Cluster -> Fault -> Assertion
assertActed cluster fault = do
  acted' <- map snd . acted <$> readIORef (adversary cluster)
  assertBool (show fault <> " did not record that it acted") (fault `elem` acted')

assertNotActed :: Cluster -> Fault -> Assertion
assertNotActed cluster fault = do
  acted' <- map snd . acted <$> readIORef (adversary cluster)
  assertBool (show fault <> " recorded acting where it changed nothing") (fault `notElem` acted')

versionAfter :: Cluster -> KubectlRequest -> IO (Maybe Value)
versionAfter cluster request = do
  _ <- clusterAnswer cluster request
  fmap (field "resourceVersion" . field "metadata") . get False quotaOrService <$> readIORef (server cluster)
  where
    quotaOrService = case request ^. #arguments of
      _ : "resourcequota" : _ -> quotaKey
      _ -> serviceKey

exitOf :: KubectlResult -> Maybe ExitCode
exitOf = either (const Nothing) (\(code, _, _) -> Just code)

stderrOf :: KubectlResult -> IO Text
stderrOf = either (assertFailure . T.unpack) (\(_, _, err) -> pure (T.pack err))

stdoutOf :: KubectlResult -> IO Text
stdoutOf = either (assertFailure . T.unpack) (\(_, out, _) -> pure (T.pack out))

live :: Cluster -> ObjectKey -> IO (Maybe Value)
live cluster key = get True key <$> readIORef (server cluster)

dataOf :: Cluster -> ObjectKey -> IO (Maybe Text)
dataOf cluster key = (>>= textOf . field "current" . field "data") <$> live cluster key

uidOf :: Cluster -> ObjectKey -> IO (Maybe Text)
uidOf cluster key = (>>= textOf . field "uid" . field "metadata") <$> live cluster key

stampOf :: Cluster -> ObjectKey -> IO (Maybe Text)
stampOf cluster key = (>>= specDigestOf) <$> live cluster key

writersOf :: Cluster -> ObjectKey -> IO [Text]
writersOf cluster key = maybe [] (\v -> [m | e <- arrayOf (field "managedFields" (field "metadata" v)), Just m <- [textOf (field "manager" e)]]) <$> live cluster key

conditionsOf :: Cluster -> ObjectKey -> IO [(Text, Text)]
conditionsOf cluster key = maybe [] (\v -> [(t, s) | c <- arrayOf (field "conditions" (field "status" v)), Just t <- [textOf (field "type" c)], Just s <- [textOf (field "status" c)]]) <$> live cluster key

readyOf :: Cluster -> ObjectKey -> IO (Maybe Text)
readyOf cluster key = readyOf' <$> (settle >> live cluster key)
  where
    settle = modifyIORef' (server cluster) settleControllers

readyOf' :: Maybe Value -> Maybe Text
readyOf' = (>>= \v -> listToMaybe [s | c <- arrayOf (field "conditions" (field "status" v)), textOf (field "type" c) == Just "Ready", Just s <- [textOf (field "status" c)]])

generationOf, observedOf, readyReplicasOf :: Maybe Value -> Maybe Int
generationOf = (>>= intOf . field "generation" . field "metadata")
observedOf = (>>= intOf . field "observedGeneration" . field "status")
readyReplicasOf = (>>= intOf . field "readyReplicas" . field "status")

revisionsEqualOf :: Maybe Value -> Maybe Bool
revisionsEqualOf = fmap (\v -> field "currentRevision" (field "status" v) == field "updateRevision" (field "status" v))

-- * JSON

field :: Text -> Value -> Value
field key = \case
  Object fields -> fromMaybe Null (KM.lookup (Key.fromText key) fields)
  _ -> Null

objectOf :: Value -> KM.KeyMap Value
objectOf = \case
  Object fields -> fields
  _ -> KM.empty

textOf :: Value -> Maybe Text
textOf = \case
  String s -> Just s
  _ -> Nothing

intOf :: Value -> Maybe Int
intOf = \case
  Number n -> Just (round n)
  _ -> Nothing

arrayOf :: Value -> [Value]
arrayOf = \case
  Array values -> toList values
  _ -> []
