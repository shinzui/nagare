{-# LANGUAGE GADTs #-}

-- | Discover managed writers from accepted declarations and immutable native
-- objects before a live data fence is reviewed. A dependency edge or direct
-- PVC mount may identify a writer; an unsupported controller refuses the
-- whole discovery rather than silently omitting it.
module Nagare.Inventory.DataFence.WriterInventory
  ( WriterKind (..)
  , WriterCandidate (..)
  , discoverWriterCandidates
  ) where

import Control.Monad (forM, unless)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Dsl.Prelude
import Nagare.Resource.Inventory
  (Declaration (..), ManagedResource (..), declarationDependencies,
    declarationId)
import Nagare.Resource.Reference
  (Dependency (..), SomeRef (..), refProducer)
import Nagare.Resource.Types

data WriterKind
  = StatefulSetWriter
  | DeploymentWriter
  | CronJobWriter
  | JobWriter
  deriving stock (Eq, Ord, Show)

data WriterCandidate = WriterCandidate
  { candidateResource :: !ResourceId
  , candidateKind :: !WriterKind
  , candidateAddress :: !ProviderAddress
  , candidateByDependency :: !Bool
  , candidateByMount :: !Bool
  }
  deriving stock (Eq, Show)

-- | The target is normally the accepted database StatefulSet or the workload
-- owning the live PVC. The native map must cover each discovered controller;
-- missing or malformed immutable evidence refuses the selection.
discoverWriterCandidates
  :: ResourceId -> ResourceId -> Text -> [Declaration]
  -> Map ResourceId (ManagedResource, ByteString)
  -> Either Text [WriterCandidate]
discoverWriterCandidates target cluster claim declarations native = do
  unless (not (T.null claim)) (Left "fenced PVC name is empty")
  let byId = Map.fromList [(declarationId declaration, declaration)
        | declaration <- declarations]
  unless (length declarations == Map.size byId)
    (Left "accepted writer inventory has duplicate resource identities")
  unless (Map.member target byId)
    (Left "fenced writer target is absent from accepted declarations")
  let affected = dependentClosure target declarations
      relevant =
        [(resource, member, bytes)
        | (resource, (member, bytes)) <- Map.toAscList native
        , inCluster cluster (address member)]
  decoded <- forM relevant $ \(resource, member, bytes) -> do
    value <- first (\err -> "accepted native object is malformed: " <> T.pack err)
      (eitherDecodeStrict' bytes)
    pure (resource, member, value)
  selected <- forM decoded $ \(resource, member, value) -> do
    let dependent = Set.member resource affected
        mounted = mountsClaim claim value
        kind = workloadKind (address member)
        possibleController = hasPodTemplate value
    if not dependent && not mounted
      then pure Nothing
      else case kind of
        Just supported -> pure (Just (WriterCandidate resource supported
          (address member) dependent mounted))
        Nothing
          | possibleController || mounted ->
              Left ("accepted writer controller lacks a fence control: "
                <> resourceIdText resource)
          | otherwise -> pure Nothing
  let candidates = sortOn candidateResource (mapMaybe id selected)
      selectedIds = Set.fromList (map candidateResource candidates)
      unsupportedDependents =
        [resourceIdText resource
        | resource <- Set.toAscList affected
        , Just declaration <- [Map.lookup resource byId]
        , resource /= target
        , declarationNeedsNativeControl declaration
        , Set.notMember resource selectedIds]
  unless (null unsupportedDependents)
    (Left ("accepted dependent may write but has no native fence control: "
      <> T.intercalate "," unsupportedDependents))
  unless (not (maybe False declarationNeedsNativeControl (Map.lookup target byId))
      || Set.member target selectedIds)
    (Left "fenced writer target has no supported native control")
  let uncontrolled = [resourceIdText (candidateResource candidate)
        | candidate <- candidates, candidateKind candidate /= StatefulSetWriter]
  unless (null uncontrolled)
    (Left ("accepted writer has no implemented fence control: "
      <> T.intercalate "," uncontrolled))
  pure candidates

dependentClosure :: ResourceId -> [Declaration] -> Set ResourceId
dependentClosure target declarations = go (Set.singleton target)
  where
    go known =
      let added = Set.fromList
            [declarationId declaration
            | declaration <- declarations
            , any (`Set.member` known) (map dependencyProducer
                (declarationDependencies declaration))]
          next = Set.union known added
       in if next == known then known else go next

dependencyProducer :: Dependency -> ResourceId
dependencyProducer (OrderedAfter resource) = resource
dependencyProducer (Consumes (SomeRef reference)) = refProducer reference
dependencyProducer (ReadyAfter (SomeRef reference)) = refProducer reference

inCluster :: ResourceId -> ProviderAddress -> Bool
inCluster cluster (Kubernetes owner _ _ _ _) = owner == cluster
inCluster _ _ = False

workloadKind :: ProviderAddress -> Maybe WriterKind
workloadKind (Kubernetes _ "apps" kind _ _) = case nameText kind of
  "statefulset" -> Just StatefulSetWriter
  "deployment" -> Just DeploymentWriter
  _ -> Nothing
workloadKind (Kubernetes _ "batch" kind _ _) = case nameText kind of
  "cronjob" -> Just CronJobWriter
  "job" -> Just JobWriter
  _ -> Nothing
workloadKind _ = Nothing

-- | Scan structured native JSON, not text, so Pod templates nested in a
-- CronJob or custom controller cannot hide a direct mount of the claim.
mountsClaim :: Text -> Value -> Bool
mountsClaim claim (Object fields) =
  case KM.lookup "persistentVolumeClaim" fields of
    Just (Object source) | KM.lookup "claimName" source == Just (String claim) -> True
    _ -> any (mountsClaim claim) (KM.elems fields)
mountsClaim claim (Array values) = any (mountsClaim claim) (V.toList values)
mountsClaim _ _ = False

hasPodTemplate :: Value -> Bool
hasPodTemplate (Object fields) =
  KM.member "template" fields || any hasPodTemplate (KM.elems fields)
hasPodTemplate (Array values) = any hasPodTemplate (V.toList values)
hasPodTemplate _ = False

declarationNeedsNativeControl :: Declaration -> Bool
declarationNeedsNativeControl (Managed resource) = case address resource of
  Kubernetes _ group kind _ _ ->
    (group == "apps" && nameText kind `elem`
      ["statefulset", "deployment", "daemonset", "replicaset"])
      || (group == "batch" && nameText kind `elem` ["cronjob", "job"])
      || (group == "serving.knative.dev" && nameText kind == "service")
  Helm {} -> True
  _ -> False
declarationNeedsNativeControl _ = False
