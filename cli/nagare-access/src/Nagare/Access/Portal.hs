-- | Domain vocabulary and pure helpers for an operator-provided auth portal.
module Nagare.Access.Portal
  ( AccessToken (..)
  , CapturedResponse (..)
  , LoginNotice (..)
  , PortalPage (..)
  , PortalPageKind (..)
  , RefreshToken (..)
  , ReturnTarget (..)
  , SafePath
  , decodeSessionHandoff
  , mkSafePath
  , parseReturnTarget
  , portalHome
  , portalLoginUrl
  , portalPageResponse
  , renderReturnTarget
  , safePathText
  , SessionHandoff (..)
  )
where

import Nagare.Access.Prelude
import Data.Generics.Labels ()

import Data.Aeson (FromJSON (parseJSON), eitherDecodeStrict, withObject, (.:), (.:?))
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Nagare.Access.BackendMap
import Nagare.Access.Challenge (safeReturnDestination)
import Network.HTTP.Types (Header, Status)
import Network.HTTP.Types.URI (urlEncode)
import Network.Wai (Response, responseLBS)

newtype AccessToken = AccessToken Text
  deriving stock (Generic, Eq)

instance Show AccessToken where
  show _ = "AccessToken <redacted>"

newtype RefreshToken = RefreshToken Text
  deriving stock (Generic, Eq)

instance Show RefreshToken where
  show _ = "RefreshToken <redacted>"

data SessionHandoff = SessionHandoff
  { accessToken :: !AccessToken
  , refreshToken :: !RefreshToken
  , returnTo :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON SessionHandoff where
  parseJSON =
    withObject "SessionHandoff" $ \obj -> do
      rawAccess <- obj .: "accessToken"
      rawRefresh <- obj .: "refreshToken"
      returnTo <- obj .:? "returnTo"
      access <- nonEmptyToken "accessToken" AccessToken rawAccess
      refresh <- nonEmptyToken "refreshToken" RefreshToken rawRefresh
      pure SessionHandoff {accessToken = access, refreshToken = refresh, returnTo = returnTo}

decodeSessionHandoff :: ByteString -> Either Text SessionHandoff
decodeSessionHandoff encoded = do
  decoded <- mapLeft Text.pack (convertFromBase Base64URLUnpadded encoded :: Either String ByteString)
  mapLeft Text.pack (eitherDecodeStrict decoded)

data CapturedResponse = CapturedResponse
  { status :: !Status
  , headers :: ![Header]
  , body :: !LBS.ByteString
  }
  deriving stock (Generic, Eq, Show)

newtype SafePath = SafePath Text
  deriving stock (Generic, Eq, Show)

safePathText :: SafePath -> Text
safePathText (SafePath path) = path

mkSafePath :: Text -> Maybe SafePath
mkSafePath = fmap SafePath . safeReturnDestination

data ReturnTarget = ReturnTarget
  { host :: !PublicHost
  , path :: !SafePath
  }
  deriving stock (Generic, Eq, Show)

renderReturnTarget :: ReturnTarget -> Text
renderReturnTarget target =
  "https://" <> publicHostText (target ^. #host) <> safePathText (target ^. #path)

parseReturnTarget :: BackendMap -> Text -> Maybe ReturnTarget
parseReturnTarget backends candidate = do
  afterScheme <- Text.stripPrefix "https://" candidate
  let (authority, remainder) = Text.break isPathStart afterScheme
  if Text.null authority || Text.any (`elem` ['@', '\\']) authority then Nothing else Just ()
  host <- either (const Nothing) Just (mkPublicHost authority)
  if isRoutedHost host backends then Just () else Nothing
  path <- mkSafePath (normalizeRemainder remainder)
  pure ReturnTarget {host = host, path = path}
  where
    isPathStart c = c == '/' || c == '?' || c == '#'
    normalizeRemainder text
      | Text.null text = "/"
      | Text.head text == '/' = text
      | otherwise = "/" <> text

portalHome :: Portal -> ReturnTarget
portalHome portal =
  ReturnTarget
    { host = portal ^. #host
    , path = SafePath "/"
    }

data LoginNotice = SessionFailed | LoggedOut
  deriving stock (Generic, Eq, Show)

portalLoginUrl :: Portal -> Maybe LoginNotice -> Maybe ReturnTarget -> Text
portalLoginUrl portal notice target =
  "https://" <> publicHostText (portal ^. #host) <> "/login" <> renderQuery parameters
  where
    parameters =
      noticeParameter notice
        <> maybe [] (\returnTarget -> [("return_to", renderReturnTarget returnTarget)]) target
    noticeParameter (Just SessionFailed) = [("error", "session")]
    noticeParameter (Just LoggedOut) = [("logged_out", "1")]
    noticeParameter Nothing = []

    renderQuery [] = ""
    renderQuery pairs =
      "?" <> Text.intercalate "&" [name <> "=" <> encode value | (name, value) <- pairs]
    encode = TE.decodeUtf8 . urlEncode True . TE.encodeUtf8

data PortalPageKind = ForbiddenPage | UnavailablePage
  deriving stock (Generic, Eq, Show)

newtype PortalPage = PortalPage LBS.ByteString
  deriving stock (Generic, Eq, Show)

portalPageResponse :: Status -> PortalPage -> Response
portalPageResponse status (PortalPage body) =
  responseLBS
    status
    [ ("Content-Type", "text/html; charset=utf-8")
    , ("Cache-Control", "no-store")
    ]
    body

nonEmptyToken :: (MonadFail m) => String -> (Text -> a) -> Text -> m a
nonEmptyToken label constructor raw
  | Text.null raw = fail (label <> " must not be empty")
  | otherwise = pure (constructor raw)

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = either (Left . f) Right
