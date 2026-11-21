-- | Validate the public release proof before any provider publication: the
-- EP-172 transition rehearsal record, against the release.json of the tagged
-- commit. A release after v0.5.0 proves the full gate, this rehearsal and the
-- intranet upgrade (operator, 2026-10-10); MasterPlan 37 D3 dropped the
-- native output, clone-free and platform metadata attachments, so a release
-- is its signed tag, its notes and this record.
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
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding (at)

-- | The evidence attachment beside the notes.
releaseEvidenceAssetNames :: Text -> [FilePath]
releaseEvidenceAssetNames version = [rehearsalAsset version]

rehearsalAsset :: Text -> FilePath
rehearsalAsset version = "nagare-transition-rehearsal-v" <> T.unpack version <> ".json"

-- | Refuse unless the tagged release.json is this version and the transition
-- rehearsal record moved a release it accepts to this candidate, ended
-- converged on the candidate, and read its seeded data back unchanged.
validateReleaseEvidence :: Text -> Text -> ByteString -> Map FilePath ByteString -> Either Text ()
validateReleaseEvidence version revision releaseJson assets = do
  metadata <- first (const "the tag's release.json is not JSON") (eitherDecodeStrict' releaseJson)
  require (field "platformVersion" metadata == String version) "the tag's release.json is not this version"
  rehearsal <- maybe (Left ("missing release evidence asset: " <> T.pack (rehearsalAsset version))) Right (Map.lookup (rehearsalAsset version) assets) >>= first (const "invalid release evidence JSON: the transition rehearsal record") . eitherDecodeStrict'
  rejectSensitive rehearsal
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

nonempty :: Value -> Bool
nonempty (String value) = not (T.null value)
nonempty _ = False

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
