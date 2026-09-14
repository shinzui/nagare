-- | Stable human- and machine-readable build identity for @nagarectl@.
module Nagare.Version
  ( BuildVersion (..)
  , PlatformVersion (..)
  , VersionError (..)
  , Compatibility (..)
  , currentBuildVersion
  , parsePlatformVersion
  , renderPlatformVersion
  , comparePlatformVersions
  , compatibilityToken
  , renderBuildVersionJson
  , renderBuildVersionJsonWithTools
  , renderBuildVersionText
  )
where

import Data.Aeson (encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Version (showVersion)
import Nagare.Dsl.Prelude hiding ((.=))
import Numeric.Natural (Natural)
import Paths_nagarectl qualified as Package
import Text.Read (readMaybe)

-- | Nagare's release identity. The optional suffix follows semantic-version
-- prerelease syntax (for example @0.2.0-rc.1@); build metadata is deliberately
-- excluded because it does not participate in platform compatibility.
data PlatformVersion = PlatformVersion
  { major :: !Natural
  , minor :: !Natural
  , patch :: !Natural
  , preRelease :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Ord, Show)

newtype VersionError = VersionError {text :: Text}
  deriving stock (Generic, Eq, Show)

data Compatibility
  = Exact
  | PatchSkew
  | MinorUpgradeRequired
  | MajorIncompatible
  | LegacyUnknown
  deriving stock (Eq, Show)

parsePlatformVersion :: Text -> Either VersionError PlatformVersion
parsePlatformVersion input = do
  let (core, suffixWithDash) = Text.breakOn "-" (Text.strip input)
      suffix = if Text.null suffixWithDash then Nothing else Just (Text.drop 1 suffixWithDash)
      pieces = Text.splitOn "." core
  (majorPart, minorPart, patchPart) <- case pieces of
    [a, b, c] -> Right (a, b, c)
    _ -> Left (VersionError "platform version must have major.minor.patch form")
  majorValue <- parseNumber "major" majorPart
  minorValue <- parseNumber "minor" minorPart
  patchValue <- parseNumber "patch" patchPart
  validatedSuffix <- traverse validatePreRelease suffix
  pure (PlatformVersion majorValue minorValue patchValue validatedSuffix)
  where
    parseNumber label value
      | Text.null value = Left (VersionError (label <> " version component is empty"))
      | Text.length value > 1 && Text.head value == '0' = Left (VersionError (label <> " version component has a leading zero"))
      | not (Text.all isAsciiDigit value) = Left (VersionError (label <> " version component must contain only ASCII digits"))
      | otherwise = maybe (Left (VersionError (label <> " version component is invalid"))) Right (readMaybe (Text.unpack value))
    isAsciiDigit c = c >= '0' && c <= '9'
    validatePreRelease value
      | Text.null value = Left (VersionError "prerelease suffix is empty")
      | any Text.null identifiers = Left (VersionError "prerelease identifiers must not be empty")
      | not (Text.all validCharacter value) = Left (VersionError "prerelease suffix may contain only ASCII letters, digits, dots, and hyphens")
      | any numericLeadingZero identifiers = Left (VersionError "numeric prerelease identifiers must not have leading zeros")
      | otherwise = Right value
      where
        identifiers = Text.splitOn "." value
        validCharacter c = isAsciiDigit c || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c == '.' || c == '-'
        numericLeadingZero part = Text.length part > 1 && Text.all isAsciiDigit part && Text.head part == '0'

renderPlatformVersion :: PlatformVersion -> Text
renderPlatformVersion version =
  Text.intercalate "." (map (Text.pack . show) [version ^. #major, version ^. #minor, version ^. #patch])
    <> maybe "" ("-" <>) (version ^. #preRelease)

-- | Compare the release supplying an operation with an observed or intended
-- release. Missing identity is legacy/unknown; a prerelease difference is
-- treated as patch-level skew within the same major/minor line.
comparePlatformVersions :: PlatformVersion -> Maybe PlatformVersion -> Compatibility
comparePlatformVersions _ Nothing = LegacyUnknown
comparePlatformVersions expected (Just observed)
  | expected == observed = Exact
  | expected ^. #major /= observed ^. #major = MajorIncompatible
  | expected ^. #minor /= observed ^. #minor = MinorUpgradeRequired
  | otherwise = PatchSkew

compatibilityToken :: Compatibility -> Text
compatibilityToken Exact = "exact"
compatibilityToken PatchSkew = "patch-skew"
compatibilityToken MinorUpgradeRequired = "minor-upgrade-required"
compatibilityToken MajorIncompatible = "major-incompatible"
compatibilityToken LegacyUnknown = "legacy-unknown"

-- | Version metadata carried by a built CLI distribution.
data BuildVersion = BuildVersion
  { version :: !Text
  -- ^ Semantic package version generated from the Cabal package metadata.
  , revision :: !(Maybe Text)
  -- ^ Optional source revision for distribution channels that provide one.
  }
  deriving stock (Generic, Eq, Show)

-- | Build identity for the running executable.
currentBuildVersion :: BuildVersion
currentBuildVersion =
  BuildVersion
    { version = Text.pack (showVersion Package.version)
    , revision = Nothing
    }

-- | Render the stable command-line representation.
renderBuildVersionText :: BuildVersion -> Text
renderBuildVersionText (BuildVersion version revision) =
  "nagarectl "
    <> version
    <> maybe "" (\revision -> " (" <> revision <> ")") revision

-- | Render the stable JSON representation used by automation.
renderBuildVersionJson :: BuildVersion -> ByteString
renderBuildVersionJson (BuildVersion version revision) =
  LBS.toStrict . encode . object $
    ["version" .= version, "platformVersion" .= version]
      <> maybe [] (\revision -> ["revision" .= revision]) revision

-- | Render build identity plus the executable paths selected from the invoking
-- process's PATH. Missing tools remain explicit JSON nulls. Plain
-- 'renderBuildVersionJson' intentionally stays path-independent for release
-- evidence that must be byte-stable across machines.
renderBuildVersionJsonWithTools :: BuildVersion -> [(Text, Maybe FilePath)] -> ByteString
renderBuildVersionJsonWithTools (BuildVersion version revision) tools =
  LBS.toStrict . encode . object $
    ["version" .= version, "platformVersion" .= version]
      <> maybe [] (\sourceRevision -> ["revision" .= sourceRevision]) revision
      <> ["tools" .= object [Key.fromText name .= path | (name, path) <- tools]]
