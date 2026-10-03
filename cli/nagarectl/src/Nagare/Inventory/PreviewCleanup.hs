-- | Exact preview ownership and age selection for reviewed cleanup.
module Nagare.Inventory.PreviewCleanup
  ( previewCleanupServices
  , parsePreviewAge
  , eligiblePreviewCollections
  , previewCleanupRevisions
  , validatePreviewIncarnations
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime)
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter
import Nagare.Inventory.CollectionPolicy (supportsRetainedCollection)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Plan (InventoryHistory (..), PlanError (..))
import Nagare.Inventory.Site (sitePreviewRetirementScope)
import Nagare.Inventory.Status (consumersOf)
import Nagare.Inventory.Store (ScopeRevision (..), retainedOwner, retainedRevision)
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import Nagare.Resource.Wire (encodeCanonicalScope)

previewOwner :: ScopeId -> Bool
previewOwner owner = scopeKind owner == Standalone && "site-preview-" `T.isPrefixOf` nameText (scopeName owner)

-- A scope prefix narrows discovery only. The existing preview compiler's exact
-- address/policy contract must then account for every owned declaration.
previewCleanupServices :: Text -> ScopeSnapshot -> Either Text [ManagedResource]
previewCleanupServices namespace snapshot = traverse validate candidates
  where
    candidates =
      [ (scope, service, cluster, name)
      | (_, scope) <- Map.elems (snapshotScopes snapshot)
      , previewOwner (scopeId scope)
      , bundle <- scopeBundles scope
      , Managed service <- declarations bundle
      , Kubernetes cluster "serving.knative.dev" kind (Just ns) name <- [service ^. #address]
      , nameText kind == "service"
      , nameText ns == namespace
      ]
    validate (scope, service, cluster, name) = do
      let members = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle]
          domains =
            [ nameText host
            | member <- members
            , Kubernetes _ "serving.knative.dev" kind _ host <- [member ^. #address]
            , nameText kind == "domainmapping"
            ]
          claims =
            [ nameText claim
            | member <- members
            , Kubernetes _ "" kind _ claim <- [member ^. #address]
            , nameText kind == "persistentvolumeclaim"
            ]
      domain <- case domains of
        [one] -> Right one
        _ -> Left "preview cleanup requires exactly one accepted preview route"
      volumes <-
        traverse
          (maybe (Left "preview cleanup found a foreign volume address") Right . T.stripPrefix ("nagare-vol-" <> nameText name <> "-"))
          claims
      selected <- sitePreviewRetirementScope snapshot cluster (nameText name) namespace domain volumes
      unless (selected == scopeId scope) (Left "preview cleanup Service differs from its exact accepted owner")
      pure service

-- The native age is meaningful only for this exact Service incarnation.
-- Its UID must subsequently agree with the shared planner's fresh observation.
parsePreviewAge :: UTCTime -> Int -> ManagedResource -> ByteString -> Either Text (PhysicalIdentity, Bool)
parsePreviewAge now days service bytes = do
  unless (days >= 0) (Left "preview TTL must not be negative")
  (namespace, name) <- case service ^. #address of
    Kubernetes _ "serving.knative.dev" kind (Just ns) nativeName
      | nameText kind == "service" ->
          Right (nameText ns, nameText nativeName)
    _ -> Left "preview age requires a namespaced Knative Service"
  value <- first T.pack (eitherDecodeStrict' bytes)
  (uid, created) <-
    first T.pack $
      parseEither
        ( withObject "preview Service" $ \root -> do
            version <- root .: "apiVersion"
            kind <- root .: "kind"
            unless (version == ("serving.knative.dev/v1" :: Text) && kind == ("Service" :: Text)) (fail "unexpected preview native kind")
            metadata <- root .: "metadata"
            actualName <- metadata .: "name"
            actualNamespace <- metadata .: "namespace"
            unless (actualName == name && actualNamespace == namespace) (fail "preview native address differs from accepted ownership")
            physical <- metadata .: "uid" >>= either (fail . T.unpack) pure . mkPhysicalIdentity
            created <- metadata .: "creationTimestamp"
            pure (physical, created)
        )
        value
  unless (created <= now) (Left "preview creation time is in the future")
  pure (uid, diffUTCTime now created > fromIntegral days * 86400)

-- Structural screening is not native evidence: the normal collection planner
-- still observes and binds every selected retained incarnation before review.
previewCleanupRevisions :: Text -> InventoryHistory -> [(ScopeId, ScopeRevision)]
previewCleanupRevisions namespace history =
  Set.toAscList
    ( Set.fromList
        [ (retainedOwner incarnation, retainedRevision incarnation)
        | (incarnation, resource) <- Map.elems (historyRetained history)
        , previewOwner (retainedOwner incarnation)
        , Kubernetes _ _ _ (Just ns) _ <- [resource ^. #address]
        , nameText ns == namespace
        ]
    )

eligiblePreviewCollections :: Text -> InventoryHistory -> ValidatedInventory -> Map.Map (ScopeId, ScopeRevision) ScopeDeclaration -> Either Text [ResourceId]
eligiblePreviewCollections namespace history inventory originals = do
  checked <- Map.fromList <$> traverse validateOriginal (previewCleanupRevisions namespace history)
  pure
    [ resource ^. #identity
    | (incarnation, resource) <- Map.elems (historyRetained history)
    , previewOwner (retainedOwner incarnation)
    , resource ^. #owner == retainedOwner incarnation
    , Just original <- [Map.lookup (retainedOwner incarnation, retainedRevision incarnation) checked]
    , resource `elem` [member | bundle <- scopeBundles original, Managed member <- declarations bundle]
    , supportsRetainedCollection resource
    , Kubernetes _ _ _ (Just ns) _ <- [resource ^. #address]
    , nameText ns == namespace
    , Set.notMember (resource ^. #identity) active
    , null (consumersOf history inventory (resource ^. #identity))
    ]
  where
    active = Set.fromList (map declarationId (inventoryDeclarations inventory))
    validateOriginal key@(owner, revision) = do
      scope <- maybe (Left "retained preview original scope evidence is missing") Right (Map.lookup key originals)
      unless
        (scopeId scope == owner && contentDigest (encodeCanonicalScope scope) == revisionDigest revision)
        (Left "retained preview original scope identity or digest differs")
      snapshot <- first (T.pack . show) (mkScopeSnapshot (inventoryBinding inventory) (Map.singleton owner (revisionGeneration revision, scope)) Map.empty)
      services <- previewCleanupServices namespace snapshot
      unless (length services == 1) (Left "retained cleanup owner does not have an original complete preview contract")
      pure (key, scope)

validatePreviewIncarnations :: Map.Map ResourceId PhysicalIdentity -> ObservationSet -> Either (NonEmpty PlanError) ()
validatePreviewIncarnations expected observed = case [ resource
                                                     | (resource, uid) <- Map.toAscList expected
                                                     , Map.lookup resource (observationMap observed) /= Just (ObservedPresent uid)
                                                     ] of
  [] -> Right ()
  changed -> Left (PlanError "preview-age-incarnation" "preview age evidence no longer matches a present accepted Service incarnation" changed :| [])
