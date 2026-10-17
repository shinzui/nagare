-- | Independent reviewed control of one exact en relationship: a direct
-- app-viewer grant, a team membership, or a team's app-viewer grant
-- (MasterPlan 27, EP-187). Each is its own scope, bound to the accepted auth
-- en Service and, for a host grant, to the host's exact protected route.
module Nagare.Inventory.Access
  ( AccessBinding (..)
  , AccessFact (..)
  , AccessPlan (..)
  , AccessOps (..)
  , Relationship (..)
  , relationshipOf
  , teamRelationship
  , teamSchemaDeclarations
  , activeSchemaSupportsTeams
  , acceptedProtectedHost
  , compileAccessScope
  , compileTeamMemberScope
  , compileTeamAccessScope
  , compilePortalSyncScope
  , accessBindings
  , acceptedAccessBindings
  , mkAccessAdapter
  )
where

import Control.Monad (forM, forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (maybeToList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Access.ShomeiUser (ShomeiUser, isShomeiUserId)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Access (TeamKey, teamKeyText)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference (Dependency (OrderedAfter))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

-- | Explicit synchronization rolls both startup readers after the complete
-- settings maps: Shomei reads environment variables and the enforcer loads its
-- backend file once. Accepted images, configuration and physical names stay fixed.
compilePortalSyncScope ::
  ScopeDeclaration ->
  [(ManagedResource, ByteString)] ->
  Text ->
  Either Text (ScopeDeclaration, Map ResourceId (ManagedResource, ByteString))
compilePortalSyncScope scope workloads token = do
  owner <- mkScopeId Platform "auth"
  unless
    (scopeId scope == owner && not (T.null token))
    (Left "portal sync requires the accepted auth owner and a nonempty rollout token")
  let workloadKind resource = case resource ^. #address of
        Kubernetes _ group kind (Just namespace) name
          | nameText namespace == "nagare-system"
          , (group, nameText kind, nameText name)
              `elem` [("apps", "deployment", "shomei"), ("serving.knative.dev", "service", "nagare-access")] ->
              Just (nameText name)
        _ -> Nothing
  unless
    ( Set.fromList (map (workloadKind . fst) workloads) == Set.fromList [Just "shomei", Just "nagare-access"]
        && length workloads == 2
    )
    (Left "portal sync requires exactly the accepted Shomei Deployment and access enforcer Service")
  members <- forM workloads $ \(resource, native) -> do
    unless
      ( resource ^. #owner == owner && case resource ^. #spec of
          NativeObject digest -> digest == contentDigest native
          KnativeService digest -> digest == contentDigest native
          _ -> False
      )
      (Left "portal sync workload bytes differ from accepted auth intent")
    unless
      ( [ accepted
        | bundle <- scopeBundles scope
        , Managed accepted <- bundle ^. #declarations
        , accepted ^. #identity == resource ^. #identity
        ]
          == [resource]
      )
      (Left "portal sync workload differs from its accepted owner scope")
    value <- first (const "invalid accepted portal workload") (eitherDecodeStrict native)
    updated <- updateAt ["spec", "template", "metadata"] (withAnnotations token) value
    bytes <- canonicalValue updated
    let revised =
          resource
            & #spec
            .~ ( case resource ^. #spec of
                   KnativeService _ -> KnativeService (contentDigest bytes)
                   _ -> NativeObject (contentDigest bytes)
               )
            & #dependencies
            .~ Set.toAscList
              ( Set.fromList
                  (resource ^. #dependencies <> [OrderedAfter (backendMapResourceId owner), OrderedAfter (shomeiSettingsResourceId owner)])
              )
    pure (revised ^. #identity, (revised, bytes))
  let rollout = Map.fromList members
      replace (Managed resource) = case Map.lookup (resource ^. #identity) rollout of
        Just (revised, _) -> Managed revised
        Nothing -> Managed resource
      replace declaration = declaration
  complete <-
    first
      (T.pack . show)
      (mkScopeDeclaration owner [bundle & #declarations %~ map replace | bundle <- scopeBundles scope])
  pure (complete, rollout)
  where
    withAnnotations stamp (Object metadata) = do
      annotations <- case KM.lookup "annotations" metadata of
        Nothing -> Right KM.empty
        Just (Object values) -> Right values
        _ -> Left "portal workload Pod template annotations are malformed"
      pure
        ( Object
            ( KM.insert
                "annotations"
                (Object (KM.insert "nagare.dev/portal-sync" (String stamp) annotations))
                metadata
            )
        )
    withAnnotations _ _ = Left "portal workload Pod template metadata is malformed"
    updateAt [] change value = change value
    updateAt (field : remaining) change (Object fields) = do
      value <- maybe (Left "portal workload lacks its accepted Pod template") Right (KM.lookup field fields)
      updated <- updateAt remaining change value
      pure (Object (KM.insert field updated fields))
    updateAt _ _ _ = Left "portal workload Pod template is malformed"

-- | The one relationship a reviewed access scope controls.
data Relationship
  = -- | @app:<host>#viewer@user:<id>@
    DirectViewer !Name !Text
  | -- | @group:<team>#member@user:<id>@
    TeamMember !TeamKey !Text
  | -- | @app:<host>#viewer@group:<team>#member@
    TeamViewer !Name !TeamKey
  deriving stock (Eq, Show)

-- | The auth en Service and the relationship a typed address names.
relationshipOf :: ProviderAddress -> Maybe (ResourceId, Relationship)
relationshipOf = \case
  AccessTuple auth host subject -> Just (auth, DirectViewer host subject)
  TeamMemberTuple auth team subject -> Just (auth, TeamMember team subject)
  TeamAccessTuple auth host team -> Just (auth, TeamViewer host team)
  _ -> Nothing

-- | Whether a binding relies on the group schema (EP-187) rather than the
-- original direct-user model.
teamRelationship :: AccessBinding -> Bool
teamRelationship binding = case relationshipOf (accessResource binding ^. #address) of
  Just (_, DirectViewer _ _) -> False
  Just _ -> True
  Nothing -> False

-- | The en schema declarations team relationships rely on, exactly as the
-- reviewed bootstrap ConfigMap (@cluster/bootstrap/en/configmap.yaml@) states
-- them, with layout collapsed to single spaces.
teamSchemaDeclarations :: [Text]
teamSchemaDeclarations =
  [ "object group { relation member: user }"
  , "object app { relation viewer: user, group#member permission access = viewer }"
  ]

-- | Whether an active schema source (@GET /v1/schema@) declares those
-- relations and that permission. Layout is ignored; the relation subject
-- types and the permission rewrite are compared exactly, so a schema that
-- names the relations but changes what they mean is not accepted.
activeSchemaSupportsTeams :: Text -> Bool
activeSchemaSupportsTeams source = all (`T.isInfixOf` normalized) teamSchemaDeclarations
  where
    normalized = T.unwords (T.words source)

-- These dependencies come from the composed owner declarations, not live lists.
-- A team membership has no route: it depends on the auth en Service alone.
data AccessBinding = AccessBinding
  { accessResource :: !ManagedResource
  , accessAuth :: !ManagedResource
  , accessRoute :: !(Maybe ManagedResource)
  }
  deriving stock (Eq, Show)

data AccessFact = AccessFact
  { accessPhysical :: !PhysicalIdentity
  , accessPresent :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AccessPlan = AccessPlan
  { accessPlanVersion :: !Int
  , accessOperation :: !OperationId
  , accessAction :: !OperationAction
  , accessInputDigest :: !ContentDigest
  , accessTarget :: !ResourceId
  , accessBefore :: !AccessFact
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data AccessOps = AccessOps
  { accessInspect :: !(AccessBinding -> IO (Either Text AccessFact))
  , accessWrite :: !(AccessBinding -> AccessFact -> IO AdapterExecution)
  }

-- | The en a grant is written through is the context's en Service, reached
-- through a private port-forward at run time. Older grants recorded the local
-- address used then; that record no longer selects a transport (F97).
enServiceEndpoint :: Text
enServiceEndpoint = "http://en.nagare-system.svc.cluster.local"

-- | A direct viewer grant for one user on one protected host.
compileAccessScope :: ScopeSnapshot -> Text -> ShomeiUser -> Bool -> Either Text ScopeDeclaration
compileAccessScope snapshot rawHost user granted = do
  let subject = user ^. #userId
  host <- hostName rawHost
  unless (isShomeiUserId subject) (Left "access subject must be a Shomei user id (user_…)")
  declarations <- composedDeclarationsOf snapshot
  (auth, route) <- protectedOwner declarations host
  compileRelationship
    snapshot
    auth
    (Just route)
    "access"
    "viewer"
    (AccessTuple (auth ^. #identity) host subject)
    (fromMaybe "viewer" (user ^. #email))
    granted
    [resourceIdText (auth ^. #identity), nameText host, subject]

-- | One user's membership in one team. A team first exists through its first
-- accepted membership; nothing else creates it.
compileTeamMemberScope :: ScopeSnapshot -> TeamKey -> ShomeiUser -> Bool -> Either Text ScopeDeclaration
compileTeamMemberScope snapshot team user present = do
  let subject = user ^. #userId
  unless (isShomeiUserId subject) (Left "team member must be a Shomei user id (user_…)")
  declarations <- composedDeclarationsOf snapshot
  auth <- authService declarations
  compileRelationship
    snapshot
    auth
    Nothing
    "access-member"
    "member"
    (TeamMemberTuple (auth ^. #identity) team subject)
    (fromMaybe "member" (user ^. #email))
    present
    ["team-member", resourceIdText (auth ^. #identity), teamKeyText team, subject]

-- | One team's viewer grant on one protected host. The team must have
-- accepted membership history in this context, even if every member has
-- since been removed, so a grant never names a team nobody reviewed.
compileTeamAccessScope :: ScopeSnapshot -> Text -> TeamKey -> Bool -> Either Text ScopeDeclaration
compileTeamAccessScope snapshot rawHost team present = do
  host <- hostName rawHost
  declarations <- composedDeclarationsOf snapshot
  (auth, route) <- protectedOwner declarations host
  unless
    (teamKnown declarations (auth ^. #identity) team)
    (Left ("team " <> teamKeyText team <> " has no accepted membership in this context; add a member first"))
  compileRelationship
    snapshot
    auth
    (Just route)
    "access-team"
    "viewer"
    (TeamAccessTuple (auth ^. #identity) host team)
    "viewer"
    present
    ["team-access", resourceIdText (auth ^. #identity), nameText host, teamKeyText team]

-- | A hostname this context protects: normalized, with an accepted
-- protected backend contribution and enforcer route. A public or foreign
-- host has no effective-access answer worth asking en for.
acceptedProtectedHost :: ScopeSnapshot -> Text -> Either Text Name
acceptedProtectedHost snapshot rawHost = do
  host <- hostName rawHost
  declarations <- composedDeclarationsOf snapshot
  _ <- protectedOwner declarations host
  pure host

hostName :: Text -> Either Text Name
hostName rawHost = mkName (T.toLower (T.dropWhileEnd (== '.') (T.strip rawHost)))

composedDeclarationsOf :: ScopeSnapshot -> Either Text [Declaration]
composedDeclarationsOf snapshot = inventoryDeclarations <$> first (T.pack . show) (composeSnapshot snapshot)

teamKnown :: [Declaration] -> ResourceId -> TeamKey -> Bool
teamKnown declarations auth team =
  or
    [ True
    | Managed resource <- declarations
    , TeamMemberTuple owner known _ <- [resource ^. #address]
    , owner == auth
    , known == team
    ]

compileRelationship ::
  ScopeSnapshot ->
  ManagedResource ->
  Maybe ManagedResource ->
  Text ->
  Text ->
  ProviderAddress ->
  Text ->
  Bool ->
  [Text] ->
  Either Text ScopeDeclaration
compileRelationship snapshot auth route prefix logical address label present digestInput = do
  let key = T.take 40 (digestText (contentDigest (TE.encodeUtf8 (T.intercalate "\n" digestInput))))
  owner <- mkScopeId Standalone (prefix <> "-" <> key)
  logicalKey <- mkLogicalKey logical
  role <- mkName "grant"
  validated <- mkProviderAddress address
  let resource =
        ManagedResource
          (mintResourceId owner logicalKey role)
          owner
          AccessExecutor
          validated
          []
          (AccessGrantSpec enServiceEndpoint present)
          Retain
          Stateless
          Private
          (Set.toAscList (Set.fromList (OrderedAfter (auth ^. #identity) : [OrderedAfter (r ^. #identity) | r <- maybeToList route])))
          []
          -- The review names the email the operator gave alongside the id.
          (SourceLocation "access" label)
  forM_ (Map.lookup owner (snapshotScopes snapshot)) $ \(_, prior) ->
    forM_ [old | bundle <- scopeBundles prior, Managed old <- bundle ^. #declarations] $ \old ->
      unless
        (old ^. #identity == resource ^. #identity && old ^. #address == resource ^. #address)
        (Left "accepted access tuple identity changed")
  first
    (T.pack . show)
    ( mkScopeDeclaration
        owner
        [ResourceBundle [Managed resource] [] [] [] [] []]
    )

authService :: [Declaration] -> Either Text ManagedResource
authService declarations = do
  authOwner <- mkScopeId Platform "auth"
  one
    "access requires one accepted platform auth en Service"
    [ r
    | Managed r <- declarations
    , r ^. #owner == authOwner
    , Kubernetes _ "" kind (Just ns) name <- [r ^. #address]
    , nameText kind == "service"
    , nameText ns == "nagare-system"
    , nameText name == "en"
    , NativeObject {} <- [r ^. #spec]
    ]

protectedOwner :: [Declaration] -> Name -> Either Text (ManagedResource, ManagedResource)
protectedOwner declarations host = do
  authOwner <- mkScopeId Platform "auth"
  auth <- authService declarations
  cluster <- case auth ^. #address of Kubernetes c _ _ _ _ -> Right c; _ -> Left "invalid auth service"
  let protected =
        [ ()
        | Managed r <- declarations
        , r ^. #owner == authOwner
        , BackendMapSpec entries <- [r ^. #spec]
        , (h, _, role) <- entries
        , h == host
        , role /= PortalBackend
        ]
  unless
    (length protected == 1)
    (Left "hostname has no unique accepted protected backend contribution")
  route <-
    one
      "hostname has no unique accepted protected DomainMapping"
      [ r
      | Managed r <- declarations
      , Hostname host `elem` (r ^. #aliases)
      , Kubernetes c "serving.knative.dev" kind _ name <- [r ^. #address]
      , c == cluster
      , nameText kind == "domainmapping"
      , name == host
      , OrderedAfter (backendMapResourceId authOwner) `elem` (r ^. #dependencies)
      ]
  pure (auth, route)

one :: Text -> [a] -> Either Text a
one _ [single] = Right single
one reason _ = Left reason

accessBindings :: [Declaration] -> Either Text (Map ResourceId AccessBinding)
accessBindings declarations = Map.fromList <$> traverse bind resources
  where
    resources =
      Map.elems
        ( Map.fromList
            [ (r ^. #identity, r)
            | Managed r <- declarations
            , r ^. #executor == AccessExecutor
            ]
        )
    bind resource = do
      (authId, relationship) <- case (relationshipOf (resource ^. #address), resource ^. #spec) of
        (Just pair, AccessGrantSpec endpoint _) | validAccessEndpoint endpoint -> Right pair
        _ -> Left "invalid typed access tuple declaration"
      (auth, route) <- case relationship of
        DirectViewer host _ -> fmap Just <$> protectedOwner declarations host
        TeamViewer host _ -> fmap Just <$> protectedOwner declarations host
        TeamMember _ _ -> (,Nothing) <$> authService declarations
      unless
        ( authId == auth ^. #identity
            && Set.fromList (resource ^. #dependencies)
              == Set.fromList (OrderedAfter authId : [OrderedAfter (r ^. #identity) | r <- maybeToList route])
            && resource ^. #lifecycle == Retain
            && resource ^. #dataPolicy == Stateless
        )
        (Left "access tuple differs from its auth owner or protected route")
      pure (resource ^. #identity, AccessBinding resource auth route)

-- | The accepted access tuples, each bound on its own against the accepted
-- non-access declarations, so a review that retires one can still observe it
-- and retire it (c3i teardown on 3ae20f8c). A tuple whose auth owner or
-- protected route is no longer accepted stays unbound and unobservable.
acceptedAccessBindings :: [Declaration] -> Map ResourceId AccessBinding
acceptedAccessBindings declarations =
  Map.fromList
    [ pair
    | Managed resource <- declarations
    , resource ^. #executor == AccessExecutor
    , Right bound <- [accessBindings (Managed resource : others)]
    , pair <- Map.toList bound
    ]
  where
    others = [declaration | declaration@(Managed other) <- declarations, other ^. #executor /= AccessExecutor] <> [declaration | declaration@(External {}) <- declarations]

mkAccessAdapter :: Map ResourceId ManagedResource -> Map ResourceId AccessBinding -> AccessOps -> Adapter
mkAccessAdapter accepted bindings ops =
  Adapter
    { adapterExecutor = AccessExecutor
    , adapterIdentity = "reviewed-en-direct-viewer"
    , adapterVersion = "1"
    , adapterObserve = \ids -> do
        results <- traverse observe ids
        pure (sequence results >>= observationSet)
    , adapterPrepare = \operation -> case selected operation of
        Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
        Right binding -> do
          observed <- accessInspect ops binding
          pure $ do
            fact <- first (PrepareRefused (plannedOperationId operation)) observed
            first (PrepareRefused (plannedOperationId operation)) (checkAction operation binding fact)
            let plan =
                  AccessPlan
                    1
                    (plannedOperationId operation)
                    (plannedAction operation)
                    (plannedInputDigest operation)
                    (accessResource binding ^. #identity)
                    fact
            bytes <- first (PrepareRefused (plannedOperationId operation)) (canonicalValue (toJSON plan))
            pure (PreparedNative bytes (summary binding))
    , adapterPreflight = \operation prepared -> withPlan operation prepared $ \binding plan -> do
        fact <- accessInspect ops binding
        pure $ do
          current <- fact
          unless (current == accessBefore plan) (Left "reviewed access tuple or owner changed")
    , adapterExecute = \operation prepared -> do
        result <- withPlan operation prepared $ \binding plan -> do
          fact <- accessInspect ops binding
          case fact of
            Left reason -> pure (Right (AdapterEffectFailed (KnownNoEffect reason)))
            Right current
              | current /= accessBefore plan ->
                  pure (Right (AdapterEffectFailed (KnownNoEffect "reviewed access tuple or owner changed")))
            Right current | accessPresent current == wanted binding -> pure (Right AdapterEffectCompleted)
            Right current -> Right <$> accessWrite ops binding current
        pure (either (AdapterEffectFailed . KnownNoEffect) id result)
    , adapterVerify = \operation prepared -> withPlan operation prepared $ \binding plan -> do
        fact <- accessInspect ops binding
        pure (fact >>= completion binding plan)
    , adapterSettle = Nothing
    , adapterRecover = \operation prepared -> do
        result <- withPlan operation prepared $ \binding plan -> do
          fact <- accessInspect ops binding
          pure (fact >>= completion binding plan)
        pure (either RecoveryUnresolved RecoveryProvedComplete result)
    }
  where
    wanted binding = case accessResource binding ^. #spec of AccessGrantSpec _ granted -> granted; _ -> False
    selected operation = do
      resource <- case NE.toList (plannedResources operation) of
        [single] -> Right single
        _ -> Left "access operation must select exactly one tuple"
      unless
        ( plannedExecutor operation == AccessExecutor
            && plannedAction operation `elem` [CreateResource, UpdateResource, VerifyResource]
        )
        (Left "access retirement, adoption, and arbitrary operations are not admitted")
      maybe (Left "access operation has no reviewed declaration") Right (Map.lookup resource bindings)
    observe resource = case Map.lookup resource bindings of
      Nothing -> pure (Left "access resource is not declared")
      Just binding -> do
        fact <- accessInspect ops binding
        pure $
          Right
            ( resource
            , case fact of
                Left reason -> ObservationUnavailable reason
                Right current
                  | Map.notMember resource accepted && accessPresent current -> ObservedUnowned (accessPhysical current)
                  | Map.notMember resource accepted -> ConfirmedAbsent (contentDigest "access:absent")
                  | accessPresent current == wanted binding -> ObservedPresent (accessPhysical current)
                  | otherwise ->
                      ObservedDrifted
                        (accessPhysical current)
                        (contentDigest (if accessPresent current then "access:granted" else "access:revoked"))
            )
    checkAction operation binding fact = case plannedAction operation of
      CreateResource -> unless (not (accessPresent fact)) (Left "foreign existing grant requires explicit adoption")
      VerifyResource -> unless (accessPresent fact == wanted binding) (Left "access tuple does not match desired state")
      UpdateResource -> unless (Map.member (accessResource binding ^. #identity) accepted) (Left "access update has no accepted owner")
      _ -> Left "unsupported access action"
    withPlan :: PlannedOperation -> PreparedNative -> (AccessBinding -> AccessPlan -> IO (Either Text a)) -> IO (Either Text a)
    withPlan operation prepared action = case decode operation (preparedNativeBytes prepared) of
      Left reason -> pure (Left reason)
      Right (binding, plan) -> action binding plan
    decode operation bytes = do
      binding <- selected operation
      plan <- first (const "invalid private access plan") (eitherDecodeStrict bytes)
      unless
        ( accessPlanVersion plan == 1
            && accessOperation plan == plannedOperationId operation
            && accessAction plan == plannedAction operation
            && accessInputDigest plan == plannedInputDigest operation
            && accessTarget plan == accessResource binding ^. #identity
        )
        (Left "access native plan differs from the reviewed operation")
      checkAction operation binding (accessBefore plan)
      pure (binding, plan)
    completion binding plan fact = do
      unless
        ( accessPhysical fact == accessPhysical (accessBefore plan)
            && accessPresent fact == wanted binding
        )
        (Left "exact reviewed access tuple completion cannot be proved")
      canonical <- canonicalValue (object ["plan" .= plan, "observed" .= fact])
      pure (contentDigest canonical)
    summary binding = case relationshipOf (accessResource binding ^. #address) of
      Just (_, DirectViewer host subject) ->
        verb binding <> subject <> emailNote (accessResource binding ^. #source) <> " viewer on " <> nameText host
      Just (_, TeamMember team subject) ->
        (if wanted binding then "add " else "remove ")
          <> subject
          <> emailNote (accessResource binding ^. #source)
          <> (if wanted binding then " to team " else " from team ")
          <> teamKeyText team
      Just (_, TeamViewer host team) ->
        verb binding <> "team " <> teamKeyText team <> " viewer on " <> nameText host
      Nothing -> "invalid access tuple"
    verb binding = if wanted binding then "grant " else "revoke "
    emailNote = \case
      SourceLocation "access" label | T.any (== '@') label -> " (" <> label <> ")"
      _ -> ""
