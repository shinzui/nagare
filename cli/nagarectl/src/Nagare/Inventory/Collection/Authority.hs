-- | Review-bound controller collection. An observed graph is evidence, not an
-- atomic Kubernetes graph transaction. The grant covers the parent's exclusive
-- controller descendants; preflight rejects changed evidence before submission.
module Nagare.Inventory.Collection.Authority
  ( CollectionNode (..)
  , CollectionAuthority (..)
  , parseCollectionNode
  , authorizeCollection
  , checkCollectionBefore
  , checkCollectionComplete
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))

data CollectionNode = CollectionNode
  { token :: !Text
  , namespace :: !Text
  , name :: !Text
  , uid :: !Text
  , version :: !Text
  , kind :: !Text
  , owners :: ![Text]
  , controllers :: ![Text]
  , inventoryOwner :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CollectionAuthority = CollectionAuthority
  { parent :: !CollectionNode
  , apiResources :: ![Text]
  , descendants :: ![CollectionNode]
  , protected :: ![CollectionNode]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- Only metadata is retained. No Secret data, Pod environment or service data
-- belongs in the collection authority or its public summary.
parseCollectionNode :: Text -> Value -> Either Text (Maybe CollectionNode)
parseCollectionNode resource =
  first T.pack
    . parseEither
      ( withObject "collection object" $ \o -> do
          k <- o .: "kind"
          meta <- o .: "metadata"
          withObject
            "metadata"
            ( \m -> do
                identity <- m .:? "uid"
                annotations <- m .:? "annotations" .!= KM.empty
                owned <- annotations .:? "nagare.dev/resource-id"
                refs <- m .:? "ownerReferences" .!= []
                ownerIds <- traverse (withObject "ownerReference" (.: "uid")) refs
                controllerIds <-
                  fmap concat $
                    traverse
                      ( withObject "ownerReference" $ \r -> do
                          active <- r .:? "controller" .!= False
                          if active then (: []) <$> r .: "uid" else pure []
                      )
                      refs
                case identity of
                  -- Only the known non-persisted API may omit a UID. Treating
                  -- every ownerless object as a projection silently drops
                  -- incomplete persisted/protected evidence from the review.
                  Nothing
                    | resource == "pods.metrics.k8s.io"
                    , k == "PodMetrics"
                    , null ownerIds
                    , owned == Nothing ->
                        pure Nothing
                  Nothing -> fail "persisted or owned collection object lacks UID"
                  Just ident -> do
                    ns <- m .: "namespace"
                    n <- m .: "name"
                    rv <- m .: "resourceVersion"
                    unless (all (not . T.null) [resource, ns, n, ident, rv]) (fail "empty collection identity")
                    pure (Just (CollectionNode resource ns n ident rv k (sort ownerIds) (sort controllerIds) owned))
            )
            meta
      )

addressKey :: CollectionNode -> (Text, Text, Text)
addressKey n = (token n, namespace n, name n)

stable :: CollectionNode -> CollectionNode
stable n = n {version = ""}

sameGraph :: [CollectionNode] -> [CollectionNode] -> Bool
sameGraph a b =
  Map.fromList [(addressKey n, stable n) | n <- a]
    == Map.fromList [(addressKey n, stable n) | n <- b]

validateNodes :: [CollectionNode] -> Either Text ()
validateNodes nodes = do
  unless
    ( all
        ( \n ->
            all (not . T.null) [token n, namespace n, name n, uid n, version n, kind n]
              && all (not . T.null) (owners n <> controllers n)
              && all (`elem` owners n) (controllers n)
        )
        nodes
    )
    (Left "invalid collection identity or owner references")
  unless (length nodes == Set.size (Set.fromList (map uid nodes))) (Left "duplicate observed UID")
  unless (length nodes == Set.size (Set.fromList (map addressKey nodes))) (Left "duplicate observed address")

closure :: Set.Set Text -> [CollectionNode] -> [CollectionNode]
closure roots nodes = go roots
  where
    go seen =
      let next = Set.union seen (Set.fromList [uid n | n <- nodes, any (`Set.member` seen) (owners n)])
       in if next == seen
            then [n | n <- nodes, Set.member (uid n) seen, Set.notMember (uid n) roots]
            else go next

-- A finite supported stateless contract. An infrastructure upgrade introducing
-- another kind requires an explicit policy and native contract check.
allowed :: CollectionNode -> Bool
allowed n =
  (token n, kind n)
    `elem` [ ("configurations.serving.knative.dev", "Configuration")
           , ("routes.serving.knative.dev", "Route")
           , ("revisions.serving.knative.dev", "Revision")
           , ("deployments.apps", "Deployment")
           , ("replicasets.apps", "ReplicaSet")
           , ("pods", "Pod")
           , ("services", "Service")
           , ("endpoints", "Endpoints")
           , ("endpointslices.discovery.k8s.io", "EndpointSlice")
           , ("images.caching.internal.knative.dev", "Image")
           , ("ingresses.networking.internal.knative.dev", "Ingress")
           , ("podautoscalers.autoscaling.internal.knative.dev", "PodAutoscaler")
           , ("metrics.autoscaling.internal.knative.dev", "Metric")
           , ("serverlessservices.networking.internal.knative.dev", "ServerlessService")
           ]

authorizeCollection :: CollectionNode -> [Text] -> [CollectionNode] -> Either Text CollectionAuthority
authorizeCollection root apis nodes = do
  validateNodes nodes
  unless
    (not (null apis) && length apis == Set.size (Set.fromList apis) && all ((`elem` apis) . token) nodes)
    (Left "collection API coverage is incomplete or duplicated")
  unless (token root == "services.serving.knative.dev" && kind root == "Service") (Left "controller collection requires a Knative Service")
  unless (root `elem` nodes) (Left "reviewed parent differs from complete namespace observation")
  let children = closure (Set.singleton (uid root)) nodes
      members = Set.fromList (uid root : map uid children)
      preserved = [n | n <- nodes, Set.notMember (uid n) members, inventoryOwner n /= Nothing]
  unless
    ( all
        ( \n ->
            namespace n == namespace root
              && allowed n
              && inventoryOwner n == Nothing
              && case (owners n, controllers n) of ([owner], [controller]) -> owner == controller && Set.member owner members; _ -> False
        )
        children
    )
    (Left "descendant is unsupported, independently managed, cross-namespace, or has shared/non-controller ownership")
  pure (CollectionAuthority root (sort apis) children preserved)

checkCollectionBefore :: CollectionAuthority -> [Text] -> [CollectionNode] -> Either Text ()
checkCollectionBefore authority apis nodes = do
  current <- authorizeCollection (parent authority) apis nodes
  unless
    ( apiResources current == apiResources authority
        && sameGraph (descendants current) (descendants authority)
        && sameGraph (protected authority) [n | n <- protected current, addressKey n `elem` map addressKey (protected authority)]
    )
    (Left "collection graph, protected objects, or API discovery changed since review")

checkCollectionComplete :: CollectionAuthority -> [Text] -> [CollectionNode] -> Either Text ()
checkCollectionComplete authority apis nodes = do
  validateNodes nodes
  unless (sort apis == apiResources authority) (Left "collection API discovery changed")
  let targets = parent authority : descendants authority
      addresses = Set.fromList (map addressKey targets)
      ids = Set.fromList (map uid targets)
      observedTargets = [n | n <- nodes, Set.member (addressKey n) addresses || Set.member (uid n) ids]
      newChildren = closure ids nodes
  unless (null observedTargets && null newChildren) (Left "parent or reviewed/new descendants remain present or were replaced")
  let expected = protected authority
      observed = [n | n <- nodes, addressKey n `elem` map addressKey expected]
  unless (sameGraph expected observed) (Left "protected namespace identity or ownership changed during collection")
