module Nagare.Resource.Inventory
  ( Executor (..)
  , DesiredSpec (..)
  , ManagedResource (..)
  , Declaration (..)
  , ClaimKind (..)
  , claimsOf
  , declarationId
  , declarationSource
  , declarationDependencies
  , DeclaredOperation (..)
  , OperationKind (..)
  , OperationInput (..)
  , BackendRole (..)
  , Contribution (..)
  , ContributionGrant (..)
  , backendMapResourceId
  , shomeiSettingsResourceId
  , ResourceBundle (..)
  , ScopeDeclaration
  , mkScopeDeclaration
  , scopeId
  , scopeBundles
  , ClaimHolder (..)
  , ReservationReason (..)
  , ScopeSnapshot
  , mkScopeSnapshot
  , snapshotBinding
  , snapshotScopes
  , snapshotReservations
  , ScopeChange (..)
  , CompositionCandidate
  , ValidatedInventory
  , composeInventory
  , composeSnapshot
  , candidateInventory
  , candidateBase
  , candidateChanges
  , candidateGenerations
  , inventoryScopes
  , inventoryDeclarations
  , inventoryBinding
  , contributionDependents
  , composedDeclarations
  )
where

import Data.Generics.Labels ()
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (group, sort, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified
import Nagare.Dsl.Prelude
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types

data Executor = KubernetesExecutor | PulumiExecutor | HostExecutor | ArtifactExecutor | CacheExecutor | HelmExecutor
  deriving stock (Eq, Ord, Show, Generic)

-- | Closed, versioned alternatives. Native bytes are referenced by content identity.
-- Controller reservations are derived here, never supplied by an executor at apply.
data DesiredSpec
  = NativeObject !ContentDigest
  | KnativeService !ContentDigest
  | Certificate !Name !ContentDigest
  | StatefulSet !Integer ![Name] !ContentDigest
  | HelmRelease !(NonEmpty ProviderAddress) !ContentDigest
  | ArtifactPublication !Name !Text !ContentDigest !Bool
  | NamespaceSpec !(Maybe ContentDigest)
  | BackendMapSpec ![(Name, Text, BackendRole)]
  | ShomeiSettingsSpec !Name !(Maybe Name)
  | LogicalCache !ContentDigest
  deriving stock (Eq, Ord, Show, Generic)

data ManagedResource = ManagedResource
  { identity :: !ResourceId
  , owner :: !ScopeId
  , executor :: !Executor
  , address :: !ProviderAddress
  , aliases :: ![ProviderAddress]
  , spec :: !DesiredSpec
  , lifecycle :: !LifecyclePolicy
  , dataPolicy :: !DataPolicy
  , sensitivity :: !Sensitivity
  , dependencies :: ![Dependency]
  , delegations :: ![Delegation]
  , source :: !SourceLocation
  }
  deriving stock (Eq, Ord, Show, Generic)

data Declaration
  = Managed !ManagedResource
  | External !ResourceId !ProviderAddress ![Dependency] !SourceLocation
  | ObservedChild !ResourceId !ResourceId !ProviderAddress !PhysicalIdentity !SourceLocation
  deriving stock (Eq, Ord, Show, Generic)

data ClaimKind = DirectClaim | AliasClaim | DerivedReservation deriving stock (Eq, Ord, Show, Generic)

declarationId :: Declaration -> ResourceId
declarationId (Managed r) = r ^. #identity
declarationId (External r _ _ _) = r
declarationId (ObservedChild r _ _ _ _) = r

declarationSource :: Declaration -> SourceLocation
declarationSource (Managed r) = r ^. #source
declarationSource (External _ _ _ s) = s
declarationSource (ObservedChild _ _ _ _ s) = s

declarationDependencies :: Declaration -> [Dependency]
declarationDependencies (Managed r) = r ^. #dependencies
declarationDependencies (External _ _ ds _) = ds
declarationDependencies (ObservedChild _ p _ _ _) = [OrderedAfter p]

claimsOf :: Declaration -> NonEmpty (ClaimKind, CanonicalClaim)
claimsOf (External _ a _ _) = (DirectClaim, canonicalClaim a) :| []
claimsOf (ObservedChild _ _ a _ _) = (DirectClaim, canonicalClaim a) :| []
claimsOf (Managed r) =
  (DirectClaim, canonicalClaim (r ^. #address))
    :| (map ((AliasClaim,) . canonicalClaim) (r ^. #aliases) <> map ((DerivedReservation,) . canonicalClaim) (derived r))

derived :: ManagedResource -> [ProviderAddress]
derived r = case (r ^. #address, r ^. #spec) of
  (Kubernetes c _ _ ns n, KnativeService _) -> [Kubernetes c "" (known "service") ns n]
  (Kubernetes c _ _ ns _, Certificate secret _) -> [Kubernetes c "" (known "secret") ns secret]
  (Kubernetes c _ _ ns n, StatefulSet replicas templates _) ->
    [Kubernetes c "" (known "pod") ns pod | i <- [0 .. bounded replicas - 1], Right pod <- [mkName (ordinal n i)]]
      <> [Kubernetes c "" (known "persistentvolumeclaim") ns pvc | t <- templates, i <- [0 .. bounded replicas - 1], Right pvc <- [mkName (nameText t <> "-" <> ordinal n i)]]
  (_, HelmRelease objects _) -> NE.toList objects
  _ -> []
  where
    ordinal n i = nameText n <> "-" <> packInteger i
    bounded count = if count >= 0 && count <= 10000 then count else 0

-- Internal constants and generated names are checked by structural validation too.
known :: Text -> Name
known = either (error . show) id . mkName

packInteger :: Integer -> Text
packInteger = Data.Text.pack . show

data OperationInput = CapabilityInput !SomeRef | SecretInput !SecretRef | ContentInput !ContentDigest
  deriving stock (Eq, Ord, Show, Generic)

data OperationKind = SchemaMigration | CreateLogicalCache | SnapshotData | RestoreData | PublishRelease | ActivateHost
  deriving stock (Eq, Ord, Show, Generic)

data DeclaredOperation = DeclaredOperation
  { identity :: !ResourceId
  , affects :: !(NonEmpty ResourceId)
  , inputs :: ![OperationInput]
  , recovery :: !RecoveryClass
  , operationKind :: !OperationKind
  }
  deriving stock (Eq, Ord, Show, Generic)

data BackendRole = ProtectedBackend | PortalBackend
  deriving stock (Eq, Ord, Show, Generic)

data Contribution
  = RegisterNamespace
      {owner :: !ScopeId, cluster :: !ResourceId, namespace :: !Name, key :: !LogicalKey}
  | RegisterBackend
      {owner :: !ScopeId, cluster :: !ResourceId, host :: !Name, upstream :: !Text
      , role :: !BackendRole, key :: !LogicalKey}
  deriving stock (Eq, Ord, Show, Generic)

data ContributionGrant = NamespaceGrant !ScopeId !ResourceId | BackendMapGrant !ResourceId | ShomeiSettingsGrant !ResourceId !Name
  deriving stock (Eq, Ord, Show, Generic)

data ResourceBundle = ResourceBundle
  { declarations :: ![Declaration]
  , exports :: ![SomeExport]
  , conditions :: ![SomeRef]
  , contributions :: ![Contribution]
  , operations :: ![DeclaredOperation]
  , grants :: ![ContributionGrant]
  }
  deriving stock (Eq, Ord, Show, Generic)

data ScopeDeclaration = ScopeDeclaration ScopeId [ResourceBundle] deriving stock (Eq, Ord, Show)

scopeId :: ScopeDeclaration -> ScopeId
scopeId (ScopeDeclaration s _) = s

scopeBundles :: ScopeDeclaration -> [ResourceBundle]
scopeBundles (ScopeDeclaration _ bs) = bs

mkScopeDeclaration :: ScopeId -> [ResourceBundle] -> Either (NonEmpty InventoryError) ScopeDeclaration
mkScopeDeclaration s bs = checked errors (ScopeDeclaration s (sort bs))
  where
    ds = concatMap (^. #declarations) bs
    ids = map declarationId ds <> map (^. #identity) (concatMap (^. #operations) bs)
    errors =
      [inventoryError "duplicate-id" "duplicate resource or operation identity in scope" & #scopes .~ [s] & #resources .~ [r] | r <- duplicates ids]
        <> concatMap validateDeclaration ds
        <> [err "wrong-owner" "managed declaration belongs to a different scope" d | d@(Managed r) <- ds, r ^. #owner /= s]
        <> [err "derived-auth-settings" "shared auth settings must be composed from owner grants and contributions" d
           | d@(Managed r) <- ds, case r ^. #spec of BackendMapSpec _ -> True; ShomeiSettingsSpec {} -> True; _ -> False]
    err c m d = inventoryError c m & #scopes .~ [s] & #resources .~ [declarationId d] & #sources .~ [declarationSource d]

validateDeclaration :: Declaration -> [InventoryError]
validateDeclaration d@(Managed r) = [err m | m <- issues]
  where
    err m = inventoryError "invalid-declaration" m & #scopes .~ [r ^. #owner] & #resources .~ [r ^. #identity] & #sources .~ [r ^. #source]
    issues =
      ["durable resources require retention or protection" | Durable _ <- [r ^. #dataPolicy], r ^. #lifecycle == DeleteWhenUnreferenced]
        <> [message | address <- r ^. #address : r ^. #aliases, Left message <- [mkProviderAddress address]]
        <> ["executor does not match address" | not executorMatches]
        <> ["controller kind requires its explicit reservation-producing spec" | not specMatches]
        <> ["invalid replica count or generated name" | StatefulSet count templates _ <- [r ^. #spec], count < 0 || count > 10000 || any (> 230) (map (Data.Text.length . nameText) templates) || addressNameLength > 230]
        <> ["generated controller address exceeds provider name bounds" | StatefulSet count templates _ <- [r ^. #spec], count >= 0, count <= 10000, toInteger (length (derived r)) /= count * (1 + toInteger (length templates))]
        <> ["delegated fields overlap" | or [x == y || (x <> ".") `Data.Text.isPrefixOf` y || (y <> ".") `Data.Text.isPrefixOf` x | (i, x) <- zip [0 :: Int ..] delegatedFields, (j, y) <- zip [0 :: Int ..] delegatedFields, i < j]]
        <> ["duplicate address within declaration" | length claimSet /= Set.size (Set.fromList claimSet)]
        <> ["shared backend map belongs to the platform auth scope"
           | BackendMapSpec _ <- [r ^. #spec], scopeIdText (r ^. #owner) /= "platform:auth"]
        <> ["shared Shomei settings belong to the platform auth scope"
           | ShomeiSettingsSpec {} <- [r ^. #spec], scopeIdText (r ^. #owner) /= "platform:auth"]
    -- Avoid expanding an invalid StatefulSet before reporting its bounds.
    claimSet = case r ^. #spec of
      StatefulSet n _ _ | n < 0 || n > 10000 || addressNameLength > 230 -> []
      _ -> map snd (NE.toList (claimsOf d))
    addressNameLength = case r ^. #address of Kubernetes _ _ _ _ n -> Data.Text.length (nameText n); _ -> 0
    delegatedFields = map nameText (concatMap (NE.toList . (^. #fields)) (r ^. #delegations))
    executorMatches = case r ^. #address of
      Kubernetes {} -> r ^. #executor == KubernetesExecutor
      GlobalBucket {} -> r ^. #executor == PulumiExecutor
      CloudInstance {} -> r ^. #executor == PulumiExecutor
      PulumiUrn {} -> r ^. #executor == PulumiExecutor
      Host {} -> r ^. #executor == HostExecutor
      Artifact {} -> r ^. #executor == ArtifactExecutor
      AtticCache {} -> r ^. #executor == CacheExecutor
      Helm {} -> r ^. #executor == HelmExecutor
      _ -> True
    specMatches = case (r ^. #address, r ^. #spec) of
      (Kubernetes _ "serving.knative.dev" k (Just _) _, KnativeService _) -> nameText k == "service"
      (Kubernetes _ "cert-manager.io" k (Just _) _, Certificate {}) -> nameText k == "certificate"
      (Kubernetes _ "apps" k (Just _) _, StatefulSet {}) -> nameText k == "statefulset"
      (Kubernetes _ "" k Nothing _, NamespaceSpec _) -> nameText k == "namespace"
      (Kubernetes _ "" k (Just ns) n, BackendMapSpec _) ->
        nameText k == "configmap" && nameText ns == "nagare-system" && nameText n == "nagare-access-backends"
      (Kubernetes _ "" k (Just ns) n, ShomeiSettingsSpec {}) ->
        nameText k == "configmap" && nameText ns == "nagare-system" && nameText n == "nagare-shomei-settings"
      (Kubernetes _ g k _ _, NativeObject _) -> (g, nameText k) `notElem` [("serving.knative.dev", "service"), ("cert-manager.io", "certificate"), ("apps", "statefulset")]
      (AtticCache _ _, LogicalCache _) -> True
      (AtticCache {}, _) -> False
      (Helm {}, HelmRelease {}) -> True
      (Helm {}, _) -> False
      (_, NativeObject _) -> True
      (_, HelmRelease {}) -> False
      (Artifact _ _, ArtifactPublication {}) -> True
      _ -> False
validateDeclaration d = [inventoryError "invalid-address" message & #resources .~ [declarationId d] & #sources .~ [declarationSource d] | address <- addresses, Left message <- [mkProviderAddress address]]
  where
    addresses = case d of External _ a _ _ -> [a]; ObservedChild _ _ a _ _ -> [a]; Managed _ -> []

data ReservationReason = RetainedIncarnation | CandidateIncarnation | UnresolvedTransaction
  deriving stock (Eq, Ord, Show, Generic)

data ClaimHolder = ClaimHolder !ScopeId !ResourceId !PhysicalIdentity !ReservationReason
  deriving stock (Eq, Ord, Show, Generic)

data ScopeSnapshot = ScopeSnapshot ContextBinding (Map ScopeId (ScopeGeneration, ScopeDeclaration)) (Map CanonicalClaim ClaimHolder)
  deriving stock (Eq, Show)

mkScopeSnapshot :: ContextBinding -> Map ScopeId (ScopeGeneration, ScopeDeclaration) -> Map CanonicalClaim ClaimHolder -> Either (NonEmpty InventoryError) ScopeSnapshot
mkScopeSnapshot b ss rs =
  checked
    [inventoryError "snapshot-scope" "snapshot key disagrees with complete scope declaration" | (s, (_, d)) <- Map.toList ss, s /= scopeId d]
    (ScopeSnapshot b ss rs)

snapshotBinding :: ScopeSnapshot -> ContextBinding
snapshotBinding (ScopeSnapshot b _ _) = b

snapshotScopes :: ScopeSnapshot -> Map ScopeId (ScopeGeneration, ScopeDeclaration)
snapshotScopes (ScopeSnapshot _ ss _) = ss

snapshotReservations :: ScopeSnapshot -> Map CanonicalClaim ClaimHolder
snapshotReservations (ScopeSnapshot _ _ rs) = rs

data ScopeChange = ReplaceScope !ScopeDeclaration | RetireScope !ScopeId !RetirementIntent deriving stock (Eq, Ord, Show, Generic)

data ValidatedInventory = ValidatedInventory ContextBinding (Map ScopeId ScopeDeclaration) [Declaration] deriving stock (Eq, Show)

data CompositionCandidate = CompositionCandidate ValidatedInventory (Map ScopeId ScopeGeneration) (NonEmpty ScopeChange) (Map ScopeId ScopeGeneration) deriving stock (Eq, Show)

candidateInventory :: CompositionCandidate -> ValidatedInventory
candidateInventory (CompositionCandidate i _ _ _) = i

candidateBase :: CompositionCandidate -> Map ScopeId ScopeGeneration
candidateBase (CompositionCandidate _ b _ _) = b

candidateChanges :: CompositionCandidate -> NonEmpty ScopeChange
candidateChanges (CompositionCandidate _ _ c _) = c

candidateGenerations :: CompositionCandidate -> Map ScopeId ScopeGeneration
candidateGenerations (CompositionCandidate _ _ _ g) = g

inventoryScopes :: ValidatedInventory -> Map ScopeId ScopeDeclaration
inventoryScopes (ValidatedInventory _ ss _) = ss

inventoryDeclarations :: ValidatedInventory -> [Declaration]
inventoryDeclarations (ValidatedInventory _ _ ds) = ds

inventoryBinding :: ValidatedInventory -> ContextBinding
inventoryBinding (ValidatedInventory b _ _) = b

-- | The contributor retains a dependency on the owner-composed Namespace even
-- though that Namespace is absent from its own lifecycle-owned declarations.
contributionDependents :: ValidatedInventory -> Map ResourceId (Set.Set ScopeId)
contributionDependents inventory =
  Map.fromListWith Set.union
    [ (contributionResourceId c, Set.singleton s)
    | (s, d) <- Map.toList (inventoryScopes inventory)
    , b <- scopeBundles d
    , c <- b ^. #contributions
    ]

composeInventory :: ScopeSnapshot -> NonEmpty ScopeChange -> Either (NonEmpty InventoryError) CompositionCandidate
composeInventory snapshot changes = do
  checked changeErrors ()
  ds <- composedDeclarations ss
  checked
    (validateGraph ss ds (snapshotReservations snapshot))
    (CompositionCandidate (ValidatedInventory (snapshotBinding snapshot) ss ds) base (NE.sort changes) generations)
  where
    original = snapshotScopes snapshot
    base = fmap fst original
    selected = NE.toList changes
    changedId (ReplaceScope s) = scopeId s
    changedId (RetireScope s _) = s
    changeErrors =
      [inventoryError "duplicate-change" "scope selected more than once" & #scopes .~ [s] | s <- duplicates (map changedId selected)]
        <> [inventoryError "unknown-retirement" "cannot retire a scope absent from the snapshot" & #scopes .~ [s] | RetireScope s _ <- selected, Map.notMember s original]
    ss = foldl change (fmap snd original) selected
    change m (ReplaceScope s) = Map.insert (scopeId s) s m
    change m (RetireScope s _) = Map.delete s m
    generations = Map.mapWithKey (\s _ -> if s `elem` map changedId selected then nextGeneration (Map.lookup s base) else base Map.! s) ss

-- | Reconstruct accepted effective resources for read-only status. This runs
-- the same closed contribution and claim validation as a changed candidate.
composeSnapshot :: ScopeSnapshot -> Either (NonEmpty InventoryError) ValidatedInventory
composeSnapshot snapshot = do
  declarations <- composedDeclarations scopes
  checked (validateGraph scopes declarations (snapshotReservations snapshot))
    (ValidatedInventory (snapshotBinding snapshot) scopes declarations)
  where
    scopes = fmap snd (snapshotScopes snapshot)

scopeDeclarations :: ScopeDeclaration -> [Declaration]
scopeDeclarations = concatMap (^. #declarations) . scopeBundles

-- | Reconstruct the effective view from accepted scope members as well as
-- from a candidate. Shared resources are never stored in a contributor's
-- scope bytes, so historical comparison must run the same closed composer.
composedDeclarations :: Map ScopeId ScopeDeclaration -> Either (NonEmpty InventoryError) [Declaration]
composedDeclarations ss = do
  contributed <- composeContributions ss
  pure (sortOn declarationId (concatMap scopeDeclarations (Map.elems ss) <> contributed))

composeContributions :: Map ScopeId ScopeDeclaration -> Either (NonEmpty InventoryError) [Declaration]
composeContributions ss = checked errors (namespaces <> backendMaps <> shomeiSettings)
  where
    requests = [(s, c) | (s, d) <- Map.toList ss, b <- scopeBundles d, c <- b ^. #contributions]
    namespaceRequests = [(s, c, namespaceName) | (s, c@(RegisterNamespace _ _ namespaceName _)) <- requests]
    backendRequests = [(s, c, hostName, upstreamText, backendRole)
      | (s, c@(RegisterBackend _ _ hostName upstreamText backendRole _)) <- requests]
    grouped = Map.fromListWith (<>)
      [ ((c ^. #owner, c ^. #cluster, namespaceName), (s, c) :| []) | (s, c, namespaceName) <- namespaceRequests ]
    authorized s c = maybe False (elem (NamespaceGrant s (c ^. #cluster)) . concatMap (^. #grants) . scopeBundles) (Map.lookup (c ^. #owner) ss)
    backendOwners =
      [ (s, clusterId)
      | (s, d) <- Map.toList ss
      , b <- scopeBundles d
      , BackendMapGrant clusterId <- b ^. #grants]
    shomeiOwners =
      [ (s, clusterId, baseDomain)
      | (s, d) <- Map.toList ss
      , b <- scopeBundles d
      , ShomeiSettingsGrant clusterId baseDomain <- b ^. #grants]
    backendAuthorized s c = scopeKind s == Application
      && (c ^. #owner, c ^. #cluster) `elem` backendOwners
    backendGroups = Map.fromListWith (<>)
      [ ((c ^. #owner, c ^. #cluster), [(s, c, hostName, upstreamText, backendRole)])
      | (s, c, hostName, upstreamText, backendRole) <- backendRequests]
    errors = [inventoryError "unauthorized-contribution" "namespace contribution lacks an owner grant" & #scopes .~ [s, c ^. #owner] | (s, c, _) <- namespaceRequests, not (authorized s c)]
      <> [inventoryError "reserved-namespace-contribution" "shared platform and Kubernetes system namespaces cannot be requested by a contributor" & #scopes .~ [s, c ^. #owner]
         | (s, c, namespaceName) <- namespaceRequests, nameText namespaceName `elem`
           ["default", "kube-system", "kube-public", "kube-node-lease", "cert-manager", "knative-serving", "kourier-system", "nagare-system", "personal"]]
      <> [inventoryError "unauthorized-contribution" "backend contribution lacks an application scope and owner grant" & #scopes .~ [s, c ^. #owner]
         | (s, c, _, _, _) <- backendRequests, not (backendAuthorized s c)]
      <> [inventoryError "invalid-backend-upstream" "backend upstream must be an HTTP(S) origin" & #scopes .~ [s, c ^. #owner]
         | (s, c, _, upstreamText, _) <- backendRequests, not ("http://" `Data.Text.isPrefixOf` upstreamText
           || "https://" `Data.Text.isPrefixOf` upstreamText)]
      <> [inventoryError "conflicting-backend" "public host has multiple backend contributions" & #scopes .~ [s | (s, _, _, _, _) <- entries]
         | (_, groupEntries) <- Map.toList backendGroups
         , entries <- Map.elems (Map.fromListWith (<>) [(hostName, [entry]) | entry@(_, _, hostName, _, _) <- groupEntries])
         , length entries > 1]
      <> [inventoryError "multiple-portals" "backend map has more than one portal" & #scopes .~ [s | (s, _, _, _, _) <- portals]
         | (_, entries) <- Map.toList backendGroups
         , let portals = [entry | entry@(_, _, _, _, backendRole) <- entries, backendRole == PortalBackend]
         , length portals > 1]
      <> [inventoryError "duplicate-backend-owner" "backend map owner has duplicate grants" & #scopes .~ [owner]
         | (owner, _) <- duplicates backendOwners]
      <> [inventoryError "invalid-backend-owner" "only the platform auth scope can own the shared backend map" & #scopes .~ [owner]
         | (owner, _) <- backendOwners, scopeKind owner /= Platform || scopeIdText owner /= "platform:auth"]
      <> [inventoryError "invalid-shomei-owner" "Shomei settings require the platform auth backend grant" & #scopes .~ [owner]
         | (owner, clusterId, _) <- shomeiOwners, scopeKind owner /= Platform
           || scopeIdText owner /= "platform:auth" || (owner, clusterId) `notElem` backendOwners]
      <> [inventoryError "duplicate-shomei-owner" "Shomei settings owner has duplicate grants" & #scopes .~ [owner]
         | (owner, _) <- duplicates [(owner, clusterId) | (owner, clusterId, _) <- shomeiOwners]]
    namespaces =
      [ Managed
          ( ManagedResource
              (namespaceContributionId c)
              (c ^. #owner)
              KubernetesExecutor
              (Kubernetes (c ^. #cluster) "" (known "namespace") Nothing namespaceName)
              []
              (NamespaceSpec Nothing)
              Retain
              Stateless
              Public
              []
              []
              (SourceLocation "contribution" (scopeIdText (c ^. #owner)))
          )
      | ((_, _, namespaceName), (_, c) :| _) <- Map.toAscList grouped
      ]
    backendMaps =
      [ Managed
          (ManagedResource
            (backendMapResourceId owner)
            owner KubernetesExecutor
            (Kubernetes clusterId "" (known "configmap") (Just (known "nagare-system")) (known "nagare-access-backends"))
            []
            (BackendMapSpec (sortOn (nameText . first3) [(hostName, upstreamText, backendRole)
              | (_, _, hostName, upstreamText, backendRole) <- Map.findWithDefault [] (owner, clusterId) backendGroups]))
            Retain Stateless Private [] [] (SourceLocation "contribution" (scopeIdText owner)))
      | (owner, clusterId) <- backendOwners
      ]
    shomeiSettings =
      [ Managed
          (ManagedResource
            (shomeiSettingsResourceId owner)
            owner KubernetesExecutor
            (Kubernetes clusterId "" (known "configmap") (Just (known "nagare-system")) (known "nagare-shomei-settings"))
            []
            (ShomeiSettingsSpec baseDomain (case [hostName
              | (_, _, hostName, _, PortalBackend) <- Map.findWithDefault [] (owner, clusterId) backendGroups] of
                [portal] -> Just portal
                _ -> Nothing))
            Retain Stateless Private [] [] (SourceLocation "contribution" (scopeIdText owner)))
      | (owner, clusterId, baseDomain) <- shomeiOwners
      ]
    first3 (value, _, _) = value

namespaceContributionId :: Contribution -> ResourceId
namespaceContributionId (RegisterNamespace owner _ namespaceName _) =
  mintResourceId owner
    (either (error . Data.Text.unpack) id (mkLogicalKey (nameText namespaceName)))
    (known "namespace")
namespaceContributionId (RegisterBackend owner _ _ _ _ _) = backendMapResourceId owner

backendMapResourceId :: ScopeId -> ResourceId
backendMapResourceId owner =
  -- Preserve the accepted direct ConfigMap identity while changing its
  -- declaration to owner-composed content. A new ID at the same address would
  -- require a separate reviewed ownership transfer.
  mintResourceId owner (either (error . Data.Text.unpack) id (mkLogicalKey "auth"))
    (known "object-4eecf2a0a71a1cc10010dce9a74e8f6276942e0d")

contributionResourceId :: Contribution -> ResourceId
contributionResourceId c@RegisterNamespace {} = namespaceContributionId c
contributionResourceId c@RegisterBackend {} = backendMapResourceId (c ^. #owner)

shomeiSettingsResourceId :: ScopeId -> ResourceId
shomeiSettingsResourceId owner = mintResourceId owner
  (either (error . Data.Text.unpack) id (mkLogicalKey "auth")) (known "shomei-settings")

validateGraph :: Map ScopeId ScopeDeclaration -> [Declaration] -> Map CanonicalClaim ClaimHolder -> [InventoryError]
validateGraph ss ds reservations =
  [issue "duplicate-id" "duplicate logical identity" [d | d <- ds, declarationId d == r] [] | r <- duplicates (map declarationId ds <> map (^. #identity) ops)]
    <> [issue "claim-conflict" "canonical address claimed by multiple resources" holders [c] | (c, holders) <- Map.toList claims, length holders > 1]
    <> [issue "reserved-claim" "address held by retained, candidate, or unresolved history" [d] [c] & #scopes %~ (s :) & #resources %~ (r :) | (c, ClaimHolder s r _ _) <- Map.toList reservations, d <- Map.findWithDefault [] c claims, declarationId d /= r]
    <> concatMap validateDeclaration ds
    <> [issue "dangling-reference" "dependency producer is absent" [d] [] & #resources %~ (p :)
       | d <- ds, p <- map dependencyProducer (declarationDependencies d), Map.notMember p byId && Set.notMember p operationIds]
    <> [issue "reference-mismatch" "output capability, constraints, or sensitivity disagree with its export" [d] [] | d <- ds, ref <- dependencyRefs (declarationDependencies d), not (matches ref)]
    <> [issue "output-operation" "cache signing-key consumer has no logical-cache operation" [d] []
       | d <- ds, ref <- dependencyRefs (declarationDependencies d), cacheKeyRef ref
       , Set.notMember (dependencyRefProducer ref) cacheOutputProducers]
    <> [inventoryError "condition-mismatch" "required condition has no compatible exported output" | b <- bundles, ref <- b ^. #conditions, not (matches ref)]
    <> [inventoryError "invalid-export" "export producer must be declared in its exporting scope" & #scopes .~ [s] & #resources .~ [r] | (s, sc) <- Map.toList ss, b <- scopeBundles sc, e <- b ^. #exports, let (r, _, _, _, _) = exportSignature e, r `notElem` map declarationId (scopeDeclarations sc)]
    <> [inventoryError "duplicate-export" "producer and output key exported more than once" | not (null (duplicates [(r, k) | (r, k, _, _, _) <- exports]))]
    <> [inventoryError "incompatible-constraints" "output cannot belong to multiple namespaces or projects" & #resources .~ [r] | (r, _, _, cs, _) <- exports, Set.size (Set.fromList [n | InNamespace n <- cs]) > 1 || Set.size (Set.fromList [n | InProject n <- cs]) > 1]
    <> [issue "condition-kind" "readiness requires a readiness or TLS capability" [d] [] | d <- ds, ReadyAfter ref <- declarationDependencies d, not (isCondition ref)]
    <> [inventoryError "condition-kind" "required condition must have a readiness or TLS capability" | b <- bundles, ref <- b ^. #conditions, not (isCondition ref)]
    <> [inventoryError "dependency-cycle" "resource and operation dependency graph contains a cycle" & #resources .~ cycleIds | CyclicSCC cycleIds <- stronglyConnComp graph]
    <> [issue "unreserved-child" "observed child lacks a reservation from its named parent" [d] [canonicalClaim a] | d@(ObservedChild _ p a _ _) <- ds, not (maybe False (elem (DerivedReservation, canonicalClaim a) . NE.toList . claimsOf) (Map.lookup p byId))]
    <> [inventoryError "operation-reference" "declared operation affects an absent resource or has incompatible inputs" & #resources .~ [op ^. #identity] | op <- ops, any (`Map.notMember` byId) (NE.toList (op ^. #affects)) || any (not . matches) [r | CapabilityInput r <- op ^. #inputs]]
    <> [issue "delegation-controller" "delegation controller is absent" [d] [] | d@(Managed r) <- ds, del <- r ^. #delegations, Map.notMember (del ^. #controller) byId]
  where
    byId = Map.fromList [(declarationId d, d) | d <- ds]
    bundles = concatMap scopeBundles (Map.elems ss)
    ops = concatMap (^. #operations) bundles
    operationIds = Set.fromList (map (^. #identity) ops)
    cacheOutputProducers = Set.fromList
      [resource | operation <- ops, operation ^. #operationKind == CreateLogicalCache, resource <- NE.toList (operation ^. #affects)]
    graph =
      [(declarationId d, declarationId d, map dependencyProducer (declarationDependencies d)) | d <- ds]
        <> [(op ^. #identity, op ^. #identity, NE.toList (op ^. #affects)) | op <- ops]
    exports = map exportSignature (concatMap (^. #exports) bundles)
    matches r = let (p, k, c, cs, s) = refSignature r in any (\(p', k', c', cs', s') -> (p, k, c, s) == (p', k', c', s') && all (`elem` cs') cs) exports
    cacheKeyRef ref = let (_, _, capability, _, _) = refSignature ref in capability == NixCachePublicKey
    dependencyRefProducer (SomeRef ref) = refProducer ref
    isCondition ref = let (_, _, c, _, _) = refSignature ref in c `elem` [ReadinessCondition, TlsReady]
    claims = Map.fromListWith (<>) [(c, [d]) | d@(Managed _) <- ds, (_, c) <- NE.toList (claimsOf d)]
    issue c m involved cs =
      inventoryError c m
        & #scopes
        .~ Set.toAscList
          ( Set.fromList
              ( [s | (s, sc) <- Map.toList ss, any (`elem` scopeDeclarations sc) involved]
                  <> [r ^. #owner | Managed r <- involved]
                  <> [s | (s, sc) <- Map.toList ss, b <- scopeBundles sc, contribution <- b ^. #contributions, contributionResourceId contribution `elem` map declarationId involved]
              )
          )
        & #resources
        .~ map declarationId involved
        & #claims
        .~ cs
        & #sources
        .~ map declarationSource involved

dependencyProducer :: Dependency -> ResourceId
dependencyProducer (OrderedAfter r) = r
dependencyProducer (Consumes (SomeRef r)) = refProducer r
dependencyProducer (ReadyAfter (SomeRef r)) = refProducer r

dependencyRefs :: [Dependency] -> [SomeRef]
dependencyRefs = concatMap (\case Consumes r -> [r]; ReadyAfter r -> [r]; OrderedAfter _ -> [])

duplicates :: (Ord a) => [a] -> [a]
duplicates xs = [x | x : _ : _ <- group (sort xs)]

checked :: [InventoryError] -> a -> Either (NonEmpty InventoryError) a
checked [] a = Right a
checked (e : es) _ = Left (e :| es)
