-- Controlled counterfactual over the exact same two-operation prune review.
module Main where
import Prelude
import Control.Exception (SomeException,try,evaluate)
import Control.Monad
import Control.Lens ((^.))
import Data.IORef
import Data.Text qualified
import Data.List.NonEmpty qualified
import Data.Map.Strict qualified as Map
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Execute qualified as E
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Status
import Nagare.Inventory.Store
import Nagare.Inventory.Digest
import Nagare.Resource.Inventory
import Nagare.Resource.Types
import System.Environment
import PruneHelpers qualified as P
import OperationalHelpers (ok)
main = do
  P.main
  root <- getEnv "MP23_PRUNE_ROOT"
  mode <- getEnv "MP23_PROBE"
  store <- P.must (openFilesystemStore (root<>"/state/nagare/prune-spike/inventory"))
  history <- P.must (loadInventoryHistory store)
  let h=historyHead history
      inventory=ok (mkScopeSnapshot (headBinding h)
        (Map.map (\(r,s)->(revisionGeneration r,s)) (historyAccepted history))
        (historyReservations history) >>= composeSnapshot)
      tx=ok (mkTransactionId (maybe (error "no transaction") id (headActiveTransaction h)))
  (native,_) <- P.must (loadAcceptedNative store history inventory)
  recovered <- newIORef (0::Int)
  effects <- newIORef (0::Int)
  let base=mkKubernetesAdapter native KubernetesAdapterOps
        {kubernetesContext=headBinding h ^. #identity,
         kubernetesObserve= \r-> let { (m,b)=native Map.! r; uid=ok (mkPhysicalIdentity "ingestion-uid") }
                               in pure $ case m ^. #address of
                                 Kubernetes _ _ _ _ n | "nagare-schedprune-" `Data.Text.isPrefixOf` nameText n ->
                                   KubernetesFailed (ok (mkPhysicalIdentity "failed-prune-uid")) "7" (Just r) (contentDigest b)
                                 _ -> KubernetesPresent uid "7" (Just r) (contentDigest b),
         kubernetesMutateConditional= \_->modifyIORef' effects (+1)>>error "must not repeat partial deletion"}
      adapter=base {adapterRecover= \o p->modifyIORef' recovered (+1)>>adapterRecover base o p}
  result <- try $ do
    outcome <- E.resumeTransaction store (ok (mkAdapterRegistry [adapter])) tx
    void (evaluate (length (show outcome)))
    pure outcome
  r<-readIORef recovered; e<-readIORef effects
  print (mode,"recoveries",r,"effects",e)
  case (result :: Either SomeException (Either (Data.List.NonEmpty.NonEmpty E.AdmissionError) E.TransactionResult)) of
    Left err -> do
      print ("exception",show err)
      unless (mode=="prune-executor-cf" && r==1 && e==0) (error "unexpected exception")
    Right value -> do
      print ("result",show value)
      case (mode,value) of
        ("prune-executor",Left _) | r==0 && e==0 -> pure ()
        ("prune-executor-fixed",Right (E.StoppedAmbiguous _ _)) | r==1 && e==0 -> pure ()
        _ -> error "counterfactual did not expose expected branch"
