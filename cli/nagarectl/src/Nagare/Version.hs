-- | Stable human- and machine-readable build identity for @nagarectl@.
module Nagare.Version
  ( BuildVersion (..)
  , currentBuildVersion
  , renderBuildVersionJson
  , renderBuildVersionText
  )
where

import Data.Aeson (encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Version (showVersion)
import Paths_nagarectl qualified as Package

-- | Version metadata carried by a built CLI distribution.
data BuildVersion = BuildVersion
  { versionText :: !Text
  -- ^ Semantic package version generated from the Cabal package metadata.
  , revisionText :: !(Maybe Text)
  -- ^ Optional source revision for distribution channels that provide one.
  }
  deriving stock (Eq, Show)

-- | Build identity for the running executable.
currentBuildVersion :: BuildVersion
currentBuildVersion =
  BuildVersion
    { versionText = Text.pack (showVersion Package.version)
    , revisionText = Nothing
    }

-- | Render the stable command-line representation.
renderBuildVersionText :: BuildVersion -> Text
renderBuildVersionText (BuildVersion versionText revisionText) =
  "nagarectl "
    <> versionText
    <> maybe "" (\revision -> " (" <> revision <> ")") revisionText

-- | Render the stable JSON representation used by automation.
renderBuildVersionJson :: BuildVersion -> ByteString
renderBuildVersionJson (BuildVersion versionText revisionText) =
  LBS.toStrict . encode . object $
    ["version" .= versionText]
      <> maybe [] (\revision -> ["revision" .= revision]) revisionText
