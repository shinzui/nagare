-- | Validate the complete public release proof before any provider publication.
module Nagare.Inventory.ReleaseEvidence
  ( inventoryEvidenceAssetNames
  , validateInventoryReleaseEvidence
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding (at, index)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Resource.Types (digestText)
import Nagare.Resource.Wire (canonicalValue)

inventoryEvidenceAssetNames :: Text -> [FilePath]
inventoryEvidenceAssetNames version =
  [ "nagare-inventory-evidence-v" <> T.unpack version <> ".json"
  , "nagare-platform-metadata-v" <> T.unpack version <> ".json"
  , "inventory-coverage.json"
  ]
    <> ["inventory-" <> mode <> "-" <> kind <> ".json" | mode <- ["local", "cloud"], kind <- ["target", "health", "fixture", "evidence"]]

validateInventoryReleaseEvidence :: Text -> Text -> Map FilePath ByteString -> Either Text ()
validateInventoryReleaseEvidence version revision assets = do
  manifest <- document manifestName
  index <- document ("nagare-inventory-evidence-v" <> T.unpack version <> ".json")
  metadata <- document metadataName
  coverage <- document "inventory-coverage.json"
  mapM_ rejectSensitive [index, metadata, coverage]
  require (field "schemaVersion" index == Number 1) "unsupported inventory release index"
  let candidate = field "candidate" index
      payloads = field "payloadDigests" manifest
  require (field "version" candidate == String version && field "sourceRevision" candidate == String revision) "inventory index candidate differs from release"
  boundDigest candidate "manifestDigest" manifestName
  boundDigest candidate "metadataDigest" metadataName
  boundDigest index "coverageDigest" "inventory-coverage.json"
  systems <- strings (field "systems" manifest)
  supported <- strings (field "supportedSystems" metadata)
  require (not (null systems) && unique systems && Set.fromList systems == Set.fromList supported && unique supported && field "platformVersion" metadata == String version) "release systems differ from platform metadata"
  require (field "schemaVersion" coverage == Number 1 && field "complete" coverage == Bool True && field "dirty" coverage == Bool False && field "sourceRevision" coverage == String revision && hexValue (field "candidateDigest" coverage)) "command coverage is incomplete or stale"
  forM_ ["pending", "pendingRecipes", "incompleteCatalogueRows", "errors"] $ \key -> require (field key coverage == Array mempty) "command coverage has unresolved entries"
  forM_ ["registeredRoutes", "recipes", "libraryCalls"] $ \key -> require (positive (field key coverage)) "command coverage lacks a mutation family"
  deferred <- strings (field "deferredRoutes" coverage)
  recovery <- strings (field "recoveryOnlyRoutes" coverage)
  require (deferred == ["DbCommand.DbPruneScheduledBackups", "DbCommand.DbRestore.--into-live", "DbCommand.DbShell", "StorageCommand.StorageRestore.--into-live"] && recovery == ["DbCommand.DbRecoverScheduledPrune"]) "command coverage changes the supported contract"
  native <- array (field "nativeSystems" index)
  nativeSystems <- traverse (text . field "system") native
  require (unique nativeSystems && Set.fromList nativeSystems == Set.fromList systems) "inventory index lacks exactly the supported native systems"
  forM_ native $ \entry -> do
    system <- text (field "system" entry)
    let outputName = "nix-output-" <> T.unpack system <> ".json"
        rehearsalName = "clone-free-" <> T.unpack system <> ".json"
        expectedPayload = field (Key.fromText system) payloads
    output <- document outputName
    rehearsal <- document rehearsalName
    mapM_ rejectSensitive [output, rehearsal]
    boundDigest entry "outputDigest" outputName
    boundDigest entry "rehearsalDigest" rehearsalName
    forM_ [output, rehearsal] $ \value -> require (field "system" value == String system && field "version" value == String version && field "revision" value == String revision) "native evidence belongs to another candidate"
    require (hashValue expectedPayload && field "payloadDigest" entry == expectedPayload && at ["outputs", "nagare-platform", "narHash"] output == expectedPayload && hashValue (at ["outputs", "nagarectl", "narHash"] output)) "native payload identity differs from release"
    checks <- strings (field "checks" rehearsal)
    nativeSupported <- strings (field "supportedSystems" rehearsal)
    require (field "cloneFree" rehearsal == Bool True && field "installedSmoke" rehearsal /= Bool True && Set.fromList nativeSupported == Set.fromList systems && all (`elem` checks) ["version", "context", "typed-config", "payload", "operator-recipe"]) "native rehearsal is incomplete"
  scenarios <- array (field "scenarios" index)
  modes <- traverse (text . field "mode") scenarios
  require (Set.fromList modes == Set.fromList ["local", "cloud"] && unique modes) "both local and cloud scenarios are required"
  forM_ scenarios $ \entry -> do
    mode <- text (field "mode" entry)
    let asset kind = "inventory-" <> T.unpack mode <> "-" <> kind <> ".json"
    target <- document (asset "target")
    health <- document (asset "health")
    fixture <- document (asset "fixture")
    evidence <- document (asset "evidence")
    mapM_ rejectSensitive [target, health, fixture, evidence]
    boundDigest entry "targetDigest" (asset "target")
    boundDigest entry "healthDigest" (asset "health")
    boundDigest entry "fixtureDigest" (asset "fixture")
    boundDigest health "fixtureDigest" (asset "fixture")
    require (field "schemaVersion" fixture == Number 1 && field "mode" fixture == String mode) "scenario fixture definition has wrong schema or mode"
    boundDigest entry "evidenceDigest" (asset "evidence")
    require (field "schemaVersion" target == Number 1 && field "mode" target == String mode && nonempty (field "context" target) && nonempty (field "kubeContext" target) && nonempty (field "expectedCluster" target)) "scenario target is incomplete"
    require (if mode == "cloud" then nonempty (field "expectedProject" target) else field "expectedProject" target == Null) "scenario project binding is invalid"
    forM_ [("context", "context"), ("kubeContext", "kubeContext"), ("cluster", "expectedCluster"), ("project", "expectedProject")] $ \(key, targetKey) -> require (field key entry == field targetKey target) "scenario index differs from target"
    checks <- strings (field "checks" health)
    require (field "schemaVersion" health == Number 1 && field "mode" health == String mode && field "context" health == field "context" target && field "cluster" health == field "expectedCluster" target && field "operatorRevision" health == String revision && field "healthy" health == Bool True && hexValue (field "fixtureDigest" health) && all (`elem` checks) (requiredChecks mode)) "scenario health lacks required supported assertions"
    let payload = field "payload" evidence
        run = field "run" evidence
    canonicalTarget <- canonicalValue target
    require (field "fixtureDigest" run == String (digestText (contentDigest (canonicalTarget <> "\n")))) "scenario run differs from saved target"
    system <- text (field "system" payload)
    require (field "schemaVersion" evidence == Number 1 && field "version" payload == String version && field "sourceRevision" payload == String revision && system `elem` systems && field "digest" payload == field (Key.fromText system) payloads && field "system" entry == String system) "scenario payload differs from candidate"
    require (field "mode" run == String mode && hexValue (field "id" run) && field "runId" entry == field "id" run && hexValue (field "fixtureDigest" run)) "scenario run binding is invalid"
    forM_ ["inventoryDigest", "reviewedChangeDigest", "privateStoreHeadDigest"] $ \key -> require (hexValue (field key evidence)) "scenario lacks committed evidence digests"
    receipts <- array (field "componentReceipts" evidence)
    require (not (null receipts) && field "receiptCount" entry == Number (fromIntegral (length receipts)) && all validReceipt receipts) "scenario lacks complete committed receipts"
    require (at ["finalObservation", "complete"] evidence == Bool True && at ["coverage", "complete"] evidence == Bool True && at ["coverage", "resultDigest"] evidence == field "coverageDigest" index && at ["tools", "operator", "revision"] evidence == String revision) "scenario final observation or coverage is incomplete"
  where
    manifestName = "nagare-release-" <> T.unpack version <> ".json"
    metadataName = "nagare-platform-metadata-v" <> T.unpack version <> ".json"
    bytes name = maybe (Left ("missing release evidence asset: " <> T.pack name)) Right (Map.lookup name assets)
    document name = bytes name >>= first (const ("invalid release evidence JSON: " <> T.pack name)) . eitherDecodeStrict'
    boundDigest value key name = do
      actual <- digestText . contentDigest <$> bytes name
      require (field key value == String actual) ("release evidence digest differs: " <> T.pack name)

requiredChecks :: Text -> [Text]
requiredChecks mode =
  [ "collision-refusal"
  , "adoption"
  , "drift-classification"
  , "convergence-noop-removal"
  , "independent-scope-preservation"
  , "secret-read-refusal"
  , "interrupted-recovery"
  , "postgresql-backup-restore"
  , "redis-backup-restore"
  , "clickhouse-backup-restore"
  , "volume-backup-restore"
  , "source-unavailable-recovery"
  , "backup-freshness"
  , "retained-data"
  , "access-grant-revoke"
  ]
    <> if mode == "local" then ["retained-postgresql-rename"] else ["shared-history-takeover", "google-cdn"]

field :: Key.Key -> Value -> Value
field key (Object fields) = fromMaybe Null (KM.lookup key fields)
field _ _ = Null

at :: [Key.Key] -> Value -> Value
at keys value = foldl (flip field) value keys

require :: Bool -> Text -> Either Text ()
require condition reason = unless condition (Left reason)

text :: Value -> Either Text Text
text (String value) | not (T.null value) = Right value
text _ = Left "release evidence requires a nonempty string"

array :: Value -> Either Text [Value]
array (Array values) = Right (toList values)
array _ = Left "release evidence requires an array"

strings :: Value -> Either Text [Text]
strings value = array value >>= traverse text

unique :: (Ord a) => [a] -> Bool
unique values = Set.size (Set.fromList values) == length values

nonempty :: Value -> Bool
nonempty (String value) = not (T.null value)
nonempty _ = False

hexValue :: Value -> Bool
hexValue (String value) = T.length value == 64 && T.all (`elem` ("0123456789abcdef" :: String)) value
hexValue _ = False

hashValue :: Value -> Bool
hashValue (String value) = "sha256-" `T.isPrefixOf` value
hashValue _ = False

positive :: Value -> Bool
positive (Number value) = value > 0 && fromInteger (floor value) == value
positive _ = False

validReceipt :: Value -> Bool
validReceipt value = nonempty (field "operation" value) && all (hexValue . (`field` value)) ["journalDigest", "receiptDigest"]

rejectSensitive :: Value -> Either Text ()
rejectSensitive (Object fields) = forM_ (KM.toList fields) $ \(key, value) -> do
  let normalized = T.filter (`notElem` ("_- " :: String)) (T.toLower (Key.toText key))
  require (not (any (`T.isInfixOf` normalized) ["password", "credential", "accesstoken", "privatekey", "secret"])) "sensitive key in public release evidence"
  rejectSensitive value
rejectSensitive (Array values) = mapM_ rejectSensitive values
rejectSensitive (String value) = require (not (any (`T.isInfixOf` value) ["must-never-be-public", "ENC[", "-----BEGIN PRIVATE KEY-----"])) "sensitive value in public release evidence"
rejectSensitive _ = Right ()
