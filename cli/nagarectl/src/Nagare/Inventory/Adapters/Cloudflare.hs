-- | Offline reviewed Cloudflare owner contract. The injected operations must
-- return a complete, normalized ruleset or an exact proxied A record. A live
-- transport and context-bound zone verification are separate capabilities.
module Nagare.Inventory.Adapters.Cloudflare
  ( CloudflareBinding (..)
  , CloudflareTarget (..)
  , CloudflareObservation (..)
  , CloudflareMutationPlan (..)
  , CloudflareAdapterOps (..)
  , cloudflareBindingsFromDeclarations
  , mkCloudflareAdapter
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Cdn.Cloudflare (buildComposedCacheRulesPayload)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

newtype CloudflareBinding = CloudflareBinding {cloudflareDeclaration :: ManagedResource}
  deriving stock (Eq, Show)

data CloudflareTarget
  = CloudflareDnsTarget !Name !Text !Bool !Int
  | CloudflareRulesTarget !Value
  | CloudflareTlsTarget !CloudflareTlsMode
  deriving stock (Eq, Show, Generic)

data CloudflareObservation
  = CloudflareMissing
  | CloudflarePresent !PhysicalIdentity !(Maybe Text) !CloudflareTarget
  | CloudflareUnavailable !Text
  deriving stock (Eq, Show)

data CloudflareMutationPlan = CloudflareMutationPlan
  { cloudflarePlanOperation :: !OperationId
  , cloudflarePlanAction :: !OperationAction
  , cloudflarePlanInputDigest :: !ContentDigest
  , cloudflarePlanResource :: !ResourceId
  , cloudflarePlanZone :: !Name
  , cloudflarePlanTarget :: !CloudflareTarget
  , cloudflarePlanPrevious :: !(Maybe CloudflareTarget)
  , cloudflarePlanPhysical :: !(Maybe PhysicalIdentity)
  , cloudflarePlanVersion :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data CloudflareAdapterOps = CloudflareAdapterOps
  { cloudflareInspect :: !(ResourceId -> IO CloudflareObservation)
  , cloudflareCreate :: !(CloudflareMutationPlan -> IO AdapterExecution)
  , cloudflareReplace :: !(CloudflareMutationPlan -> IO AdapterExecution)
  , cloudflareDelete :: !(CloudflareMutationPlan -> IO AdapterExecution)
  }

-- | Only composed platform rulesets and host records with an exact route and
-- ruleset dependency enter this adapter. The composition validator checks the
-- owner grant and the same-owner hostname pair before this binder is called.
cloudflareBindingsFromDeclarations :: [Declaration] -> Either Text (Map ResourceId CloudflareBinding)
cloudflareBindingsFromDeclarations declarations = do
  bindings <- traverse bind cloudflareResources
  let result = Map.fromList bindings
  unless (Map.size result == length bindings) (Left "duplicate Cloudflare resource identity")
  pure result
  where
    byId = Map.fromList [(declarationId declaration, declaration) | declaration <- declarations]
    cloudflareResources =
      [ resource
      | Managed resource <- declarations
      , case resource ^. #address of
          CloudflareRuleset {} -> True
          CloudflareTlsSetting {} -> True
          CloudflareDnsRecord {} -> True
          _ -> False
      ]
    bind resource = case (resource ^. #address, resource ^. #spec) of
      (CloudflareRuleset zone, CloudflareRulesSpec _)
        | scopeKind (resource ^. #owner) == Platform
        , OrderedAfter (cloudflareTlsResourceId (resource ^. #owner) zone)
            `elem` resource ^. #dependencies
        , Just (Managed tls) <- Map.lookup (cloudflareTlsResourceId (resource ^. #owner) zone) byId
        , tls ^. #address == CloudflareTlsSetting zone
        , CloudflareZoneTlsSpec _ <- tls ^. #spec ->
            Right (resource ^. #identity, CloudflareBinding resource)
      (CloudflareTlsSetting _, CloudflareZoneTlsSpec _)
        | scopeKind (resource ^. #owner) == Platform ->
            Right (resource ^. #identity, CloudflareBinding resource)
      (CloudflareDnsRecord zone host, desired)
        | case desired of CloudflareProxiedARecord _ -> True; CloudflareDnsOnlyARecord _ -> True; _ -> False
        , Hostname host `elem` resource ^. #aliases
        , Just (Managed route) <- routeDependency resource
        , route ^. #owner == resource ^. #owner
        , Kubernetes _ "serving.knative.dev" kind _ routeHost <- route ^. #address
        , nameText kind == "domainmapping" && routeHost == host
        , Just (Managed ruleset) <- rulesDependency resource
        , ruleset ^. #address == CloudflareRuleset zone
        , CloudflareRulesSpec intents <- ruleset ^. #spec
        , case desired of
            CloudflareDnsOnlyARecord _ -> host `notElem` map cacheHost intents
            _ -> host `elem` map cacheHost intents ->
            Right (resource ^. #identity, CloudflareBinding resource)
      _ -> Left "Cloudflare resource lacks its platform ruleset, exact route, or hostname claim"
    routeDependency resource = case [ declaration
                                    | OrderedAfter producer <- resource ^. #dependencies
                                    , Just declaration <- [Map.lookup producer byId]
                                    , case declaration of
                                        Managed member -> case member ^. #address of Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind == "domainmapping"; _ -> False
                                        _ -> False
                                    ] of
      [declaration] -> Just declaration
      _ -> Nothing
    rulesDependency resource = case [ declaration
                                    | OrderedAfter producer <- resource ^. #dependencies
                                    , Just declaration <- [Map.lookup producer byId]
                                    , case declaration of
                                        Managed member -> case member ^. #address of CloudflareRuleset {} -> True; _ -> False
                                        _ -> False
                                    ] of
      [declaration] -> Just declaration
      _ -> Nothing

mkCloudflareAdapter ::
  Map ResourceId ManagedResource ->
  Map ResourceId CloudflareBinding ->
  CloudflareAdapterOps ->
  Adapter
mkCloudflareAdapter accepted specs ops =
  Adapter
    { adapterExecutor = CdnExecutor
    , adapterIdentity = "reviewed-cloudflare-offline"
    , adapterVersion = "1"
    , adapterObserve = \resources -> do
        entries <- traverse observe resources
        pure (sequence entries >>= observationSet)
    , adapterPrepare = \operation -> do
        case planFor accepted specs operation of
          Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
          Right initial -> do
            fact <- cloudflareInspect ops (cloudflarePlanResource initial)
            let prepared = do
                  (physical, version) <- preparePhysical initial fact
                  let plan = initial {cloudflarePlanPhysical = physical, cloudflarePlanVersion = version}
                  bytes <- canonicalValue (toJSON plan)
                  pure (PreparedNative bytes (summary plan))
            pure (first (PrepareRefused (plannedOperationId operation)) prepared)
    , adapterPreflight = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
        Left reason -> pure (Left reason)
        Right plan -> checkBefore plan <$> cloudflareInspect ops (cloudflarePlanResource plan)
    , adapterExecute = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
        Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
        Right plan -> do
          fact <- cloudflareInspect ops (cloudflarePlanResource plan)
          case checkBefore plan fact of
            Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
            Right () -> case cloudflarePlanAction plan of
              CreateResource -> cloudflareCreate ops plan
              UpdateResource | cloudflarePlanPrevious plan == Just (cloudflarePlanTarget plan) -> pure AdapterEffectCompleted
              UpdateResource -> cloudflareReplace ops plan
              RetireResource -> cloudflareDelete ops plan
              VerifyResource -> pure AdapterEffectCompleted
              AdoptResource -> pure AdapterEffectCompleted
              _ -> pure (AdapterEffectFailed (KnownNoEffect "Cloudflare action is unsupported"))
    , adapterVerify = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
        Left reason -> pure (Left reason)
        Right plan -> do
          fact <- cloudflareInspect ops (cloudflarePlanResource plan)
          pure
            ( case fact of
                CloudflareMissing | cloudflarePlanAction plan == RetireResource -> Right (absentProof plan)
                CloudflarePresent physical version target
                  | cloudflarePlanAction plan /= RetireResource
                  , target == cloudflarePlanTarget plan
                  , maybe True (== physical) (cloudflarePlanPhysical plan)
                  , plannedAction operation `elem` [CreateResource, UpdateResource]
                      || version == cloudflarePlanVersion plan ->
                      Right (proof plan physical)
                CloudflareUnavailable reason -> Left reason
                _ -> Left "Cloudflare resource does not match the reviewed target and physical identity"
            )
    , adapterSettle = Nothing
    , adapterRecover = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
        Left reason -> pure (RecoveryUnresolved reason)
        Right plan -> case cloudflarePlanAction plan of
          RetireResource -> do
            fact <- cloudflareInspect ops (cloudflarePlanResource plan)
            pure
              ( case fact of
                  CloudflareMissing -> RecoveryProvedComplete (absentProof plan)
                  _ -> RecoveryUnresolved "retained DNS absence is unconfirmed; never resend deletion automatically"
              )
          action
            | action `elem` [VerifyResource, AdoptResource]
                || (action == UpdateResource && cloudflarePlanPrevious plan == Just (cloudflarePlanTarget plan)) -> do
                fact <- cloudflareInspect ops (cloudflarePlanResource plan)
                pure
                  ( case fact of
                      CloudflarePresent physical version target
                        | target == cloudflarePlanTarget plan
                        , Just physical == cloudflarePlanPhysical plan
                        , version == cloudflarePlanVersion plan ->
                            RecoveryProvedComplete (proof plan physical)
                      CloudflareUnavailable reason -> RecoveryUnresolved reason
                      _ -> RecoveryUnresolved "Cloudflare verification no longer matches its reviewed resource"
                  )
          _ ->
            pure
              ( RecoveryUnresolved
                  "Cloudflare mutation acknowledgement is uncertain; inspect the provider ID and journal before recovery"
              )
    }
  where
    observe resource = case Map.lookup resource specs of
      Nothing -> pure (Left "Cloudflare resource is absent from reviewed declarations")
      Just binding -> do
        fact <- cloudflareInspect ops resource
        pure $ case fact of
          CloudflareMissing ->
            Right
              ( resource
              , ConfirmedAbsent
                  (contentDigest (TE.encodeUtf8 (resourceIdText resource <> ":absent")))
              )
          CloudflarePresent physical _ target
            | Map.notMember resource accepted -> Right (resource, ObservedUnowned physical)
            | Right (_, desired) <- targetFor (cloudflareDeclaration binding)
            , target == desired ->
                Right (resource, ObservedPresent physical)
            | otherwise ->
                Right
                  ( resource
                  , ObservedDrifted
                      physical
                      (contentDigest (either (error . T.unpack) id (canonicalValue (toJSON target))))
                  )
          CloudflareUnavailable reason -> Right (resource, ObservationUnavailable reason)

planFor ::
  Map ResourceId ManagedResource ->
  Map ResourceId CloudflareBinding ->
  PlannedOperation ->
  Either Text CloudflareMutationPlan
planFor accepted specs operation = do
  resource <- case NE.toList (plannedResources operation) of
    [single] -> Right single
    _ -> Left "Cloudflare operation must affect exactly one resource"
  binding <- maybe (Left "Cloudflare declaration is absent") Right (Map.lookup resource specs)
  let desiredResource = cloudflareDeclaration binding
  (zone, target) <- targetFor desiredResource
  previous <- case plannedAction operation of
    CreateResource | Map.notMember resource accepted -> Right Nothing
    CreateResource -> Left "Cloudflare create already has an accepted owner"
    VerifyResource | Map.member resource accepted -> Right Nothing
    VerifyResource -> Left "Cloudflare verification lacks an accepted owner"
    AdoptResource | Map.notMember resource accepted -> Right Nothing
    AdoptResource -> Left "Cloudflare adoption already has an accepted owner"
    RetireResource -> case Map.lookup resource accepted of
      Just old | old == desiredResource && supportsRetainedCollection old -> Right (Just target)
      _ -> Left "Cloudflare collection requires its exact retained stateless DNS declaration"
    UpdateResource -> case Map.lookup resource accepted of
      Just old | old ^. #address == desiredResource ^. #address -> do
        (_, oldTarget) <- targetFor old
        Right (Just oldTarget)
      _ -> Left "reviewed Cloudflare update lacks an accepted previous declaration at the same address"
    _ -> Left "Cloudflare action is unsupported by this reviewed resource contract"
  pure
    ( CloudflareMutationPlan
        (plannedOperationId operation)
        (plannedAction operation)
        (plannedInputDigest operation)
        resource
        zone
        target
        previous
        Nothing
        Nothing
    )

targetFor :: ManagedResource -> Either Text (Name, CloudflareTarget)
targetFor resource = case (resource ^. #address, resource ^. #spec) of
  (CloudflareDnsRecord zone host, CloudflareProxiedARecord address) ->
    Right (zone, CloudflareDnsTarget host address True 1)
  (CloudflareDnsRecord zone host, CloudflareDnsOnlyARecord address) ->
    Right (zone, CloudflareDnsTarget host address False 1)
  (CloudflareRuleset zone, CloudflareRulesSpec intents) ->
    Right (zone, CloudflareRulesTarget (buildComposedCacheRulesPayload intents))
  (CloudflareTlsSetting zone, CloudflareZoneTlsSpec mode) ->
    Right (zone, CloudflareTlsTarget mode)
  _ -> Left "Cloudflare address or desired specification is invalid"

preparePhysical ::
  CloudflareMutationPlan ->
  CloudflareObservation ->
  Either Text (Maybe PhysicalIdentity, Maybe Text)
preparePhysical plan fact = case (cloudflarePlanAction plan, fact) of
  (CreateResource, CloudflareMissing) -> Right (Nothing, Nothing)
  (RetireResource, CloudflarePresent physical version target)
    | Just target == cloudflarePlanPrevious plan, isJust version -> Right (Just physical, version)
  (UpdateResource, CloudflarePresent physical version target)
    | Just target == cloudflarePlanPrevious plan -> Right (Just physical, version)
  (VerifyResource, CloudflarePresent physical version target)
    | target == cloudflarePlanTarget plan -> Right (Just physical, version)
  (AdoptResource, CloudflarePresent physical version target)
    | target == cloudflarePlanTarget plan -> Right (Just physical, version)
  (_, CloudflareUnavailable reason) -> Left reason
  (CreateResource, CloudflarePresent {}) -> Left "Cloudflare resource already exists without reviewed ownership"
  _ -> Left "Cloudflare provider state differs from the reviewed action"

checkBefore :: CloudflareMutationPlan -> CloudflareObservation -> Either Text ()
checkBefore plan fact = do
  (physical, version) <- preparePhysical plan fact
  unless
    (physical == cloudflarePlanPhysical plan && version == cloudflarePlanVersion plan)
    (Left "Cloudflare physical identity or version changed after review")

decodePlan ::
  Map ResourceId ManagedResource ->
  Map ResourceId CloudflareBinding ->
  PlannedOperation ->
  ByteString ->
  Either Text CloudflareMutationPlan
decodePlan accepted specs operation bytes = do
  plan <- first T.pack (eitherDecodeStrict bytes)
  expected <- planFor accepted specs operation
  unless
    (plan {cloudflarePlanPhysical = Nothing, cloudflarePlanVersion = Nothing} == expected)
    (Left "private Cloudflare mutation differs from reviewed declarations")
  pure plan

summary :: CloudflareMutationPlan -> Text
summary plan | cloudflarePlanAction plan == RetireResource = "delete only retained Cloudflare DNS record " <> maybe "(missing identity)" physicalIdentityText (cloudflarePlanPhysical plan)
summary plan = case cloudflarePlanTarget plan of
  CloudflareDnsTarget host address proxied _ -> "review Cloudflare " <> (if proxied then "proxied" else "DNS-only") <> " A record " <> nameText host <> " -> " <> address
  CloudflareRulesTarget _ -> "review complete Cloudflare cache rules for zone " <> nameText (cloudflarePlanZone plan)
  CloudflareTlsTarget mode ->
    "review Cloudflare origin TLS "
      <> T.pack (show mode)
      <> " for zone "
      <> nameText (cloudflarePlanZone plan)

absentProof :: CloudflareMutationPlan -> ContentDigest
absentProof plan =
  contentDigest
    ( either
        (error . T.unpack)
        id
        (canonicalValue (object ["plan" .= plan, "confirmedAbsent" .= True]))
    )

proof :: CloudflareMutationPlan -> PhysicalIdentity -> ContentDigest
proof plan physical =
  contentDigest
    ( either
        (error . T.unpack)
        id
        (canonicalValue (object ["plan" .= plan, "physical" .= physical]))
    )

instance ToJSON CloudflareTarget where toJSON = genericToJSON defaultOptions

instance FromJSON CloudflareTarget where parseJSON = genericParseJSON defaultOptions

instance ToJSON CloudflareMutationPlan where
  toJSON plan =
    object
      [ "version" .= (1 :: Int)
      , "operation" .= cloudflarePlanOperation plan
      , "action" .= cloudflarePlanAction plan
      , "inputDigest" .= cloudflarePlanInputDigest plan
      , "resource" .= cloudflarePlanResource plan
      , "zone" .= cloudflarePlanZone plan
      , "target" .= cloudflarePlanTarget plan
      , "previous" .= cloudflarePlanPrevious plan
      , "physical" .= cloudflarePlanPhysical plan
      , "providerVersion" .= cloudflarePlanVersion plan
      ]

instance FromJSON CloudflareMutationPlan where
  parseJSON = withObject "Cloudflare mutation plan" $ \o -> do
    version <- o .: "version" :: Parser Int
    unless (version == 1) (fail "unsupported Cloudflare mutation plan version")
    CloudflareMutationPlan
      <$> o .: "operation"
      <*> o .: "action"
      <*> o .: "inputDigest"
      <*> o .: "resource"
      <*> o .: "zone"
      <*> o .: "target"
      <*> o .: "previous"
      <*> o .: "physical"
      <*> o .: "providerVersion"
