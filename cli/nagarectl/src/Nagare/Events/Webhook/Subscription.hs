{-# LANGUAGE OverloadedStrings #-}

-- | The webhook destination's settings (EP-234): its receiver URL, the
-- cluster-private hosts the review explicitly allows, and the signing keys
-- as references to context-owned Secrets — never their values. Only the
-- webhook adapter reads these; the shared subscription carries them as its
-- destination's settings.
--
-- An ordinary receiver is HTTPS. A URL with user information, a fragment,
-- a credential-like query parameter, or a loopback, link-local or metadata
-- host is refused. Plain HTTP and private addresses are allowed only for a
-- host the review names in @allowHosts@; the transport checks the resolved
-- address again when it connects.
module Nagare.Events.Webhook.Subscription
  ( webhookTransport
  , webhookSettingsVersion
  , SecretKeyRef (..)
  , WebhookSettings (..)
  , ReceiverUrl (..)
  , parseReceiverUrl
  , webhookDestination
  , decodeWebhookSettings
  , webhookRedirects
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, toLower)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Subscription (DestinationSpec (..), SubscriptionId, subscriptionIdText)
import Nagare.Events.Webhook.Signature (mkKeyId)

webhookTransport :: Text
webhookTransport = "webhook"

webhookSettingsVersion :: Int
webhookSettingsVersion = 1

-- | One signing key: its ID, and the Secret field that holds it.
data SecretKeyRef = SecretKeyRef
  { keyId :: !Text
  , namespace :: !Text
  , secret :: !Text
  , key :: !Text
  }
  deriving stock (Eq, Show, Generic)

data WebhookSettings = WebhookSettings
  { url :: !Text
  , allowHosts :: ![Text]
  , signing :: ![SecretKeyRef]
  -- ^ The current key first; a retiring key after it during rotation.
  }
  deriving stock (Eq, Show, Generic)

data ReceiverUrl = ReceiverUrl
  { secure :: !Bool
  , host :: !Text
  , port :: !Int
  , path :: !Text
  -- ^ The path and query, starting with @/@.
  }
  deriving stock (Eq, Show, Generic)

-- | Validate a receiver URL against the hosts a review allows.
parseReceiverUrl :: [Text] -> Text -> Either Text ReceiverUrl
parseReceiverUrl allowed raw = do
  when (T.length raw > 2048) (Left "a receiver URL has at most 2048 characters")
  when (T.any (\c -> c <= ' ' || c == '\DEL') raw) (Left "a receiver URL holds no spaces or control characters")
  (secure', rest) <- case (T.stripPrefix "https://" raw, T.stripPrefix "http://" raw) of
    (Just after, _) -> Right (True, after)
    (_, Just after) -> Right (False, after)
    _ -> Left "a receiver URL is https:// (or http:// for an allowed cluster-private host)"
  when ("#" `T.isInfixOf` rest) (Left "a receiver URL has no fragment")
  let (authority, pathPart) = T.breakOn "/" rest
      path' = if T.null pathPart then "/" else pathPart
  when ("@" `T.isInfixOf` authority) (Left "a receiver URL carries no user information")
  (host', port') <- case T.breakOnEnd ":" authority of
    ("", _) -> Right (authority, if secure' then 443 else 80)
    (withColon, portText)
      | Just hostPart <- T.stripSuffix ":" withColon
      , not (T.null portText) && T.length portText <= 5 && T.all isDigit portText
      , Just n <- readInt portText
      , n > 0 && n <= 65535 ->
          Right (hostPart, n)
    _ -> Left "a receiver URL's port is a number from 1 to 65535"
  let lowered = T.map toLower host'
  unless (validHost lowered) (Left "a receiver URL names a DNS host name or an IPv4 address")
  when (forbiddenHost lowered) (Left "a receiver URL may not name a loopback, link-local or metadata host")
  let named = lowered `elem` map (T.map toLower) allowed
  unless (secure' || named) (Left "plain http is allowed only for a host named with --allow-host")
  when (credentialQuery path') (Left "a receiver URL carries no credential in its query; the request is signed instead")
  pure (ReceiverUrl secure' lowered port' path')
  where
    readInt text = case reads (T.unpack text) of
      [(n, "")] -> Just (n :: Int)
      _ -> Nothing
    validHost value =
      not (T.null value)
        && T.length value <= 253
        && all (\label -> not (T.null label) && T.length label <= 63 && T.all (\c -> isAsciiLower c || isDigit c || c == '-') label && not ("-" `T.isPrefixOf` label)) (T.splitOn "." value)
    forbiddenHost value =
      value `elem` ["localhost", "metadata", "metadata.google.internal"]
        || "localhost." `T.isSuffixOf` (value <> ".")
        || "127." `T.isPrefixOf` value
        || "169.254." `T.isPrefixOf` value
        || value == "0.0.0.0"
    credentialQuery value = case T.breakOn "?" value of
      (_, "") -> False
      (_, query) ->
        any
          (\pair -> any (`T.isInfixOf` T.map toLower (fst (T.breakOn "=" pair))) ["token", "key", "secret", "password", "signature", "auth", "credential"])
          (T.splitOn "&" (T.drop 1 query))

-- | The typed destination of a webhook subscription. Its identity is the
-- subscription's: v1 has one destination per subscription.
webhookDestination :: SubscriptionId -> WebhookSettings -> Either Text DestinationSpec
webhookDestination subscription settings' = do
  _ <- parseReceiverUrl (settings' ^. #allowHosts) (settings' ^. #url)
  when (null (settings' ^. #signing)) (Left "a webhook subscription needs a signing key")
  when (length (settings' ^. #signing) > 2) (Left "a webhook subscription signs with at most two keys, during a rotation")
  traverse_ checkRef (settings' ^. #signing)
  when (length (map (^. #keyId) (settings' ^. #signing)) /= length (nubOrd (map (^. #keyId) (settings' ^. #signing)))) (Left "signing key IDs are distinct")
  pure (DestinationSpec ("webhook:" <> subscriptionIdText subscription) webhookTransport webhookSettingsVersion (toJSON settings'))
  where
    checkRef ref = do
      _ <- mkKeyId (ref ^. #keyId)
      unless (all kubernetesName [ref ^. #namespace, ref ^. #secret]) (Left "a signing Secret and its namespace are Kubernetes names")
      unless (not (T.null (ref ^. #key)) && T.length (ref ^. #key) <= 253 && T.all (\c -> isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("-_." :: String)) (ref ^. #key)) (Left "a signing Secret key is a Kubernetes data key")
    kubernetesName value = not (T.null value) && T.length value <= 63 && T.all (\c -> isAsciiLower c || isDigit c || c == '-') value
    nubOrd = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- | A destination's webhook settings, of the version this adapter reads.
decodeWebhookSettings :: DestinationSpec -> Either Text WebhookSettings
decodeWebhookSettings spec = do
  unless (spec ^. #transport == webhookTransport) (Left "the destination is not a webhook")
  unless (spec ^. #version == webhookSettingsVersion) (Left ("unsupported webhook settings version " <> T.pack (show (spec ^. #version))))
  case fromJSON (spec ^. #settings) of
    Success settings' -> settings' <$ parseReceiverUrl (settings' ^. #allowHosts) (settings' ^. #url)
    Error err -> Left (T.pack err)

-- | A new URL or allowed-host list sends elsewhere; new signing keys only
-- sign differently.
webhookRedirects :: DestinationSpec -> DestinationSpec -> Bool
webhookRedirects old new = case (decodeWebhookSettings old, decodeWebhookSettings new) of
  (Right before, Right after) -> before ^. #url /= after ^. #url || before ^. #allowHosts /= after ^. #allowHosts
  _ -> True

exactKeys :: String -> [Key] -> Object -> Parser ()
exactKeys label allowed o = unless (all (`elem` allowed) (KM.keys o)) (fail (label <> " has an unknown field"))

instance ToJSON SecretKeyRef where
  toJSON ref = object ["keyId" .= (ref ^. #keyId), "namespace" .= (ref ^. #namespace), "secret" .= (ref ^. #secret), "key" .= (ref ^. #key)]

instance FromJSON SecretKeyRef where
  parseJSON = withObject "signing key" $ \o -> exactKeys "signing key" ["keyId", "namespace", "secret", "key"] o >> (SecretKeyRef <$> o .: "keyId" <*> o .: "namespace" <*> o .: "secret" <*> o .: "key")

instance ToJSON WebhookSettings where
  toJSON settings' = object ["url" .= (settings' ^. #url), "allowHosts" .= (settings' ^. #allowHosts), "signing" .= (settings' ^. #signing)]

instance FromJSON WebhookSettings where
  parseJSON = withObject "webhook settings" $ \o -> exactKeys "webhook settings" ["url", "allowHosts", "signing"] o >> (WebhookSettings <$> o .: "url" <*> o .: "allowHosts" <*> o .: "signing")
