-- Offline design spike, NOT a production index or admission path.
module Main where

import Prelude
import Control.Monad
import Data.Aeson (object, toJSON, (.=), eitherDecodeStrict')
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Control.Lens ((^.), (&), (.~))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Adapters.Helm
import Nagare.Inventory.Components.Observability
import Nagare.Inventory.Digest
import Nagare.Inventory.Kubernetes
import Nagare.Inventory.KubernetesReview
import Nagare.Inventory.HelmReview
import Nagare.Inventory.Plan
import Nagare.Inventory.Status (sameNativeBinding)
import Nagare.Inventory.Store
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)
import OperationalHelpers (fakeObjectOps, ok, must)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnv)

binding = ContextBinding (ok (mkContextId "evidence-spike")) (name "project")
name = ok . mkName
scope = ok (mkScopeId Platform "evidence")
rid key = mintResourceId scope (ok (mkLogicalKey key)) (name "resource")
fixtureCluster = rid "cluster"
kube key physical = ok (bindKubernetesObject (KubernetesInput
  (rid key) scope fixtureCluster value (contentDigest bytes) Retain Stateless Private
  (SourceLocation "fixture.yaml" "document[0]")))
  where
    value = object ["apiVersion" .= ("v1" :: T.Text), "kind" .= ("ConfigMap" :: T.Text),
      "metadata" .= object ["name" .= physical, "namespace" .= ("personal" :: T.Text)]]
    bytes = ok (canonicalValue value)
helm = ok (compileRenderedRelease ObservabilityReleaseInput
  { releaseId = rid "helm", releaseOwner = scope, releaseCluster = fixtureCluster
  , releaseNamespace = name "monitoring", releaseName = name "metrics"
  , releaseChartPath = "fixture.tgz", releaseChartBytes = "pinned chart"
  , releaseValuesPath = "values.yaml", releaseValuesBytes = "pinned values"
  , releaseRenderedBytes = "apiVersion: v1\nkind: Service\nmetadata:\n  name: metrics\n"
  , releaseCrdsBytes = Nothing, releaseKubeVersion = "v1.32.0"
  , releaseHelmVersion = "v4.2.4", releaseApiVersions = [], releaseDependencies = [] })

-- Candidate lookup key; actual authority is the caller's accepted/retained
-- declaration and the original immutable review, never this sidecar.
lookupName context member = ObjectName ("prototype-evidence/" <> digestText (contentDigest bytes))
  where
    digestBound = case member ^. #spec of
      NativeObject _ -> True
      KnativeService _ -> True
      Certificate _ _ -> True
      StatefulSet _ _ _ -> True
      HelmRelease _ _ -> True
      NamespaceSpec (Just _) -> True
      _ -> False
    normalized = if digestBound then object
      ["identity" .= (member ^. #identity), "owner" .= (member ^. #owner),
       "executor" .= (member ^. #executor), "address" .= (member ^. #address),
       "spec" .= (member ^. #spec)] else toJSON member
    bytes = ok (canonicalValue (object ["context" .= context, "binding" .= normalized]))

prepare store physical width = do
  let kubes = Map.fromList [(m ^. #identity, (m,b)) | (m,b) <-
        kube "selected" physical : [kube ("sibling-" <> T.pack (show n)) ("sibling-" <> T.pack (show n)) | n <- [1..width]]]
      helms = Map.singleton (rid "helm") helm
      registry = ok (mkAdapterRegistry
        [mkKubernetesAdapter kubes KubernetesAdapterOps
          {kubernetesContext = binding ^. #identity,
           kubernetesObserve = \_ -> pure (KubernetesAbsent (contentDigest "absent")),
           kubernetesMutateConditional = \_ -> error "prototype must never mutate"},
         mkHelmAdapter helms HelmAdapterOps
          {helmObserve = \_ -> pure (HelmAbsent (contentDigest "absent")),
           helmMutateConditional = \_ -> error "prototype must never mutate"}])
      declared = ok (mkScopeDeclaration scope [ResourceBundle
        [Managed m | (m,_) <- Map.elems kubes <> Map.elems helms] [] [] [] [] []])
      candidate = ok (composeInventory (ok (mkScopeSnapshot binding Map.empty Map.empty)) (ReplaceScope declared :| []))
      observed = ok (observationSet [(r,ConfirmedAbsent (contentDigest "absent")) | r <- Map.keys kubes <> Map.keys helms])
  history <- must (loadInventoryHistory store)
  before <- must (readStoreSnapshot store)
  bundle <- must (prepareReview registry before (ok (planChanges candidate noLifecycleDecisions history observed)))
  void (must (publishReview store bundle))
  pure bundle

members bundle = Map.union (ok (kubernetesSpecsFromReview bundle)) (ok (helmSpecsFromReview bundle))
indexBundle ops bundle = forM_ (Map.elems (members bundle)) $ \(member,_) -> do
  result <- putObject ops IfAbsent (lookupName (reviewContextBinding (reviewBundleDocument bundle)) member)
    (ok (canonicalValue (toJSON (reviewDigest bundle))))
  case result of
    PutWritten _ -> pure ()
    PutPreconditionFailed -> pure () -- spike only; production must verify existing witness
    other -> error (show other)

-- Deliberately reuse the complete production loader/reconstructors. Count how
-- much work a review-level pointer actually performs before choosing a format.
selected = selectedWith False

-- Diagnostic projection only. The original document is verified before making
-- a temporary view for the actual reconstructors. Never admit this view: it is
-- not an original ReviewBundle, and this spike covers unfenced direct natives.
loadProjection store digest wanted = do
  raw <- must (readObject store (reviewKey digest))
  case raw of
    Nothing -> pure (Left "original review missing")
    Just bytes -> case eitherDecodeStrict' bytes of
      Left err -> pure (Left err)
      Right doc | encodeReviewDocument doc /= bytes || contentDigest bytes /= digest ->
        pure (Left "original review digest/canonical encoding mismatch")
      Right doc -> do
        let ids = Set.fromList [m ^. #identity | m <- wanted]
            operations = filter (any (`Set.member` ids) . plannedResources . reviewPlannedOperation) (reviewOperations doc)
            private = Set.toList (Set.fromList [d | o <- operations, Just d <- [reviewNativeDigest o]])
            scopes = [revisionDigest r | r <- Map.elems (reviewDesiredRevisions doc)]
            readRequired category d = do
              r <- readObject store (objectKeyFor category d)
              pure $ case r of
                Left err -> Left (show err)
                Right Nothing -> Left "selected projection member missing"
                Right (Just b) | contentDigest b == d -> Right (d,b)
                _ -> Left "selected projection digest mismatch"
        scopeResults <- traverse (readRequired "scopes") scopes
        nativeResults <- traverse (readRequired "native") private
        pure (ReviewBundle (doc {reviewOperations = operations})
          <$> (Map.fromList <$> sequence scopeResults)
          <*> (Map.fromList <$> sequence nativeResults))

selectedWith narrow ops store context wanted = do
  pointers <- forM wanted $ \member -> getObject ops (lookupName context member) >>= \case
    ObjectFound _ bytes -> pure (eitherDecodeStrict' bytes)
    ObjectAbsent -> pure (Left "selected evidence index missing; explicit rebuild required")
    other -> pure (Left (show other))
  case sequence pointers of
    Left err -> pure (Left err)
    Right digests -> do
      bundles <- forM (Set.toAscList (Set.fromList digests)) $ \d ->
        if narrow then loadProjection store d wanted
        else either (Left . show) Right <$> loadPublishedReview store d
      pure $ do
        loaded <- sequence bundles
        unless (all ((== context) . reviewContextBinding . reviewBundleDocument) loaded)
          (Left "selected review context mismatch")
        -- Both real reconstructors validate every operation in each chosen bundle.
        pairs <- traverse (\b -> (,) <$> either (Left . T.unpack) Right (kubernetesSpecsFromReview b)
                                    <*> either (Left . T.unpack) Right (helmSpecsFromReview b)) loaded
        let candidates = concatMap (\(k,h) -> Map.elems k <> Map.elems h) pairs
        result <- forM wanted $ \current -> case [bytes | (old,bytes) <- candidates, sameNativeBinding old current] of
          [] -> Left "selected review does not prove requested native binding"
          first:rest | all (== first) rest -> Right (current,first)
          _ -> Left "selected reviews disagree"
        pure (result, sum [Map.size (reviewBundleNative b) | b <- loaded])

assert label value = unless value (error ("FAILED: " <> label))
expectLeft label action = do
  result <- action
  case result of
    Left err -> print (label, "refused", err)
    Right _ -> error ("unexpected success: " <> label)

onlyDigest bundle resource = case [d | o <- reviewOperations (reviewBundleDocument bundle),
  resource `elem` plannedResources (reviewPlannedOperation o), Just d <- [reviewNativeDigest o]] of
    [d] -> d
    other -> error ("fixture needs exactly one native operation: " <> show other)

main = do
  cache <- getEnv "MP23_CACHE"
  forM_ [(width,noise) | width <- [0,50], noise <- [0,500]] $ \(width,noise) -> do
    base <- fakeObjectOps
    gets <- newIORef ([] :: [ObjectName])
    lists <- newIORef (0 :: Int)
    let ops = base {getObject = \n -> modifyIORef' gets (n:) >> getObject base n,
                    listObjects = \n -> modifyIORef' lists (+1) >> listObjects base n}
    publisher <- must (newObjectStore ops binding "publisher" Nothing)
    void (must (initializeStore publisher binding "publisher"))
    bundle <- prepare publisher ("current" :: T.Text) width
    indexBundle ops bundle
    forM_ [1..noise] $ \n -> do
      let doc = ReviewDocument 1 binding n 0 Map.empty Map.empty (contentDigest "noise") "spike" "1" [] [] Map.empty Map.empty Map.empty
          bytes = encodeReviewDocument doc
      void (must (publishIfAbsent publisher (reviewKey (contentDigest bytes)) bytes))
    -- This invalid review is deliberately irrelevant to both selected bindings.
    void (must (publishIfAbsent publisher (reviewKey (contentDigest "{}")) "{}"))
    let selectedMember = fst (kube "selected" ("current" :: T.Text))
        wanted = [selectedMember, fst helm]
        path = cache <> "/native-" <> show width <> "-" <> show noise
    createDirectoryIfMissing True path
    reader <- must (newObjectStore ops binding "reader" (Just path))
    forM_ ["cold","warm"] $ \phase -> do
      writeIORef gets []; writeIORef lists 0
      (found,decoded) <- must (selected ops reader binding wanted)
      assert "exact Kubernetes and Helm bytes" (found == [kube "selected" ("current" :: T.Text),helm])
      calls <- readIORef gets; listed <- readIORef lists
      print ("lookup", width, noise, phase, "gets",length calls,"lists",listed,"reconstructed-members",decoded)
      assert "no historical review list" (listed == 0)
    let projectedPath = path <> "-projected"
    createDirectoryIfMissing True projectedPath
    projectedReader <- must (newObjectStore ops binding "projected-reader" (Just projectedPath))
    forM_ [("cold",6),("warm",2)] $ \(phase,expectedReads) -> do
      writeIORef gets []; writeIORef lists 0
      (projected, projectedDecodes) <- must (selectedWith True ops projectedReader binding wanted)
      projectionReads <- length <$> readIORef gets
      assert "projection exact bytes and fixed private reconstruction" (projected == [kube "selected" ("current" :: T.Text),helm] && projectedDecodes == 2 && projectionReads == expectedReads)
      print ("projection",width,noise,phase,"gets",projectionReads,"reconstructed-private-members",projectedDecodes,
             "original-review-and-scope-bytes",BS.length (encodeReviewDocument (reviewBundleDocument bundle)) + sum (map BS.length (Map.elems (reviewBundleScopes bundle))))
    writeIORef gets []
    void (must (selectedWith True ops projectedReader binding []))
    emptyGets <- readIORef gets
    assert "empty projection does no IO" (null emptyGets)
    let moved = selectedMember & #source .~ SourceLocation "moved/Config.hs" "document[7]"
    (rebound,_) <- must (selected ops reader binding [moved])
    assert "scope metadata only rebinds" (rebound == [(moved,snd (kube "selected" ("current" :: T.Text)))])
    (projectedRebound,_) <- must (selectedWith True ops reader binding [moved])
    assert "projection metadata-only rebind" (projectedRebound == rebound)
    print ("metadata-only",width,noise,"same lookup key and exact native bytes")
    when (width == 0 && noise == 0) $ do
      old <- prepare publisher ("retained-old" :: T.Text) 0
      indexBundle ops old
      let retained = fst (kube "selected" ("retained-old" :: T.Text))
      (found,_) <- must (selected ops publisher binding [selectedMember,retained])
      assert "two incarnations of one ID" (found == [kube "selected" ("current" :: T.Text),kube "selected" ("retained-old" :: T.Text)])
      (projectedRetained,_) <- must (selectedWith True ops publisher binding [selectedMember,retained])
      assert "projection distinct incarnations" (projectedRetained == found)
      print ("retained-and-current", "same resource ID; distinct correct bytes")
      -- Stop publication between the original review and its derived sidecar.
      crash <- prepare publisher ("crash-window" :: T.Text) 0
      expectLeft "publication interrupted before index" (selected ops publisher binding [fst (kube "selected" ("crash-window" :: T.Text))])
      indexBundle ops crash
      void (must (selected ops publisher binding [fst (kube "selected" ("crash-window" :: T.Text))]))
      print ("publication retry", "explicit sidecar completion restores lookup")
      let poisoned = ops {getObject = \n -> if n == lookupName binding (selectedMember)
            then pure (ObjectFound (Generation 999) (ok (canonicalValue (toJSON (reviewDigest old)))))
            else getObject ops n}
      expectLeft "wrong incarnation pointer" (selected poisoned publisher binding [selectedMember])
      let foreignContext = ContextBinding (ok (mkContextId "other")) (name "project")
          crossContext = ops {getObject = \_ -> pure (ObjectFound (Generation 999) (ok (canonicalValue (toJSON (reviewDigest bundle)))))}
      expectLeft "cross context pointer" (selected crossContext publisher foreignContext [selectedMember])
      let selectedDigest = onlyDigest bundle (rid "selected")
          privateName = ObjectName ("native/" <> digestText selectedDigest <> ".json")
          corrupt = ops {getObject = \n -> if n == privateName then pure (ObjectFound (Generation 999) "{}") else getObject ops n}
      corruptedStore <- must (newObjectStore corrupt binding "corrupt-reader" Nothing)
      expectLeft "changed selected private member" (selected ops corruptedStore binding [selectedMember])
      let missingSelected = ops {getObject = \n -> if n == privateName then pure ObjectAbsent else getObject ops n}
      missingStore <- must (newObjectStore missingSelected binding "missing-selected-reader" Nothing)
      expectLeft "missing selected private member" (selected ops missingStore binding [selectedMember])
      expectLeft "projection wrong incarnation" (selectedWith True poisoned publisher binding [selectedMember])
      expectLeft "projection cross context" (selectedWith True crossContext publisher foreignContext [selectedMember])
      expectLeft "projection corrupt selected member" (selectedWith True ops corruptedStore binding [selectedMember])
      expectLeft "projection missing selected member" (selectedWith True ops missingStore binding [selectedMember])
    when (width == 50 && noise == 0) $ do
      let siblingDigest = onlyDigest bundle (rid "sibling-1")
          missing = ops {getObject = \n -> if n == ObjectName ("native/" <> digestText siblingDigest <> ".json")
                          then pure ObjectAbsent else getObject ops n}
      broken <- must (newObjectStore missing binding "missing-reader" Nothing)
      expectLeft "unselected sibling member missing" (selected ops broken binding [selectedMember])
      (isolated,decoded) <- must (selectedWith True ops broken binding [selectedMember])
      assert "projection ignores missing sibling" (isolated == [kube "selected" ("current" :: T.Text)] && decoded == 1)
      print ("projection missing unselected sibling", "selected bytes reconstructed successfully")
  print ("all prototype assertions", "passed; review-level pointer still expands siblings")
