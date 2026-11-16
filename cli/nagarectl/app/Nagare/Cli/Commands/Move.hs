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
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LBS
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
import Nagare.Cli.Move.BaseSteps (BaseStepOps (..), performBase)
import Nagare.Cli.Move.Manifest (collectManifest, listBaseMove, manifestFile)
import Nagare.Cli.Move.Observe
import Nagare.Cli.Move.Sites (carrySitesStep, readSavedManifest, verifySitesStep)
import Nagare.Cli.Options.Move (MoveCommand (..))
import Nagare.Cli.Platform.InfrastructureReview (prepareInfraTargetWithPulumi)
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Context (writeContextProfile)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Pulumi (ensurePulumiForActiveContext)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Context.BaseFlip (baseEnvironmentRefusal, baseMoveKind, flippedProfile)
import Nagare.Context.BaseMove (renderManifest)
import Nagare.Context.Move
import Nagare.Context.MoveChecks
import Nagare.Context.MoveCommit
import Nagare.Context.MoveHosts
import Nagare.Context.MoveReview (ReviewOps (..), ReviewPlan (..))
import Nagare.Context.MoveReview qualified as MoveReview
import Nagare.Context.MoveSites (renderUnrouted, siteProgress)
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
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeDirectoryRecursive)
import System.Environment (lookupEnv)
import System.Exit (ExitCode)
import System.FilePath (takeDirectory, (</>))

-- | The kind of move EP-243 runs; EP-246 adds another.
ingressMove :: Text
ingressMove = "ingress"

runContextMove :: Maybe String -> MoveCommand -> IO ()
runContextMove mctx command = do
  active <- activeTarget mctx
  case command of
    MoveStatus -> withStore active >>= status active
    MoveList new out -> listBaseMove active new out
    MoveStart Nothing -> start active
    MoveStart (Just new) -> startBase active new
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
  marker <- openMove store ingressMove now (profile ^. #baseDomain) (profile ^. #baseDomain) (profile ^. #externalDomainTlsEnabled) sameDomainSteps >>= either dieT pure
  TIO.putStrLn ("Opened a move of " <> profile ^. #baseDomain <> " onto the Cloudflare Tunnel, started " <> moveStartedAt marker <> ".")
  TIO.putStrLn "While it is open, only the move's own reviews are admitted: deploys wait until it finishes or rolls back."
  TIO.putStrLn "Run `nagarectl context move apply --yes` to run its steps; it stops whenever you have something to do."

-- | EP-246: list what changes, refuse what cannot move, check the new zone, save the manifest, open.
startBase :: ActiveTarget -> Text -> IO ()
startBase active new = do
  let profile = active ^. #profile
  manifest <- collectManifest active new >>= either (\refusals -> dieT (T.unlines ("The move to " <> new <> " cannot start:" : map ("  " <>) refusals))) pure
  TIO.putStr (renderManifest manifest)
  basePrecheck new >>= \case
    StepCompleted -> pure ()
    StepWaiting reason -> dieT ("not yet: " <> reason)
    StepRefused reason -> dieT reason
  directory <- takeDirectory <$> reviewDirectory active baseMoveKind MovingForward CheckPreconditions
  createDirectoryIfMissing True directory
  LBS.writeFile (directory </> manifestFile) (encode manifest)
  store <- withStore active
  now <- T.pack . iso8601Show <$> getCurrentTime
  marker <-
    openMove store baseMoveKind now (profile ^. #baseDomain) new (profile ^. #externalDomainTlsEnabled) baseDomainSteps >>= either dieT pure
  TIO.putStrLn ("Opened a move of " <> profile ^. #baseDomain <> " to " <> new <> ", started " <> moveStartedAt marker <> "; the manifest is " <> T.pack (directory </> manifestFile) <> ".")
  TIO.putStrLn "Old names serve until the flip. Run `nagarectl context move apply --yes`; it stops whenever you have something to do."

-- | The new zone is the target, active, with no foreign DS record at its parent.
basePrecheck :: Text -> IO StepOutcome
basePrecheck new = do
  facts <- sequence3 observeZone (observeParentDs new) observeDnssec
  pure (either StepRefused (\(zone, ds, dnssec) -> basePreconditions new zone ds dnssec) facts)

status :: ActiveTarget -> InventoryStore -> IO ()
status active store =
  openMoveOf store >>= either dieT pure >>= \case
    Nothing -> TIO.putStrLn "No context move is open."
    Just marker -> do
      let progress = moveProgress marker
      TIO.putStrLn (moveKind marker <> " move, started " <> moveStartedAt marker <> ", " <> directionText (progress ^. #direction))
      TIO.putStrLn (T.pack (show (progress ^. #completed)) <> " of " <> T.pack (show (length (progress ^. #steps))) <> " steps done")
      forM_ (progress ^. #inProgress) $ \step -> TIO.putStrLn ("In progress: " <> moveStepToken step)
      TIO.putStrLn ("Left: " <> T.intercalate ", " (map moveStepToken (remainingSteps progress)))
      -- EP-246 D5: while the sites carry over, what is left of them.
      when (moveKind marker == baseMoveKind && progress ^. #inProgress == Just CarrySites) $ do
        manifest <- takeDirectory <$> reviewDirectory active baseMoveKind MovingForward CheckPreconditions >>= readSavedManifest
        snapshot <- Inventory.loadTargetSnapshotReadOnly active
        case siteProgress snapshot (manifest ^. #hosts) of
          Left reason -> TIO.putStrLn ("Sites: " <> reason)
          Right sites -> do
            unless (null (sites ^. #unrouted)) (TIO.putStrLn ("Sites: " <> renderUnrouted (manifest ^. #newBase) (sites ^. #unrouted)))
            TIO.putStrLn ("Grants left to declare on the new names: " <> T.pack (show (length (sites ^. #grants))))

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
  directory <- (</> "retire-cloud-dns") . takeDirectory <$> reviewDirectory active ingressMove MovingForward CommitMove
  let identity = "operator-cli"
      finish = do
        writeContextProfile (active ^. #contextName) (profile & #retainedDnsName .~ "")
        TIO.putStrLn "Cleared NAGARE_RETAINED_DNS_NAME. The solver's two IAM grants are retired, not deleted: remove them in the project if you want."
  outcome <-
    MoveReview.reviewStep
      ( stageReviewOps
          mctx
          active
          store
          (== identity)
          "the Cloud DNS retirement's"
          directory
          (planRetirement active store cloudDnsSet identity directory finish)
      )
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
  environment <- fmap T.pack <$> lookupEnv "NAGARE_BASE_DOMAIN"
  forM_ (baseEnvironmentRefusal marker environment) dieT
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
perform mctx active store marker direction step
  | moveKind marker == baseMoveKind = performBase active marker baseOps direction step
  | otherwise = sameDomain
  where
    baseOps =
      BaseStepOps
        { reviewIt = reviewStep
        , commit = commit
        , tokenSaved = tokenSaved
        , precheck = basePrecheck (moveTargetBase marker)
        , dnssecActive = observed dnssecReady <$> observeDnssec
        , carrySites = do
            manifest <- movesDirectory >>= readSavedManifest
            carrySitesStep active manifest $ \plan -> do
              directory <- reviewDirectory active (moveKind marker) MovingForward CarrySites
              identity <- identityFor CarrySites <$> payloadId
              MoveReview.reviewStep
                (stageReviewOps mctx active store (isStep CarrySites) "the move's carry-sites" directory (plan identity directory))
        , verifySites = do
            manifest <- movesDirectory >>= readSavedManifest
            verifySitesStep active manifest (\hosts -> moveEnv >>= (`probeEdgeHosts` hosts))
        }
    movesDirectory = takeDirectory <$> reviewDirectory active (moveKind marker) MovingForward CheckPreconditions
    payloadId = do
      (paths, _) <- resolvePlatformWorkspace (active ^. #contextName)
      manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
      pure (manifest ^. #payloadId)
    sameDomain = case (direction, step) of
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
    base = moveRetainedDnsName marker
    identityFor = moveReviewIdentity (moveKind marker)
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
    -- plan changes nothing ('Nagare.Context.MoveReview').
    reviewStep dir' stepNow = do
      directory <- reviewDirectory active (moveKind marker) dir' stepNow
      MoveReview.reviewStep
        (stageReviewOps mctx active store (isStep stepNow) ("the move's " <> moveStepToken stepNow) directory (planStageReview active (identityFor stepNow) directory >> pure True))
    isStep stepNow identity = case parseMoveReviewIdentity identity of
      Just (kind, reviewed, _) -> kind == moveKind marker && reviewed == stepNow
      Nothing -> False

    -- commit-move: the web rules' policy, retirement and collection reviews, then the profile.
    commit = do
      directory <- reviewDirectory active (moveKind marker) MovingForward CommitMove
      (paths, _) <- resolvePlatformWorkspace (active ^. #contextName)
      manifest <- readPayloadManifest paths >>= either (dieT . renderWorkspaceError) pure
      let finish = do
            -- EP-246's flip already wrote the new base; the commit writes the same four values again.
            let profile =
                  if moveKind marker == baseMoveKind
                    then flippedProfile marker (active ^. #profile)
                    else active ^. #profile & #ingress .~ IngressCloudflareTunnel & #retainedDnsName .~ base
            either dieT pure (validateIngressMode profile)
            writeContextProfile (active ^. #contextName) profile
            TIO.putStrLn ("Wrote the context profile: NAGARE_INGRESS=cloudflare-tunnel, NAGARE_RETAINED_DNS_NAME=" <> base <> ".")
      MoveReview.reviewStep
        ( stageReviewOps
            mctx
            active
            store
            (isStep CommitMove)
            "the move's commit-move"
            directory
            (planRetirement active store webRuleSet (identityFor CommitMove (manifest ^. #payloadId)) directory finish)
        )

-- | The production review operations: a review saved in @directory@, applied when its identity is
-- @accepted@. @planIt@ plans and saves the next review, or returns 'False' when nothing is left.
stageReviewOps :: Maybe String -> ActiveTarget -> InventoryStore -> (Text -> Bool) -> Text -> FilePath -> IO Bool -> ReviewOps IO
stageReviewOps mctx active store accepted label directory planIt =
  ReviewOps
    { savedReview = doesDirectoryExist directory
    , planReview =
        planIt >>= \case
          False -> pure (ReviewPlan [] Map.empty Map.empty (T.pack directory))
          True -> do
            bundle <- Plan.loadReviewBundle directory >>= either dieT pure
            headValue <- readHead store >>= either (dieT . T.pack . show) pure
            let document = Plan.reviewBundleDocument bundle
            pure
              ReviewPlan
                { actions = map (plannedAction . Plan.reviewPlannedOperation) (Plan.reviewOperations document)
                , desired = Plan.reviewDesiredRevisions document
                , accepted = maybe Map.empty headAccepted headValue
                , location = T.pack directory
                }
    , applyReview = do
        outcome <- try (applyStageReview mctx active accepted ("this review is not " <> label <> " review") directory True)
        discard
        pure (either (\(_ :: ExitCode) -> False) (const True) outcome)
    , discardReview = discard
    }
  where
    discard = doesDirectoryExist directory >>= (`when` removeDirectoryRecursive directory)

-- | Plan and save the next review that moves @retiring@ out of the cloud scope under @identity@, or,
-- when none is left, run @finish@ and return 'False'.
planRetirement :: ActiveTarget -> InventoryStore -> RetiredSet -> Text -> FilePath -> IO () -> IO Bool
planRetirement active store retiring identity directory finish = do
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
  action <- either dieT pure (commitAction retiring accepted retained)
  case action of
    CommitPolicy scope -> do
      candidate <- compose scope
      Inventory.planInventoryCandidateWithPayloadIdentity (registry verifyOnly) identity active candidate directory
      pure True
    CommitRetire scope members -> do
      candidate <- compose scope
      Inventory.planInventoryCandidateWithRetirementsPayload (registry verifyOnly) identity active candidate members directory
      pure True
    CommitCollect member -> do
      Inventory.planInventoryCollectionsWithPayload (registry (const (Right ()))) identity active (member :| []) directory
      pure True
    CommitProfile -> finish >> pure False

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
reviewDirectory :: ActiveTarget -> Text -> MoveDirection -> MoveStep -> IO FilePath
reviewDirectory active kind direction step = do
  state <- nagareStateDir
  let prefix = case direction of
        MovingForward -> "forward-"
        RollingBack -> "rollback-"
  pure (state </> T.unpack (contextStateDirName (active ^. #contextName)) </> "moves" </> T.unpack (kind <> "-" <> prefix <> moveStepToken step))

withStore :: ActiveTarget -> IO InventoryStore
withStore = Inventory.openTargetStore

requireYes :: Bool -> Text -> IO ()
requireYes yes name = unless yes (dieT (name <> " changes the context; pass --yes"))
