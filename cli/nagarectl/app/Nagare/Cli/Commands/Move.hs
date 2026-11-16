-- | @nagarectl context move@ (EP-243): open a move of a direct context onto the tunnel, run or resume
-- its steps, report where it stands, and roll it back. The steps and their order live in
-- 'Nagare.Context.Move'; the open move lives in the inventory head ('Nagare.Context.MoveStore').
--
-- A step that changes the context plans its stage under the move's review identity, saves the
-- review and stops so the operator can read it; the next @apply --yes@ applies that review and plans
-- the next one, and the step completes when a plan changes nothing. A step that observes asks
-- 'Nagare.Context.MoveChecks' what the facts mean.
module Nagare.Cli.Commands.Move (runContextMove) where

import Control.Exception (try)
import Data.Foldable (forM_)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Nagare.Cli.Bootstrap.Review (applyStageReview, planStageReview)
import Nagare.Cli.Inventory.CloudHistory (requireCloudCollectionProtocol)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistry)
import Nagare.Cli.Move.Observe
import Nagare.Cli.Options.Move (MoveCommand (..))
import Nagare.Cli.Platform.InfrastructureReview (prepareInfraTargetWithPulumi)
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Context (writeContextProfile)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Pulumi (ensurePulumiForActiveContext)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Context.Move
import Nagare.Context.MoveChecks
import Nagare.Context.MoveCommit
import Nagare.Context.MoveHosts
import Nagare.Context.MoveStore
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (OperationAction (VerifyResource), plannedAction, withPreparationGuard)
import Nagare.Inventory.Adapters.CloudflareRuntime (mirrorRecordTtl)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Components.CloudflareTunnel (cloudflareTunnelTokenSecretFile)
import Nagare.Inventory.Components.ObservabilitySecrets (contextSecretsDirectory)
import Nagare.Inventory.Plan qualified as Plan
import Nagare.Inventory.Store (InventoryStore, headAccepted, readHead)
import Nagare.Inventory.Store.Manifest (MoveMarker (..), moveReviewIdentity, parseMoveReviewIdentity)
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Platform.Workspace (readPayloadManifest, renderWorkspaceError)
import Nagare.Resource.Inventory qualified as Resource
import Nagare.Resource.Types (ScopeKind (Platform), mkScopeId, nameText, scopeKind, scopeName)
import Nagare.Target (ActiveTarget, IngressMode (..), Mode (Cloud), contextNameText, contextStateDirName, nagareStateDir, validateIngressMode)
import System.Directory (doesDirectoryExist, doesFileExist, removeDirectoryRecursive)
import System.Exit (ExitCode)
import System.FilePath (takeDirectory, (</>))

-- | The kind of move EP-243 runs; EP-246 adds another.
ingressMove :: Text
ingressMove = "ingress"

runContextMove :: Maybe String -> MoveCommand -> IO ()
runContextMove mctx command = do
  active <- activeTarget mctx
  case command of
    MoveStatus -> withStore active >>= status
    MoveStart -> start active
    MoveApply yes -> requireYes yes "context move apply" >> proceed mctx active runMove
    MoveRollback yes -> requireYes yes "context move rollback" >> proceed mctx active rollbackMove
    MoveRetireDns yes -> requireYes yes "context move retire-dns" >> retireDns mctx active

start :: ActiveTarget -> IO ()
start active = do
  let profile = active ^. #profile
  unless (profile ^. #mode == Cloud) (dieT "a context move needs a cloud context")
  unless (profile ^. #ingress == IngressDirect) (dieT "this context already serves through the tunnel")
  -- D11: list every URL the move changes, and refuse what it cannot carry.
  snapshot <- Inventory.loadTargetSnapshot active
  let changes =
        hostChanges
          (profile ^. #baseDomain)
          [ member
          | (_, scope) <- Map.elems (Resource.snapshotScopes snapshot)
          , bundle <- Resource.scopeBundles scope
          , Resource.Managed member <- Resource.declarations bundle
          ]
  unless (null changes) $ TIO.putStr (T.unlines ("These URLs change when the move flattens default names:" : map renderHostChange changes))
  when (any blocksMove changes) $
    dieT "a protected name or a deep custom domain would stop being served; this nagarectl cannot carry them yet, so the move does not start"
  -- D4: refuse before the move opens, so a renewing certificate or a DS record costs nothing.
  checkPreconditions active (profile ^. #baseDomain) >>= \case
    StepCompleted -> pure ()
    StepWaiting reason -> dieT ("not yet: " <> reason)
    StepRefused reason -> dieT reason
  store <- withStore active
  now <- T.pack . iso8601Show <$> getCurrentTime
  marker <- openMove store ingressMove now (profile ^. #baseDomain) sameDomainSteps >>= either dieT pure
  TIO.putStrLn ("Opened a move of " <> profile ^. #baseDomain <> " onto the Cloudflare Tunnel, started " <> moveStartedAt marker <> ".")
  TIO.putStrLn "While it is open, only the move's own reviews are admitted: deploys wait until it finishes or rolls back."
  TIO.putStrLn "Run `nagarectl context move apply --yes` to run its steps; it stops whenever you have something to do."

status :: InventoryStore -> IO ()
status store =
  openMoveOf store >>= either dieT pure >>= \case
    Nothing -> TIO.putStrLn "No context move is open."
    Just marker -> do
      let progress = moveProgress marker
      TIO.putStrLn (moveKind marker <> " move, started " <> moveStartedAt marker <> ", " <> directionText (progress ^. #direction))
      TIO.putStrLn (T.pack (show (progress ^. #completed)) <> " of " <> T.pack (show (length (progress ^. #steps))) <> " steps done")
      forM_ (progress ^. #inProgress) $ \step -> TIO.putStrLn ("In progress: " <> moveStepToken step)
      TIO.putStrLn ("Left: " <> T.intercalate ", " (map moveStepToken (remainingSteps progress)))

-- | D2: once a move has committed and the registrar delegates to Cloudflare, retire the Cloud DNS
-- zone the move kept, its records and the solver's grants, then clear @NAGARE_RETAINED_DNS_NAME@.
retireDns :: Maybe String -> ActiveTarget -> IO ()
retireDns mctx active = do
  let profile = active ^. #profile
      base = profile ^. #retainedDnsName
  unless (profile ^. #ingress == IngressCloudflareTunnel && not (T.null base)) (dieT "this context keeps no Cloud DNS zone from a move")
  store <- withStore active
  openMoveOf store >>= either dieT pure >>= mapM_ (const (dieT "a context move is open; finish or roll it back first"))
  zone <- observeZone >>= either dieT pure >>= maybe (dieT "CF_ZONE_ID names no zone") pure
  parent <- observeParentDelegation base >>= either dieT pure
  resolvers <- observeResolverNameServers base
  let cloudflare = zone ^. #assignedNameServers
  unless (zone ^. #zoneState == "active" && all (sameNameServers cloudflare) (fst parent : resolvers)) $
    dieT "the parent or a public resolver still names other name servers than Cloudflare's; Cloud DNS may still answer for this domain"
  directory <- (</> "retire-cloud-dns") . takeDirectory <$> reviewDirectory active MovingForward CommitMove
  saved <- doesDirectoryExist directory
  let identity = "operator-cli"
      next =
        retireSet active store cloudDnsSet "the kept Cloud DNS zone, its records and grants" identity directory $ do
          writeContextProfile (active ^. #contextName) (profile & #retainedDnsName .~ "")
          TIO.putStrLn "Cleared NAGARE_RETAINED_DNS_NAME. The solver's two IAM grants are retired, not deleted: remove them in the project if you want."
  outcome <- if saved then applySavedReview mctx active (== identity) "the Cloud DNS retirement's" directory next else next
  case outcome of
    StepCompleted -> TIO.putStrLn "The Cloud DNS set is retired."
    StepWaiting reason -> TIO.putStrLn ("Waiting: " <> reason)
    StepRefused reason -> dieT reason

directionText :: MoveDirection -> Text
directionText = \case
  MovingForward -> "moving forward"
  RollingBack -> "rolling back"

proceed :: Maybe String -> ActiveTarget -> (MoveOps IO -> MoveRecord -> IO (MoveResult, MoveRecord)) -> IO ()
proceed mctx active run = do
  store <- withStore active
  marker <- openMoveOf store >>= either dieT pure >>= maybe (dieT "no context move is open; start one with `nagarectl context move start`") pure
  (result, _) <- run (moveOps mctx active store marker) (moveProgress marker)
  case result of
    MoveFinished -> closeMove store >>= either dieT pure >> TIO.putStrLn "Every step is done; the move is closed and the context serves through the tunnel."
    MoveRolledBack -> closeMove store >>= either dieT pure >> TIO.putStrLn "Every completed step is undone; the move is closed."
    MoveStopped step (StepWaiting reason) -> TIO.putStrLn ("Waiting at " <> moveStepToken step <> ": " <> reason <> "\nRun the same command again when that is done.")
    MoveStopped step (StepRefused reason) -> dieT ("Refused at " <> moveStepToken step <> ": " <> reason)
    MoveStopped step StepCompleted -> dieT ("stopped after completing " <> moveStepToken step)
    MoveRefused reason -> dieT reason

moveOps :: Maybe String -> ActiveTarget -> InventoryStore -> MoveMarker -> MoveOps IO
moveOps mctx active store marker =
  MoveOps
    { performStep = perform mctx active store marker
    , saveMove = \record -> saveMoveProgress store record >>= either dieT pure
    }

perform :: Maybe String -> ActiveTarget -> InventoryStore -> MoveMarker -> MoveDirection -> MoveStep -> IO StepOutcome
perform mctx active store marker direction step = case (direction, step) of
  (MovingForward, CheckPreconditions) -> checkPreconditions active base
  (MovingForward, AwaitNameServers) -> observed (maybe (StepRefused "CF_ZONE_ID names no zone") nameServersActive) <$> observeZone
  (MovingForward, EnableDnssec) -> observed dnssecReady <$> observeDnssec
  (MovingForward, ConfirmDirect) -> moveEnv >>= \env -> directAnswers base <$> probeDirect env True
  (MovingForward, VerifyTunnel) -> moveEnv >>= fmap edgeAnswers . probeEdge
  (MovingForward, AwaitOldTtl) -> oldAnswers
  (MovingForward, CloseFirewall) -> guarded oldAnswers (reviewStep MovingForward CloseFirewall)
  (MovingForward, StartConnector) -> guarded tokenSaved (reviewStep MovingForward StartConnector)
  (MovingForward, SwitchRecords) ->
    guarded (moveEnv >>= observeConnectors <&> observed connectorsServe) (reviewStep MovingForward SwitchRecords)
  (MovingForward, CommitMove) -> commit
  (MovingForward, other) -> reviewStep MovingForward other
  (RollingBack, SwitchRecords) -> guarded (moveEnv >>= \env -> directAnswers base <$> probeDirect env False) (reviewStep RollingBack SwitchRecords)
  (RollingBack, CarryHostnames) -> guarded edgeCaches (reviewStep RollingBack CarryHostnames)
  (RollingBack, StartConnector) -> guarded edgeCaches (reviewStep RollingBack StartConnector)
  (RollingBack, EnableDnssec) -> observed dnssecRemoved <$> observeParentDs base
  (RollingBack, MirrorZone) -> guarded returned (reviewStep RollingBack MirrorZone)
  (RollingBack, other) -> reviewStep RollingBack other
  where
    base = moveRetainedDnsName marker
    identityFor = moveReviewIdentity ingressMove
    oldAnswers = do
      now <- getCurrentTime
      facts <- sequence3 observeZone (observeParentDelegation base) (observeApexRecord base)
      pure $ case facts of
        Left reason -> StepRefused reason
        Right (zone, (_, parentTtl), apex) ->
          oldAnswersExpired now mirrorRecordTtl (zone >>= (^. #activatedOn)) parentTtl (apex ^. #modifiedOn)
    edgeCaches = do
      now <- getCurrentTime
      observed (\apex -> edgeCachesExpired now mirrorRecordTtl (apex ^. #toVm) (apex ^. #modifiedOn)) <$> observeApexRecord base
    returned = do
      env <- moveEnv
      cloudDns <- observeCloudDnsNameServers env
      parent <- observeParentDelegation base
      resolvers <- observeResolverNameServers base
      pure (either StepRefused id (nameServersReturned <$> cloudDns <*> (fst <$> parent) <*> pure resolvers))
    tokenSaved = do
      (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
      directory <- contextSecretsDirectory (workspace ^. #root) (contextNameText (active ^. #contextName))
      saved <- doesFileExist (directory </> cloudflareTunnelTokenSecretFile)
      pure (if saved then StepCompleted else StepWaiting "save the tunnel's token with `nagarectl tunnel token`; the connector needs it")
    connectorsServe = \case
      [] -> StepCompleted
      problems -> StepRefused ("the tunnel's connectors are not ready: " <> T.intercalate "; " problems)
    moveEnv = do
      (_, workspace) <- ensurePulumiForActiveContext mctx
      address <- stackOutput (workspace ^. #pulumiDir) "publicIp" >>= maybe (dieT "the stack has no publicIp output") pure
      zone <- stackOutput (workspace ^. #pulumiDir) "dnsZoneName"
      pure (MoveEnv (contextNameText (active ^. #contextName)) base (active ^. #profile . #project) address zone)

    -- A review step: apply the review saved by the last run, then plan the next one; complete when a
    -- plan changes nothing.
    reviewStep dir' stepNow = do
      directory <- reviewDirectory active dir' stepNow
      saved <- doesDirectoryExist directory
      if saved then applySaved directory stepNow (planned directory stepNow) else planned directory stepNow
    planned directory stepNow = do
      planStageReview active (identityFor stepNow) directory
      settledOrWait directory
    applySaved directory stepNow = applySavedReview mctx active (isStep stepNow) ("the move's " <> moveStepToken stepNow) directory
    isStep stepNow identity = case parseMoveReviewIdentity identity of
      Just (kind, reviewed, _) -> kind == ingressMove && reviewed == stepNow
      Nothing -> False

    -- commit-move: the web rules' policy, retirement and collection reviews, then the profile.
    commit = do
      directory <- reviewDirectory active MovingForward CommitMove
      saved <- doesDirectoryExist directory
      let next = do
            (paths, _) <- resolvePlatformWorkspace (active ^. #contextName)
            manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
            retireSet active store webRuleSet "the three web firewall rules" (identityFor CommitMove (manifest ^. #payloadId)) directory $ do
              let profile = active ^. #profile & #ingress .~ IngressCloudflareTunnel & #retainedDnsName .~ base
              either dieT pure (validateIngressMode profile)
              writeContextProfile (active ^. #contextName) profile
              TIO.putStrLn ("Wrote the context profile: NAGARE_INGRESS=cloudflare-tunnel, NAGARE_RETAINED_DNS_NAME=" <> base <> ".")
      if saved then applySaved directory CommitMove next else next
    settledOrWait directory = do
      bundle <- Plan.loadReviewBundle directory >>= either dieT pure
      headValue <- readHead store >>= either (dieT . T.pack . show) pure
      let document = Plan.reviewBundleDocument bundle
          changes = filter ((/= VerifyResource) . plannedAction . Plan.reviewPlannedOperation) (Plan.reviewOperations document)
          accepted = maybe Map.empty headAccepted headValue
      if null changes && Plan.reviewDesiredRevisions document `Map.isSubmapOf` accepted
        then removeDirectoryRecursive directory >> pure StepCompleted
        else waitForReview directory "its operations are this step's change"

-- | Apply the review saved in @directory@ when its identity is @accepted@, discard it either way, and
-- continue with @next@ only when it applied.
applySavedReview :: Maybe String -> ActiveTarget -> (Text -> Bool) -> Text -> FilePath -> IO StepOutcome -> IO StepOutcome
applySavedReview mctx active accepted label directory next = do
  outcome <- try (applyStageReview mctx active accepted ("this review is not " <> label <> " review") directory True)
  removeDirectoryRecursive directory
  case outcome of
    Left (_ :: ExitCode) ->
      pure
        ( StepRefused
            "the saved review did not apply (see above). If `nagarectl inventory status` shows an active transaction, settle it with `nagarectl inventory resume`; then run the same command again to plan afresh"
        )
    Right () -> next

-- | Plan the next review that moves @set@ out of the cloud scope under @identity@, or, when none is
-- left, run @finish@ and complete.
retireSet :: ActiveTarget -> InventoryStore -> RetiredSet -> Text -> Text -> FilePath -> IO () -> IO StepOutcome
retireSet active store retiring what identity directory finish = do
  -- Cloud plans and collections need the context's Pulumi home, backend and passphrase.
  (_, infra) <- prepareInfraTargetWithPulumi True active
  requireCloudCollectionProtocol infra
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshot active
  history <- Plan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  cloud <- either dieT pure (mkScopeId Platform "cloud")
  let accepted = snd <$> Map.lookup cloud (Resource.snapshotScopes snapshot)
      retained = [member | (_, (_, member)) <- Map.toAscList (Plan.historyRetained history), retiredMember retiring member]
      registry check candidate previous = withPreparationGuard check <$> inventoryPlanRegistry active workspace candidate previous
      compose scope = either (dieT . T.pack . show) pure (Resource.composeInventory snapshot (Resource.ReplaceScope scope :| []))
      verifyOnly operation =
        unless (plannedAction operation == VerifyResource) (Left "retiring a cloud set cannot change a native resource before it collects one")
  either (pure . StepRefused) id $
    commitAction retiring accepted retained <&> \case
      CommitPolicy scope -> do
        candidate <- compose scope
        Inventory.planInventoryCandidateWithPayloadIdentity (registry verifyOnly) identity active candidate directory
        waitForReview directory ("it lets " <> what <> " be deleted; nothing changes in the cloud")
      CommitRetire scope members -> do
        candidate <- compose scope
        Inventory.planInventoryCandidateWithRetirementsPayload (registry verifyOnly) identity active candidate members directory
        waitForReview directory ("it removes " <> what <> " from the cloud scope and keeps them in the cloud")
      CommitCollect member -> do
        Inventory.planInventoryCollectionsWithPayload (registry (const (Right ()))) identity active (member :| []) directory
        waitForReview directory ("it deletes one of " <> what)
      CommitProfile -> finish >> pure StepCompleted

waitForReview :: FilePath -> Text -> IO StepOutcome
waitForReview directory what =
  pure (StepWaiting ("read the review saved in " <> T.pack directory <> " above: " <> what <> ". Run the same command again to apply it"))

-- | @check-preconditions@: the zone, the parent's DS record and every certificate's renewal time.
checkPreconditions :: ActiveTarget -> Text -> IO StepOutcome
checkPreconditions active base = do
  now <- getCurrentTime
  facts <- sequence3 observeZone (observeParentDs base) (requireCluster >> observeRenewals)
  pure (either StepRefused (\(zone, ds, renewals) -> preconditions now base zone ds renewals) facts)
  where
    requireCluster = guardKubernetesContext active >>= either dieT (const (pure ()))

-- | Run a guard, and the step only when the guard completes.
guarded :: IO StepOutcome -> IO StepOutcome -> IO StepOutcome
guarded check next =
  check >>= \case
    StepCompleted -> next
    other -> pure other

observed :: (a -> StepOutcome) -> Either Text a -> StepOutcome
observed = either StepRefused

sequence3 :: IO (Either Text a) -> IO (Either Text b) -> IO (Either Text c) -> IO (Either Text (a, b, c))
sequence3 a b c = do
  x <- a
  y <- b
  z <- c
  pure ((,,) <$> x <*> y <*> z)

-- | Where a step's saved review waits for the operator: one directory per direction and step.
reviewDirectory :: ActiveTarget -> MoveDirection -> MoveStep -> IO FilePath
reviewDirectory active direction step = do
  state <- nagareStateDir
  let prefix = case direction of
        MovingForward -> "forward-"
        RollingBack -> "rollback-"
  pure (state </> T.unpack (contextStateDirName (active ^. #contextName)) </> "moves" </> T.unpack (ingressMove <> "-" <> prefix <> moveStepToken step))

withStore :: ActiveTarget -> IO InventoryStore
withStore = Inventory.openTargetStore

requireYes :: Bool -> Text -> IO ()
requireYes yes name = unless yes (dieT (name <> " changes the context; pass --yes"))
