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
module Nagare.Test.World.Cluster
  ( Cluster (..)
  , UnsupportedRequest (..)
  , newCluster
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
import Nagare.Inventory.Adapters.Kubernetes (KubernetesAdapterOps, KubernetesState, mkKubernetesAdapterWithConfigurationObservation)
import Nagare.Inventory.Adapters.KubernetesRuntime
  ( mkKubernetesRuntimeOpsAndBatchWithCacheKey
  , observeKubernetesConfiguration
  , readBackupReceiptFromCompletedPod
  , readLiveManagedObject
  )
import Nagare.Inventory.Adapters.RestoreScratch (restoreScratchPodFailed)
import Nagare.Inventory.KubernetesTransport (KubectlRequest (..), KubectlResult, KubernetesRuntimeConfig (..), runKubectlWith, withKubectlInterpreter)
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Types (ContextId, ResourceId)
import Nagare.Test.World.Adversary
import Nagare.Test.World.ApiServer
import Nagare.Test.World.Kinds (KindSemantics (..), ReadinessModel (..))
import Nagare.Test.World.Kubectl
import System.Exit (ExitCode (..))

data Cluster = Cluster
  { server :: !(IORef ApiServer)
  , adversary :: !(IORef Adversary)
  , requests :: !(IORef [(Maybe Boundary, LoggedRequest)])
  -- ^ Every request and the boundary it counted as, most recent first.
  , inspecting :: !(IORef Bool)
  -- ^ The model reads as an operator would: no fault fires, nothing churns.
  , churning :: !(IORef (Maybe (Boundary, Fault)))
  -- ^ Where 'ChurnAlways' fired, once it has.
  }

newtype UnsupportedRequest = UnsupportedRequest Text
  deriving stock (Show)

instance Exception UnsupportedRequest

newCluster :: ApiServer -> IORef Adversary -> IO Cluster
newCluster initial adversary' = Cluster <$> newIORef initial <*> pure adversary' <*> newIORef [] <*> newIORef False <*> newIORef Nothing

-- | Answer one kubectl request: count its boundary, apply the fault scheduled
-- there, then let the fake server answer.
clusterAnswer :: Cluster -> KubectlRequest -> IO KubectlResult
clusterAnswer cluster request = do
  quiet <- readIORef (inspecting cluster)
  let logged = logRequest request
      written = writtenKey request
      key = written <|> (logged ^. #target)
      call = callOf (logged ^. #verb) key
  placement <- case call of
    Just call' | not quiet -> nextFaultAt (adversary cluster) call'
    _ -> pure Nothing
  modifyIORef' (requests cluster) ((fst <$> placement, logged) :)
  -- A write reaches a lagging controller: it observes again.
  for_ written $ \k ->
    when (maybe True ((/= ControllerLag) . snd) placement) $
      modifyIORef' (server cluster) (\s -> if Set.member k (frozen s) then controllerStep k (s & #frozen %~ Set.delete k) else s)
  for_ placement (before key)
  unless quiet (for_ key churnBeforeObserving)
  case placement of
    Just placed@(_, TransientReadFailure) -> do
      noteActed (adversary cluster) placed
      pure (Right (ExitFailure 1, "", "Unable to connect to the server: net/http: TLS handshake timeout"))
    Just placed@(_, RefusedBeforeEffect) -> do
      noteActed (adversary cluster) placed
      pure (Right (ExitFailure 1, "", "Error from server (Forbidden): admission webhook \"policy.example\" denied the request: refused before any effect"))
    _ -> do
      previous <- readIORef (server cluster)
      response <- atomicModifyIORef' (server cluster) (kubectlResponse request)
      current <- readIORef (server cluster)
      case response of
        Unsupported argv -> throwIO (UnsupportedRequest ("world: kubectl request outside the runtime's grammar: " <> argv))
        Answered code stdout stderr -> case placement of
          Just placed@(_, LostAcknowledgement) -> do
            noteActed (adversary cluster) placed
            pure (Right (ExitFailure 1, "", "error: unexpected EOF"))
          Just placed@(_, Interrupt) | current /= previous -> do
            noteActed (adversary cluster) placed
            throwIO Interrupted
          Just placed@(_, fault)
            | fault `elem` [LandsUnready, LandsFailed]
            , code == ExitSuccess
            , maybe False (landsWith fault) key ->
                noteActed (adversary cluster) placed >> answered code stdout stderr
          _ -> answered code stdout stderr
  where
    answered code stdout stderr = pure (Right (code, T.unpack stdout, T.unpack stderr))
    note = noteActed (adversary cluster)

    -- Faults that change the world before the request is answered.
    before key placed@(_, fault) = case (fault, key) of
      (ForeignObject, Just k) -> do
        s <- readIORef (server cluster)
        when (isNothing (get False k s)) $ case create "kubectl-create" (foreignObject k) s of
          Right (s', _) -> writeIORef (server cluster) s' >> note placed
          Left _ -> pure ()
      (Replaced, Just k) -> do
        s <- readIORef (server cluster)
        case get False k s of
          Just live | stamped live -> case delete (Preconditions Nothing Nothing) Background k s of
            Right s' | Just content' <- withoutServerFields live, Right (s'', _) <- create "kubectl-replace" content' s' -> writeIORef (server cluster) s'' >> note placed
            _ -> pure ()
          _ -> pure ()
      (Deleted, Just k) -> do
        s <- readIORef (server cluster)
        case get False k s of
          Just live | stamped live, Right s' <- delete (Preconditions Nothing Nothing) Background k s -> writeIORef (server cluster) s' >> note placed
          _ -> pure ()
      (ChurnAlways, _) -> writeIORef (churning cluster) (Just placed)
      (StatusChurn, Just k) -> do
        s <- readIORef (server cluster)
        when (hasStatus k && isJust (get False k s)) $ case writeStatus (statusManager k) k (object ["churn" .= ("before-write" :: Text)]) s of
          Right (s', _) | s' /= s -> writeIORef (server cluster) s' >> note placed
          _ -> pure ()
      (ForeignManager, Just k) -> do
        s <- readIORef (server cluster)
        case get False k s >>= editable of
          Just patch | Right (s', _) <- patchUpdate "kubectl-edit" k patch s -> writeIORef (server cluster) s' >> note placed
          _ -> pure ()
      (LandsUnready, Just _) -> registerOutcome Unready
      (LandsFailed, Just _) -> registerOutcome Failed
      (ControllerLag, Just k) -> do
        s <- readIORef (server cluster)
        let lags = maybe False (^. #tracksObservedGeneration) (semanticsFor k) && maybe False ((/= Null) . field "status") (get False k s)
        modifyIORef' (server cluster) (#frozen %~ Set.insert k)
        when lags (note placed)
      _ -> pure ()

    -- The written spec's outcome, by the stamp the request carries.
    registerOutcome outcome = for_ (requestBody request) $ \body ->
      modifyIORef' (server cluster) (#outcomes %~ Map.insert (outcomeKey body) outcome)

    landsWith fault k = case (^. #readinessModel) <$> semanticsFor k of
      Just JobTerminal -> True
      Just NoReadinessModel -> False
      Just _ -> fault == LandsUnready
      Nothing -> False

    -- 'ChurnAlways': the kind's churn source writes status before every
    -- observation from then on (RES-4 E10).
    churnBeforeObserving k =
      readIORef (churning cluster) >>= \case
        Just placed | callOf "get" (Just k) == Just ObserveCall -> do
          s <- readIORef (server cluster)
          let s' = churnOnce k s
          when (s' /= s) $ do
            writeIORef (server cluster) s'
            already <- elem placed . acted <$> readIORef (adversary cluster)
            unless already (note placed)
        _ -> pure ()

    hasStatus k = maybe False (^. #hasStatusSubresource) (semanticsFor k)

-- | The boundary a request counts as.
callOf :: Text -> Maybe ObjectKey -> Maybe Call
callOf verb key = case verb of
  "get" | isJust key -> Just ObserveCall
  _ | verb `elem` ["create", "apply", "patch", "delete"] -> Just MutateCall
  _ -> Nothing

-- | The object a create or apply writes, from its body.
writtenKey :: KubectlRequest -> Maybe ObjectKey
writtenKey request = case request ^. #arguments of
  verb : _ | verb `elem` ["create", "apply"] -> keyOf =<< requestBody request
  _ -> logRequest request ^. #target

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

-- | The application-scope adapter, composed as the CLI composes it
-- (@inventoryKubernetesAdapterWith False@), over the fake cluster.
clusterAdapter :: ContextId -> Cluster -> Map.Map ResourceId (ManagedResource, ByteString) -> Adapter
clusterAdapter context cluster specs =
  let config = clusterConfig context cluster
      (ops, batch) = mkKubernetesRuntimeOpsAndBatchWithCacheKey config noCache specs
   in mkKubernetesAdapterWithConfigurationObservation
        specs
        ops
        batch
        (observeKubernetesConfiguration config noCache specs)
        (readBackupReceiptFromCompletedPod config specs)
        (restoreScratchPodFailed config specs)
        (readLiveManagedObject config)

noCache :: ResourceId -> IO (Either Text Text)
noCache _ = pure (Left "the world has no cache client")
