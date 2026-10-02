-- | Site responsibilities; internal implementation behind Nagare.Dsl.Load.
module Nagare.Dsl.Load.Site
  ( SiteConfig (..)
  , decodeSite
  )
where

import Data.Aeson (eitherDecodeStrict)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Nagare.Dsl.Load.Error (LoadError (..))
import Nagare.Dsl.Load.Fields (JsonKindEnvelope (..))
import Nagare.Dsl.Load.ServerSite (decodeServerSite)
import Nagare.Dsl.Load.StaticSite (decodeStaticSite)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Server.Types (ServerSite)
import Nagare.Dsl.Static.Types (StaticSite)

-- | The two site shapes @nagarectl site deploy@ can deploy.
data SiteConfig
  = SiteStatic !StaticSite
  | SiteServer !ServerSite
  deriving stock (Generic, Eq, Show)

decodeSite :: ByteString -> Either LoadError SiteConfig
decodeSite bs =
  case eitherDecodeStrict bs of
    Left perr ->
      Left (MarshalError "json" ("could not decode config output: " <> Text.pack perr))
    Right (JsonKindEnvelope envelopeKind) -> case envelopeKind of
      Just "StaticSite" -> SiteStatic <$> decodeStaticSite bs
      Just "ServerSite" -> SiteServer <$> decodeServerSite bs
      Just other -> Left (UnexpectedKind "StaticSite or ServerSite" other)
      Nothing -> Left (UnexpectedKind "StaticSite or ServerSite" "<none>")
