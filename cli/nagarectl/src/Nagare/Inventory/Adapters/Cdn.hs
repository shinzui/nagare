-- | Reviewed, hostname-specific DNS effects. An existing foreign record is
-- never adopted by matching its value. A lost write stays unresolved because
-- Cloud DNS does not give an RRset an incarnation ID.
module Nagare.Inventory.Adapters.Cdn
  ( DnsBinding (..)
  , DnsMutationPlan (..)
  , DnsObservation (..)
  , DnsAdapterOps (..)
  , dnsSpecsFromDeclarations
  , mkDnsAdapter
  ) where

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
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

newtype DnsBinding = DnsBinding {dnsDeclaration :: ManagedResource}
  deriving stock (Eq, Show)

data DnsMutationPlan = DnsMutationPlan
  { dnsPlanOperation :: !OperationId
  , dnsPlanAction :: !OperationAction
  , dnsPlanInputDigest :: !ContentDigest
  , dnsPlanResource :: !ResourceId
  , dnsPlanProject :: !Name
  , dnsPlanZone :: !Name
  , dnsPlanHost :: !Name
  , dnsPlanTarget :: !Text
  , dnsPlanTtl :: !Int
  , dnsPlanPrevious :: !(Maybe (Text, Int))
  } deriving stock (Eq, Show, Generic)

data DnsObservation
  = DnsMissing
  | DnsPresent !PhysicalIdentity !Text !Int
  | DnsUnavailable !Text
  deriving stock (Eq, Show)

data DnsAdapterOps = DnsAdapterOps
  { dnsInspect :: !(ResourceId -> IO DnsObservation)
  , dnsCreate :: !(DnsMutationPlan -> IO AdapterExecution)
  , dnsReplace :: !(DnsMutationPlan -> IO AdapterExecution)
  }

dnsSpecsFromDeclarations :: [Declaration] -> Either Text (Map ResourceId DnsBinding)
dnsSpecsFromDeclarations declarations = do
  bindings <- traverse bind dnsResources
  let result = Map.fromList bindings
  unless (Map.size result == length bindings) (Left "duplicate DNS resource identity")
  pure result
  where
    byId = Map.fromList [(declarationId declaration, declaration) | declaration <- declarations]
    dnsResources = [resource | Managed resource <- declarations,
      DnsRecord {} <- [resource ^. #address]]
    bind resource = case (resource ^. #address, resource ^. #spec) of
      (DnsRecord _ _ host, DnsARecord _ _)
        | Hostname host `elem` resource ^. #aliases
        , [domain, backend] <- [producer | OrderedAfter producer <- resource ^. #dependencies]
        , Just (Managed domainResource) <- Map.lookup domain byId
        , Just (Managed backendResource) <- Map.lookup backend byId
        , resource ^. #owner == domainResource ^. #owner
        , case domainResource ^. #address of
            Kubernetes _ "serving.knative.dev" kind _ domainHost ->
              nameText kind == "domainmapping" && domainHost == host
            _ -> False
        , backendResource ^. #executor == PulumiExecutor ->
            Right (resource ^. #identity, DnsBinding resource)
      _ -> Left "DNS resource lacks its exact hostname, domain, or Pulumi backend dependency"

mkDnsAdapter :: Map ResourceId ManagedResource -> Map ResourceId DnsBinding -> DnsAdapterOps -> Adapter
mkDnsAdapter accepted specs ops = Adapter
  { adapterExecutor = CdnExecutor
  , adapterIdentity = "reviewed-google-cloud-dns"
  , adapterVersion = "1"
  , adapterObserve = \resources -> do
      entries <- traverse observe resources
      pure (sequence entries >>= observationSet)
  , adapterPrepare = \operation -> pure $ do
      plan <- first (PrepareRefused (plannedOperationId operation)) (planFor accepted specs operation)
      bytes <- first (PrepareRefused (plannedOperationId operation)) (canonicalValue (toJSON plan))
      pure (PreparedNative bytes (summary plan))
  , adapterPreflight = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
      Left reason -> pure (Left reason)
      Right plan -> do
        fact <- dnsInspect ops (dnsPlanResource plan)
        pure (checkBefore plan fact)
  , adapterExecute = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
      Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
      Right plan -> do
        fact <- dnsInspect ops (dnsPlanResource plan)
        case checkBefore plan fact of
          Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          Right () -> case dnsPlanAction plan of
            CreateResource -> dnsCreate ops plan
            UpdateResource -> dnsReplace ops plan
            VerifyResource -> pure AdapterEffectCompleted
            _ -> pure (AdapterEffectFailed (KnownNoEffect "DNS action is unsupported"))
  , adapterVerify = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
      Left reason -> pure (Left reason)
      Right plan -> do
        fact <- dnsInspect ops (dnsPlanResource plan)
        pure (case fact of
          DnsPresent physical target ttl | target == dnsPlanTarget plan && ttl == dnsPlanTtl plan ->
            Right (proof plan physical)
          DnsUnavailable reason -> Left reason
          _ -> Left "DNS record does not match the reviewed target after execution")
  , adapterRecover = \operation prepared -> case decodePlan accepted specs operation (preparedNativeBytes prepared) of
      Left reason -> pure (RecoveryUnresolved reason)
      Right plan -> do
        fact <- dnsInspect ops (dnsPlanResource plan)
        pure (case (dnsPlanAction plan, fact) of
          (VerifyResource, DnsPresent physical target ttl)
            | target == dnsPlanTarget plan && ttl == dnsPlanTtl plan ->
                RecoveryProvedComplete (proof plan physical)
          (_, DnsUnavailable reason) -> RecoveryUnresolved reason
          _ -> RecoveryUnresolved "DNS mutation may have taken effect; inspect the exact record and journal before recovery")
  }
  where
    observe resource = case Map.lookup resource specs of
      Nothing -> pure (Left "DNS resource is absent from reviewed declarations")
      Just binding -> do
        fact <- dnsInspect ops resource
        pure $ case fact of
          DnsMissing -> Right (resource, ConfirmedAbsent (contentDigest (TE.encodeUtf8 (resourceIdText resource <> ":absent"))))
          DnsPresent physical target ttl
            | Map.notMember resource accepted -> Right (resource, ObservedUnowned physical)
            | DnsARecord wanted wantedTtl <- dnsDeclaration binding ^. #spec
            , target == wanted && ttl == wantedTtl -> Right (resource, ObservedPresent physical)
            | otherwise -> Right (resource, ObservedDrifted physical (contentDigest (TE.encodeUtf8 (target <> ":" <> T.pack (show ttl)))))
          DnsUnavailable reason -> Right (resource, ObservationUnavailable reason)
    summary plan = case dnsPlanAction plan of
      UpdateResource -> "change Cloud DNS A record " <> nameText (dnsPlanHost plan) <> " to " <> dnsPlanTarget plan
      _ -> "review Cloud DNS A record " <> nameText (dnsPlanHost plan) <> " -> " <> dnsPlanTarget plan

planFor :: Map ResourceId ManagedResource -> Map ResourceId DnsBinding -> PlannedOperation -> Either Text DnsMutationPlan
planFor accepted specs operation = do
  resource <- case NE.toList (plannedResources operation) of
    [single] -> Right single
    _ -> Left "DNS operation must affect exactly one record"
  binding <- maybe (Left "DNS declaration is absent") Right (Map.lookup resource specs)
  (project, zone, host, target, ttl) <- case (dnsDeclaration binding ^. #address, dnsDeclaration binding ^. #spec) of
    (DnsRecord p z h, DnsARecord ip seconds) -> Right (p, z, h, ip, seconds)
    _ -> Left "DNS declaration has an invalid address or specification"
  previous <- case plannedAction operation of
    CreateResource -> Right Nothing
    VerifyResource -> Right Nothing
    UpdateResource -> case Map.lookup resource accepted of
      Just old -> case (old ^. #address, old ^. #spec) of
        (DnsRecord oldProject oldZone oldHost, DnsARecord oldTarget oldTtl)
          | (project, zone, host) == (oldProject, oldZone, oldHost)
          , (target, ttl) /= (oldTarget, oldTtl) -> Right (Just (oldTarget, oldTtl))
        _ -> Left "reviewed DNS update requires the same accepted project, zone, and hostname"
      Nothing -> Left "DNS update lacks an accepted previous declaration"
    _ -> Left "DNS adoption, retirement, and replacement require separate reviewed capabilities"
  pure (DnsMutationPlan (plannedOperationId operation) (plannedAction operation)
    (plannedInputDigest operation) resource project zone host target ttl previous)

decodePlan :: Map ResourceId ManagedResource -> Map ResourceId DnsBinding -> PlannedOperation -> ByteString -> Either Text DnsMutationPlan
decodePlan accepted specs operation bytes = do
  plan <- first T.pack (eitherDecodeStrict bytes)
  expected <- planFor accepted specs operation
  unless (plan == expected) (Left "private DNS mutation differs from the reviewed declaration")
  pure plan

checkBefore :: DnsMutationPlan -> DnsObservation -> Either Text ()
checkBefore plan fact = case (dnsPlanAction plan, fact) of
  (CreateResource, DnsMissing) -> Right ()
  (VerifyResource, DnsPresent _ target ttl)
    | (target, ttl) == (dnsPlanTarget plan, dnsPlanTtl plan) -> Right ()
  (UpdateResource, DnsPresent _ target ttl)
    | Just (target, ttl) == dnsPlanPrevious plan -> Right ()
  (_, DnsUnavailable reason) -> Left reason
  (CreateResource, DnsPresent {}) -> Left "DNS record already exists without reviewed ownership"
  _ -> Left "DNS observation differs from the reviewed action"

proof :: DnsMutationPlan -> PhysicalIdentity -> ContentDigest
proof plan physical = contentDigest (either (error . T.unpack) id
  (canonicalValue (object ["plan" .= plan, "physical" .= physical])))

instance ToJSON DnsMutationPlan where
  toJSON plan = object
    [ "version" .= (1 :: Int), "operation" .= dnsPlanOperation plan
    , "action" .= dnsPlanAction plan, "inputDigest" .= dnsPlanInputDigest plan
    , "resource" .= dnsPlanResource plan, "project" .= dnsPlanProject plan
    , "zone" .= dnsPlanZone plan, "host" .= dnsPlanHost plan
    , "target" .= dnsPlanTarget plan, "ttl" .= dnsPlanTtl plan
    , "previous" .= dnsPlanPrevious plan]

instance FromJSON DnsMutationPlan where
  parseJSON = withObject "DNS mutation plan" $ \o -> do
    version <- o .: "version" :: Parser Int
    unless (version == 1) (fail "unsupported DNS mutation plan version")
    DnsMutationPlan <$> o .: "operation" <*> o .: "action" <*> o .: "inputDigest"
      <*> o .: "resource" <*> o .: "project" <*> o .: "zone" <*> o .: "host"
      <*> o .: "target" <*> o .: "ttl" <*> o .: "previous"
