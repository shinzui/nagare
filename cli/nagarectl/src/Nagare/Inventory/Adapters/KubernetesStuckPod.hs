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
  , PodReplacement (..)
  , KubernetesPodOps (..)
  , noPodOps
  , runtimePodOps
  , stuckPod
  , podTerminating
  , isStatefulSet
  , preparePodReplacement
  , decodePodReplacement
  , podReplacementSummary
  )
where

import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecodeStrict', toJSON)
import Data.Aeson.KeyMap qualified as KM
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
import Nagare.Inventory.Adapter (OperationAction (ReplaceStuckPod), PlannedOperation (..), PrepareError (..), PreparedNative (..))
import Nagare.Inventory.Adapters.KubernetesReadiness (statefulSetReady)
import Nagare.Inventory.Journal (OperationId)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), invokeKubectl)
import Nagare.Resource.Canonical (canonicalValue)
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
  deriving anyclass (ToJSON, FromJSON)

-- | The reviewed native bytes of a 'ReplaceStuckPod' operation: the pod the
-- review saw blocking the member's rollout, bound to the operation.
data PodReplacement = PodReplacement
  { version :: !Int
  , operation :: !OperationId
  , inputDigest :: !ContentDigest
  , member :: !ResourceId
  , target :: !ProviderAddress
  -- ^ The member StatefulSet's address.
  , stuck :: !StuckPod
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

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

-- | A pod being deleted is already going, so it is never stuck. The rule is
-- EP-180 M6's for members (@parseObserved@ classes an object as
-- @KubernetesTerminating@): a @deletionTimestamp@ that is present and not
-- null.
podTerminating :: Object -> Bool
podTerminating root = case KM.lookup "metadata" root of
  Just (Object metadata) -> KM.lookup "deletionTimestamp" metadata `notElem` [Nothing, Just Null]
  _ -> False

-- | An @apps/StatefulSet@ address, the only kind whose pods this module
-- replaces.
isStatefulSet :: ProviderAddress -> Bool
isStatefulSet = \case
  Kubernetes _ "apps" kind (Just _) _ -> nameText kind == "statefulset"
  _ -> False

-- | Review the member's stuck pod. A member whose rollout is no longer stuck
-- refuses: the plan that proposed the replacement is stale.
preparePodReplacement :: KubernetesPodOps -> PlannedOperation -> ResourceId -> ProviderAddress -> IO (Either PrepareError PreparedNative)
preparePodReplacement pods operation' resource address' = do
  found <- readStuckPod pods resource
  pure . first (PrepareRefused (plannedOperationId operation')) $ do
    reviewed <- found >>= maybe (Left "the StatefulSet's rollout is no longer stuck; the plan is stale, replan") Right
    let replacement = PodReplacement 1 (plannedOperationId operation') (plannedInputDigest operation') resource address' reviewed
    bytes <- canonicalValue (toJSON replacement)
    pure (PreparedNative bytes (podReplacementSummary replacement))

-- | The reviewed replacement, bound to this operation and member.
decodePodReplacement :: PlannedOperation -> ResourceId -> ProviderAddress -> PreparedNative -> Either Text PodReplacement
decodePodReplacement operation' resource address' prepared = do
  replacement <- first T.pack (eitherDecodeStrict' (preparedNativeBytes prepared))
  unless (replacement ^. #version == 1) (Left "unsupported pod replacement version")
  unless (plannedAction operation' == ReplaceStuckPod) (Left "a pod replacement belongs to a replace-stuck-pod operation")
  unless (replacement ^. #operation == plannedOperationId operation' && replacement ^. #inputDigest == plannedInputDigest operation') (Left "pod replacement operation binding changed")
  unless (replacement ^. #member == resource && replacement ^. #target == address') (Left "pod replacement resource binding changed")
  pure replacement

-- | The review line, for example
-- @replace-stuck-pod  statefulset personal/pg  pod pg-0 (uid 3f2a9c1e…, revision 9d647, not Ready) blocks rollout to revision d9d6d@.
podReplacementSummary :: PodReplacement -> Text
podReplacementSummary replacement =
  "replace-stuck-pod  statefulset "
    <> reviewed ^. #namespace
    <> "/"
    <> set'
    <> "  pod "
    <> reviewed ^. #pod
    <> " (uid "
    <> T.take 8 (physicalIdentityText (reviewed ^. #podUid))
    <> "…, revision "
    <> short (reviewed ^. #podRevision)
    <> ", not Ready) blocks rollout to revision "
    <> short (reviewed ^. #updateRevision)
  where
    reviewed = replacement ^. #stuck
    set' = case replacement ^. #target of
      Kubernetes _ _ _ _ name' -> nameText name'
      _ -> "?"
    -- A revision is named <statefulset>-<hash>.
    short revision = fromMaybe revision (T.stripPrefix (set' <> "-") revision)
