-- | The recovery model's invariants, checked against a run: I5 (the store
-- ends consistent), I2, I3 and I4 (after each review), and EP-181's I9 (a
-- correction converges) with its excuses.
module Nagare.Test.Model.Invariants
  ( storeConsistent
  , correctionConverges
  , faultedTemplateRecurs
  , refusedTemplateExcused
  , refusalExcused
  , i8Settlement
  , settlementGap
  , checkInvariants
  )
where

import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text qualified as T
import InventoryTransactionSpec (fixtureBinding)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Status qualified as Status
import Nagare.Inventory.Store
import Nagare.Resource.Inventory
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types
import Nagare.Test.Model.Fixtures
import Nagare.Test.Model.Rebuild (rebuildLineageHolds)
import Nagare.Test.Model.Run
import Nagare.Test.Model.Scenarios
import Nagare.Test.World.Adversary
import Nagare.Test.World.ApiServer (Outcome (Good))
import Nagare.Test.World.Kubernetes

-- | I5: after the scenario, the head reads back idle and every published
-- journal event up to it decodes and validates as one chain.
storeConsistent :: Run -> IO (Either Text ())
storeConsistent run = do
  current <- inspectHead run
  case current of
    Left err -> pure (Left ("I5: the head cannot be read: " <> T.pack (show err)))
    Right Nothing -> pure (Left "I5: the head is missing")
    Right (Just value)
      | isJust (headActiveTransaction value) -> pure (Left "I5: the scenario ended with an active transaction")
      | otherwise -> do
          raw <- inspectJournal run (headSequence value)
          pure $ case raw >>= first (StoreInvalidObject "journal") . traverse decodeJournalEvent of
            Left err -> Left ("I5: the published journal is unreadable: " <> T.pack (show err))
            Right events -> first (\err -> "I5: the journal chain is invalid: " <> err) (() <$ validateJournal events)

-- | I9 (EP-181, from RES-4 G3): a run that takes every step of its scenario,
-- and whose final step reviews a spec the scenario does not mark unready, ends
-- with that step's scope converged at its accepted revision, every member the
-- revision bound live at its reviewed digest and Ready. A close that keeps the
-- scope does not satisfy it. A fault that acted during the final step, or one
-- whose effect legitimately outlives later writes, excuses the run.
correctionConverges :: Scenario -> Map.Map Call Int -> Run -> IO (Either Text ())
correctionConverges scenario finalStart run = case finalScope of
  Nothing -> pure (Right ())
  Just scope -> do
    adversary <- readIORef (runAdversary run)
    current <- inspectHead run >>= orFail "read head"
    world <- readIORef (runWorld run)
    bound <- readIORef (runBound run)
    let accepted = current >>= Map.lookup scope . headAccepted
        converged = current >>= Map.lookup scope . headConverged
        finalMembers = fromMaybe Map.empty (accepted >>= (`Map.lookup` bound) . revisionDigest)
        unproven =
          [ resource
          | (resource, digest) <- Map.toList finalMembers
          , case Map.lookup resource (objects world) of
              Just object' -> nativeDigest object' /= digest || readiness object' /= Ready
              Nothing -> Set.notMember resource (deletedOutOfBand world)
          ]
    -- The final accepted revision's OrderedAfter edges, and the members no
    -- journalled intent ever started.
    history <- inspectHistory run >>= orFail "read history"
    events <- maybe (pure []) (\headValue -> inspectJournal run (headSequence headValue) >>= orFail "read journal" >>= orFail "decode journal" . traverse decodeJournalEvent) current
    let orderedAfter =
          Map.fromList
            [ (member ^. #identity, [dependency | OrderedAfter dependency <- member ^. #dependencies])
            | Just (_, declared) <- [Map.lookup scope (historyAccepted history)]
            , bundle <- scopeBundles declared
            , Managed member <- declarations bundle
            ]
        -- EP-183 M4: after the cluster is lost, what started before the loss
        -- went with it; only the final step's transaction starts members.
        startedIn = case reverse events of
          lastEvent : _ | LoseCluster `elem` steps scenario -> filter ((== eventTransaction lastEvent) . eventTransaction) events
          _ -> events
        started = Set.fromList (concat [Map.findWithDefault [] operation (world ^. #reviewedOperations) | event <- startedIn, eventState event == IntentRecorded, Just operation <- [eventOperation event]])
        neverStarted = Set.fromList [resource | resource <- unproven, Map.notMember resource (objects world), Set.notMember resource started]
        -- EP-183 M4: a rebuild re-applies the accepted templates in one
        -- transaction, which stops at the first that never becomes Ready; the
        -- members it never started are held back by that stop, not only by
        -- their OrderedAfter edges.
        heldBack
          | LoseCluster `elem` steps scenario = Map.unionWith (<>) orderedAfter (Map.fromSet (const unproven) neverStarted)
          | otherwise = orderedAfter
    if any excuses (acted adversary) || faultedTemplateRecurs (acted adversary) (world ^. #server . #outcomes) (Map.restrictKeys finalMembers (Set.fromList unproven)) heldBack neverStarted
      then pure (Right ())
      else case (accepted, unproven) of
        (Nothing, _) -> pure (Left ("I9: the final step's scope " <> T.pack (show scope) <> " has no accepted revision"))
        _ | accepted /= converged -> pure (Left ("I9: the final step's scope " <> T.pack (show scope) <> " ended accepted but not converged"))
        (_, resource : _) -> pure (Left ("I9: the final step's scope converged while " <> resourceIdText resource <> " is not its reviewed Ready object"))
        -- EP-183 M4: a converged rebuild records each new incarnation.
        _ | take 1 (reverse (steps scenario)) == [RebuildDatabase] -> rebuildLineageHolds run
        _ -> pure (Right ())
  where
    finalScope = case reverse (steps scenario) of
      Deploy image : _ | image `notElem` unready scenario -> Just appScope
      CreateDatabase : _ -> Just databaseScopeId
      UpdateDatabase : _ -> Just databaseScopeId
      RestartDatabase : _ -> Just databaseScopeId
      RebuildDatabase : _ -> Just databaseScopeId
      _ -> Nothing
    -- (a) a fault placed during the final step: the step's first call has
    -- ordinal one more than the count at its start; (b) faults whose effect
    -- legitimately outlives later writes.
    excuses (Boundary call' n, fault) =
      n > Map.findWithDefault 0 call' finalStart
        || fault `elem` [ForeignManager, ForeignObject, Replaced, Deleted, ChurnAlways]

-- | I9's template excuse: a LandsUnready or LandsFailed fault that acted
-- excuses the run when every member left unconverged is justified:
--
-- * it declares, in the final accepted revision, exactly a template such a
--   fault landed, by spec digest (re-applying the same bad template is not a
--   correction; a different template that stays stuck is G3); or
-- * it is absent and never started (no journalled intent), and it depends
--   through the final revision's OrderedAfter edges, transitively, on a
--   member justified by its template: the dependency gate holds it back.
--
-- A member that started and then went missing is never justified. The
-- arguments are the failing members with their final digests, the final
-- revision's OrderedAfter edges, and the failing members that are absent and
-- never started.
faultedTemplateRecurs :: [(Boundary, Fault)] -> Map.Map Text Outcome -> Map.Map ResourceId ContentDigest -> Map.Map ResourceId [ResourceId] -> Set.Set ResourceId -> Bool
faultedTemplateRecurs acted' outcomes' failing orderedAfter neverStarted =
  any ((`elem` [LandsUnready, LandsFailed]) . snd) acted'
    && not (Map.null failing)
    && all justified (Map.keys failing)
  where
    faulted = Map.keysSet (Map.filter (\digest -> maybe False (/= Good) (Map.lookup (digestText digest) outcomes')) failing)
    justified resource = Set.member resource faulted || (Set.member resource neverStarted && reaches Set.empty resource)
    reaches seen resource =
      any
        (\dependency -> Set.member dependency faulted || (Set.notMember dependency seen && reaches (Set.insert dependency seen) dependency))
        (Map.findWithDefault [] resource orderedAfter)

checkInvariants :: Run -> IO (Either Text ())
checkInvariants run = do
  current <- inspectHead run >>= orFail "read head"
  world <- readIORef (runWorld run)
  bound <- readIORef (runBound run)
  previous <- readIORef (runConverged run)
  let now = maybe Map.empty headConverged current
  writeIORef (runConverged run) now
  let twice = Map.keys (Map.filter (> 1) (effectiveWrites world))
      newlyConverged = [revision | (scopeId', revision) <- Map.toList now, Map.lookup scopeId' previous /= Just revision]
      unproven =
        [ resource
        | revision <- newlyConverged
        , Just members <- [Map.lookup (revisionDigest revision) bound]
        , (resource, digest) <- Map.toList members
        , case Map.lookup resource (objects world) of
            Just object' -> nativeDigest object' /= digest || readiness object' /= Ready
            -- Deleted outside review after its verification; status, not
            -- convergence, reports that.
            Nothing -> Set.notMember resource (deletedOutOfBand world)
        ]
  stale <- convergedStaleIncarnations run
  known <- Map.union (maybe Map.empty headIncarnations current) <$> readIORef (runIncarnations run)
  writeIORef (runIncarnations run) known
  let laundered =
        [ resource
        | (resource, retained) <- Map.toList (maybe Map.empty headRetained current)
        , Just recorded <- [Map.lookup resource known]
        , retainedPhysical retained /= recorded
        ]
  pure $ case (twice, unproven, stale, laundered) of
    (operation : _, _, _, _) -> Left ("I4: operation " <> operationIdText operation <> " wrote twice")
    (_, resource : _, _, _) -> Left ("I2: scope reported converged while " <> resourceIdText resource <> " is not the reviewed Ready object")
    (_, _, resource : _, _) -> Left ("I3: status reports " <> resourceIdText resource <> " converged although its live UID differs from the recorded incarnation")
    (_, _, _, resource : _) -> Left ("I3: retirement retained " <> resourceIdText resource <> " under a UID other than its accepted incarnation")
    _ -> Right ()

-- | I3: status, computed as `inventory status` computes it, never reports a
-- member converged when its live UID differs from the recorded incarnation.
convergedStaleIncarnations :: Run -> IO [ResourceId]
convergedStaleIncarnations run = do
  history <- inspectHistory run >>= orFail "load history"
  images <- readIORef (runImages run)
  let appImages = Map.lookup appScope (historyAccepted history) >>= \(revision, _) -> Map.lookup (revisionDigest revision) images
  case (if Map.null (historyAccepted history) then Nothing else Just (fromMaybe (plainShape, "v1", "v1") appImages)) of
    Nothing -> pure []
    Just (volume, image, historyImage) -> do
      let accepted = Map.map (\(revision, declared) -> (revisionGeneration revision, declared)) (historyAccepted history)
          inventory = ok (composeSnapshot (ok (mkScopeSnapshot fixtureBinding accepted (historyReservations history))))
          members = [resource ^. #identity | Managed resource <- inventoryDeclarations inventory]
      incarnations <- inspectIncarnations run (historyHead history) >>= orFail "status incarnations"
      modifyIORef' (runWorld run) (\world -> world {inspecting = True})
      registry <- registryFor run volume image historyImage
      observed <- observeWithRegistry registry (Map.singleton KubernetesExecutor members)
      modifyIORef' (runWorld run) (\world -> world {inspecting = False})
      world <- readIORef (runWorld run)
      pure $ case observed of
        Left _ -> []
        Right observations ->
          [ Status.findingResource finding
          | finding <- Status.classifyDriftWith incarnations inventory observations
          , Status.findingCategory finding == Status.Converged
          , Just recorded <- [Map.lookup (Status.findingResource finding) incarnations]
          , Just object' <- [Map.lookup (Status.findingResource finding) (objects world)]
          , uid object' /= recorded
          ]

-- | 3d B6: I1's prepare-refusal path gets 'faultedTemplateRecurs' per
-- member. The refusal is a prepare refusal of verifies only (a review that
-- re-applies the unchanged template) of members that are not Ready, it names
-- them, and every one is live at a template an acted Lands* fault poisoned. A
-- refused update carries a corrected template and is never excused here.
refusedTemplateExcused :: Text -> [(Boundary, Fault)] -> Map.Map Text Outcome -> Map.Map ResourceId ContentDigest -> Bool
refusedTemplateExcused refusal acted' outcomes' live =
  "PrepareRefused" `T.isInfixOf` refusal
    && "required condition is not ready" `T.isInfixOf` refusal
    && not (null named)
    && Map.size refused == length named
    && faultedTemplateRecurs acted' outcomes' refused Map.empty Set.empty
  where
    named = case T.breakOn " refused verifies " refusal of
      (_, rest) | T.null rest -> []
      (_, rest) -> filter (not . T.null) (T.splitOn "," (T.strip (T.drop (T.length " refused verifies ") rest)))
    refused = Map.fromList [(resource, digest) | name <- named, Right resource <- [mkResourceId name], Just digest <- [Map.lookup resource live]]

-- | B2's pure judgement, per PlanError and resource (see 'excusedRefusal' in
-- the recovery model).
refusalExcused :: Set.Set Text -> Set.Set Text -> Text -> Bool
refusalExcused deleted foreign' refusal = not (null errors) && all covered errors
  where
    errors =
      [ (T.takeWhile (/= '"') (snd (T.breakOnEnd "planErrorCode = \"" chunk)), named (snd (T.breakOn "planErrorResources =" chunk)))
      | chunk <- drop 1 (T.splitOn "PlanError {" refusal)
      ]
    named text = [T.takeWhile (/= '"') resource | resource <- drop 1 (T.splitOn "ResourceId \"" text)]
    covered (code, resources) = not (null resources) && all (excused code) resources
    excused code resource = (code == "durable-resource-missing" && Set.member resource deleted) || Set.member resource foreign'

-- | I8's settlement of an operation with intent and no completion, when it
-- needs no adapter. ADR 26 §6: verify is effect-free by construction (the
-- driver never executes it), so a verify settles no effect whatever the
-- adapter would observe now, as close classes it. Every other action asks the
-- adapter.
i8Settlement :: OperationAction -> Maybe Settlement
i8Settlement action
  | action == VerifyResource = Just (SettledNoEffect "a verify never executes (ADR 26 §6)")
  | otherwise = Nothing

-- | I8's verdict on one settlement: unknown is a gap, unless resume resolves it.
settlementGap :: Either Text Settlement -> Maybe (Text, Text)
settlementGap result = case result of
  Left err -> Just (err, "a readable review")
  Right (SettledUnknown reason resolvesBy) | resolvesBy /= "inventory resume" -> Just (reason, resolvesBy)
  Right _ -> Nothing
