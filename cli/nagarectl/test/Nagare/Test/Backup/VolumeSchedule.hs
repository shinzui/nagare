-- | EP-183 M3: scheduled backups of backup-included application volumes. The
-- world test runs the three containers of the rendered volume Job in order
-- against fake object-store and Kubernetes clients, then checks the signed
-- receipt with the expectation derived from the same accepted CronJob bytes.
module Nagare.Test.Backup.VolumeSchedule
  ( volumeScheduleTests
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either (isLeft, isRight)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Data.Yaml qualified as Yaml
import Nagare.Cluster.GcsJob (StoreBackend (GcsBackend))
import Nagare.Database.Backup (renderInventoryVolumeBackupCronJob, volumeBackupScheduleName)
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
import Nagare.Inventory.Adapters.KubernetesRuntime (generatedCredentialTemplate)
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
import Nagare.Resource.Inventory (Declaration (Managed), ResourceBundle (..))
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy
  ( DataPolicy (Durable, Stateless)
  , LifecyclePolicy (DeleteWhenUnreferenced)
  , RecoveryIntent (..)
  , Sensitivity (Private)
  , mkSecretRef
  )
import Nagare.Resource.Policy qualified as Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types qualified as Resource
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.Support.Profiles (hourlyGcsBackup)
import System.Directory (createDirectoryIfMissing, doesFileExist, findExecutable, removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import Test.Tasty (TestTree)
import Test.Tasty.HUnit

backend :: StoreBackend
backend = GcsBackend "project" "bucket"

claimUid :: Resource.PhysicalIdentity
claimUid = either (error . T.unpack) id (Resource.mkPhysicalIdentity "11111111-1111-1111-1111-111111111111")

-- | The accepted native bytes of the rendered volume CronJob: canonical JSON.
cronBytes :: ByteString
cronBytes =
  either (error . T.unpack) id
    . canonicalValue
    . either (error . show) id
    $ (Yaml.decodeEither' (renderInventoryVolumeBackupCronJob HourlyRecoveryPoint "personal" "scenario-a" "uploads" backend 7) :: Either Yaml.ParseException Value)

cronValue :: Value
cronValue = either error id (eitherDecodeStrict cronBytes)

podContainers :: Text -> [Value]
podContainers field = case at' ["spec", "jobTemplate", "spec", "template", "spec", field] cronValue of
  Just (Array values) -> V.toList values
  _ -> []

container :: Text -> Text -> Value
container field name = case [c | c <- podContainers field, at' ["name"] c == Just (String name)] of
  [single] -> single
  _ -> error ("rendered volume Job lacks one " <> T.unpack name <> " container")

shellOf :: Value -> Text
shellOf c = case at' ["args"] c of
  Just (Array values) | [String script] <- V.toList values -> script
  _ -> error "container has no single shell argument"

plainEnv :: Value -> [(String, String)]
plainEnv c = case at' ["env"] c of
  Just (Array values) ->
    [ (T.unpack name, T.unpack value)
    | Object entry <- V.toList values
    , Just (String name) <- [KeyMap.lookup "name" entry]
    , Just (String value) <- [KeyMap.lookup "value" entry]
    ]
  _ -> []

at' :: [Text] -> Value -> Maybe Value
at' [] value = Just value
at' (key : rest) (Object fields) = KeyMap.lookup (Key.fromText key) fields >>= at' rest
at' _ _ = Nothing

volumeScheduleTests :: [TestTree]
volumeScheduleTests =
  [ testCase "a volume schedule archives its claim read-only and uploads a signed version-5 receipt" $
      withSystemTempDirectory "nagare-volume-schedule" $ \directory -> do
        realPython <- findExecutable "python3" >>= maybe (assertFailure "volume schedule test requires python3" >> pure "") pure
        let dump = directory </> "dump"
            claim = directory </> "claim"
            restored = directory </> "restored"
            dataObject = directory </> "object"
            receiptObject = directory </> "receipt"
            terminationLog = directory </> "termination-log"
            source = directory </> "source.json"
            runId = "12345678-1234-1234-1234-123456789abc" :: Text
            prefix = "gs://bucket/scheduled-volumes/personal/scenario-a/uploads/"
            dataUrl = prefix <> runId <> ".tar.gz"
            receiptUrl = dataUrl <> ".receipt.json"
            localize = T.unpack . T.replace "/source-data" (T.pack claim) . T.replace "/dump" (T.pack dump)
            sourceScript = localize (shellOf (container "initContainers" "source"))
            dumpScript = localize (shellOf (container "initContainers" "dump"))
            uploadScript = localize (shellOf (container "containers" "upload"))
            fakeGcloud = directory </> "gcloud"
            fakeGsutil = directory </> "gsutil"
            fakePython = directory </> "python3"
        mapM_ (createDirectoryIfMissing True) [dump, claim </> "nested", restored]
        BS.writeFile (claim </> "photo.bin") (BS.pack [0 .. 255])
        BS.writeFile (claim </> "nested" </> "notes.txt") "volume data\n"
        writeFile fakeGcloud $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "[ \"$1\" = storage ] && [ \"$2\" = cp ] && [ \"$5\" = --if-generation-match=0 ] || exit 2"
            , "case \"$4\" in"
            , "  \"$NAGARE_TEST_DATA_URL\") TARGET=$NAGARE_TEST_DATA;;"
            , "  \"$NAGARE_TEST_RECEIPT_URL\") TARGET=$NAGARE_TEST_RECEIPT;;"
            , "  *) exit 3;;"
            , "esac"
            , "[ ! -e \"$TARGET\" ] || exit 47"
            , "cat \"$3\" > \"$TARGET\""
            ]
        writeFile fakeGsutil $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "[ \"$1\" = cp ] && [ \"$3\" = - ] || exit 2"
            , "case \"$2\" in"
            , "  \"$NAGARE_TEST_DATA_URL\") cat \"$NAGARE_TEST_DATA\";;"
            , "  \"$NAGARE_TEST_RECEIPT_URL\") cat \"$NAGARE_TEST_RECEIPT\";;"
            , "  *) exit 3;;"
            , "esac"
            ]
        -- The Kubernetes reads of the source probe answer from a file; the
        -- probe must name exactly the claim (BACKUP_SOURCE_NAME).
        writeFile fakePython $
          unlines
            [ "#!/bin/sh"
            , "set -eu"
            , "case \"$2\" in *urllib.request*) [ \"$BACKUP_SOURCE_NAME\" = nagare-vol-scenario-a-uploads ] || exit 5; cat \"$NAGARE_TEST_SOURCE\";;"
            , "*) exec \"$NAGARE_TEST_REAL_PYTHON\" \"$@\";; esac"
            ]
        mapM_ (`setFileMode` 0o755) [fakeGcloud, fakeGsutil, fakePython]
        parentEnv <- getEnvironment
        let path = maybe "" id (lookup "PATH" parentEnv)
            jobEnv =
              plainEnv (container "containers" "upload")
                <> plainEnv (container "initContainers" "source")
                <> [ ("PATH", directory <> ":" <> path)
                   , ("BACKUP_RUN_ID", T.unpack runId)
                   , ("BACKUP_SIGNING_KEY", replicate 64 'a')
                   , ("BACKUP_TERMINATION_LOG_PATH", terminationLog)
                   , ("NAGARE_TEST_DATA", dataObject)
                   , ("NAGARE_TEST_RECEIPT", receiptObject)
                   , ("NAGARE_TEST_DATA_URL", T.unpack dataUrl)
                   , ("NAGARE_TEST_RECEIPT_URL", T.unpack receiptUrl)
                   , ("NAGARE_TEST_SOURCE", source)
                   , ("NAGARE_TEST_REAL_PYTHON", realPython)
                   ]
            runScript script =
              readCreateProcessWithExitCode
                ((proc "/bin/sh" ["-c", script]) {env = Just (jobEnv <> filter ((`notElem` map fst jobEnv) . fst) parentEnv)})
                ""
            runJob = do
              results <- mapM runScript [sourceScript, dumpScript, uploadScript]
              pure [(code, err) | (code, _, err) <- results]
        lookup "PREFIX" jobEnv @?= Just (T.unpack prefix)
        BS.writeFile source "{\"pvcUid\":\"11111111-1111-1111-1111-111111111111\"}\n"
        results <- runJob
        forM_ results $ \(code, err) -> assertBool ("volume Job container failed: " <> err) (code == ExitSuccess)
        receiptBytes <- BS.readFile receiptObject
        BS.readFile terminationLog >>= (@?= receiptBytes)
        expectation <-
          either (assertFailure . T.unpack) pure $
            scheduledVolumeReceiptExpectationFromCronJob backend "personal" "nagare-volbackup-scenario-a-uploads" claimUid cronBytes
        scheduledObjectPrefix expectation @?= prefix
        scheduledFormat expectation @?= "tar.gz"
        scheduledStatefulUid expectation @?= Nothing
        scheduledObjective expectation @?= HourlyRecoveryPoint
        case parseScheduledBackupReceipt expectation receiptUrl (T.replicate 64 "a") receiptBytes of
          Left reason -> assertFailure ("signed volume receipt was rejected: " <> T.unpack reason)
          Right checked -> do
            scheduledObjectAddress checked @?= dataUrl
            Resource.physicalIdentityText (scheduledJobUid checked) @?= runId
            assertBool "volume receipt lacks its recovery point" (isJust (scheduledRecoveryPoint checked))
        -- The stored archive restores the claim's files byte for byte.
        (untar, _, untarError) <- readCreateProcessWithExitCode (proc "tar" ["-xzf", dataObject, "-C", restored]) ""
        assertBool ("archive did not extract: " <> untarError) (untar == ExitSuccess)
        BS.readFile (restored </> "photo.bin") >>= (@?= BS.pack [0 .. 255])
        BS.readFile (restored </> "nested" </> "notes.txt") >>= (@?= "volume data\n")
        -- A database-shaped expectation never accepts a volume receipt.
        assertBool
          "a database expectation accepted a volume receipt"
          (isLeft (parseScheduledBackupReceipt (expectation {scheduledStatefulUid = Just claimUid}) receiptUrl (T.replicate 64 "a") receiptBytes))
        assertBool
          "another claim incarnation accepted the receipt"
          ( isLeft
              ( parseScheduledBackupReceipt
                  (expectation {scheduledPvcUid = either (error . T.unpack) id (Resource.mkPhysicalIdentity "33333333-3333-3333-3333-333333333333")})
                  receiptUrl
                  (T.replicate 64 "a")
                  receiptBytes
              )
          )
        -- A claim replaced while the Job runs leaves no receipt.
        mapM_ removeFile [dataObject, receiptObject]
        BS.writeFile source "{\"pvcUid\":\"33333333-3333-3333-3333-333333333333\"}\n"
        _ <- runScript sourceScript
        BS.writeFile source "{\"pvcUid\":\"44444444-4444-4444-4444-444444444444\"}\n"
        _ <- runScript dumpScript
        (replaced, _, _) <- runScript uploadScript
        assertBool "a replaced claim completed a receipt" (replaced /= ExitSuccess)
        doesFileExist receiptObject >>= (@?= False)
  , testCase "a volume expectation comes only from the accepted CronJob's own app, volume and claim" $ do
      assertBool
        "the schedule name was not checked"
        (isLeft (scheduledVolumeReceiptExpectationFromCronJob backend "personal" "nagare-volbackup-scenario-a-other" claimUid cronBytes))
      assertBool
        "the namespace was not checked"
        (isLeft (scheduledVolumeReceiptExpectationFromCronJob backend "other" "nagare-volbackup-scenario-a-uploads" claimUid cronBytes))
      let tampered = TE.encodeUtf8 (T.replace "\"nagare-vol-scenario-a-uploads\"" "\"nagare-vol-scenario-a-secrets\"" (TE.decodeUtf8 cronBytes))
      assertBool "the fixture did not change" (tampered /= cronBytes)
      assertBool
        "a schedule probing another claim was accepted"
        (isLeft (scheduledVolumeReceiptExpectationFromCronJob backend "personal" "nagare-volbackup-scenario-a-uploads" claimUid tampered))
      assertBool
        "a volume schedule passed as a bucket elsewhere"
        (isLeft (scheduledVolumeReceiptExpectationFromCronJob (GcsBackend "project" "other") "personal" "nagare-volbackup-scenario-a-uploads" claimUid cronBytes))
  , testCase "every retained volume claim compiles its reader, signing key and schedule after the claim" $ do
      let volumeNamed name retention =
            Volume
              { name = unsafe (mkVolumeName name)
              , logicalKey = Nothing
              , size = unsafe (mkQuantity "1Gi")
              , mountPath = unsafe (mkMountPath ("/" <> name))
              , accessMode = ReadWriteOnce
              , readOnly = False
              , retention = retention
              }
          owner = unsafe (Resource.mkScopeId Resource.Application "personal-scenario-a")
          foundation = unsafe (Resource.mkScopeId Resource.Platform "foundation")
          cluster = Resource.mintResourceId foundation (unsafe (Resource.mkLogicalKey "cluster")) (unsafe (Resource.mkName "resource"))
          namespaceId = Resource.mintResourceId foundation (unsafe (Resource.mkLogicalKey "foundation")) (unsafe (Resource.mkName "namespace-personal"))
          recovery = RecoveryIntent (unsafe (Resource.mkName "backup")) (mkSecretRef (unsafe (Resource.mkName "volume-key")) (unsafe (Resource.mkName "v1")) :| [])
          source = Resource.SourceLocation "test" "volume-backup"
          claimMember name lifecycle dataPolicy = do
            let bytes = case renderPersistentVolumeClaims "scenario-a" "personal" [volumeNamed name Retain] of
                  [single] -> single
                  _ -> error "one claim"
                value = either (error . show) id (Yaml.decodeEither' bytes :: Either Yaml.ParseException Value)
                canonical = unsafe (canonicalValue value)
                resource = Resource.mintResourceId owner (unsafe (Resource.mkLogicalKey name)) (unsafe (Resource.mkName "service-pvc"))
            pure
              ( resource
              , unsafe
                  ( first
                      (T.pack . show)
                      ( bindKubernetesObject
                          KubernetesInput
                            { resourceId = resource
                            , ownerScope = owner
                            , clusterId = cluster
                            , inputObject = value
                            , objectDigest = contentDigest canonical
                            , lifecyclePolicy = lifecycle
                            , inputDataPolicy = dataPolicy
                            , inputSensitivity = Private
                            , sourceLocation = source
                            }
                      )
                  )
              )
      (retainedId, retained) <- claimMember "uploads" Policy.Retain (Durable recovery)
      (_, throwaway) <- claimMember "cache" DeleteWhenUnreferenced Stateless
      compiled <- either (assertFailure . show) pure (compileVolumeBackups hourlyGcsBackup namespaceId source (Map.fromList [(retainedId, retained)]))
      (bundle, native) <- case compiled of
        [single] -> pure single
        other -> assertFailure ("expected one backup bundle, got " <> show (length other)) >> fail "bundles"
      let members = [member | Managed member <- declarations bundle]
          named kind name =
            [ member
            | member <- members
            , Resource.Kubernetes _ _ k (Just _) n <- [member ^. #address]
            , Resource.nameText k == kind
            , Resource.nameText n == name
            ]
      Map.size native @?= 5
      cron <- case named "cronjob" "nagare-volbackup-scenario-a-uploads" of
        [single] -> pure single
        _ -> assertFailure "the volume schedule is missing" >> fail "cron"
      signing <- case named "secret" "nagare-volbackup-scenario-a-uploads-signing" of
        [single] -> pure single
        _ -> assertFailure "the signing Secret is missing" >> fail "signing"
      mapM_ (\kind -> length (named kind "nagare-volbackup-scenario-a-uploads") @?= 1) ["serviceaccount", "role", "rolebinding"]
      assertBool "the schedule is not ordered after its claim" (OrderedAfter retainedId `elem` cron ^. #dependencies)
      assertBool "the schedule is not ordered after its signing key" (OrderedAfter (signing ^. #identity) `elem` cron ^. #dependencies)
      signing ^. #lifecycle @?= Policy.Retain
      signing ^. #dataPolicy @?= Durable recovery
      -- The generated-key template accepts the volume signing Secret.
      case Map.lookup (signing ^. #identity) native of
        Just (_, bytes) -> generatedCredentialTemplate (TE.decodeUtf8 bytes) @?= Right True
        Nothing -> assertFailure "signing Secret has no native bytes"
      -- The bound schedule bytes are the producer whose receipts the expectation checks.
      case Map.lookup (cron ^. #identity) native of
        Just (_, bytes) -> do
          bytes @?= cronBytes
          assertBool "the bound schedule yields no expectation" (isRight (scheduledVolumeReceiptExpectationFromCronJob backend "personal" "nagare-volbackup-scenario-a-uploads" claimUid bytes))
        Nothing -> assertFailure "volume schedule has no native bytes"
      fmap length (compileVolumeBackups hourlyGcsBackup namespaceId source (Map.fromList [(fst throwaway ^. #identity, throwaway)])) @?= Right 0
  , testCase "long app and volume names keep a distinct schedule name within the CronJob limit" $ do
      let first' = volumeBackupScheduleName (T.replicate 40 "a") "uploads"
          second' = volumeBackupScheduleName (T.replicate 40 "a") "uploads2"
      assertBool "schedule name exceeds 52 characters" (all ((<= 52) . T.length) [first', second'])
      assertBool "long schedule names collide" (first' /= second')
      volumeBackupScheduleName "scenario-a" "uploads" @?= "nagare-volbackup-scenario-a-uploads"
  ]
  where
    unsafe :: (Show e) => Either e a -> a
    unsafe = either (error . show) id
