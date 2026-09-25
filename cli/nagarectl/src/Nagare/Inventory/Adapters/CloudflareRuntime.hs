{-# LANGUAGE ScopedTypeVariables #-}

-- | Context-bound Cloudflare transport for reviewed zone and host resources.
-- Every read verifies the zone/account binding. Mutation responses with an
-- uncertain outcome remain unresolved by the reviewed adapter.
module Nagare.Inventory.Adapters.CloudflareRuntime
  ( CloudflareRuntimeConfig (..)
  , CloudflareResponse
  , cloudflareRuntimeOps
  , parseCloudflareZone
  , parseCloudflareResource
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Cdn.Cloudflare (parseExactARecordListing)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (AdapterExecution (..), OperationAction (..))
import Nagare.Inventory.Adapters.Cloudflare
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Resource.Inventory (CloudflareTlsMode (..), ManagedResource (..))
import Nagare.Resource.Types

type CloudflareResponse = (Int, ByteString)

data CloudflareRuntimeConfig = CloudflareRuntimeConfig
  { cloudflareRuntimeZone :: !Name
  , cloudflareRuntimeAccount :: !Text
  , cloudflareRuntimeGuard :: !(ResourceId -> IO (Either Text ()))
  , cloudflareRuntimeSpecs :: !(Map ResourceId CloudflareBinding)
  , cloudflareRuntimeRequest :: !(Text -> Text -> Maybe Value -> IO (Either Text CloudflareResponse))
  }

cloudflareRuntimeOps :: CloudflareRuntimeConfig -> CloudflareAdapterOps
cloudflareRuntimeOps config =
  CloudflareAdapterOps
    { cloudflareInspect = inspect config
    , cloudflareCreate = submit config
    , cloudflareReplace = submit config
    }

inspect :: CloudflareRuntimeConfig -> ResourceId -> IO CloudflareObservation
inspect config resource = do
  let binding = Map.lookup resource (cloudflareRuntimeSpecs config)
  case binding of
    Nothing -> pure (CloudflareUnavailable "Cloudflare resource is absent from the context binding")
    Just selected -> do
      guardResult <- cloudflareRuntimeGuard config resource
      case guardResult of
        Left reason -> pure (CloudflareUnavailable reason)
        Right () -> case cloudflareAddress (cloudflareDeclaration selected) of
          Left reason -> pure (CloudflareUnavailable reason)
          Right (zone, path)
            | zone /= cloudflareRuntimeZone config ->
                pure (CloudflareUnavailable "Cloudflare zone differs from the bound context")
            | otherwise -> do
                zoneResult <- cloudflareRuntimeRequest config "GET" (zonePath zone) Nothing
                case zoneResult >>= parseCloudflareZone zone (cloudflareRuntimeAccount config) of
                  Left reason -> pure (CloudflareUnavailable reason)
                  Right () -> do
                    result <- cloudflareRuntimeRequest config "GET" path Nothing
                    pure
                      ( either
                          CloudflareUnavailable
                          id
                          (result >>= parseCloudflareResource (cloudflareDeclaration selected))
                      )

cloudflareAddress :: ManagedResource -> Either Text (Name, Text)
cloudflareAddress resource = case resource ^. #address of
  CloudflareDnsRecord zone host -> Right (zone, zonePath zone <> "/dns_records?type=A&name.exact=" <> nameText host <> "&per_page=2")
  CloudflareRuleset zone -> Right (zone, zonePath zone <> "/rulesets/phases/http_request_cache_settings/entrypoint")
  CloudflareTlsSetting zone -> Right (zone, zonePath zone <> "/settings/ssl")
  _ -> Left "resource is not a Cloudflare zone or DNS claim"

zonePath :: Name -> Text
zonePath zone = "/zones/" <> nameText zone

parseCloudflareZone :: Name -> Text -> CloudflareResponse -> Either Text ()
parseCloudflareZone zone account response = do
  result <- successfulResult response
  unless
    ( fieldText "id" result == Just (nameText zone)
        && nestedText ["account", "id"] result == Just account
    )
    (Left "Cloudflare zone ID or account differs from the bound context")

parseCloudflareResource :: ManagedResource -> CloudflareResponse -> Either Text CloudflareObservation
parseCloudflareResource resource response@(status, bytes) = case resource ^. #address of
  CloudflareDnsRecord zone host -> do
    unless (status == 200) (Left "Cloudflare DNS listing was unsuccessful")
    listed <- parseExactARecordListing (nameText host) bytes
    case listed of
      Nothing -> Right CloudflareMissing
      Just (recordId, content, proxied, ttl) -> do
        record <- successfulResult response >>= arrayOnlyRecord
        physical <- physicalId ("cloudflare:zone/" <> nameText zone <> "/dns/" <> recordId)
        let version = fieldText "modified_on" record
        pure (CloudflarePresent physical version (CloudflareDnsTarget host content proxied ttl))
  CloudflareRuleset zone
    | status == 404 && explicitNotFound bytes -> Right CloudflareMissing
    | otherwise -> do
        result <- successfulResult response
        unless
          ( fieldText "phase" result == Just "http_request_cache_settings"
              && fieldText "kind" result == Just "zone"
          )
          (Left "Cloudflare cache ruleset has an unexpected phase or kind")
        rulesetId <- requiredText "id" result
        version <- requiredText "version" result
        rules <- case field "rules" result of
          Just (Array values) -> traverse normalizeRule (toList values)
          _ -> Left "Cloudflare cache ruleset has no complete rules array"
        physical <- physicalId ("cloudflare:zone/" <> nameText zone <> "/ruleset/" <> rulesetId)
        pure
          ( CloudflarePresent
              physical
              (Just version)
              (CloudflareRulesTarget (object ["rules" .= rules]))
          )
  CloudflareTlsSetting zone -> do
    result <- successfulResult response
    unless
      (fieldText "id" result == Just "ssl")
      (Left "Cloudflare origin TLS response is not the ssl setting")
    mode <- case fieldText "value" result of
      Just "flexible" -> Right CloudflareFlexible
      Just "full" -> Right CloudflareFull
      Just "strict" -> Right CloudflareFullStrict
      _ -> Left "Cloudflare origin TLS setting has an unsupported value"
    physical <- physicalId ("cloudflare:zone/" <> nameText zone <> "/setting/ssl")
    pure (CloudflarePresent physical (fieldText "modified_on" result) (CloudflareTlsTarget mode))
  _ -> Left "resource is not a Cloudflare claim"

-- Provider-generated rule IDs, versions, and timestamps do not affect the
-- desired policy; all behavior-bearing fields must match our known shape.
normalizeRule :: Value -> Either Text Value
normalizeRule rule@(Object fields) = do
  unless
    ( all
        (`elem` ["id", "version", "last_updated", "enabled", "expression", "action", "action_parameters"])
        (map Key.toText (KM.keys fields))
    )
    (Left "Cloudflare cache rule has an unsupported behavior field")
  unless
    (field "enabled" rule `elem` [Nothing, Just (Bool True)])
    (Left "Cloudflare cache rule is disabled")
  expression <- requiredText "expression" rule
  action <- requiredText "action" rule
  unless
    (action == "set_cache_settings")
    (Left "Cloudflare cache ruleset contains another action")
  parameters <-
    maybe
      (Left "Cloudflare cache rule lacks action parameters")
      Right
      (field "action_parameters" rule)
  pure
    ( object
        [ "expression" .= expression
        , "action" .= action
        , "action_parameters" .= parameters
        ]
    )
normalizeRule _ = Left "Cloudflare cache rule is not an object"

submit :: CloudflareRuntimeConfig -> CloudflareMutationPlan -> IO AdapterExecution
submit config plan = do
  current <- inspect config (cloudflarePlanResource plan)
  if not (matchesBase plan current)
    then
      pure
        ( AdapterEffectFailed
            ( KnownNoEffect
                "Cloudflare provider state changed before mutation or its binding is unavailable"
            )
        )
    else case mutationRequest plan of
      Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
      Right (method, path, body) -> do
        response <- cloudflareRuntimeRequest config method path (Just body)
        case response of
          Left _ -> pure (AdapterEffectAmbiguous "Cloudflare mutation has no verifiable response")
          Right received -> case successfulResult received of
            Left _ -> pure (AdapterEffectAmbiguous "Cloudflare mutation response was unsuccessful or unreadable")
            Right _ -> do
              observed <- inspect config (cloudflarePlanResource plan)
              pure $
                if matchesTarget plan observed
                  then AdapterEffectCompleted
                  else AdapterEffectAmbiguous "Cloudflare mutation response did not yield its exact reviewed target"

matchesBase :: CloudflareMutationPlan -> CloudflareObservation -> Bool
matchesBase plan fact = case (cloudflarePlanAction plan, fact) of
  (CreateResource, CloudflareMissing) ->
    isNothing (cloudflarePlanPrevious plan)
      && isNothing (cloudflarePlanPhysical plan)
  (UpdateResource, CloudflarePresent physical version target) ->
    Just target == cloudflarePlanPrevious plan
      && Just physical == cloudflarePlanPhysical plan
      && version == cloudflarePlanVersion plan
      && isJust version
  _ -> False

matchesTarget :: CloudflareMutationPlan -> CloudflareObservation -> Bool
matchesTarget plan (CloudflarePresent physical _ target) =
  target == cloudflarePlanTarget plan
    && maybe True (== physical) (cloudflarePlanPhysical plan)
matchesTarget _ _ = False

mutationRequest :: CloudflareMutationPlan -> Either Text (Text, Text, Value)
mutationRequest plan = case cloudflarePlanTarget plan of
  CloudflareDnsTarget host address proxied ttl ->
    let body =
          object
            [ "type" .= ("A" :: Text)
            , "name" .= nameText host
            , "content" .= address
            , "proxied" .= proxied
            , "ttl" .= ttl
            ]
        base = zonePath (cloudflarePlanZone plan) <> "/dns_records"
     in case cloudflarePlanAction plan of
          CreateResource -> Right ("POST", base, body)
          UpdateResource -> do
            physical <- maybe (Left "reviewed DNS update has no provider ID") Right (cloudflarePlanPhysical plan)
            recordId <- case T.stripPrefix
              ("cloudflare:zone/" <> nameText (cloudflarePlanZone plan) <> "/dns/")
              (physicalIdentityText physical) of
              Just value | validProviderId value -> Right value
              _ -> Left "reviewed DNS record ID differs from the bound zone"
            Right ("PUT", base <> "/" <> recordId, body)
          _ -> Left "Cloudflare DNS action is not mutable"
  CloudflareRulesTarget body ->
    Right
      ( "PUT"
      , zonePath (cloudflarePlanZone plan)
          <> "/rulesets/phases/http_request_cache_settings/entrypoint"
      , body
      )
  CloudflareTlsTarget mode ->
    Right
      ( "PATCH"
      , zonePath (cloudflarePlanZone plan)
          <> "/settings/ssl"
      , object ["value" .= tlsToken mode]
      )

tlsToken :: CloudflareTlsMode -> Text
tlsToken CloudflareFlexible = "flexible"
tlsToken CloudflareFull = "full"
tlsToken CloudflareFullStrict = "strict"

validProviderId :: Text -> Bool
validProviderId value = not (T.null value) && T.all (\c -> c `elem` ['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> ['-']) value

physicalId :: Text -> Either Text PhysicalIdentity
physicalId = mkPhysicalIdentity

successfulResult :: CloudflareResponse -> Either Text Value
successfulResult (status, bytes)
  | status /= 200 && status /= 201 = Left "Cloudflare response returned an unsuccessful HTTP status"
  | otherwise = do
      envelope <- first T.pack (eitherDecodeStrict bytes)
      unless
        (field "success" envelope == Just (Bool True))
        (Left "Cloudflare response reported failure")
      maybe (Left "Cloudflare response has no result") Right (field "result" envelope)

explicitNotFound :: ByteString -> Bool
explicitNotFound bytes = case eitherDecodeStrict bytes of
  Right envelope | field "success" envelope == Just (Bool False) ->
    case field "errors" envelope of
      Just (Array errors) -> case toList errors of
        [entry] -> maybe False (T.isInfixOf "not found" . T.toLower) (fieldText "message" entry)
        _ -> False
      _ -> False
  _ -> False

arrayOnlyRecord :: Value -> Either Text Value
arrayOnlyRecord (Array records) = case toList records of
  [record] -> Right record
  _ -> Left "Cloudflare DNS listing did not contain one exact record"
arrayOnlyRecord _ = Left "Cloudflare DNS listing is not an array"

field :: Text -> Value -> Maybe Value
field key (Object fields) = KM.lookup (Key.fromText key) fields
field _ _ = Nothing

fieldText :: Text -> Value -> Maybe Text
fieldText key value = case field key value of
  Just (String textValue) -> Just textValue
  _ -> Nothing

nestedText :: [Text] -> Value -> Maybe Text
nestedText [key] value = fieldText key value
nestedText (key : keys) value = field key value >>= nestedText keys
nestedText [] _ = Nothing

requiredText :: Text -> Value -> Either Text Text
requiredText key value = case fieldText key value of
  Just result | not (T.null result) -> Right result
  _ -> Left ("Cloudflare response has no valid " <> key)
