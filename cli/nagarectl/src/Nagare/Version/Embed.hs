-- | The platform version, read from @release.json@ at compile time (EP-210
-- M3). @release.json@ is the only place a release writes its version, so the
-- Cabal package versions stay constant and a bump recompiles only the module
-- that splices it.
module Nagare.Version.Embed
  ( embedPlatformVersion
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Language.Haskell.TH (Exp, Q, runIO)
import Language.Haskell.TH.Syntax (addDependentFile, lift)
import Nagare.Dsl.Prelude

-- | A string literal holding the @platformVersion@ of the release metadata at
-- @path@, relative to the package directory. The file becomes a dependency of
-- the splicing module.
embedPlatformVersion :: FilePath -> Q Exp
embedPlatformVersion path = do
  addDependentFile path
  bytes <- runIO (ByteString.readFile path)
  case Aeson.eitherDecodeStrict bytes >>= Aeson.parseEither (Aeson.withObject "release.json" (Aeson..: "platformVersion")) of
    Right version -> lift (Text.unpack version)
    Left problem -> fail (path <> ": " <> problem)
