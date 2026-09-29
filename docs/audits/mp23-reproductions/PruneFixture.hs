-- Synthetic already-admitted history; production CLI remains unmodified.
module Main where
import Prelude
import Control.Monad
import Control.Lens ((^.))
import Data.Aeson (Value,object,toJSON,(.=),eitherDecodeStrict')
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import System.Environment (getEnv, lookupEnv)
import Data.Maybe (fromMaybe)
import Nagare.Cluster.GcsJob (StoreBackend(..),MinioRef(..))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Kubernetes
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Inventory.Execute qualified as E
import Nagare.Inventory.Journal
import Nagare.Inventory.Digest
import Nagare.Inventory.ScheduledPrune
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes
import Nagare.Resource.Types
import Nagare.Resource.Policy
import Nagare.Resource.Wire
import OperationalHelpers (ok)

must action = action >>= either (ioError . userError . show) pure
name = ok . mkName
fixtureOwner token = ok (mkScopeId Standalone token)
rid o key = mintResourceId o (ok (mkLogicalKey key)) (name "resource")
clusterId' = rid (fixtureOwner "cluster") "cluster"
member o key value = ok (bindKubernetesObject (KubernetesInput (rid o key) o clusterId' value
  (contentDigest (ok (canonicalValue value))) Retain Stateless Private (SourceLocation "fixture" key)))
registry binding native present = ok (mkAdapterRegistry [mkKubernetesAdapter native KubernetesAdapterOps
  { kubernetesContext = binding ^. #identity
  , kubernetesObserve = \r -> pure $ if present r
      then let (_,bytes)=native Map.! r in KubernetesPresent (ok (mkPhysicalIdentity "ingestion-uid")) "7" (Just r) (contentDigest bytes)
      else KubernetesAbsent (contentDigest (TE.encodeUtf8 (resourceIdText r <> ":absent")))
  , kubernetesMutateConditional = \_ -> error "fixture generation cannot mutate a provider" }])
prepare binding store candidate native present = do
  history <- must (loadInventoryHistory store)
  facts <- must (observeWithRegistry (registry binding native present) (requirementsByExecutor (observationRequirements candidate history)))
  before <- must (readStoreSnapshot store)
  bundle <- must (prepareReview (registry binding native present) before (ok (planChanges candidate noLifecycleDecisions history facts)))
  void (must (publishReview store bundle))
  pure bundle
main = do
  root <- getEnv "MP23_PRUNE_ROOT"
  project <- T.pack . fromMaybe "project" <$> lookupEnv "MP23_PRUNE_PROJECT"
  let binding = ContextBinding (ok (mkContextId "prune-spike")) (name project)
  store <- must (openFilesystemStore (root<>"/state/nagare/prune-spike/inventory"))
  initial <- must (initializeStore store binding "prune-spike")
  let backupOwner=fixtureOwner "backup"; policyOwner=fixtureOwner "policy"
      runId="11111111-1111-1111-1111-111111111111"
      objectUrl="s3://bucket/databases/notes/"<>runId<>".sql.gz"
      receiptUrl=objectUrl<>".receipt.json"
      backupMember=member backupOwner "ingestion" (object
        ["apiVersion" .= ("batch/v1"::T.Text),"kind" .= ("Job"::T.Text),
         "metadata" .= object ["name" .= ("ingestion"::T.Text),"namespace" .= ("default"::T.Text)],
         "spec" .= object ["template" .= object ["spec" .= object
           ["restartPolicy" .= ("Never"::T.Text),"containers" .= [object ["name" .= ("upload"::T.Text),"image" .= ("fixture.invalid/ingest:pinned"::T.Text)]]]]]])
      policyMember=member policyOwner "policy" (object ["apiVersion" .= ("v1"::T.Text),"kind" .= ("ConfigMap"::T.Text),
        "metadata" .= object ["name" .= ("policy"::T.Text),"namespace" .= ("default"::T.Text)]])
      declared o m=ok (mkScopeDeclaration o [ResourceBundle [Managed (fst m)] [] [] [] [] []])
      fields=Map.fromList [("scheduled.backup.source.scope",scopeIdText policyOwner),
        ("scheduled.backup.source.generation","1"),("scheduled.backup.source.revision",digestText (contentDigest (encodeCanonicalScope policy))),
        ("scheduled.backup.source.statefulset",resourceIdText (rid policyOwner "statefulset")),
        ("scheduled.backup.source.pvc",resourceIdText (rid policyOwner "pvc")),
        ("scheduled.backup.schedule",resourceIdText (rid policyOwner "cronjob")),
        ("scheduled.backup.signing",resourceIdText (rid policyOwner "signing")),("scheduled.backup.id",runId),
        ("scheduled.backup.object",objectUrl),("scheduled.backup.object.version","17"),("scheduled.backup.object.length","123"),
        ("scheduled.backup.object.sha256",T.replicate 64 "a"),("scheduled.backup.receipt",receiptUrl),
        ("scheduled.backup.receipt.version","19"),("scheduled.backup.receipt.length","456"),("scheduled.backup.receipt.digest",T.replicate 64 "b")]
      backup=withScopeOverrides fields (declared backupOwner backupMember)
      policy=declared policyOwner policyMember
      sourceNative=Map.fromList [(fst backupMember ^. #identity,backupMember),(fst policyMember ^. #identity,policyMember)]
      initialCandidate=ok (composeInventory (ok (mkScopeSnapshot binding Map.empty Map.empty)) (ReplaceScope backup :| [ReplaceScope policy]))
  sourceReview <- prepare binding store initialCandidate sourceNative (const False)
  let revisions=reviewDesiredRevisions (reviewBundleDocument sourceReview)
  must (replaceHeadIfGenerationMatches store (Just (headGeneration initial)) initial
    {headGeneration=headGeneration initial+1,headAccepted=revisions,headConverged=revisions})
  let request=ScheduledPruneRequest "notes" "default"
        (ScheduledPruneCandidate backupOwner runId objectUrl "17" 123 (T.replicate 64 "a") receiptUrl "19" 456 (T.replicate 64 "b") (read "2026-09-29 00:00:00 UTC"::UTCTime))
        (revisions Map.! backupOwner) (ok (mkPhysicalIdentity "ingestion-uid")) policyOwner (revisions Map.! policyOwner) 7
        (MinioBackend (MinioRef "http://minio.invalid:9000" "bucket" "minio-credentials")) (SourceLocation "fixture" "scheduled-prune")
      (prune,native)=ok (compileScheduledPruneScope request backup sourceNative)
      accepted=Map.fromList [(backupOwner,(revisionGeneration (revisions Map.! backupOwner),backup)),(policyOwner,(revisionGeneration (revisions Map.! policyOwner),policy))]
      candidate=ok (composeInventory (ok (mkScopeSnapshot binding accepted Map.empty)) (ReplaceScope prune :| []))
  bundle <- prepare binding store candidate (Map.union native sourceNative) (`Map.member` sourceNative)
  void (must (writeReviewBundle (root<>"/review") bundle))
  let document=reviewBundleDocument bundle
      tx=ok (mkTransactionId ("tx-"<>digestText (reviewDigest bundle)))
      operations=map reviewPlannedOperation (reviewOperations document)
      selectedOp=case [o | o<-operations,plannedAction o==CreateResource] of [o]->o; _->error "expected one prune Job create"
      operation=plannedOperationId selectedOp
  current <- must (readHead store) >>= maybe (error "missing head") pure
  must (replaceHeadIfGenerationMatches store (Just (headGeneration current)) current
    {headGeneration=headGeneration current+1,headAccepted=reviewDesiredRevisions document,
     headActiveTransaction=Just (transactionIdText tx),headExecutorClaim=Just (ExecutorClaim (transactionIdText tx) "prune-spike" 1 "fixture")})
  written <- withProcessLock store $ \locked -> do
    void (must (E.appendEvent locked tx Nothing Pending ("admitted review "<>digestText (reviewDigest bundle))))
    void (must (E.appendEvent locked tx (Just operation) IntentRecorded "synthetic historical intent"))
    void (must (E.appendEvent locked tx (Just operation) Ambiguous "synthetic lost acknowledgement"))
  void (pure (ok written))
  let decision=object ["version" .= (1::Int),"transaction" .= tx,"operation" .= operation,
        "review" .= reviewDigest bundle,"action" .= ("abandon-partial-prune"::T.Text)]
      entries=[object ["id" .= r,"digest" .= contentDigest bytes,"native" .= (ok (eitherDecodeStrict' bytes)::Value),
        "uid" .= (if Map.member r native then "failed-prune-uid" else "ingestion-uid"::T.Text),"prune" .= Map.member r native]
        | (r,(_,bytes))<-Map.toList (Map.union native sourceNative)]
  BS.writeFile (root<>"/decision.json") (ok (canonicalValue decision))
  BS.writeFile (root<>"/fixture.json") (ok (canonicalValue (object ["transaction" .= tx,"operation" .= operation,"entries" .= entries])))
  print ("synthetic admitted scheduled prune",tx,operation)
