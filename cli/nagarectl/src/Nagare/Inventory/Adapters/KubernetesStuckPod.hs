-- | EP-181 (RES-4 G3): the pod that blocks a member StatefulSet's rollout.
--
-- Under the defaults Nagare renders (ordered pod management, rolling updates,
-- one replica), a StatefulSet never replaces a pod that is not Ready (RES-4
-- §2, experiment E6f). A corrected template then lands, moves
-- @status.updateRevision@, and never runs until that pod is deleted. A pod is
-- stuck when the controller has observed the latest spec, the pod is at a
-- revision other than @status.updateRevision@, and it is neither Ready nor
-- being deleted.
module Nagare.Inventory.Adapters.KubernetesStuckPod
  ( StuckPod (..)
  , KubernetesPodOps (..)
  , noPodOps
  , runtimePodOps
  , stuckPod
  , podTerminating
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Types (Object, Parser, parseEither, withObject, (.:), (.:?))
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.KubernetesReadiness (statefulSetReady)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), invokeKubectl)
import Nagare.Resource.Inventory (ManagedResource (..))
import Nagare.Resource.Types
import System.Exit (ExitCode (ExitSuccess))
import Text.Read (readMaybe)

-- | A pod that blocks its StatefulSet's rollout, and the StatefulSet it
-- blocks.
data StuckPod = StuckPod
  { pod :: !Text
  -- ^ The pod's name, for example @pg-0@.
  , namespace :: !Text
  , podUid :: !PhysicalIdentity
  , podResourceVersion :: !Text
  , podRevision :: !Text
  -- ^ The pod's @controller-revision-hash@ label.
  , statefulSetUid :: !PhysicalIdentity
  , updateRevision :: !Text
  -- ^ The StatefulSet's @status.updateRevision@, the template the pod blocks.
  }
  deriving stock (Eq, Show, Generic)

-- | The Kubernetes reads and writes that act on a member's pods rather than
-- on the member itself.
newtype KubernetesPodOps = KubernetesPodOps
  { readStuckPod :: ResourceId -> IO (Either Text (Maybe StuckPod))
  -- ^ The member StatefulSet's stuck pod, if it has one.
  }

-- | No pod access: nothing is ever stuck. For adapters and tests that do not
-- model pods.
noPodOps :: KubernetesPodOps
noPodOps = KubernetesPodOps (\_ -> pure (Right Nothing))

-- | Read a member StatefulSet's stuck pod through kubectl. Pods are listed
-- only when the StatefulSet reads not ready, so a healthy StatefulSet costs
-- one read.
runtimePodOps :: KubernetesRuntimeConfig -> Map ResourceId (ManagedResource, ByteString) -> KubernetesPodOps
runtimePodOps config specs = KubernetesPodOps reader
  where
    reader resource = case address . fst <$> Map.lookup resource specs of
      Just (Kubernetes _ "apps" kind (Just namespace') name')
        | nameText kind == "statefulset" -> do
            guarded <- runtimeGuard config
            case guarded of
              Left reason -> pure (Left ("cluster guard refused the StatefulSet pod read: " <> reason))
              Right () -> do
                let ns = T.unpack (nameText namespace')
                found <- readJson ["get", "statefulset.apps", T.unpack (nameText name'), "--namespace", ns, "-o", "json", "--ignore-not-found"]
                case found of
                  Left reason -> pure (Left reason)
                  Right Nothing -> pure (Right Nothing)
                  Right (Just statefulSet)
                    | statefulSetReady statefulSet -> pure (Right Nothing)
                    | otherwise -> case matchLabels statefulSet of
                        Left reason -> pure (Left reason)
                        Right selector -> do
                          pods <- readJson ["get", "pods", "--namespace", ns, "-l", selector, "-o", "json"]
                          pure $ case pods of
                            Left reason -> Left reason
                            Right Nothing -> Left "the StatefulSet's pod list is empty output"
                            Right (Just listed) -> stuckPod statefulSet listed
      Just _ -> pure (Right Nothing)
      Nothing -> pure (Left "the StatefulSet lacks its bound native object")
    readJson arguments = do
      result <- invokeKubectl config arguments ""
      pure $ do
        (code, output, _) <- result
        unless (code == ExitSuccess) (Left ("kubectl " <> T.pack (unwords (take 2 arguments)) <> " failed"))
        if all (`elem` [' ', '\n']) output
          then Right Nothing
          else Just <$> first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (T.pack output)))
    matchLabels statefulSet = first T.pack . flip parseEither statefulSet . withObject "StatefulSet" $ \root -> do
      labels <- root .: "spec" >>= (.: "selector") >>= (.: "matchLabels") :: Parser (Map Text Text)
      when (Map.null labels) (fail "the StatefulSet's selector has no matchLabels")
      pure (T.unpack (T.intercalate "," [key <> "=" <> value | (key, value) <- Map.toList labels]))

-- | The lowest-ordinal pod of the StatefulSet that blocks its rollout, given
-- the StatefulSet and a pod list (@kubectl get pods -o json@). A StatefulSet
-- without @status.updateRevision@ once its controller has observed it, or a
-- pod it controls without a revision label, is an error, never "not stuck".
stuckPod :: Value -> Value -> Either Text (Maybe StuckPod)
stuckPod statefulSet podList = first T.pack (parseEither parse ())
  where
    parse () = do
      (setUid, generation, observed, status) <- withObject "StatefulSet" statefulSetFields statefulSet
      if observed /= Just generation
        then pure Nothing
        else do
          target <- status .: "updateRevision"
          items <- withObject "PodList" (.: "items") podList
          candidates <- traverse (withObject "Pod" (candidate setUid target)) items
          pure (listToMaybe (sortOn ordinal (catMaybes candidates)))
    statefulSetFields root = do
      metadata <- root .: "metadata"
      setUid <- metadata .: "uid" >>= physical
      generation <- metadata .: "generation" :: Parser Integer
      status <- fromMaybe mempty <$> root .:? "status"
      observed <- status .:? "observedGeneration"
      pure (setUid, generation, observed, status)
    candidate setUid target root = do
      metadata <- root .: "metadata"
      owners <- fromMaybe [] <$> metadata .:? "ownerReferences"
      controlled <- or <$> traverse (controlledBy setUid) owners
      ready <- podReady root
      if not controlled || podTerminating root || ready
        then pure Nothing
        else do
          labels <- fromMaybe mempty <$> metadata .:? "labels" :: Parser (Map Text Text)
          revision <- maybe (fail "a pod the StatefulSet controls has no controller-revision-hash label") pure (Map.lookup "controller-revision-hash" labels)
          if revision == target
            then pure Nothing
            else do
              name' <- metadata .: "name"
              namespace' <- metadata .: "namespace"
              uid' <- metadata .: "uid" >>= physical
              version <- metadata .: "resourceVersion"
              pure (Just (StuckPod name' namespace' uid' version revision setUid target))
    controlledBy setUid owner = flip (withObject "ownerReference") owner $ \reference -> do
      controller <- fromMaybe False <$> reference .:? "controller"
      ownerUid <- reference .: "uid"
      pure (controller && ownerUid == physicalIdentityText setUid)
    podReady root = do
      status <- fromMaybe mempty <$> root .:? "status"
      conditions <- fromMaybe [] <$> status .:? "conditions" :: Parser [Object]
      readiness <- traverse (\condition -> (,) <$> condition .: "type" <*> condition .: "status") conditions
      pure ((("Ready" :: Text), ("True" :: Text)) `elem` readiness)
    physical text = either (fail . T.unpack) pure (mkPhysicalIdentity text)
    -- A StatefulSet names its pods <name>-<ordinal>.
    ordinal stuck = fromMaybe (maxBound :: Int) (readMaybe (T.unpack (T.takeWhileEnd (/= '-') (stuck ^. #pod))))

-- | A pod being deleted is already going, so it is never stuck.
-- EP-180 M6 replaces this with its shared parser's @KubernetesTerminating@.
podTerminating :: Object -> Bool
podTerminating root = either (const False) id (parseEither terminating root)
  where
    terminating object' = do
      metadata <- object' .:? "metadata" :: Parser (Maybe Object)
      stamp <- maybe (pure Nothing) (.:? "deletionTimestamp") metadata :: Parser (Maybe Value)
      pure (case stamp of Just (String _) -> True; _ -> False)
