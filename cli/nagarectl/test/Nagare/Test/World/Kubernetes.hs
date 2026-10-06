-- | EP-173: an in-memory Kubernetes API server behind the real adapter's
-- provider-operation seam ('KubernetesAdapterOps'). Writes are conditional on
-- the reviewed UID and resourceVersion, exactly as the API server checks them;
-- an adversary decides how a write lands. Everything above this seam (planning,
-- the driver, the adapter's recovery decisions) is production code.
module Nagare.Test.World.Kubernetes
  ( KubeObject (..)
  , KubeWorld (..)
  , Readiness (..)
  , effectiveWrites
  , newKubeWorld
  , worldKubernetesAdapter
  , worldKubernetesOps
  )
where

import Control.Exception (throwIO)
import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect), OperationId)
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Types
import Nagare.Test.World.Adversary

data Readiness
  = Ready
  | NotReady
  | FailedReadiness
  deriving stock (Eq, Show)

data KubeObject = KubeObject
  { uid :: !PhysicalIdentity
  , address :: !ProviderAddress
  , owner :: !(Maybe ResourceId)
  , generation :: !Int
  , resourceVersion :: !Int
  , nativeDigest :: !ContentDigest
  , foreignManager :: !Bool
  , readiness :: !Readiness
  }
  deriving stock (Eq, Show)

data KubeWorld = KubeWorld
  { objects :: !(Map.Map ResourceId KubeObject)
  , unreadyDigests :: !(Set.Set ContentDigest)
  -- ^ Digests that never become Ready or that fail, whoever writes them
  -- (a persistent fault outlives the write that revealed it).
  , failedDigests :: !(Set.Set ContentDigest)
  , nextUid :: !Int
  , churning :: !Bool
  -- ^ Persistent status churn on every observation (fault 'ChurnAlways').
  , quiet :: !Bool
  -- ^ Churn quiets while the operator works an exit (a refused stop is retried
  -- once status settles).
  , inspecting :: !Bool
  -- ^ The model is computing status as an operator would: no faults fire
  -- and no churn happens on these observations.
  , writes :: !(Map.Map OperationId Int)
  -- ^ Effective writes per reviewed operation (invariant I4).
  , replacedUids :: !(Set.Set PhysicalIdentity)
  , deletedOutOfBand :: !(Set.Set ResourceId)
  -- ^ Members the 'Deleted' fault removed outside review.
  , lastWriter :: !(Map.Map ResourceId OperationId)
  -- ^ The reviewed operation whose write produced each object.
  -- ^ Objects created out of band by the 'Replaced' fault, never by a review
  -- (invariant I3: they are never an accepted incarnation).
  }
  deriving stock (Eq, Show)

newKubeWorld :: Set.Set ContentDigest -> IO (IORef KubeWorld)
newKubeWorld unready = newIORef (KubeWorld Map.empty unready Set.empty 1 False False False Map.empty Set.empty Set.empty Map.empty)

effectiveWrites :: KubeWorld -> Map.Map OperationId Int
effectiveWrites = writes

-- | The adapter production builds for application scopes
-- ('inventoryKubernetesAdapterWith' without takeover), over the world.
worldKubernetesAdapter ::
  ContextId ->
  Map.Map ResourceId (ManagedResource, ByteString) ->
  IORef KubeWorld ->
  IORef Adversary ->
  Adapter
worldKubernetesAdapter context specs world adversary =
  mkKubernetesAdapterWithConfigurationObservation
    specs
    ops
    (traverse (kubernetesObserve ops))
    (stableObserve specs world adversary)
    (\_ _ -> pure (Left "no backup receipt in the Kubernetes world"))
    (\_ _ -> pure (Right False))
    (liveObject world)
  where
    ops = worldKubernetesOps context specs world adversary

worldKubernetesOps :: ContextId -> Map.Map ResourceId (ManagedResource, ByteString) -> IORef KubeWorld -> IORef Adversary -> KubernetesAdapterOps
worldKubernetesOps context specs world adversary =
  KubernetesAdapterOps
    { kubernetesContext = context
    , kubernetesObserve = observe specs world adversary
    , kubernetesMutateConditional = mutate world adversary
    }

observe :: Map.Map ResourceId (ManagedResource, ByteString) -> IORef KubeWorld -> IORef Adversary -> ResourceId -> IO KubernetesState
observe specs world adversary resource = do
  transient <- observationFaults specs world adversary resource
  if transient
    then pure (KubernetesUnknown "injected: Kubernetes API read timed out")
    else stateOf resource (\object' -> nativeDigest object') <$> readIORef world

-- | The status-independent configuration observation: status churn changes
-- resourceVersion but not this digest.
stableObserve :: Map.Map ResourceId (ManagedResource, ByteString) -> IORef KubeWorld -> IORef Adversary -> ResourceId -> IO KubernetesState
stableObserve specs world adversary resource = do
  transient <- observationFaults specs world adversary resource
  if transient
    then pure (KubernetesUnknown "injected: Kubernetes API read timed out")
    else stateOf resource (\object' -> contentDigest (TE.encodeUtf8 ("configuration:" <> digestText (nativeDigest object')))) <$> readIORef world

-- | Faults at an observation boundary, applied before the object is read.
-- 'True' when this read itself fails transiently.
observationFaults :: Map.Map ResourceId (ManagedResource, ByteString) -> IORef KubeWorld -> IORef Adversary -> ResourceId -> IO Bool
observationFaults specs world adversary resource = do
  inspection <- inspecting <$> readIORef world
  fault <- if inspection then pure Nothing else nextFault adversary ObserveCall
  when (fault == Just Replaced) $ modifyIORef' world $ \state -> case Map.lookup resource (objects state) of
    Just object'
      | isJust (owner object') ->
          let replacement = either (error . T.unpack) id (mkPhysicalIdentity ("replacement-uid-" <> T.pack (show (nextUid state))))
           in state
                { objects =
                    Map.insert
                      resource
                      object'
                        { uid = replacement
                        , generation = 1
                        , resourceVersion = 1
                        }
                      (objects state)
                , nextUid = nextUid state + 1
                , replacedUids = Set.insert replacement (replacedUids state)
                }
    _ -> state
  -- The deleted object's write no longer stands, so writing it again is not
  -- a repeated effect (I4).
  when (fault == Just Deleted) $ modifyIORef' world $ \state -> case Map.lookup resource (objects state) of
    Just object'
      | isJust (owner object') ->
          state
            { objects = Map.delete resource (objects state)
            , deletedOutOfBand = Set.insert resource (deletedOutOfBand state)
            , writes = maybe id (Map.adjust (subtract 1)) (Map.lookup resource (lastWriter state)) (writes state)
            }
    _ -> state
  when (fault == Just ChurnAlways) $ modifyIORef' world $ \state -> state {churning = True}
  when (fault == Just ForeignObject) $ case Map.lookup resource specs of
    Just (managed, _) -> modifyIORef' world $ \state ->
      if Map.member resource (objects state)
        then state
        else
          state
            { objects =
                Map.insert
                  resource
                  KubeObject
                    { uid = either (error . T.unpack) id (mkPhysicalIdentity ("foreign-uid-" <> T.pack (show (nextUid state))))
                    , address = managed ^. #address
                    , owner = Nothing
                    , generation = 1
                    , resourceVersion = 1
                    , nativeDigest = contentDigest "foreign-object"
                    , foreignManager = False
                    , readiness = Ready
                    }
                  (objects state)
            , nextUid = nextUid state + 1
            }
    Nothing -> pure ()
  -- Knative's controller writes Service status (and so resourceVersion)
  -- continuously (F30). A settled StatefulSet's status changes only when its
  -- pods do, so persistent churn is a Knative Service behaviour.
  modifyIORef' world $ \state ->
    if churning state && not (quiet state) && not (inspecting state)
      then state {objects = Map.adjust (\o -> if knativeService (address o) then o {resourceVersion = resourceVersion o + 1} else o) resource (objects state)}
      else state
  pure (fault == Just TransientReadFailure)

stateOf :: ResourceId -> (KubeObject -> ContentDigest) -> KubeWorld -> KubernetesState
stateOf resource digestOf state = case Map.lookup resource (objects state) of
  Nothing -> KubernetesAbsent (absenceOf resource)
  Just object' ->
    let revision = T.pack (show (resourceVersion object'))
        digest = digestOf object'
     in case readiness object' of
          Ready -> KubernetesPresent (uid object') revision (owner object') digest
          NotReady -> KubernetesNotReady (uid object') revision (owner object') digest
          FailedReadiness -> KubernetesFailed (uid object') revision (owner object') digest

absenceOf :: ResourceId -> ContentDigest
absenceOf resource = contentDigest (TE.encodeUtf8 ("absent:" <> resourceIdText resource))

-- | The API server's conditional write, then the runtime's readiness wait.
mutate :: IORef KubeWorld -> IORef Adversary -> KubernetesMutation -> IO AdapterExecution
mutate world adversary mutation = do
  fault <- nextFault adversary MutateCall
  when (fault == Just StatusChurn) $
    modifyIORef' world $
      \state -> state {objects = Map.adjust (\o -> o {resourceVersion = resourceVersion o + 1}) resource (objects state)}
  -- Another writer takes a reviewed field; the object stays that way.
  when (fault == Just ForeignManager) $
    modifyIORef' world $
      \state -> state {objects = Map.adjust (\o -> o {foreignManager = True}) resource (objects state)}
  current <- readIORef world
  let conflicted = case Map.lookup resource (objects current) of
        Just object' -> foreignManager object' && mutationAction mutation == UpdateResource && isNothing (mutationTakeover mutation)
        Nothing -> False
  if fault == Just RefusedBeforeEffect
    then pure (AdapterEffectFailed (KnownNoEffect "provider refused the write before any effect"))
    else
      if not (preconditionHolds current)
        then pure (AdapterEffectFailed (KnownNoEffect "conditional write precondition no longer holds"))
        else
          if conflicted
            then pure (AdapterEffectFailed (KnownNoEffect "Kubernetes object has fields managed by another writer: kubectl-edit"))
            else do
              when (fault == Just LandsUnready) $
                modifyIORef' world $
                  \state -> state {unreadyDigests = Set.insert (mutationNativeDigest mutation) (unreadyDigests state)}
              when (fault == Just LandsFailed) $
                modifyIORef' world $
                  \state -> state {failedDigests = Set.insert (mutationNativeDigest mutation) (failedDigests state)}
              landed <- atomicModifyIORef' world apply
              when (fault == Just Interrupt) (throwIO Interrupted)
              -- Like the API server, a write returns the object it wrote
              -- (ADR 27), unless the response itself was lost.
              pure $ case (fault, landed) of
                (Just LostAcknowledgement, _) -> AdapterEffectAmbiguous "Kubernetes write acknowledgement was lost"
                (_, Just (NotReady, written)) -> AdapterEffectIdentified written (AdapterEffectAmbiguous "Kubernetes object did not prove readiness; reobserve before retry")
                (_, Just (FailedReadiness, written)) -> AdapterEffectIdentified written (AdapterEffectAmbiguous "Kubernetes object did not prove readiness; reobserve before retry")
                (_, Just (_, written)) -> AdapterEffectIdentified written AdapterEffectCompleted
                (_, Nothing) -> AdapterEffectCompleted
  where
    resource = mutationResource mutation
    preconditionHolds state = case (mutationBefore mutation, Map.lookup resource (objects state)) of
      (KubernetesAbsent _, Nothing) -> True
      (KubernetesAbsent _, Just _) -> False
      (before, Just object') -> beforeIdentity before == Just (uid object', T.pack (show (resourceVersion object')))
      (_, Nothing) -> False
    beforeIdentity before = case before of
      KubernetesPresent physical revision _ _ -> Just (physical, revision)
      KubernetesNotReady physical revision _ _ -> Just (physical, revision)
      KubernetesFailed physical revision _ _ -> Just (physical, revision)
      KubernetesReplacementRequired physical revision _ _ -> Just (physical, revision)
      _ -> Nothing
    apply state = case mutationAction mutation of
      RetireResource -> (counted state {objects = Map.delete resource (objects state)}, Nothing)
      _ ->
        let digest = mutationNativeDigest mutation
            -- Fidelity: only workloads report readiness, and only a Job fails
            -- (a crash-looping Knative revision reports Ready=False).
            readinessFor
              | kindOf (mutationAddress mutation) == "job" && digest `Set.member` failedDigests state = FailedReadiness
              | hasReadiness (mutationAddress mutation) && digest `Set.member` unreadyDigests state = NotReady
              | otherwise = Ready
            written = case Map.lookup resource (objects state) of
              Just object' ->
                object'
                  { generation = generation object' + 1
                  , resourceVersion = resourceVersion object' + 1
                  , nativeDigest = digest
                  , foreignManager = foreignManager object' && isNothing (mutationTakeover mutation)
                  , readiness = readinessFor
                  }
              Nothing ->
                KubeObject
                  { uid = either (error . T.unpack) id (mkPhysicalIdentity ("world-uid-" <> T.pack (show (nextUid state))))
                  , address = mutationAddress mutation
                  , owner = Just resource
                  , generation = 1
                  , resourceVersion = 1
                  , nativeDigest = digest
                  , foreignManager = False
                  , readiness = readinessFor
                  }
            next = state {objects = Map.insert resource written (objects state), nextUid = nextUid state + 1}
         in (counted next, Just (readinessFor, uid written))
    counted state =
      state
        { writes = Map.insertWith (+) (mutationOperation mutation) 1 (writes state)
        , lastWriter = Map.insert resource (mutationOperation mutation) (lastWriter state)
        }

knativeService :: ProviderAddress -> Bool
knativeService target = case target of
  Kubernetes _ "serving.knative.dev" kind _ _ -> nameText kind == "service"
  _ -> False

kindOf :: ProviderAddress -> Text
kindOf target = case target of
  Kubernetes _ _ kind _ _ -> nameText kind
  _ -> ""

hasReadiness :: ProviderAddress -> Bool
hasReadiness target =
  kindOf target `elem` ["service", "deployment", "statefulset", "domainmapping", "job"]
    && case target of
      Kubernetes _ group kind _ _ -> not (group == "" && nameText kind == "service")
      _ -> False

-- | The live object with managed fields, as `kubectl get --show-managed-fields`
-- returns it. The controller has always observed the current generation.
liveObject :: IORef KubeWorld -> ProviderAddress -> IO (Either Text Value)
liveObject world target = do
  state <- readIORef world
  pure $ case [object' | object' <- Map.elems (objects state), address object' == target] of
    [object'] -> Right (render object')
    [] -> Left "Kubernetes object is absent"
    _ -> Left "Kubernetes address is ambiguous in the world"
  where
    render object' =
      object
        [ "metadata"
            .= object
              [ "uid" .= physicalIdentityText (uid object')
              , "resourceVersion" .= T.pack (show (resourceVersion object'))
              , "generation" .= generation object'
              , "managedFields" .= ([inventoryEntry] <> [foreignEntry | foreignManager object'] <> [statusEntry])
              ]
        , "spec" .= object ["replicas" .= (1 :: Int)]
        , "status"
            .= object
              [ "observedGeneration" .= generation object'
              , "conditions" .= [object ["type" .= ("Ready" :: Text), "status" .= (if readiness object' == Ready then "True" else "False" :: Text)]]
              , -- A StatefulSet reports readiness by its replica counts.
                "readyReplicas" .= (if readiness object' == Ready then 1 else 0 :: Int)
              ]
        ]
    inventoryEntry = object ["manager" .= ("nagare-inventory" :: Text), "operation" .= ("Apply" :: Text), "fieldsV1" .= object ["f:spec" .= object ["f:template" .= object []]]]
    foreignEntry = object ["manager" .= ("kubectl-edit" :: Text), "operation" .= ("Update" :: Text), "fieldsV1" .= object ["f:spec" .= object ["f:template" .= object []]]]
    statusEntry = object ["manager" .= ("controller" :: Text), "operation" .= ("Update" :: Text), "subresource" .= ("status" :: Text), "fieldsV1" .= object ["f:status" .= object []]]
