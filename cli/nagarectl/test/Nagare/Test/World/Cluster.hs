-- | EP-182: the fake cluster the recovery model runs against. The 'ApiServer'
-- sits behind the production kubectl interpreter
-- ('withKubectlInterpreter'), so the production runtime builds every request,
-- maps every answer and parses every object; the world never constructs a
-- 'KubernetesState' itself. A request outside the grammar the runtime emits
-- throws, so a harness gap fails the run instead of looking like a provider
-- answer.
--
-- Faults fire at boundaries counted by request: every single-object @get@ is
-- an 'ObserveCall', every write (@create@, @apply@, @patch@, @delete@) a
-- 'MutateCall'. A fault is recorded as acted ('noteActed') only when it
-- changed the server's state or the answer kubectl gave.
--
-- The world's whole state is one pure 'KubeWorld' value, so a recovery-model
-- snapshot (EP-179) copies all of it.
module Nagare.Test.World.Cluster
  ( KubeWorld (..)
  , Cluster (..)
  , UnsupportedRequest (..)
  , newWorld
  , newCluster
  , readServer
  , modifyServer
  , clusterAnswer
  , clusterConfig
  , clusterOps
  , clusterAdapter
  )
where

import Control.Exception (Exception, throwIO)
import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (for_)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter (Adapter)
import Nagare.Inventory.Adapters.Kubernetes (KubernetesAdapterOps, KubernetesState)
import Nagare.Inventory.Adapters.KubernetesApplication (kubernetesApplicationAdapter)
import Nagare.Inventory.Adapters.KubernetesRuntime (mkKubernetesRuntimeOpsAndBatchWithCacheKey)
import Nagare.Inventory.Journal (OperationId)
import Nagare.Inventory.KubernetesTransport (KubectlRequest (..), KubectlResult, KubernetesRuntimeConfig (..), runKubectlWith, withKubectlInterpreter)
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Types (ContextId, PhysicalIdentity, ResourceId, mkPhysicalIdentity, mkResourceId)
import Nagare.Test.World.Adversary
import Nagare.Test.World.ApiServer
import Nagare.Test.World.Kinds (KindSemantics (..), ReadinessModel (..))
import Nagare.Test.World.Kubectl
import System.Exit (ExitCode (..))

-- | Everything the fake cluster is, as one value.
data KubeWorld = KubeWorld
  { server :: !ApiServer
  , churning :: !(Maybe (Boundary, Fault))
  -- ^ Where 'ChurnAlways' fired, once it has.
  , quiet :: !Bool
  -- ^ Churn quiets while the operator works an exit (a refused stop is
  -- retried once status settles).
  , inspecting :: !Bool
  -- ^ The model reads as an operator would: no fault fires, nothing churns.
  , inFlight :: !(Maybe OperationId)
  -- ^ The reviewed operation whose write the adapter is executing.
  , writes :: !(Map.Map OperationId Int)
  -- ^ Effective writes per reviewed operation (invariant I4).
  , lastWriter :: !(Map.Map ResourceId OperationId)
  -- ^ The reviewed operation whose write produced each object.
  , replacedUids :: !(Set.Set PhysicalIdentity)
  -- ^ UIDs the 'Replaced' fault created outside review (invariant I3).
  , deletedOutOfBand :: !(Set.Set ResourceId)
  -- ^ Members the 'Deleted' fault removed outside review.
  , requests :: ![(Maybe Boundary, LoggedRequest)]
  -- ^ Every request and the boundary it counted as, most recent first.
  , addresses :: !(Map.Map ObjectKey ResourceId)
  -- ^ Each member's address, so an unstamped object at one is attributed.
  , reviewedOperations :: !(Map.Map OperationId [ResourceId])
  -- ^ EP-181: the members each applied review's operations act on, so the
  -- model can tell from the journal's intents which members ever started.
  , poisoned :: !(Map.Map Text (Boundary, Fault))
  -- ^ The specs a 'LandsUnready' or 'LandsFailed' fault made bad, by outcome
  -- key: the fault acts when a write of that spec lands and rolls out,
  -- whether the faulted write or a retry of it.
  }
  deriving stock (Eq, Show, Generic)

newWorld :: ApiServer -> KubeWorld
newWorld initial = KubeWorld initial Nothing False False Nothing Map.empty Map.empty Set.empty Set.empty [] Map.empty Map.empty Map.empty

data Cluster = Cluster
  { world :: !(IORef KubeWorld)
  , adversary :: !(IORef Adversary)
  }

newtype UnsupportedRequest = UnsupportedRequest Text
  deriving stock (Show)

instance Exception UnsupportedRequest

newCluster :: ApiServer -> IORef Adversary -> IO Cluster
newCluster initial adversary' = (`Cluster` adversary') <$> newIORef (newWorld initial)

readServer :: Cluster -> IO ApiServer
readServer cluster = (^. #server) <$> readIORef (world cluster)

modifyServer :: Cluster -> (ApiServer -> ApiServer) -> IO ()
modifyServer cluster f = modifyIORef' (world cluster) (#server %~ f)

-- | Answer one kubectl request: count its boundary, apply the fault scheduled
-- there, then let the fake server answer.
clusterAnswer :: Cluster -> KubectlRequest -> IO KubectlResult
clusterAnswer cluster request = do
  state0 <- readIORef (world cluster)
  let quietReads = state0 ^. #inspecting
      logged = logRequest request
      written = writtenKey request
      key = written <|> (logged ^. #target)
      call = callOf (logged ^. #verb) key
  placement <- case call of
    Just call' | not quietReads -> nextFaultAt (adversary cluster) call'
    _ -> pure Nothing
  modifyIORef' (world cluster) (#requests %~ ((fst <$> placement, logged) :))
  -- A write reaches a lagging controller: it observes again, after the write.
  -- The API server answers the write against the stored object alone, and
  -- the controller's catch-up is its own later status write (RES-4 U16), so
  -- the object only thaws here and catches up when the write lands.
  for_ written $ \k ->
    when (maybe True ((/= ControllerLag) . snd) placement) $
      modifyServer cluster (#frozen %~ Set.delete k)
  for_ placement (before key)
  -- Churn precedes observations only (RES-4 E10); a status write between
  -- every read and the write after it is not a controller's behaviour.
  unless (quietReads || state0 ^. #quiet || call /= Just ObserveCall) (for_ key churnBeforeObserving)
  case placement of
    Just placed@(_, TransientReadFailure) -> do
      noteActed (adversary cluster) placed
      pure (Right (ExitFailure 1, "", "Unable to connect to the server: net/http: TLS handshake timeout"))
    Just placed@(_, RefusedBeforeEffect) -> do
      noteActed (adversary cluster) placed
      pure (Right (ExitFailure 1, "", "Error from server (Forbidden): admission webhook \"policy.example\" denied the request: refused before any effect"))
    _ -> do
      previous <- readServer cluster
      response <- atomicModifyIORef' (world cluster) (\w -> let (s', r) = kubectlResponse request (w ^. #server) in (w & #server .~ s', r))
      current <- readServer cluster
      case response of
        Unsupported argv -> throwIO (UnsupportedRequest ("world: kubectl request outside the runtime's grammar: " <> argv))
        Answered code stdout stderr -> do
          for_ written (countWrite previous current)
          -- A bad spec acts once a write of it lands and rolls out, whoever
          -- wrote it; a refused write of it has changed nothing.
          bad <- (^. #poisoned) <$> readIORef (world cluster)
          for_ (requestBody request) $ \body -> for_ (Map.lookup (outcomeKey body) bad) $ \placed ->
            when (code == ExitSuccess && maybe False (\k -> hasReadiness k && rolledOut k previous current) key) $ do
              already <- elem placed . acted <$> readIORef (adversary cluster)
              unless already (noteActed (adversary cluster) placed)
          case placement of
            Just placed@(_, LostAcknowledgement) -> do
              noteActed (adversary cluster) placed
              pure (Right (ExitFailure 1, "", "error: unexpected EOF"))
            Just placed@(_, Interrupt) | current /= previous -> do
              noteActed (adversary cluster) placed
              throwIO Interrupted
            -- A lag acts when the controller would have changed the object
            -- after this write: a new generation to observe, or a new object's
            -- first status.
            Just placed@(_, ControllerLag)
              | code == ExitSuccess
              , Just k <- key
              , let thawed = current & #frozen %~ Set.delete k
              , controllerStep k thawed /= thawed ->
                  noteActed (adversary cluster) placed >> answered code stdout stderr
            _ -> answered code stdout stderr
  where
    answered code stdout stderr = pure (Right (code, T.unpack stdout, T.unpack stderr))
    note = noteActed (adversary cluster)

    -- An effective write by a reviewed operation: the object it names
    -- appeared, went, or changed outside its status and server bookkeeping.
    countWrite previous current k = do
      operation <- (^. #inFlight) <$> readIORef (world cluster)
      for_ operation $ \operation' ->
        when (written' k previous /= written' k current) $ do
          let resource = resourceOf k current <|> resourceOf k previous
          modifyIORef' (world cluster) $ \w ->
            w
              & #writes
              %~ Map.insertWith (+) operation' 1
              & #lastWriter
              %~ maybe id (`Map.insert` operation') resource
    written' k s = writtenContent <$> get False k s

    -- Faults that change the world before the request is answered.
    before key placed@(_, fault) = case (fault, key) of
      (ForeignObject, Just k) -> do
        s <- readServer cluster
        when (isNothing (get False k s)) $ case create "kubectl-create" (foreignObject k) s of
          Right (s', _) -> modifyServer cluster (const s') >> note placed
          Left _ -> pure ()
      (Replaced, Just k) -> do
        s <- readServer cluster
        case get False k s of
          Just live | stamped live -> case delete (Preconditions Nothing Nothing) Background k s of
            Right s'
              | Just content' <- withoutServerFields live
              , Right (s'', created') <- create "kubectl-replace" content' s' -> do
                  modifyServer cluster (const s'')
                  for_ (physicalOf created') $ \uid' -> modifyIORef' (world cluster) (#replacedUids %~ Set.insert uid')
                  note placed
            _ -> pure ()
          _ -> pure ()
      (Deleted, Just k) -> do
        s <- readServer cluster
        case get False k s of
          Just live
            | stamped live
            , Right s' <- delete (Preconditions Nothing Nothing) Background k s -> do
                modifyServer cluster (const s')
                -- The deleted object's write no longer stands, so writing it again
                -- is not a repeated effect (I4).
                for_ (resourceOf k s) $ \resource -> modifyIORef' (world cluster) $ \w ->
                  w
                    & #deletedOutOfBand
                    %~ Set.insert resource
                    & #writes
                    %~ maybe id (Map.adjust (subtract 1)) (Map.lookup resource (w ^. #lastWriter))
                note placed
          _ -> pure ()
      (ChurnAlways, _) -> modifyIORef' (world cluster) (#churning ?~ placed)
      (StatusChurn, Just k) -> do
        s <- readServer cluster
        when (hasStatus k && isJust (get False k s)) $ case writeStatus (statusManager k) k (object ["churn" .= ("before-write" :: Text)]) s of
          Right (s', _) | s' /= s -> modifyServer cluster (const s') >> note placed
          _ -> pure ()
      (ForeignManager, Just k) -> do
        s <- readServer cluster
        case get False k s >>= editable of
          Just patch | Right (s', _) <- patchUpdate "kubectl-edit" k patch s -> modifyServer cluster (const s') >> note placed
          _ -> pure ()
      (LandsUnready, Just _) -> registerOutcome placed Unready
      (LandsFailed, Just _) -> registerOutcome placed Failed
      (ControllerLag, Just k) -> modifyServer cluster (#frozen %~ Set.insert k)
      _ -> pure ()

    -- The written spec's outcome, by the stamp the request carries.
    registerOutcome placed outcome = for_ (requestBody request) $ \body -> do
      modifyServer cluster (#outcomes %~ Map.insert (outcomeKey body) outcome)
      modifyIORef' (world cluster) (#poisoned %~ Map.insert (outcomeKey body) placed)

    -- The write created the object or changed what its controller rolls
    -- out; a write that changes neither cannot land a bad revision.
    rolledOut k previous current = case (Map.lookup k (previous ^. #objects), Map.lookup k (current ^. #objects)) of
      (Nothing, Just _) -> True
      (Just before', Just after') -> templateOf (before' ^. #content) /= templateOf (after' ^. #content)
      _ -> False

    -- Every controller with a readiness model treats a spec that is not
    -- good, unready or failed, as not ready.
    hasReadiness k = case (^. #readinessModel) <$> semanticsFor k of
      Just NoReadinessModel -> False
      Just _ -> True
      Nothing -> False

    -- 'ChurnAlways': the kind's churn source writes status before every
    -- observation from then on (RES-4 E10).
    churnBeforeObserving k =
      (^. #churning) <$> readIORef (world cluster) >>= \case
        Just placed -> do
          s <- readServer cluster
          let s' = churnOnce k s
          when (s' /= s) $ do
            modifyServer cluster (const s')
            already <- elem placed . acted <$> readIORef (adversary cluster)
            unless already (note placed)
        _ -> pure ()

    hasStatus k = maybe False (^. #hasStatusSubresource) (semanticsFor k)

-- | What a write can change: the object without its status and server
-- bookkeeping, but with its deletion state.
writtenContent :: Value -> Value
writtenContent = \case
  Object root ->
    let metadata = KM.filterWithKey (\k _ -> k `notElem` ["resourceVersion", "managedFields", "generation"]) (objectOf (field "metadata" (Object root)))
     in Object (KM.insert "metadata" (Object metadata) (KM.delete "status" root))
  other -> other
  where
    objectOf = \case
      Object fields -> fields
      _ -> KM.empty

-- | The resource a stored object belongs to, by its stamp.
resourceOf :: ObjectKey -> ApiServer -> Maybe ResourceId
resourceOf k s = do
  live <- get False k s
  case field "nagare.dev/resource-id" (field "annotations" (field "metadata" live)) of
    String text' -> either (const Nothing) Just (mkResourceId text')
    _ -> Nothing

physicalOf :: Value -> Maybe PhysicalIdentity
physicalOf written = case field "uid" (field "metadata" written) of
  String text' -> either (const Nothing) Just (mkPhysicalIdentity text')
  _ -> Nothing

-- | The boundary a request counts as.
callOf :: Text -> Maybe ObjectKey -> Maybe Call
callOf verb key = case verb of
  "get" | isJust key -> Just ObserveCall
  _ | verb `elem` ["create", "apply", "patch", "delete"] -> Just MutateCall
  _ -> Nothing

-- | The object a write request writes: a create or apply's from its body, a
-- patch or delete's from its arguments. Any other request writes nothing.
writtenKey :: KubectlRequest -> Maybe ObjectKey
writtenKey request = case request ^. #arguments of
  verb : _
    | verb `elem` ["create", "apply"] -> keyOf =<< requestBody request
    | verb `elem` ["patch", "delete"] -> logRequest request ^. #target
  _ -> Nothing

requestBody :: KubectlRequest -> Maybe Value
requestBody request = either (const Nothing) Just (eitherDecodeStrict (TE.encodeUtf8 (T.pack (request ^. #input))))

-- | Owned by a Nagare review: it carries the reserved stamp.
stamped :: Value -> Bool
stamped live = isJust (specDigestOf live)

-- | An unowned object at the address, as an operator's `kubectl create`
-- would leave it.
foreignObject :: ObjectKey -> Value
foreignObject key =
  object
    [ "apiVersion" .= apiVersionOf key
    , "kind" .= (key ^. #kind)
    , "metadata" .= object (["name" .= (key ^. #name)] <> ["namespace" .= ns | Just ns <- [key ^. #namespace]])
    ]

-- | The object as a client would submit it again.
withoutServerFields :: Value -> Maybe Value
withoutServerFields = \case
  Object root -> Just (Object (KM.delete "status" root))
  _ -> Nothing

-- | A merge patch another writer makes to one of the reviewed object's own
-- fields: the first string leaf outside metadata, edited.
editable :: Value -> Maybe Value
editable live = case [(path, s) | (path, String s) <- leaves [] live, take 1 path `notElem` [["metadata"], ["status"], ["apiVersion"], ["kind"]]] of
  (path, s) : _ -> Just (nest path (String (s <> "-edited")))
  [] -> Nothing
  where
    leaves prefix = \case
      Object fields -> concat [leaves (prefix <> [Key.toText k]) v | (k, v) <- KM.toList fields]
      value -> [(prefix, value)]
    nest path value = foldr (\k v -> Object (KM.singleton (Key.fromText k) v)) value path

field :: Text -> Value -> Value
field key = \case
  Object fields -> fromMaybe Null (KM.lookup (Key.fromText key) fields)
  _ -> Null

-- | A runtime configuration whose kubectl is the fake cluster. The cluster
-- guard always passes: there is one cluster.
clusterConfig :: ContextId -> Cluster -> KubernetesRuntimeConfig
clusterConfig context cluster =
  withKubectlInterpreter
    (runKubectlWith (clusterAnswer cluster))
    (KubernetesRuntimeConfig context "world" (pure (Right ())))

clusterOps :: ContextId -> Cluster -> Map.Map ResourceId (ManagedResource, ByteString) -> (KubernetesAdapterOps, [ResourceId] -> IO [KubernetesState])
clusterOps context cluster = mkKubernetesRuntimeOpsAndBatchWithCacheKey (clusterConfig context cluster) noCache

-- | The application-scope adapter production runs (without takeover), over
-- the fake cluster: the CLI and the model share 'kubernetesApplicationAdapter'.
clusterAdapter :: ContextId -> Cluster -> Map.Map ResourceId (ManagedResource, ByteString) -> Adapter
clusterAdapter context cluster = kubernetesApplicationAdapter False (clusterConfig context cluster) noCache

noCache :: ResourceId -> IO (Either Text Text)
noCache _ = pure (Left "the world has no cache client")
