-- | A reviewed delegation of a bounded part of a context to a named deployer
-- (EP-247, ADR 35). The delegation is its own platform scope,
-- @platform:delegation-NAME@, that owns its namespaces, their quotas and a
-- record ConfigMap in @nagare-system@. The record is also kept in the scope's
-- overrides, so the accepted head alone answers what a deployer may do: the
-- bounds are pure functions of the delegation and a proposal, run when a
-- review is prepared and again at admission against the admitted head.
--
-- The name 'Delegation' is taken by field ownership in
-- "Nagare.Resource.Policy"; user-facing text still says "delegation".
module Nagare.Inventory.DeployerDelegation
  ( DelegationState (..)
  , DelegatedKind (..)
  , DelegationQuota (..)
  , DeployerDelegation (..)
  , defaultQuota
  , delegatedKindText
  , parseDelegatedKind
  , delegationStateText
  , delegationScopeId
  , delegationRecordName
  , delegationRecordKey
  , deployerOverrideKey
  , validateDelegation
  , encodeDelegation
  , decodeDelegation
  , compileDelegationScope
  , acceptedDelegations
  , delegationOfScope
  , acceptedDelegatedNamespace
  , stampDeployerScope
  , DelegationViolation (..)
  , renderViolation
  , renderViolations
  , DelegationCheck (..)
  , checkDelegatedProposal
  , admittedDelegationViolations
  , expectedProtectedMappingDigest
  , hostWithinDelegation
  , allowedKubernetesKinds
  )
where

import Control.Monad (forM_)
import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , Value
  , eitherDecodeStrict'
  , object
  , withObject
  , withText
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Char (isDigit)
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Nagare.Access.Resolve (backendConfigMapNamespace, renderAccessDomainMapping)
import Nagare.Deploy.Host (HostShape (..))
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Actor (validActorName)
import Nagare.Inventory.DelegatedKind (DelegatedKind (..), delegatedKindText, parseDelegatedKind)
import Nagare.Inventory.DeployerAccess (IdentityObject (..), identityObjects)
import Nagare.Inventory.DeployerStoreAccess (StoreAccess, storeObjects)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.ProtectedRoute (enforcerTarget)
import Nagare.Resource.Access (mkTeamKey)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), Sensitivity (Private))
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data DelegationState = DelegationActive | DelegationRevoked
  deriving stock (Eq, Ord, Show, Generic)

-- | One ResourceQuota per namespace. Pods without requests get the
-- LimitRange defaults, so the quota never refuses an unannotated workload.
data DelegationQuota = DelegationQuota
  { cpu :: !Text
  , memory :: !Text
  , pods :: !Int
  }
  deriving stock (Eq, Ord, Show, Generic)

defaultQuota :: DelegationQuota
defaultQuota = DelegationQuota {cpu = "4", memory = "8Gi", pods = 50}

data DeployerDelegation = DeployerDelegation
  { name :: !Text
  -- ^ The deployer's name, as its context's @NAGARE_DEPLOYER@ says.
  , state :: !DelegationState
  , namespaces :: !(NonEmpty Text)
  , hostSuffixes :: ![Text]
  , kinds :: !(NonEmpty DelegatedKind)
  , imageRepository :: !Text
  , team :: !Text
  , buildNamespace :: !(Maybe Text)
  , quota :: !DelegationQuota
  , baseDomain :: !Text
  -- ^ The context's base domain when the delegation was reviewed; hostname
  -- bounds are read from the record, so admission needs no context.
  , hostShape :: !HostShape
  }
  deriving stock (Eq, Show, Generic)

hostShapeText :: HostShape -> Text
hostShapeText = \case
  NestedHosts -> "nested"
  FlatHosts -> "flat"

delegationStateText :: DelegationState -> Text
delegationStateText = \case
  DelegationActive -> "active"
  DelegationRevoked -> "revoked"

delegationScopeId :: Text -> Either Text ScopeId
delegationScopeId deployer = mkScopeId Platform ("delegation-" <> deployer)

delegationRecordName :: Text -> Text
delegationRecordName deployer = "nagare-delegation-" <> deployer

-- | The scope override holding the record's canonical JSON.
delegationRecordKey :: Text
delegationRecordKey = "delegation.record"

-- | The scope override naming the delegation a deployer's scope was last
-- written under. Only a deployer's review sets it; an operator's rewrite drops
-- it, and the scope is then the operator's again.
deployerOverrideKey :: Text
deployerOverrideKey = "delegation.deployer"

-- | Namespaces no delegation may own.
reservedNamespace :: Text -> Bool
reservedNamespace ns = ns `elem` ["personal", "nagare-system", "default"] || "kube-" `T.isPrefixOf` ns

validateDelegation :: DeployerDelegation -> Either Text DeployerDelegation
validateDelegation delegation = do
  unless (validActorName (delegation ^. #name)) (Left "delegation name must be a DNS label (the deployer's NAGARE_DEPLOYER)")
  let owned = NE.toList (delegation ^. #namespaces) <> maybe [] pure (delegation ^. #buildNamespace)
  forM_ owned $ \ns -> do
    unless (validActorName ns) (Left ("namespace " <> ns <> " is not a DNS label"))
    when (reservedNamespace ns) (Left ("namespace " <> ns <> " is reserved and cannot be delegated"))
  unless (length owned == length (nub owned)) (Left "delegated namespaces and the build namespace must be distinct")
  forM_ (delegation ^. #hostSuffixes) $ \suffix ->
    unless
      (not (T.null suffix) && T.all (\c -> c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9'] || c == '-') suffix && T.length suffix <= 62)
      (Left ("host suffix " <> suffix <> " must be part of one DNS label"))
  unless (validImageRepository (delegation ^. #imageRepository)) (Left "image repository must be a registry path without a tag, digest or trailing slash")
  _ <- mkTeamKey (delegation ^. #team)
  let q = delegation ^. #quota
  when (T.null (q ^. #cpu) || T.null (q ^. #memory) || q ^. #pods < 1) (Left "quota needs a cpu, a memory and at least one pod")
  when (T.null (delegation ^. #baseDomain)) (Left "a delegation needs the context's base domain")
  pure
    ( delegation
        & #hostSuffixes
        .~ sort (nub (delegation ^. #hostSuffixes))
        & #kinds
        .~ NE.fromList (sort (nub (NE.toList (delegation ^. #kinds))))
    )

instance ToJSON DelegationQuota where
  toJSON q = object ["cpu" .= (q ^. #cpu), "memory" .= (q ^. #memory), "pods" .= (q ^. #pods)]

instance FromJSON DelegationQuota where
  parseJSON = withObject "DelegationQuota" $ \o -> do
    unless (all (`elem` ["cpu", "memory", "pods"]) (KM.keys o)) (fail "quota has an unknown field")
    DelegationQuota <$> o .: "cpu" <*> o .: "memory" <*> o .: "pods"

instance ToJSON DelegationState where
  toJSON = toJSON . delegationStateText

instance FromJSON DelegationState where
  parseJSON = withText "DelegationState" $ \case
    "active" -> pure DelegationActive
    "revoked" -> pure DelegationRevoked
    _ -> fail "delegation state must be active or revoked"

instance ToJSON DeployerDelegation where
  toJSON d =
    object
      ( [ "version" .= (1 :: Int)
        , "name" .= (d ^. #name)
        , "state" .= (d ^. #state)
        , "namespaces" .= NE.toList (d ^. #namespaces)
        , "hostSuffixes" .= (d ^. #hostSuffixes)
        , "kinds" .= NE.toList (d ^. #kinds)
        , "imageRepository" .= (d ^. #imageRepository)
        , "team" .= (d ^. #team)
        , "quota" .= (d ^. #quota)
        , "baseDomain" .= (d ^. #baseDomain)
        , "hostShape" .= hostShapeText (d ^. #hostShape)
        ]
          <> ["buildNamespace" .= ns | Just ns <- [d ^. #buildNamespace]]
      )

instance FromJSON DeployerDelegation where
  parseJSON = withObject "DeployerDelegation" $ \o -> do
    let allowed = ["version", "name", "state", "namespaces", "hostSuffixes", "kinds", "imageRepository", "team", "quota", "buildNamespace", "baseDomain", "hostShape"]
    unless (all (`elem` allowed) (KM.keys o)) (fail "delegation has an unknown field")
    version <- o .: "version"
    unless (version == (1 :: Int)) (fail "unsupported delegation version")
    namespaces <- o .: "namespaces" >>= maybe (fail "a delegation needs a namespace") pure . NE.nonEmpty
    kinds <- o .: "kinds" >>= maybe (fail "a delegation needs a kind") pure . NE.nonEmpty
    shape <-
      o .: "hostShape" >>= \case
        "nested" -> pure NestedHosts
        "flat" -> pure FlatHosts
        other -> fail ("unknown host shape " <> T.unpack other)
    DeployerDelegation
      <$> o .: "name"
      <*> o .: "state"
      <*> pure namespaces
      <*> o .: "hostSuffixes"
      <*> pure kinds
      <*> o .: "imageRepository"
      <*> o .: "team"
      <*> o .:? "buildNamespace"
      <*> o .: "quota"
      <*> o .: "baseDomain"
      <*> pure shape

encodeDelegation :: DeployerDelegation -> Either Text ByteString
encodeDelegation = canonicalValue . toJSON

decodeDelegation :: ByteString -> Either Text DeployerDelegation
decodeDelegation bytes = do
  delegation <- first T.pack (eitherDecodeStrict' bytes)
  validated <- validateDelegation delegation
  encoded <- encodeDelegation validated
  unless (encoded == bytes) (Left "delegation record is not canonical")
  pure validated

-- | Compile the delegation's scope against the accepted cluster and the
-- foundation's @nagare-system@ Namespace. Every member is 'Retain': revoking
-- or narrowing a delegation never deletes a namespace or what runs in it.
compileDelegationScope ::
  ResourceId ->
  ResourceId ->
  Maybe StoreAccess ->
  DeployerDelegation ->
  Either Text (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compileDelegationScope cluster systemNamespace store candidate = do
  delegation <- validateDelegation candidate
  owner <- delegationScopeId (delegation ^. #name)
  key <- mkLogicalKey "delegation"
  record <- encodeDelegation delegation
  let deployer = delegation ^. #name
      appNamespaces = NE.toList (delegation ^. #namespaces)
      build = delegation ^. #buildNamespace
      roleId role = mintResourceId owner key <$> mkName role
  namespaceMembers <- fmap concat . traverse' (map (,True) appNamespaces <> map (,False) (maybe [] pure build)) $ \(ns, app) -> do
    namespaceId <- roleId ("namespace-" <> ns)
    namespaceMember <- bind owner namespaceId (namespaceObject deployer ns app) []
    quotaMember <- roleId ("quota-" <> ns) >>= \i -> bind owner i (quotaObject (delegation ^. #quota) ns) [OrderedAfter namespaceId]
    limitsMember <- roleId ("limits-" <> ns) >>= \i -> bind owner i (limitRangeObject ns) [OrderedAfter namespaceId]
    pure [namespaceMember, quotaMember, limitsMember]
  recordId <- roleId "record"
  recordMember <-
    bind
      owner
      recordId
      ( object
          [ "apiVersion" .= ("v1" :: Text)
          , "kind" .= ("ConfigMap" :: Text)
          , "metadata"
              .= object
                [ "name" .= delegationRecordName deployer
                , "namespace" .= backendConfigMapNamespace
                , "labels" .= object ["app.kubernetes.io/part-of" .= ("nagare" :: Text), "nagare.dev/delegation" .= deployer]
                ]
          , "data" .= object ["delegation.json" .= TE.decodeUtf8 record]
          ]
      )
      [OrderedAfter systemNamespace]
  -- EP-248 D2, D3: the deployer's and builder's identities. A revoked
  -- delegation keeps them with empty rules.
  -- D10: on an object-store context, the deployer's store identity too.
  let active = delegation ^. #state == DelegationActive
  storeMembers <- maybe (Right []) (storeObjects deployer active) store
  let identities = identityObjects deployer active (delegation ^. #kinds) (delegation ^. #namespaces) build <> storeMembers
  identityIds <- Map.fromList <$> traverse' identities (\o -> (o ^. #role,) <$> roleId (o ^. #role))
  identityMembers <- traverse' identities $ \o -> do
    memberId <- maybe (Left "identity member id is missing") Right (Map.lookup (o ^. #role) identityIds)
    namespaceOrder <- case o ^. #namespace of
      Just ns
        | ns == backendConfigMapNamespace -> Right [OrderedAfter systemNamespace]
        | otherwise -> (\i -> [OrderedAfter i]) <$> roleId ("namespace-" <> ns)
      Nothing -> Right []
    bind owner memberId (o ^. #value) (namespaceOrder <> [OrderedAfter i | r <- o ^. #after, Just i <- [Map.lookup r identityIds]])
  let members = namespaceMembers <> [recordMember] <> identityMembers
  scope <-
    first
      (T.pack . show)
      (mkScopeDeclaration owner [ResourceBundle [Managed resource | (resource, _) <- members] [] [] [] [] []])
  pure
    ( withScopeOverrides (Map.singleton delegationRecordKey (TE.decodeUtf8 record)) scope
    , Map.fromList [(resource ^. #identity, (resource, native)) | (resource, native) <- members]
    )
  where
    traverse' xs f = traverse f xs
    bind owner resourceId value dependencies = do
      native <- canonicalValue value
      (resource, bound) <-
        first
          (T.pack . show)
          ( bindKubernetesObject
              KubernetesInput
                { resourceId = resourceId
                , ownerScope = owner
                , clusterId = cluster
                , inputObject = value
                , objectDigest = contentDigest native
                , lifecyclePolicy = Retain
                , inputDataPolicy = Stateless
                , inputSensitivity = Private
                , sourceLocation = SourceLocation "delegation" (resourceIdText resourceId)
                }
          )
      unless (bound == native) (Left "delegation native bytes changed during binding")
      pure (resource {dependencies = dependencies}, bound)

namespaceObject :: Text -> Text -> Bool -> Value
namespaceObject deployer ns app =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("Namespace" :: Text)
    , "metadata"
        .= object
          [ "name" .= ns
          , "labels"
              .= object
                ( ["app.kubernetes.io/part-of" .= ("nagare" :: Text), "nagare.dev/delegation" .= deployer]
                    <> if app
                      then ["nagare.dev/app-namespace" .= ("true" :: Text)]
                      else ["nagare.dev/build-namespace" .= ("true" :: Text)]
                )
          ]
    ]

quotaObject :: DelegationQuota -> Text -> Value
quotaObject q ns =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("ResourceQuota" :: Text)
    , "metadata" .= object ["name" .= ("nagare-delegation" :: Text), "namespace" .= ns]
    , "spec"
        .= object
          [ "hard"
              .= object
                [ "requests.cpu" .= (q ^. #cpu)
                , "requests.memory" .= (q ^. #memory)
                , "pods" .= T.pack (show (q ^. #pods))
                ]
          ]
    ]

limitRangeObject :: Text -> Value
limitRangeObject ns =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "kind" .= ("LimitRange" :: Text)
    , "metadata" .= object ["name" .= ("nagare-delegation" :: Text), "namespace" .= ns]
    , "spec"
        .= object
          [ "limits"
              .= [ object
                     [ "type" .= ("Container" :: Text)
                     , "defaultRequest" .= object ["cpu" .= ("50m" :: Text), "memory" .= ("64Mi" :: Text)]
                     , "default" .= object ["memory" .= ("512Mi" :: Text)]
                     ]
                 ]
          ]
    ]

-- | The delegation a scope's overrides record, if it is a delegation scope.
delegationOfScope :: ScopeDeclaration -> Maybe (Either Text DeployerDelegation)
delegationOfScope scope
  | scopeKind (scopeId scope) /= Platform = Nothing
  | not ("delegation-" `T.isPrefixOf` nameText (scopeName (scopeId scope))) = Nothing
  | otherwise = decodeDelegation . TE.encodeUtf8 <$> Map.lookup delegationRecordKey (scopeOverrides scope)

-- | Every accepted delegation by deployer name. A record that does not decode
-- or does not match its scope is left out, so it delegates nothing.
acceptedDelegations :: Map ScopeId ScopeDeclaration -> Map Text DeployerDelegation
acceptedDelegations scopes =
  Map.fromList
    [ (delegation ^. #name, delegation)
    | scope <- Map.elems scopes
    , Just (Right delegation) <- [delegationOfScope scope]
    , delegationScopeId (delegation ^. #name) == Right (scopeId scope)
    ]

-- | The cluster and Namespace member of a namespace an active accepted
-- delegation owns, for app, worker, task, site and storage commands.
acceptedDelegatedNamespace :: ScopeSnapshot -> Text -> Either Text (ResourceId, ResourceId)
acceptedDelegatedNamespace snapshot requested = do
  let scopes = fmap snd (snapshotScopes snapshot)
      owners =
        [ delegation
        | delegation <- Map.elems (acceptedDelegations scopes)
        , delegation ^. #state == DelegationActive
        , requested `elem` NE.toList (delegation ^. #namespaces)
        ]
  delegation <- case owners of
    [one] -> Right one
    [] -> Left ("namespace " <> requested <> " is neither a platform namespace nor owned by an active delegation")
    _ -> Left ("namespace " <> requested <> " is claimed by more than one delegation")
  owner <- delegationScopeId (delegation ^. #name)
  key <- mkLogicalKey "delegation"
  role <- mkName ("namespace-" <> requested)
  nativeName <- mkName requested
  let namespaceId = mintResourceId owner key role
  scope <- maybe (Left "delegation scope is absent") Right (Map.lookup owner scopes)
  case [ cluster
       | bundle <- scopeBundles scope
       , Managed resource <- bundle ^. #declarations
       , resource ^. #identity == namespaceId
       , Kubernetes cluster "" kind Nothing addressName <- [resource ^. #address]
       , nameText kind == "namespace"
       , addressName == nativeName
       ] of
    [cluster] -> Right (cluster, namespaceId)
    _ -> Left ("delegated Namespace " <> requested <> " does not match its accepted record")

-- | Mark a deployer-written scope with its delegation (bound (g)).
stampDeployerScope :: Text -> ScopeDeclaration -> ScopeDeclaration
stampDeployerScope deployer scope = withScopeOverrides (Map.insert deployerOverrideKey deployer (scopeOverrides scope)) scope

data DelegationViolation = DelegationViolation
  { code :: !Text
  -- ^ @delegation-revoked@ or @delegation-bounds@.
  , delegation :: !Text
  , bound :: !Text
  , member :: !Text
  , detail :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

renderViolation :: DelegationViolation -> Text
renderViolation v =
  (v ^. #code)
    <> ": delegation "
    <> (v ^. #delegation)
    <> " refuses "
    <> (v ^. #member)
    <> " ("
    <> (v ^. #bound)
    <> "): "
    <> (v ^. #detail)

renderViolations :: NonEmpty DelegationViolation -> Text
renderViolations = T.intercalate "\n" . map renderViolation . NE.toList

-- | What a deployer's proposal changes, and what the head it is checked
-- against holds.
data DelegationCheck = DelegationCheck
  { deployer :: !Text
  , delegations :: !(Map Text DeployerDelegation)
  , replaced :: ![ScopeDeclaration]
  -- ^ The desired declarations of the scopes the proposal writes.
  , retired :: ![ScopeId]
  , collected :: ![ResourceId]
  , accepted :: !(Map ScopeId ScopeDeclaration)
  }
  deriving stock (Generic)

-- | The bounds of D4: scope kind, namespace, hostname, access, member kind,
-- image repository and scope ownership. Every violation is returned.
checkDelegatedProposal :: DelegationCheck -> Either (NonEmpty DelegationViolation) ()
checkDelegatedProposal check = case Map.lookup deployer (check ^. #delegations) of
  Nothing -> refuse [violation "delegation-revoked" deployer "delegation" deployer "no accepted delegation names this deployer"]
  Just d
    | d ^. #state == DelegationRevoked -> refuse [violation "delegation-revoked" deployer "delegation" deployer "the delegation is revoked"]
    | otherwise ->
        refuse
          ( concatMap (replacedViolations d) (check ^. #replaced)
              <> concatMap retiredViolations (check ^. #retired)
              <> [bounds "member-kind" (resourceIdText resource) "collecting retained data is not delegated" | resource <- check ^. #collected]
          )
  where
    deployer = check ^. #deployer
    refuse = maybe (Right ()) Left . NE.nonEmpty
    violation = DelegationViolation
    bounds = violation "delegation-bounds" deployer
    ownedByDeployer scope = Map.lookup deployerOverrideKey (scopeOverrides scope) == Just deployer
    retiredViolations owner = case Map.lookup owner (check ^. #accepted) of
      Just prior | ownedByDeployer prior -> []
      _ -> [bounds "ownership" (scopeIdText owner) "the scope was not written by this deployer"]
    replacedViolations d scope =
      let owner = scopeId scope
          scopeText = scopeIdText owner
          ownership = case Map.lookup owner (check ^. #accepted) of
            Just prior | not (ownedByDeployer prior) -> [bounds "ownership" scopeText "the scope was written by another actor"]
            _ -> []
          stamp = [bounds "ownership" scopeText "the scope does not record this deployer" | not (ownedByDeployer scope)]
          classified = scopeClass owner
          kindErrors = case classified of
            Nothing -> [bounds "scope-kind" scopeText "a deployer may write only application, worker, task, site and app image scopes"]
            Just ScopeImage -> []
            Just (ScopeWorkload allowedBy)
              | any (`elem` NE.toList (d ^. #kinds)) allowedBy -> []
              | otherwise -> [bounds "scope-kind" scopeText "the delegation does not allow this kind"]
          bundles = scopeBundles scope
          members = [resource | bundle <- bundles, Managed resource <- bundle ^. #declarations]
          contributions = concatMap (^. #contributions) bundles
          protectedHosts = [(nameText host, upstream) | RegisterBackend _ _ host upstream role _ <- contributions, role /= PortalBackend]
          preview = "site-preview-" `T.isPrefixOf` nameText (scopeName owner)
       in ownership
            <> stamp
            <> kindErrors
            <> concatMap (memberViolations d preview protectedHosts) members
            <> concatMap (contributionViolations d preview) contributions
            <> [bounds "member-kind" scopeText "a deployer scope cannot grant contributions" | bundle <- bundles, not (null (bundle ^. #grants))]
            <> [ bounds "access" (resourceIdText (resource ^. #identity)) "a public Knative Service; every delegated host requires access = requireLogin"
               | resource <- members
               , Kubernetes _ "serving.knative.dev" kind (Just ns) svc <- [resource ^. #address]
               , nameText kind == "service"
               , upstreamOf (nameText ns) (nameText svc) `notElem` map snd protectedHosts
               ]
    delegated d ns = ns `elem` NE.toList (d ^. #namespaces)
    memberViolations d preview protectedHosts resource =
      let memberText = resourceIdText (resource ^. #identity)
       in case (resource ^. #executor, resource ^. #address) of
            (KubernetesExecutor, Kubernetes _ group kind mns objectName) ->
              let kindText = nameText kind
                  nsText = maybe "" nameText mns
                  host = nameText objectName
               in if kindText == "domainmapping"
                    then
                      if nsText == backendConfigMapNamespace
                        then
                          [ bounds "hostname" memberText ("hostname " <> host <> " is outside the delegation")
                          | not (hostWithinDelegation d (d ^. #hostShape) (d ^. #baseDomain) preview host)
                          ]
                            <> [ bounds "namespace" memberText "a route in nagare-system must be the generated protected route for one of this scope's hosts, targeting the access enforcer"
                               | host `notElem` map fst protectedHosts
                                   || nativeDigest resource /= either (const Nothing) Just (expectedProtectedMappingDigest host)
                               ]
                        else [bounds "member-kind" memberText "public routes are not delegated; protected hosts are routed by the access enforcer"]
                    else
                      [ bounds "member-kind" memberText ("Kubernetes " <> kindText <> " is not delegated")
                      | (group, kindText) `notElem` allowedKubernetesKinds
                      ]
                        <> [ bounds "namespace" memberText ("namespace " <> (if T.null nsText then "(cluster)" else nsText) <> " is outside the delegation")
                           | not (delegated d nsText)
                           ]
            (ArtifactExecutor, _) -> case resource ^. #spec of
              ArtifactPublication kind destination _ _
                | nameText kind /= "oci-image" -> [bounds "member-kind" memberText "only OCI images may be published"]
                | not (withinRepository (d ^. #imageRepository) destination) ->
                    [bounds "image-repository" memberText ("image " <> destination <> " is outside " <> (d ^. #imageRepository))]
                | otherwise -> []
              _ -> [bounds "member-kind" memberText "artifact without a publication"]
            (executor, _) -> [bounds "member-kind" memberText (T.pack (show executor) <> " members are not delegated")]
    contributionViolations d preview = \case
      RegisterNamespace {namespace = ns} -> [bounds "member-kind" (nameText ns) "namespace requests are not delegated"]
      RegisterCloudflareCache {route = r} -> [bounds "member-kind" (resourceIdText r) "CDN resources are not delegated"]
      RegisterBackend {host = h, upstream = u, role = r} ->
        [ bounds "hostname" (nameText h) ("hostname " <> nameText h <> " is outside the delegation")
        | not (hostWithinDelegation d (d ^. #hostShape) (d ^. #baseDomain) preview (nameText h))
        ]
          <> [bounds "access" (nameText h) "the auth portal is not delegated" | r == PortalBackend]
          <> [ bounds "namespace" (nameText h) ("upstream " <> u <> " is outside the delegation")
             | not (any (\ns -> (".svc.cluster.local" `T.isSuffixOf` u) && (("." <> ns <> ".svc.cluster.local") `T.isSuffixOf` u)) (NE.toList (d ^. #namespaces)))
             ]
    nativeDigest resource = case resource ^. #spec of
      NativeObject digest -> Just digest
      _ -> Nothing

data ScopeClass = ScopeImage | ScopeWorkload ![DelegatedKind]

scopeClass :: ScopeId -> Maybe ScopeClass
scopeClass owner = case scopeKind owner of
  Application -> Just (ScopeWorkload [DelegatedWebApp])
  Publication | "app-image-" `T.isPrefixOf` n -> Just ScopeImage
  Standalone
    | "worker-" `T.isPrefixOf` n -> Just (ScopeWorkload [DelegatedWorker])
    | "task-run-" `T.isPrefixOf` n -> Just (ScopeWorkload [DelegatedTask])
    | "app-hook-" `T.isPrefixOf` n -> Just (ScopeWorkload [DelegatedWebApp])
    | "site-" `T.isPrefixOf` n -> Just (ScopeWorkload [DelegatedStaticSite, DelegatedServerSite])
  _ -> Nothing
  where
    n = nameText (scopeName owner)

-- | Kubernetes kinds a delegated workload renders: services, deployments,
-- configuration, credentials, jobs and their isolation. Volumes, databases,
-- namespaces, RBAC and certificates are never delegated.
allowedKubernetesKinds :: [(Text, Text)]
allowedKubernetesKinds =
  [ ("serving.knative.dev", "service")
  , ("", "service")
  , ("apps", "deployment")
  , ("", "configmap")
  , ("", "secret")
  , ("", "serviceaccount")
  , ("batch", "cronjob")
  , ("batch", "job")
  , ("networking.k8s.io", "networkpolicy")
  ]

upstreamOf :: Text -> Text -> Text
upstreamOf ns svc = "http://" <> svc <> "." <> ns <> ".svc.cluster.local"

-- | @HOST[:PORT]/PATH@: a registry host, which may carry a port (a local
-- registry does), then a path with no tag, digest, space or trailing slash.
validImageRepository :: Text -> Bool
validImageRepository repository = case T.breakOn "/" repository of
  (host, path) ->
    not (T.null host)
      && T.length path > 1
      && not (T.any (`elem` ("@ " :: String)) repository)
      && not (T.any (== ':') path)
      && not ("/" `T.isSuffixOf` path)
      && case T.splitOn ":" host of
        [_] -> True
        [name, port] -> not (T.null name) && not (T.null port) && T.all isDigit port
        _ -> False

withinRepository :: Text -> Text -> Bool
withinRepository repository destination = case T.stripPrefix repository destination of
  Just rest -> any (`T.isPrefixOf` rest) ["/", ":", "@"]
  Nothing -> False

-- | A hostname a deployer may serve: the default name of a delegated
-- namespace, one label under the base domain that ends in an allowed suffix,
-- or, for a site preview, the context's preview shape.
hostWithinDelegation :: DeployerDelegation -> HostShape -> Text -> Bool -> Text -> Bool
hostWithinDelegation d shape base preview host = case T.stripSuffix ("." <> base) host of
  Nothing -> False
  Just prefix ->
    let labels = T.splitOn "." prefix
        label = case labels of
          [one] -> Just one
          _ -> Nothing
        nested = case labels of
          [workload, ns] -> validLabel workload && ns `elem` NE.toList (d ^. #namespaces)
          _ -> False
        flat = case label of
          Just one -> any (\ns -> maybe False validLabel (T.stripSuffix ("-" <> ns) one)) (NE.toList (d ^. #namespaces))
          Nothing -> False
        suffixed = case label of
          Just one -> any (\suffix -> suffix `T.isSuffixOf` one && validLabel one) (d ^. #hostSuffixes)
          Nothing -> False
        previewHost =
          preview && case (shape, labels) of
            (NestedHosts, [p, site, "preview"]) -> validLabel p && validLabel site
            (FlatHosts, [one]) -> "-preview" `T.isSuffixOf` one && validLabel one
            _ -> False
        defaultName = case shape of
          NestedHosts -> nested
          FlatHosts -> flat
     in defaultName || suffixed || previewHost
  where
    validLabel l = not (T.null l) && T.length l <= 63 && T.all (\c -> c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9'] || c == '-') l && T.head l /= '-' && T.last l /= '-'

-- | The digest of the generated protected route for a host: a DomainMapping
-- in @nagare-system@ whose ref is the @nagare-access@ enforcer.
expectedProtectedMappingDigest :: Text -> Either Text ContentDigest
expectedProtectedMappingDigest host = do
  value <-
    first
      (T.pack . show)
      ( Yaml.decodeEither'
          ( renderAccessDomainMapping
              backendConfigMapNamespace
              host
              enforcerTarget
          ) ::
          Either Yaml.ParseException Value
      )
  contentDigest <$> canonicalValue value

-- | D5: a deployer's review is checked again at admission against the
-- delegation recorded in the head it admits on, so a revocation or narrowed
-- bounds apply to reviews saved earlier.
admittedDelegationViolations ::
  Text ->
  Map ScopeId ScopeDeclaration ->
  [ScopeDeclaration] ->
  [ScopeId] ->
  [ResourceId] ->
  Either (NonEmpty DelegationViolation) ()
admittedDelegationViolations deployer accepted replacedScopes retiredScopes collectedResources =
  checkDelegatedProposal
    DelegationCheck
      { deployer = deployer
      , delegations = acceptedDelegations accepted
      , replaced = replacedScopes
      , retired = retiredScopes
      , collected = collectedResources
      , accepted = accepted
      }
