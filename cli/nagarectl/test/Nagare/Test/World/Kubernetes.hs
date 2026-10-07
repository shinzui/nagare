-- | EP-173, rebuilt by EP-182: the recovery model's Kubernetes world. The
-- model runs the production adapter ('kubernetesApplicationAdapter') against
-- a fake cluster ("Nagare.Test.World.Cluster") whose API server behaves as
-- RES-4 validated a real one does. The world never tells the adapter what an
-- object's state is: the production runtime reads rendered objects through
-- the production kubectl interpreter.
--
-- What the model's invariants read is the ground truth ('objects'): who owns
-- each member, which reviewed spec it carries, and whether that spec will
-- truly run, from the controllers' own state rather than from what the
-- status currently says.
module Nagare.Test.World.Kubernetes
  ( KubeObject (..)
  , KubeWorld (..)
  , Readiness (..)
  , objects
  , effectiveWrites
  , newKubeWorld
  , worldKubernetesAdapter
  )
where

import Control.Exception (finally)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (Adapter (..), PlannedOperation (plannedOperationId))
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (OperationId)
import Nagare.Resource.Inventory (ManagedResource)
import Nagare.Resource.Types
import Nagare.Test.World.Adversary (Adversary)
import Nagare.Test.World.ApiServer hiding (objects)
import Nagare.Test.World.Cluster
import Nagare.Test.World.Kinds (KindSemantics (..), ReadinessModel (..))

data Readiness
  = Ready
  | NotReady
  | FailedReadiness
  deriving stock (Eq, Show)

-- | One member's object as it truly is.
data KubeObject = KubeObject
  { uid :: !PhysicalIdentity
  , owner :: !(Maybe ResourceId)
  -- ^ The member its stamp names; 'Nothing' for an unstamped object.
  , nativeDigest :: !ContentDigest
  -- ^ The reviewed spec digest its stamp carries; for an unstamped object, a
  -- digest of what it holds.
  , readiness :: !Readiness
  -- ^ Whether its spec truly runs: the controllers' state, not the status.
  }
  deriving stock (Eq, Show)

-- | A fresh world in which the listed spec digests never become Ready.
newKubeWorld :: Set.Set ContentDigest -> IO (IORef KubeWorld)
newKubeWorld unready = newIORef (newWorld (emptyServer & #outcomes .~ Map.fromList [(digestText digest, Unready) | digest <- Set.toList unready]))

effectiveWrites :: KubeWorld -> Map.Map OperationId Int
effectiveWrites = (^. #writes)

-- | Every member object the cluster holds, by the member it belongs to: its
-- stamp, or, unstamped, the member whose address it occupies.
objects :: KubeWorld -> Map.Map ResourceId KubeObject
objects state =
  Map.fromList
    [ (resource, KubeObject physical stampedOwner digest (truth key stored))
    | (key, stored) <- Map.toList (server' ^. #objects)
    , Just physical <- [either (const Nothing) Just (mkPhysicalIdentity (stored ^. #uid))]
    , let rendered = fromMaybe Null (get False key server')
          stampedOwner = stampOwner rendered
    , Just resource <- [stampedOwner <|> Map.lookup key (state ^. #addresses)]
    , let digest = fromMaybe (contentDigest (TE.encodeUtf8 (T.pack (show (stored ^. #content))))) (specDigestOf rendered >>= either (const Nothing) Just . mkContentDigest)
    ]
  where
    server' = state ^. #server
    stampOwner rendered = case textAt' ["metadata", "annotations", "nagare.dev/resource-id"] rendered of
      Just text' -> either (const Nothing) Just (mkResourceId text')
      Nothing -> Nothing
    truth key stored
      | stored ^. #deleting = NotReady
      | otherwise = case (^. #readinessModel) <$> semanticsFor key of
          Just KnativeConditions
            | key ^. #kind == "service" && Map.member (key & #group .~ "") (server' ^. #objects) -> NotReady
            | otherwise -> fromOutcome (outcomeFor stored)
          Just DeploymentRollout -> fromOutcome (outcomeFor stored)
          Just JobTerminal -> case outcomeFor stored of
            Failed -> FailedReadiness
            other -> fromOutcome other
          Just StatefulSetRollout ->
            let replicas = maybe 1 round (numberAt ["spec", "replicas"] (stored ^. #content)) :: Int
                running = [pod | pod <- stored ^. #pods, pod ^. #ready]
             in if length running >= replicas && outcomeFor stored == Good then Ready else NotReady
          _ -> Ready
    outcomeFor stored = fromMaybe Good (Map.lookup (outcomeKey (stored ^. #content)) (server' ^. #outcomes))
    fromOutcome = \case
      Good -> Ready
      _ -> NotReady

-- | The application-scope adapter production runs, over the fake cluster. It
-- records each member's address, so an unstamped object at one is still
-- attributed to its member, and marks the reviewed operation whose write is
-- in flight, so effective writes count per operation (I4).
worldKubernetesAdapter ::
  ContextId ->
  Map.Map ResourceId (ManagedResource, ByteString) ->
  IORef KubeWorld ->
  IORef Adversary ->
  IO Adapter
worldKubernetesAdapter context specs worldRef adversaryRef = do
  modifyIORef' worldRef (#addresses %~ Map.union (Map.fromList [(key, resource) | (resource, (managed, _)) <- Map.toList specs, Just key <- [addressKey (managed ^. #address)]]))
  let base = clusterAdapter context (Cluster worldRef adversaryRef) specs
  pure
    base
      { adapterExecute = \operation prepared -> do
          modifyIORef' worldRef (#inFlight ?~ plannedOperationId operation)
          adapterExecute base operation prepared `finally` modifyIORef' worldRef (#inFlight .~ Nothing)
      }

addressKey :: ProviderAddress -> Maybe ObjectKey
addressKey = \case
  Kubernetes _ group kind namespace name -> Just (ObjectKey group (nameText kind) (nameText <$> namespace) (nameText name))
  _ -> Nothing

numberAt :: [Text] -> Value -> Maybe Double
numberAt path value = case foldl' (\v k -> case v of Object fields -> fromMaybe Null (KM.lookup (Key.fromText k) fields); _ -> Null) value path of
  Number n -> Just (realToFrac n)
  _ -> Nothing

textAt' :: [Text] -> Value -> Maybe Text
textAt' path value = case foldl' (\v k -> case v of Object fields -> fromMaybe Null (KM.lookup (Key.fromText k) fields); _ -> Null) value path of
  String text' -> Just text'
  _ -> Nothing
