-- | Exact native bytes of accepted and retained Kubernetes and Helm members,
-- recovered from digest-addressed observation bytes (MasterPlan 37: apart
-- from "Nagare.Inventory.Status" so the admin API's backup collector does not
-- link the adapters). A context whose observation bytes predate their own
-- publication needs the review decoder the CLI passes; without it a missing
-- member is an error naming @inventory store materialize-native@.
module Nagare.Inventory.AcceptedNative
  ( LegacyReviewNative
  , loadAcceptedNativeWith
  , loadObservedAcceptedNativeSelected
  , sameNativeBinding
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.BackendMap (compileContributedBackendMaps, compileContributedShomeiSettings)
import Nagare.Inventory.Components.Foundation (compileContributedNamespaces)
import Nagare.Inventory.ObservationNative
import Nagare.Inventory.Plan.Publication (loadPublishedReview)
import Nagare.Inventory.Plan.Types (InventoryHistory (..), ReviewBundle, historyDeclarations)
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Types

-- | The Kubernetes and Helm native members one published review recorded.
type LegacyReviewNative =
  ReviewBundle ->
  Either
    Text
    ( Map ResourceId (ManagedResource, ByteString)
    , Map ResourceId (ManagedResource, ByteString)
    )

-- | 'loadAcceptedNativeWith' for the selected accepted members, from
-- observation bytes alone.
loadObservedAcceptedNativeSelected ::
  Set.Set ResourceId ->
  InventoryStore ->
  InventoryHistory ->
  ValidatedInventory ->
  IO
    ( Either
        Text
        ( Map ResourceId (ManagedResource, ByteString)
        , Map ResourceId (ManagedResource, ByteString)
        )
    )
loadObservedAcceptedNativeSelected wanted = loadAcceptedNativeWith Nothing False (Just wanted)

loadAcceptedNativeWith ::
  Maybe LegacyReviewNative ->
  Bool ->
  Maybe (Set.Set ResourceId) ->
  InventoryStore ->
  InventoryHistory ->
  ValidatedInventory ->
  IO
    ( Either
        Text
        ( Map ResourceId (ManagedResource, ByteString)
        , Map ResourceId (ManagedResource, ByteString)
        )
    )
loadAcceptedNativeWith legacyReviews retainedOnly selection store history inventory
  | not (any needsNative relevantMembers) = pure (Right (Map.empty, Map.empty))
  | otherwise = do
      stored <- loadStored
      pure $ do
        (kubernetes, helm) <- stored
        generated <- generatedContributions
        pure (Map.union kubernetes generated, helm)
  where
    loadStored = do
      direct <- loadObservationNativeChecked store currentMembers
      case direct of
        Right native -> pure (Right (observationKubernetes native, observationHelm native))
        Left (ObservationNativeInvalid reason) -> pure (Left reason)
        Left (ObservationNativeMissing digest) -> case legacyReviews of
          Just fromReview -> legacy fromReview
          Nothing -> pure (Left ("observation native bytes are missing for " <> digestText digest <> "; run inventory store materialize-native to extract historical review evidence"))
    -- Contributed namespaces, the access backend map and Shomei settings are
    -- composed targets with a typed spec; no review stores their bytes, but the
    -- accepted or retained spec determines them exactly (F40).
    generatedContributions = do
      let historical =
            (if retainedOnly then [] else historyDeclarations history)
              <> [Managed old | (_, (_, old)) <- Map.toAscList (historyRetained history)]
      compiled <-
        Map.unions
          <$> sequence
            [ compileContributedNamespaces historical
            , compileContributedBackendMaps historical
            , compileContributedShomeiSettings historical
            ]
      pure (Map.filterWithKey (\resource (member, _) -> selected resource && current resource member) compiled)
    current resource member
      | Just (_, old) <- Map.lookup resource (historyRetained history) =
          old == member && (retainedOnly || Map.notMember resource desired)
      | otherwise = not retainedOnly && Map.lookup resource desired == Just member
    -- Accepted/retained declarations bind these bytes. They do not authorize
    -- an effect: apply/recovery still validates its original mutation envelope.
    selected resource = maybe True (Set.member resource) selection
    currentMembers =
      [ wanted
      | not retainedOnly
      , (resource, wanted) <- Map.toAscList desired
      , Map.lookup resource acceptedMembers == Just wanted
      , selected resource
      ]
        <> [ old
           | (resource, (_, old)) <- Map.toAscList (historyRetained history)
           , (retainedOnly || Map.notMember resource desired)
           , selected resource
           ]
    legacy fromReview = do
      snapshot <- readStoreSnapshot store
      case snapshot of
        Left failure -> pure (Left (T.pack (show failure)))
        Right state -> do
          loaded <- traverse (loadPublishedReview store) (Set.toAscList (storeSnapshotReviewDigests state))
          let result = do
                retained <- first (T.pack . show) (sequence loaded)
                entries <- traverse (collect fromReview) retained
                kubernetes <- agree (concatMap fst entries)
                helm <- agree (concatMap snd entries)
                pure (kubernetes, helm)
          case result of
            Left _ -> pure ()
            Right (kubernetes, helm) ->
              mapM_
                (cacheObservationBytes store . snd)
                (Map.elems kubernetes <> Map.elems helm)
          pure result
    relevantMembers =
      (if retainedOnly then [] else Map.elems desired)
        <> map snd (Map.elems (historyRetained history))
    needsNative member = member ^. #executor `elem` [KubernetesExecutor, HelmExecutor]
    -- A scope replacement need not republish native bytes for unchanged
    -- members. Digest-bound native bytes can still be recovered from an older
    -- immutable review and rebound to the current accepted declaration.
    acceptedMembers =
      Map.fromList
        [ (member ^. #identity, member)
        | (_, (_, scope)) <- Map.toList (historyAccepted history)
        , bundle <- scopeBundles scope
        , Managed member <- declarations bundle
        ]
    desired =
      Map.fromList
        [ (resource ^. #identity, resource)
        | Managed resource <- inventoryDeclarations inventory
        ]
    collect fromReview bundle = do
      let current member =
            if retainedOnly
              then retainedCurrent member
              else case activeCurrent member of
                Just acceptedMember -> Just acceptedMember
                Nothing | Map.notMember (member ^. #identity) desired -> retainedCurrent member
                Nothing -> Nothing
          activeCurrent member = case ( Map.lookup (member ^. #identity) acceptedMembers
                                      , Map.lookup (member ^. #identity) desired
                                      ) of
            (Just acceptedMember, Just wanted)
              | acceptedMember == wanted && sameNativeBinding member acceptedMember ->
                  Just acceptedMember
            _ -> Nothing
          retainedCurrent member = case Map.lookup (member ^. #identity) (historyRetained history) of
            Just (_, old) | sameNativeBinding member old -> Just old
            _ -> Nothing
      (kubernetes, helm) <- fromReview bundle
      pure
        ( [ (resource, (acceptedMember, bytes))
          | (resource, (member, bytes)) <- Map.toList kubernetes
          , Just acceptedMember <- [current member]
          , selected resource
          ]
        , [ (resource, (acceptedMember, bytes))
          | (resource, (member, bytes)) <- Map.toList helm
          , Just acceptedMember <- [current member]
          , selected resource
          ]
        )
    agree entries =
      traverse
        one
        ( Map.fromListWith
            (<>)
            [(resource, [native]) | (resource, native) <- entries]
        )
    one [] = Left "accepted resource has an empty native evidence group"
    one values@(firstValue : _)
      | all (== firstValue) values = Right firstValue
      | otherwise = Left "accepted reviews disagree on a resource's native bytes"

-- A digest in the desired specification binds the provider bytes even when
-- provenance, dependency order, or lifecycle metadata changes without a new
-- provider operation. A generated object without such a digest needs exact
-- declaration equality; otherwise its bytes could have changed invisibly.
sameNativeBinding :: ManagedResource -> ManagedResource -> Bool
sameNativeBinding earlier current =
  earlier == current
    || nativeHasDigest (current ^. #spec)
      && earlier ^. #identity == current ^. #identity
      && earlier ^. #owner == current ^. #owner
      && earlier ^. #executor == current ^. #executor
      && earlier ^. #address == current ^. #address
      && earlier ^. #spec == current ^. #spec
  where
    nativeHasDigest = \case
      NativeObject _ -> True
      KnativeService _ -> True
      Certificate _ _ -> True
      StatefulSet _ _ _ -> True
      HelmRelease _ _ -> True
      NamespaceSpec (Just _) -> True
      _ -> False
