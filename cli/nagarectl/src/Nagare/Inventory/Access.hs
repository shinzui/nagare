-- | Independent reviewed control of one direct app-viewer relationship.
module Nagare.Inventory.Access
  ( AccessBinding (..)
  , AccessFact (..)
  , AccessPlan (..)
  , AccessOps (..)
  , compileAccessScope
  , compilePortalSyncScope
  , accessBindings
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
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
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

-- These dependencies come from the composed owner declarations, not live lists.
data AccessBinding = AccessBinding
  { accessResource :: !ManagedResource
  , accessAuth :: !ManagedResource
  , accessRoute :: !ManagedResource
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

compileAccessScope :: ScopeSnapshot -> Text -> Text -> Text -> Bool -> Either Text ScopeDeclaration
compileAccessScope snapshot rawHost subject endpoint granted = do
  host <- mkName (T.toLower (T.dropWhileEnd (== '.') (T.strip rawHost)))
  unless (validAccessEndpoint endpoint) (Left "access endpoint must be an HTTP(S) base URL without credentials, query, or fragment")
  unless (not (T.null (T.strip subject)) && not (T.any (< ' ') subject)) (Left "invalid access subject")
  inventory <- first (T.pack . show) (composeSnapshot snapshot)
  (auth, route) <- protectedOwner (inventoryDeclarations inventory) host
  let key =
        T.take
          40
          ( digestText
              ( contentDigest
                  ( TE.encodeUtf8
                      (resourceIdText (auth ^. #identity) <> "\n" <> nameText host <> "\n" <> subject)
                  )
              )
          )
  owner <- mkScopeId Standalone ("access-" <> key)
  logical <- mkLogicalKey "viewer"
  role <- mkName "grant"
  let resource =
        ManagedResource
          (mintResourceId owner logical role)
          owner
          AccessExecutor
          (AccessTuple (auth ^. #identity) host subject)
          []
          (AccessGrantSpec endpoint granted)
          Retain
          Stateless
          Private
          [OrderedAfter (auth ^. #identity), OrderedAfter (route ^. #identity)]
          []
          (SourceLocation "access" "viewer")
  -- A changed endpoint cannot silently move a previously owned relationship.
  forM_ (Map.lookup owner (snapshotScopes snapshot)) $ \(_, prior) ->
    forM_ [old | bundle <- scopeBundles prior, Managed old <- bundle ^. #declarations] $ \old ->
      unless
        ( old ^. #identity == resource ^. #identity
            && old ^. #address == resource ^. #address
            && case old ^. #spec of AccessGrantSpec oldEndpoint _ -> oldEndpoint == endpoint; _ -> False
        )
        (Left "accepted access endpoint or tuple identity changed; use an explicit ownership transition")
  first
    (T.pack . show)
    ( mkScopeDeclaration
        owner
        [ResourceBundle [Managed resource] [] [] [] [] []]
    )

protectedOwner :: [Declaration] -> Name -> Either Text (ManagedResource, ManagedResource)
protectedOwner declarations host = do
  authOwner <- mkScopeId Platform "auth"
  auth <-
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
  cluster <- case auth ^. #address of Kubernetes c _ _ _ _ -> Right c; _ -> Left "invalid auth service"
  let protected =
        [ ()
        | Managed r <- declarations
        , r ^. #owner == authOwner
        , BackendMapSpec entries <- [r ^. #spec]
        , (h, _, role) <- entries
        , h == host
        , role == ProtectedBackend
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
  where
    one _ [single] = Right single; one reason _ = Left reason

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
      (authId, host) <- case (resource ^. #address, resource ^. #spec) of
        (AccessTuple auth host _, AccessGrantSpec endpoint _) | validAccessEndpoint endpoint -> Right (auth, host)
        _ -> Left "invalid typed access tuple declaration"
      (auth, route) <- protectedOwner declarations host
      unless
        ( authId == auth ^. #identity
            && Set.fromList (resource ^. #dependencies) == Set.fromList [OrderedAfter authId, OrderedAfter (route ^. #identity)]
            && resource ^. #lifecycle == Retain
            && resource ^. #dataPolicy == Stateless
        )
        (Left "access tuple differs from its auth owner or protected route")
      pure (resource ^. #identity, AccessBinding resource auth route)

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
    summary binding = case accessResource binding ^. #address of
      AccessTuple _ host subject ->
        (if wanted binding then "grant " else "revoke ")
          <> subject
          <> " viewer on "
          <> nameText host
      _ -> "invalid access tuple"
