-- | EP-183 M3: ingestion of a scheduled volume run. A volume's run compiles
-- through the database ingestion with one pin fewer: its only source is the
-- claim the accepted CronJob is ordered after. The world test runs the
-- rendered volume producer, then the rendered ingestion Job's own verify
-- script against the stored archive and receipt.
module Nagare.Test.Backup.VolumeIngest
  ( volumeIngestTests
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.Backup (renderInventoryVolumeBackupCronJob)
import Nagare.Dsl.Prelude hiding ((<.>))
import Nagare.Dsl.Render (renderPersistentVolumeClaims)
import Nagare.Dsl.Types
  ( AccessMode (ReadWriteOnce)
  , RetentionPolicy (Retain)
  , Volume (..)
  , mkMountPath
  , mkQuantity
  , mkVolumeName
  )
import Nagare.Inventory.Application (compileVolumeBackups)
import Nagare.Inventory.Backup
  ( ScheduledBackupReceipt (..)
  , ScheduledReceiptExpectation (..)
  , parseScheduledBackupReceipt
  , scheduledVolumeReceiptExpectationFromCronJob
  )
import Nagare.Inventory.BackupFreshness (RecoveryPointObjective (HourlyRecoveryPoint))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.ScheduledIngest
import Nagare.Inventory.ScheduledReceipt (ScheduledReceiptEvidence (..))
import Nagare.Inventory.Store (ScopeRevision (..))
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Durable), RecoveryIntent (..), Sensitivity (Private), mkSecretRef)
import Nagare.Resource.Policy qualified as Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Support.Profiles (hourlyGcsBackup)
import System.Directory (createDirectoryIfMissing, findExecutable)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

unsafe :: (Show e) => Either e a -> a
unsafe = either (error . show) id

backend :: StoreBackend
backend = GcsBackend "project" "bucket"

schedule :: Text
schedule = "nagare-volbackup-scenario-a-uploads"

uid :: Text -> Resource.PhysicalIdentity
uid = unsafe . Resource.mkPhysicalIdentity

claimUid, cronUid, signingUid :: Resource.PhysicalIdentity
claimUid = uid "11111111-1111-1111-1111-111111111111"
cronUid = uid "22222222-2222-2222-2222-222222222222"
signingUid = uid "55555555-5555-5555-5555-555555555555"

runId :: Text
runId = "12345678-1234-1234-1234-123456789abc"

-- | The accepted application scope: one retained claim plus the backup
-- members compiled for it, with their native bytes.
data Fixture = Fixture
  { scope :: !ScopeDeclaration
  , native :: !(Map Resource.ResourceId (ManagedResource, ByteString))
  , claim :: !ManagedResource
  , cron :: !ManagedResource
  , signing :: !ManagedResource
  }
  deriving stock (Generic)

fixture :: Fixture
fixture =
  let owner = unsafe (Resource.mkScopeId Resource.Application "personal-scenario-a")
      foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")
      cluster = Resource.mintResourceId foundation (unsafe (Resource.mkLogicalKey "cluster")) (unsafe (Resource.mkName "resource"))
      namespaceId = Resource.mintResourceId foundation (unsafe (Resource.mkLogicalKey "foundation")) (unsafe (Resource.mkName "namespace-personal"))
      recovery = RecoveryIntent (unsafe (Resource.mkName "backup")) (mkSecretRef (unsafe (Resource.mkName "volume-key")) (unsafe (Resource.mkName "v1")) :| [])
      source = Resource.SourceLocation "test" "volume-ingest"
      volume =
        Volume
          { name = unsafe (mkVolumeName "uploads")
          , logicalKey = Nothing
          , size = unsafe (mkQuantity "1Gi")
          , mountPath = unsafe (mkMountPath "/uploads")
          , accessMode = ReadWriteOnce
          , readOnly = False
          , retention = Retain
          }
      claimValue = case renderPersistentVolumeClaims "scenario-a" "personal" [volume] of
        [single] -> unsafe (Yaml.decodeEither' single :: Either Yaml.ParseException Value)
        _ -> error "one claim"
      claimId = Resource.mintResourceId owner (unsafe (Resource.mkLogicalKey "uploads")) (unsafe (Resource.mkName "service-pvc"))
      bound =
        unsafe
          ( bindKubernetesObject
              KubernetesInput
                { resourceId = claimId
                , ownerScope = owner
                , clusterId = cluster
                , inputObject = claimValue
                , objectDigest = contentDigest (unsafe (canonicalValue claimValue))
                , lifecyclePolicy = Policy.Retain
                , inputDataPolicy = Durable recovery
                , inputSensitivity = Private
                , sourceLocation = source
                }
          )
      claimNative = Map.singleton claimId bound
      (bundle, backupNative) = case unsafe (compileVolumeBackups hourlyGcsBackup namespaceId source claimNative) of
        [single] -> single
        _ -> error "one backup bundle"
      allNative = Map.union claimNative backupNative
      named kind objectName =
        case [ member
             | (member, _) <- Map.elems allNative
             , Resource.Kubernetes _ _ k (Just _) n <- [member ^. #address]
             , Resource.nameText k == kind
             , Resource.nameText n == objectName
             ] of
          [single] -> single
          _ -> error ("fixture lacks one " <> T.unpack kind)
      declared = unsafe (mkScopeDeclaration owner [ResourceBundle [Managed (fst bound)] [] [] [] [] [], bundle])
   in Fixture declared allNative (fst bound) (named "cronjob" schedule) (named "secret" (schedule <> "-signing"))

revision :: ScopeRevision
revision = ScopeRevision (unsafe (Resource.mkScopeGeneration 1)) (contentDigest "accepted")

expectation :: ScheduledReceiptExpectation
expectation = unsafe (scheduledVolumeReceiptExpectationFromCronJob backend "personal" schedule claimUid (snd (native fixture Map.! (fixture ^. #cron . #identity))))

request :: ScheduledBackupReceipt -> Integer -> Integer -> ContentDigestLike -> ScheduledIngestRequest
request receipt objectLength receiptLength receiptDigest =
  ScheduledIngestRequest
    { ingestSourceKind = IngestVolume schedule
    , ingestNamespace = "personal"
    , ingestBackupId = runId
    , ingestSourceRevision = revision
    , ingestPvcUid = claimUid
    , ingestScheduleUid = cronUid
    , ingestSigningUid = signingUid
    , ingestEvidence =
        ScheduledReceiptEvidence
          { scheduledReceipt = receipt
          , scheduledObjectVersion = "1"
          , scheduledReceiptVersion = "1"
          , scheduledObjectLength = objectLength
          , scheduledReceiptLength = receiptLength
          , scheduledReceiptDigest = receiptDigest
          }
    , ingestBackend = backend
    , ingestSource = Resource.SourceLocation "storage backup-receipts/scenario-a/uploads" runId
    , ingestAcceptedIncarnations =
        Map.fromList
          [ (fixture ^. #claim . #identity, claimUid)
          , (fixture ^. #signing . #identity, signingUid)
          , (fixture ^. #cron . #identity, cronUid)
          ]
    }

type ContentDigestLike = Resource.ContentDigest

syntheticRequest :: ScheduledIngestRequest
syntheticRequest =
  request
    ( ScheduledBackupReceipt
        (uid runId)
        (scheduledObjectPrefix expectation <> runId <> ".tar.gz")
        (T.replicate 64 "0")
        (scheduledPolicyRevision expectation)
        Nothing
    )
    1
    1
    (contentDigest "receipt")

compiled :: ScheduledIngestRequest -> Either (NonEmpty Resource.InventoryError) (ScopeDeclaration, Map Resource.ResourceId (ManagedResource, ByteString))
compiled r = compileScheduledIngestScope r (fixture ^. #scope) (fixture ^. #native)

jobValue :: Map Resource.ResourceId (ManagedResource, ByteString) -> Value
jobValue m = case Map.elems m of
  [(_, bytes)] -> unsafe (eitherDecodeStrict bytes)
  _ -> error "one ingestion Job"

at' :: [Text] -> Value -> Maybe Value
at' [] value = Just value
at' (key : rest) (Object fields) = KeyMap.lookup (Key.fromText key) fields >>= at' rest
at' (key : rest) (Array values) | key == "0", (first' : _) <- V.toList values = at' rest first'
at' _ _ = Nothing

volumeIngestTests :: [TestTree]
volumeIngestTests =
  [ testCase "a volume run ingests with exactly its claim, schedule and signing key as sources" $ do
      (receiptScope, jobs) <- either (assertFailure . show) pure (compiled syntheticRequest)
      Resource.scopeIdText (scopeId receiptScope)
        @?= "standalone:volume-scheduled-receipt-personal-" <> schedule <> "-" <> runId
      let overrides = scopeOverrides receiptScope
      Map.lookup "scheduled.backup.source.kind" overrides @?= Just "volume"
      Map.lookup "scheduled.backup.source.pvc" overrides @?= Just (Resource.resourceIdText (fixture ^. #claim . #identity))
      assertBool "a volume run names a StatefulSet" (not (any (T.isPrefixOf "scheduled.backup.source.statefulset") (Map.keys overrides)))
      member <- case Map.elems jobs of
        [(single, _)] -> pure single
        _ -> assertFailure "one ingestion Job" >> fail "job"
      member ^. #dependencies @?= sort (map (OrderedAfter . (^. #identity)) [claim fixture, cron fixture, signing fixture])
      let bytes = snd (head (Map.elems jobs))
      scheduledIngestJobSourcePins bytes
        @?= Right (Just [(fixture ^. #claim . #identity, claimUid), (fixture ^. #cron . #identity, cronUid), (fixture ^. #signing . #identity, signingUid)])
      proof <- either (assertFailure . T.unpack) pure (scheduledIngestSourceProof receiptScope)
      fmap scheduledSourceStatefulId proof @?= Just Nothing
      let envNames = case at' ["spec", "template", "spec", "containers", "0", "env"] (jobValue jobs) of
            Just (Array values) -> [n | Object e <- V.toList values, Just (String n) <- [KeyMap.lookup "name" e]]
            _ -> []
      assertBool "a volume Job carries a StatefulSet UID" ("STATEFUL_UID" `notElem` envNames)
  , testCase "a volume run is refused for another claim incarnation, a database shape, or a StatefulSet pin" $ do
      assertBool
        "a replaced claim became a recovery point"
        (isLeft (compiled syntheticRequest {ingestPvcUid = uid "33333333-3333-3333-3333-333333333333"}))
      assertBool
        "a database-shaped request ingested a volume run"
        (isLeft (compiled syntheticRequest {ingestSourceKind = IngestDatabase "uploads" claimUid}))
      assertBool
        "another schedule name was accepted"
        (isLeft (compiled syntheticRequest {ingestSourceKind = IngestVolume "nagare-volbackup-scenario-a-other"}))
      (_, jobs) <- either (assertFailure . show) pure (compiled syntheticRequest)
      let withStateful = case jobValue jobs of
            Object root ->
              let addPin (Object metadata) = case KeyMap.lookup "annotations" metadata of
                    Just (Object annotations) ->
                      Object (KeyMap.insert "annotations" (Object (KeyMap.insert "nagare.dev/scheduled-receipt-source-statefulset" (String "x") annotations)) metadata)
                    _ -> Object metadata
                  addPin other = other
               in Object (maybe root (\m -> KeyMap.insert "metadata" (addPin m) root) (KeyMap.lookup "metadata" root))
            other -> other
      assertBool
        "a volume Job with a StatefulSet pin was accepted"
        (isLeft (scheduledIngestJobSourcePins (BL.toStrict (encode withStateful))))
  , testCase "the rendered ingestion Job verifies a real volume receipt and the database script refuses it" $
      withSystemTempDirectory "nagare-volume-ingest" $ \directory -> do
        realPython <- findExecutable "python3" >>= maybe (assertFailure "volume ingest test requires python3" >> pure "") pure
        let claimDir = directory </> "claim"
            dump = directory </> "dump"
            work = directory </> "work"
            dataObject = directory </> "object"
            receiptObject = directory </> "receipt"
            source = directory </> "source.json"
            dataUrl = scheduledObjectPrefix expectation <> runId <> ".tar.gz"
            receiptUrl = dataUrl <> ".receipt.json"
            cronValue = unsafe (Yaml.decodeEither' (renderInventoryVolumeBackupCronJob HourlyRecoveryPoint "personal" "scenario-a" "uploads" backend 7) :: Either Yaml.ParseException Value)
            container field containerName = case at' ["spec", "jobTemplate", "spec", "template", "spec", field] cronValue of
              Just (Array values) -> case [c | c <- V.toList values, at' ["name"] c == Just (String containerName)] of
                [single] -> single
                _ -> error "container"
              _ -> error "containers"
            shellOf c = case at' ["args"] c of
              Just (Array values) | [String script] <- V.toList values -> script
              _ -> error "script"
            plainEnv c = case at' ["env"] c of
              Just (Array values) -> [(T.unpack n, T.unpack v) | Object e <- V.toList values, Just (String n) <- [KeyMap.lookup "name" e], Just (String v) <- [KeyMap.lookup "value" e]]
              _ -> []
            localize = T.unpack . T.replace "/source-data" (T.pack claimDir) . T.replace "/dump" (T.pack dump) . T.replace "/work/" (T.pack (work <> "/")) . T.replace "/dev/termination-log" (T.pack (directory </> "ingest-termination-log"))
            fakeGcloud = directory </> "gcloud"
            fakeGsutil = directory </> "gsutil"
            fakePython = directory </> "python3"
        mapM_ (createDirectoryIfMissing True) [claimDir, dump, work]
        BS.writeFile (claimDir </> "photo.bin") (BS.pack [0 .. 255])
        BS.writeFile source "{\"pvcUid\":\"11111111-1111-1111-1111-111111111111\"}\n"
        -- One fake answers the producer's create-only uploads and the
        -- ingestion's exact-generation describe and download.
        writeFile fakeGcloud $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "target() { case \"$1\" in \"$NAGARE_TEST_RECEIPT_URL\") echo \"$NAGARE_TEST_RECEIPT\";; \"$NAGARE_TEST_DATA_URL\") echo \"$NAGARE_TEST_DATA\";; *) exit 3;; esac; }"
            , "if [ \"$2\" = cp ] && [ \"$5\" = --if-generation-match=0 ]; then t=$(target \"$4\"); [ ! -e \"$t\" ] || exit 47; cat \"$3\" > \"$t\"; exit 0; fi"
            , "if [ \"$2\" = objects ] && [ \"$3\" = describe ]; then"
            , "  case \"$4\" in *#1) ;; *) exit 4;; esac"
            , "  url=${4%#1}; t=$(target \"$url\"); key=${url#gs://bucket/}"
            , "  printf '{\"bucket\":\"bucket\",\"name\":\"%s\",\"generation\":1,\"size\":%s}' \"$key\" \"$(wc -c < \"$t\" | tr -d ' ')\"; exit 0"
            , "fi"
            , "if [ \"$2\" = cp ] && [ \"$3\" = --do-not-decompress ]; then case \"$4\" in *#1) ;; *) exit 4;; esac; t=$(target \"${4%#1}\"); cat \"$t\" > \"$5\"; exit 0; fi"
            , "exit 2"
            ]
        writeFile fakeGsutil $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "case \"$2\" in \"$NAGARE_TEST_DATA_URL\") cat \"$NAGARE_TEST_DATA\";; \"$NAGARE_TEST_RECEIPT_URL\") cat \"$NAGARE_TEST_RECEIPT\";; *) exit 3;; esac"
            ]
        writeFile fakePython $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "case \"$2\" in *urllib.request*) cat \"$NAGARE_TEST_SOURCE\";; *) exec \"$NAGARE_TEST_REAL_PYTHON\" \"$@\";; esac"
            ]
        mapM_ (`setFileMode` 0o755) [fakeGcloud, fakeGsutil, fakePython]
        parentEnv <- getEnvironment
        let path = maybe "" id (lookup "PATH" parentEnv)
            common =
              [ ("PATH", directory <> ":" <> path)
              , ("BACKUP_SIGNING_KEY", replicate 64 'a')
              , ("NAGARE_TEST_DATA", dataObject)
              , ("NAGARE_TEST_RECEIPT", receiptObject)
              , ("NAGARE_TEST_DATA_URL", T.unpack dataUrl)
              , ("NAGARE_TEST_RECEIPT_URL", T.unpack receiptUrl)
              , ("NAGARE_TEST_SOURCE", source)
              , ("NAGARE_TEST_REAL_PYTHON", realPython)
              ]
            run extra script =
              readCreateProcessWithExitCode
                ((proc "/bin/sh" ["-c", script]) {env = Just (extra <> common <> filter ((`notElem` map fst (extra <> common)) . fst) parentEnv)})
                ""
            producerEnv =
              plainEnv (container "containers" "upload")
                <> plainEnv (container "initContainers" "source")
                <> [("BACKUP_RUN_ID", T.unpack runId), ("BACKUP_TERMINATION_LOG_PATH", work </> "producer-log")]
        forM_' [shellOf (container "initContainers" "source"), shellOf (container "initContainers" "dump"), shellOf (container "containers" "upload")] $ \script -> do
          (code, _, err) <- run producerEnv (localize script)
          assertBool ("producer container failed: " <> err) (code == ExitSuccess)
        receiptBytes <- BS.readFile receiptObject
        objectBytes <- BS.readFile dataObject
        receipt <- either (assertFailure . T.unpack) pure (parseScheduledBackupReceipt expectation receiptUrl (T.replicate 64 "a") receiptBytes)
        let real =
              request
                receipt
                (fromIntegral (BS.length objectBytes))
                (fromIntegral (BS.length receiptBytes))
                (contentDigest receiptBytes)
        (_, jobs) <- either (assertFailure . show) pure (compiled real)
        let job = jobValue jobs
            verify = case at' ["spec", "template", "spec", "containers", "0"] job of
              Just c -> c
              Nothing -> error "verify container"
            ingestEnv = [(k, v) | (k, v) <- plainEnv verify]
        (code, _, err) <- run ingestEnv (localize (shellOf verify))
        assertBool ("the volume ingestion Job refused its own receipt: " <> err) (code == ExitSuccess)
        terminal <- BS.readFile (directory </> "ingest-termination-log")
        assertBool "the ingestion Job wrote no terminal proof" (not (BS.null terminal))
        -- The database script demands a StatefulSet the volume receipt never names.
        (refused, _, _) <- run (("STATEFUL_UID", "11111111-1111-1111-1111-111111111111") : ingestEnv) (localize (ingestScriptFor backend))
        assertBool "the database script accepted a volume receipt" (refused /= ExitSuccess)
  ]
  where
    forM_' xs f = mapM_ f xs
