-- | Validate the public release proof before any provider publication: the
-- native output and clone-free rehearsal of every supported system, the
-- platform metadata, and the EP-172 transition rehearsal record. A release
-- after v0.5.0 proves the full gate, this rehearsal and the intranet upgrade
-- (operator, 2026-10-10); the per-release local and cloud evidence chain of
-- MasterPlan 23 is not re-run.
module Nagare.Inventory.ReleaseEvidence
  ( releaseEvidenceAssetNames
  , validateReleaseEvidence
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
import Nagare.Dsl.Prelude hiding (at)

-- | The evidence attachments beside the manifest, notes, native outputs,
-- clone-free rehearsals and checksums.
releaseEvidenceAssetNames :: Text -> [FilePath]
releaseEvidenceAssetNames version =
  [ "nagare-transition-rehearsal-v" <> T.unpack version <> ".json"
  , "nagare-platform-metadata-v" <> T.unpack version <> ".json"
  ]

-- | Refuse unless every native system's output and rehearsal, the platform
-- metadata and the transition rehearsal record bind this version and
-- candidate revision, and the rehearsal ended converged on the candidate
-- with its seeded data read back unchanged.
validateReleaseEvidence :: Text -> Text -> Map FilePath ByteString -> Either Text ()
validateReleaseEvidence version revision assets = do
  manifest <- document manifestName
  metadata <- document metadataName
  rehearsal <- document rehearsalName
  mapM_ rejectSensitive [metadata, rehearsal]
  systems <- strings (field "systems" manifest)
  supported <- strings (field "supportedSystems" metadata)
  require (not (null systems) && unique systems && Set.fromList systems == Set.fromList supported && unique supported && field "platformVersion" metadata == String version) "release systems differ from platform metadata"
  let payloads = field "payloadDigests" manifest
  forM_ systems $ \system -> do
    let outputName = "nix-output-" <> T.unpack system <> ".json"
        cloneFreeName = "clone-free-" <> T.unpack system <> ".json"
        expectedPayload = field (Key.fromText system) payloads
    output <- document outputName
    cloneFree <- document cloneFreeName
    mapM_ rejectSensitive [output, cloneFree]
    forM_ [output, cloneFree] $ \value -> require (field "system" value == String system && field "version" value == String version && field "revision" value == String revision) "native evidence belongs to another candidate"
    require (hashValue expectedPayload && at ["outputs", "nagare-platform", "narHash"] output == expectedPayload && hashValue (at ["outputs", "nagarectl", "narHash"] output)) "native payload identity differs from release"
    checks <- strings (field "checks" cloneFree)
    nativeSupported <- strings (field "supportedSystems" cloneFree)
    require (field "cloneFree" cloneFree == Bool True && field "installedSmoke" cloneFree /= Bool True && Set.fromList nativeSupported == Set.fromList systems && all (`elem` checks) ["version", "context", "typed-config", "inventory-compile", "payload", "operator-recipe"]) "native rehearsal is incomplete"
  require (field "schemaVersion" rehearsal == Number 1 && field "mode" rehearsal == String "local" && nonempty (field "context" rehearsal)) "transition rehearsal has an unsupported schema or mode"
  let candidate = field "candidate" rehearsal
      source = field "source" rehearsal
  require (field "version" candidate == String version && field "revision" candidate == String revision) "transition rehearsal belongs to another candidate"
  sourceVersion <- text (field "version" source)
  accepted <- strings (field "transitionsFrom" metadata)
  require (sourceVersion /= version && sourceVersion `elem` accepted && nonempty (field "revision" source)) "transition rehearsal moved from a release the payload does not accept"
  seeded <- text (at ["sentinel", "seeded"] rehearsal)
  require (at ["sentinel", "readBack"] rehearsal == String seeded) "transition rehearsal read the seeded data back changed"
  require (positive (at ["transition", "reviews"] rehearsal)) "transition rehearsal applied no transition review"
  let identities = at ["platform", "identities"] rehearsal
  forM_ ["cli", "payload", "cluster"] $ \component -> require (at [component, "version"] identities == String version && at [component, "revision"] identities == String revision) "transition rehearsal did not end on the candidate"
  require (at ["context", "version"] identities == String version) "transition rehearsal did not pin the context to the candidate"
  require (at ["inventory", "activeTransaction"] rehearsal == Null && at ["inventory", "observationComplete"] rehearsal == Bool True) "transition rehearsal ended with an open transaction"
  require (at ["replan", "operations"] rehearsal == Number 0 && at ["replan", "reaccepts"] rehearsal == Number 0) "transition rehearsal replan is not converged"
  where
    manifestName = "nagare-release-" <> T.unpack version <> ".json"
    metadataName = "nagare-platform-metadata-v" <> T.unpack version <> ".json"
    rehearsalName = "nagare-transition-rehearsal-v" <> T.unpack version <> ".json"
    bytes name = maybe (Left ("missing release evidence asset: " <> T.pack name)) Right (Map.lookup name assets)
    document name = bytes name >>= first (const ("invalid release evidence JSON: " <> T.pack name)) . eitherDecodeStrict'

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

strings :: Value -> Either Text [Text]
strings (Array values) = traverse text (toList values)
strings _ = Left "release evidence requires an array"

unique :: (Ord a) => [a] -> Bool
unique values = Set.size (Set.fromList values) == length values

nonempty :: Value -> Bool
nonempty (String value) = not (T.null value)
nonempty _ = False

hashValue :: Value -> Bool
hashValue (String value) = "sha256-" `T.isPrefixOf` value
hashValue _ = False

positive :: Value -> Bool
positive (Number value) = value > 0 && fromInteger (floor value) == value
positive _ = False

rejectSensitive :: Value -> Either Text ()
rejectSensitive (Object fields) = forM_ (KM.toList fields) $ \(key, value) -> do
  let normalized = T.filter (`notElem` ("_- " :: String)) (T.toLower (Key.toText key))
  require (not (any (`T.isInfixOf` normalized) ["password", "credential", "accesstoken", "privatekey", "secret"])) "sensitive key in public release evidence"
  rejectSensitive value
rejectSensitive (Array values) = mapM_ rejectSensitive values
rejectSensitive (String value) = require (not (any (`T.isInfixOf` value) ["must-never-be-public", "ENC[", "-----BEGIN PRIVATE KEY-----"])) "sensitive value in public release evidence"
rejectSensitive _ = Right ()
