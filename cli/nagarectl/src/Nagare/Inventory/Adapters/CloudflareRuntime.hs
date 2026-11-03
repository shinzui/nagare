{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Context-bound Cloudflare transport for reviewed zone and host resources.
-- Every read verifies the zone/account binding. Mutation responses with an
-- uncertain outcome remain unresolved by the reviewed adapter.
module Nagare.Inventory.Adapters.CloudflareRuntime
  ( CloudflareRuntimeConfig (..)
  , CloudflareResponse
  , cloudflareRuntimeOps
  , tunnelIngressRules
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
import Nagare.Resource.Inventory (CloudflareTlsMode (..), DesiredSpec (..), ManagedResource (..))
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
    , cloudflareDelete = submit config
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
        Right ()
          | isTunnelFamily (cloudflareDeclaration selected ^. #address) ->
              inspectTunnelFamily config (cloudflareDeclaration selected)
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
        (`elem` ["id", "ref", "version", "last_updated", "enabled", "expression", "action", "action_parameters"])
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
    else
      tunnelFamilyRequest config plan >>= \case
        Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
        Right (method, path, body) -> do
          response <- cloudflareRuntimeRequest config method path (if method == "DELETE" then Nothing else Just body)
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
  -- A zone setting always exists, so its first write is bound to the value reviewed.
  (CreateResource, CloudflarePresent physical version CloudflareZoneSettingTarget {}) ->
    Just physical == cloudflarePlanPhysical plan && version == cloudflarePlanVersion plan
  (action, CloudflarePresent physical version target)
    | action `elem` [UpdateResource, RetireResource] ->
        Just target == cloudflarePlanPrevious plan
          && Just physical == cloudflarePlanPhysical plan
          && version == cloudflarePlanVersion plan
          && isJust version
  _ -> False

matchesTarget :: CloudflareMutationPlan -> CloudflareObservation -> Bool
matchesTarget plan CloudflareMissing = cloudflarePlanAction plan == RetireResource
matchesTarget plan (CloudflarePresent physical _ target) =
  cloudflarePlanAction plan /= RetireResource
    && target == cloudflarePlanTarget plan
    && maybe True (== physical) (cloudflarePlanPhysical plan)
matchesTarget _ _ = False

-- | The tunnel family's request, resolving the tunnel's ID when the reviewed target names it.
tunnelFamilyRequest :: CloudflareRuntimeConfig -> CloudflareMutationPlan -> IO (Either Text (Text, Text, Value))
tunnelFamilyRequest config plan = case cloudflarePlanTarget plan of
  CloudflareTunnelTarget tunnel ->
    pure
      ( case cloudflarePlanAction plan of
          CreateResource ->
            Right ("POST", accountPath config <> "/cfd_tunnel", object ["name" .= nameText tunnel, "config_src" .= ("cloudflare" :: Text)])
          _ -> Left "a Cloudflare tunnel is only created; nothing else about it is mutable"
      )
  CloudflareTunnelConfigTarget tunnel base origin -> withTunnel tunnel $ \tunnelId ->
    Right
      ( "PUT"
      , accountPath config <> "/cfd_tunnel/" <> tunnelId <> "/configurations"
      , object ["config" .= object ["ingress" .= tunnelIngressRules base origin]]
      )
  CloudflareTunnelRecordTarget record tunnel -> withTunnel tunnel $ \tunnelId ->
    let body =
          object
            [ "type" .= ("CNAME" :: Text)
            , "name" .= record
            , "content" .= tunnelCnameTarget tunnelId
            , "proxied" .= True
            , "ttl" .= (1 :: Int)
            ]
        base = zonePath (cloudflarePlanZone plan) <> "/dns_records"
     in case cloudflarePlanAction plan of
          CreateResource -> Right ("POST", base, body)
          UpdateResource -> do
            physical <- maybe (Left "reviewed DNS update has no provider ID") Right (cloudflarePlanPhysical plan)
            recordId <- case T.stripPrefix ("cloudflare:zone/" <> nameText (cloudflarePlanZone plan) <> "/dns/") (physicalIdentityText physical) of
              Just value | validProviderId value -> Right value
              _ -> Left "reviewed DNS record ID differs from the bound zone"
            Right ("PUT", base <> "/" <> recordId, body)
          _ -> Left "a tunnel record is only created or updated"
  CloudflareZoneSettingTarget setting value ->
    pure (Right ("PATCH", zonePath (cloudflarePlanZone plan) <> "/settings/" <> nameText setting, object ["value" .= value]))
  _ -> pure (mutationRequest plan)
  where
    withTunnel tunnel build =
      findTunnel config tunnel <&> \case
        Left reason -> Left reason
        Right Nothing -> Left "the reviewed tunnel does not exist yet"
        Right (Just (tunnelId, _)) -> build tunnelId

accountPath :: CloudflareRuntimeConfig -> Text
accountPath config = "/accounts/" <> cloudflareRuntimeAccount config

tunnelCnameTarget :: Text -> Text
tunnelCnameTarget tunnelId = tunnelId <> ".cfargotunnel.com"

-- | The declared rules: the two names the free certificate covers, then a catch-all.
tunnelIngressRules :: Text -> Text -> [Value]
tunnelIngressRules base origin =
  [ object ["hostname" .= base, "service" .= origin]
  , object ["hostname" .= ("*." <> base), "service" .= origin]
  , object ["service" .= ("http_status:404" :: Text)]
  ]

-- | The tunnel's ID and creation time, by its exact name among undeleted tunnels.
findTunnel :: CloudflareRuntimeConfig -> Name -> IO (Either Text (Maybe (Text, Maybe Text)))
findTunnel config tunnel = do
  listed <- cloudflareRuntimeRequest config "GET" (accountPath config <> "/cfd_tunnel?is_deleted=false&name=" <> nameText tunnel) Nothing
  pure $ do
    response <- listed
    result <- successfulResult response
    case result of
      Array values -> case [value | value <- toList values, fieldText "name" value == Just (nameText tunnel)] of
        [] -> Right Nothing
        [one] -> do
          tunnelId <- requiredText "id" one
          unless (validTunnelId tunnelId) (Left "Cloudflare returned an invalid tunnel ID")
          Right (Just (tunnelId, fieldText "created_at" one))
        _ -> Left "more than one Cloudflare tunnel has this name"
      _ -> Left "Cloudflare tunnel listing has no result array"

validTunnelId :: Text -> Bool
validTunnelId value = not (T.null value) && T.all (\c -> c `elem` ['a' .. 'f'] <> ['0' .. '9'] <> "-") value

inspectTunnelFamily :: CloudflareRuntimeConfig -> ManagedResource -> IO CloudflareObservation
inspectTunnelFamily config resource = case resource ^. #address of
  CloudflareTunnel zone tunnel -> bound zone $ do
    found <- findTunnel config tunnel
    pure $ case found of
      Left reason -> CloudflareUnavailable reason
      Right Nothing -> CloudflareMissing
      Right (Just (tunnelId, created)) -> present ("cloudflare:account/" <> cloudflareRuntimeAccount config <> "/tunnel/" <> tunnelId) created (CloudflareTunnelTarget tunnel)
  CloudflareTunnelConfig zone tunnel
    | CloudflareTunnelConfigSpec base origin <- resource ^. #spec -> bound zone $ do
        found <- findTunnel config tunnel
        case found of
          Left reason -> pure (CloudflareUnavailable reason)
          Right Nothing -> pure CloudflareMissing
          Right (Just (tunnelId, _)) -> do
            response <- cloudflareRuntimeRequest config "GET" (accountPath config <> "/cfd_tunnel/" <> tunnelId <> "/configurations") Nothing
            pure (either CloudflareUnavailable id (response >>= parseTunnelConfig config tunnel tunnelId base origin))
  CloudflareTunnelRecord zone _
    | CloudflareTunnelRecordSpec record tunnel <- resource ^. #spec -> bound zone $ do
        found <- findTunnel config tunnel
        response <- cloudflareRuntimeRequest config "GET" (zonePath zone <> "/dns_records?type=CNAME&name.exact=" <> T.replace "*" "%2A" record) Nothing
        pure $ either CloudflareUnavailable id $ do
          tunnelId <- found
          received <- response
          parseTunnelRecord zone record tunnel (fst <$> tunnelId) received
  CloudflareZoneSetting zone setting -> bound zone $ do
    response <- cloudflareRuntimeRequest config "GET" (zonePath zone <> "/settings/" <> nameText setting) Nothing
    pure $ either CloudflareUnavailable id $ do
      result <- response >>= successfulResult
      unless (fieldText "id" result == Just (nameText setting)) (Left "Cloudflare returned another zone setting")
      value <- requiredText "value" result
      physical <- physicalId ("cloudflare:zone/" <> nameText zone <> "/setting/" <> nameText setting)
      -- A setting's @modified_on@ can be null or absent (observed 2026-11-02); its value is what a review binds.
      Right (CloudflarePresent physical (Just (fromMaybe value (fieldText "modified_on" result))) (CloudflareZoneSettingTarget setting value))
  _ -> pure (CloudflareUnavailable "resource is not in the Cloudflare tunnel family")
  where
    present raw version target = either CloudflareUnavailable (\physical -> CloudflarePresent physical version target) (physicalId raw)
    bound zone action
      | zone /= cloudflareRuntimeZone config = pure (CloudflareUnavailable "Cloudflare zone differs from the bound context")
      | otherwise = do
          zoneResult <- cloudflareRuntimeRequest config "GET" (zonePath zone) Nothing
          case zoneResult >>= parseCloudflareZone zone (cloudflareRuntimeAccount config) of
            Left reason -> pure (CloudflareUnavailable reason)
            Right () -> case declaredBase resource of
              Just base
                | Right received <- zoneResult
                , Right result <- successfulResult received
                , fieldText "name" result /= Just base ->
                    pure (CloudflareUnavailable ("the base domain " <> base <> " is not this Cloudflare zone"))
              _ -> action

-- | The base domain a member declares, which must be the zone itself (EP-242 D1).
declaredBase :: ManagedResource -> Maybe Text
declaredBase resource = case resource ^. #spec of
  CloudflareTunnelConfigSpec base _ -> Just base
  CloudflareTunnelRecordSpec record _ -> Just (fromMaybe record (T.stripPrefix "*." record))
  _ -> Nothing

parseTunnelConfig :: CloudflareRuntimeConfig -> Name -> Text -> Text -> Text -> CloudflareResponse -> Either Text CloudflareObservation
parseTunnelConfig config tunnel tunnelId base origin response = do
  result <- successfulResult response
  physical <- physicalId ("cloudflare:account/" <> cloudflareRuntimeAccount config <> "/tunnel/" <> tunnelId <> "/configuration")
  let version = case field "version" result of
        Just (Number n) -> Just (T.pack (show n))
        _ -> Nothing
      observed = nestedField ["config", "ingress"] result
  pure $ case observed of
    Nothing -> CloudflareMissing
    Just (Array rules)
      | null rules -> CloudflareMissing
      | map essentialRule (toList rules) == tunnelIngressRules base origin ->
          CloudflarePresent physical version (CloudflareTunnelConfigTarget tunnel base origin)
    Just other ->
      -- Drift: a rule set this context did not declare reads back as never equal to it.
      CloudflarePresent physical version (CloudflareTunnelConfigTarget tunnel "drifted" (T.pack (show other)))
  where
    essentialRule rule = case rule of
      Object fields -> Object (KM.filterWithKey (\key _ -> Key.toText key `elem` ["hostname", "service"]) fields)
      other -> other

nestedField :: [Text] -> Value -> Maybe Value
nestedField [] value = Just value
nestedField (key : rest) value = field key value >>= nestedField rest

parseTunnelRecord :: Name -> Text -> Name -> Maybe Text -> CloudflareResponse -> Either Text CloudflareObservation
parseTunnelRecord zone record tunnel tunnelId response = do
  result <- successfulResult response
  case result of
    Array values -> case toList values of
      [] -> Right CloudflareMissing
      [one] -> do
        recordId <- requiredText "id" one
        content <- requiredText "content" one
        physical <- physicalId ("cloudflare:zone/" <> nameText zone <> "/dns/" <> recordId)
        let proxied = field "proxied" one == Just (Bool True)
            pointsAt = Just content == (tunnelCnameTarget <$> tunnelId)
            observed
              | pointsAt && proxied = tunnel
              | pointsAt = unproxiedTunnel
              | otherwise = foreignTunnel
        Right (CloudflarePresent physical (fieldText "modified_on" one) (CloudflareTunnelRecordTarget record observed))
      _ -> Left "more than one CNAME has this exact name"
    _ -> Left "Cloudflare DNS listing has no result array"

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
          action | action `elem` [UpdateResource, RetireResource] -> do
            physical <- maybe (Left "reviewed DNS update has no provider ID") Right (cloudflarePlanPhysical plan)
            recordId <- case T.stripPrefix
              ("cloudflare:zone/" <> nameText (cloudflarePlanZone plan) <> "/dns/")
              (physicalIdentityText physical) of
              Just value | validProviderId value -> Right value
              _ -> Left "reviewed DNS record ID differs from the bound zone"
            Right (if action == RetireResource then "DELETE" else "PUT", base <> "/" <> recordId, body)
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
  _ -> Left "this Cloudflare target needs the tunnel family's request"

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
        -- Cloudflare says "could not find entrypoint ruleset in the ... phase", code 10003 (observed 2026-11-02).
        [entry] ->
          field "code" entry == Just (Number 10003)
            || maybe False (\message -> any (`T.isInfixOf` T.toLower message) ["not found", "could not find"]) (fieldText "message" entry)
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
