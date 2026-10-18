-- | The reviewed release transition of an admitted inventory context (EP-172,
-- ADR 6): whether the running CLI's payload may move a context pinned to
-- another release. Planning refuses an unsupported pair before any write.
module Nagare.Platform.Transition
  ( TransitionPair (..)
  , TransitionRefusal (..)
  , inventorySchemaVersion
  , checkTransition
  , platformReviewExpectation
  , renderTransitionRefusal
  , sameDeclarationsModuloSource
  , transitionOwnerRefusal
  , transitionContinueRefusal
  , transitionCommitRefusal
  , TransitionState (..)
  , TransitionDelta (..)
  , TransitionRow (..)
  , transitionTable
  , renderTransitionTable
  )
where

import Control.Monad (unless, when)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store (HeadManifest (..), TransitionMarker (..), parseTransitionReviewIdentity)
import Nagare.Platform.Workspace (PayloadManifest)
import Nagare.Resource.Inventory (ScopeDeclaration)
import Nagare.Resource.Types (ScopeId, scopeIdText)
import Nagare.Resource.Wire (encodeCanonicalScope)

-- | An accepted move: the context's pinned release and this payload's.
data TransitionPair = TransitionPair
  { source :: !Text
  , target :: !Text
  }
  deriving stock (Eq, Show, Generic)

data TransitionRefusal
  = -- | The context has no release pin, so there is nothing to move from.
    UnpinnedContext
  | -- | The context already runs this payload's release.
    AlreadyAtTarget !Text
  | -- | This payload does not list the pinned release as a source.
    UnsupportedSource !Text !Text ![Text]
  | -- | The store head's wire version is outside what this payload reads.
    UnsupportedStoreVersion !Int !Int !Int
  deriving stock (Eq, Show)

-- | The inventory store's current head wire version (`version` in head.json).
inventorySchemaVersion :: Int
inventorySchemaVersion = 1

-- | Refuse or accept moving a context pinned to @pin@, whose store head has
-- wire version @headVersion@, to this payload. Pure: the caller reads the pin
-- and the head, and nothing is written.
checkTransition :: PayloadManifest -> Maybe Text -> Int -> Either TransitionRefusal TransitionPair
checkTransition manifest pin headVersion = do
  source <- maybe (Left UnpinnedContext) Right pin
  let target = manifest ^. #platformVersion
      accepted = manifest ^. #transitionsFrom
      oldest = manifest ^. #minimumInventorySchemaVersion
  when (source == target) (Left (AlreadyAtTarget target))
  unless (source `elem` accepted) (Left (UnsupportedSource source target accepted))
  unless (headVersion >= oldest && headVersion <= inventorySchemaVersion) (Left (UnsupportedStoreVersion headVersion oldest inventorySchemaVersion))
  pure (TransitionPair source target)

-- | While a transition is open, only the target payload's CLI may mutate the
-- context: any other refuses and names the payload that finishes the move.
transitionOwnerRefusal :: TransitionMarker -> Text -> Maybe Text
transitionOwnerRefusal marker payload
  | payload == transitionTarget marker = Nothing
  | otherwise =
      Just
        ( "a release transition from "
            <> transitionSource marker
            <> " to payload "
            <> transitionTarget marker
            <> " is open since "
            <> transitionStartedAt marker
            <> "; this nagarectl carries payload "
            <> payload
            <> ", so only the target release's nagarectl applies, resumes, recovers or closes until platform transition commit ends it"
        )

-- | F130: planning or applying under an open transition. Its target payload
-- continues it. While the store is idle, a newer release that moves the same
-- pinned source may supersede it: its first admitted stage retargets the
-- marker, so a defect that strands the target cannot strand the context.
transitionContinueRefusal :: HeadManifest -> TransitionMarker -> Text -> Maybe Text
transitionContinueRefusal headValue marker payload
  | isNothing (headActiveTransaction headValue) && isNothing (headExecutorClaim headValue) = Nothing
  | otherwise = transitionOwnerRefusal marker payload

-- | Why `platform transition commit` may not write the pin yet, if anything:
-- no transition is open, another payload's is, a transaction is unresolved, or
-- a scope the transition moves (@moved@) is accepted at a revision that has
-- not converged. The pin is the transition's last write (ADR 6), so it waits
-- for every such scope update to land.
transitionCommitRefusal :: Text -> (ScopeId -> Bool) -> HeadManifest -> Maybe Text
transitionCommitRefusal payload moved headValue = case headTransition headValue of
  Nothing -> Just "no release transition is open; review one with platform transition plan"
  Just marker
    | Just reason <- transitionOwnerRefusal marker payload -> Just reason
    | isJust (headActiveTransaction headValue) || isJust (headExecutorClaim headValue) ->
        Just "the transition has an unresolved transaction; resume or close it before committing"
    | scope : _ <- unconverged ->
        Just ("scope " <> scopeIdText scope <> " is accepted at a revision that has not converged; review the transition's next stage before committing")
    | otherwise -> Nothing
  where
    unconverged =
      [ scope
      | (scope, revision) <- Map.toList (headAccepted headValue)
      , moved scope
      , Map.lookup scope (headConverged headValue) /= Just revision
      ]

-- | What a platform review's payload identity requires at apply: the payload
-- that planned it and the context pin it expects. A bootstrap review was
-- planned by this payload against a context pinned to its release; a
-- transition review (EP-172) by the target payload against the source release.
platformReviewExpectation :: PayloadManifest -> Text -> Maybe (Text, Text)
platformReviewExpectation manifest identity = case T.stripPrefix "nagare-bootstrap:" identity of
  Just payload -> Just (payload, manifest ^. #platformVersion)
  Nothing -> (\(source, payload) -> (payload, source)) <$> parseTransitionReviewIdentity identity

-- | Whether two declarations of a scope differ only in where their members
-- were declared from. Declarations embed the payload workspace path as each
-- member's source, so a transition sees every scope change there; the planner
-- judges members the same way, so such a scope is re-accepted with no
-- operation. The judgement is on the scope wire with every source removed.
sameDeclarationsModuloSource :: ScopeDeclaration -> ScopeDeclaration -> Bool
sameDeclarationsModuloSource left right = case (wire left, wire right) of
  (Right a, Right b) -> a == b
  _ -> False
  where
    wire = fmap unsourced . Aeson.eitherDecodeStrict' . encodeCanonicalScope
    unsourced :: Aeson.Value -> Aeson.Value
    unsourced = \case
      Aeson.Object fields -> Aeson.Object (KM.mapWithKey (\key value -> if key == "source" then Aeson.Null else unsourced value) fields)
      Aeson.Array items -> Aeson.Array (fmap unsourced items)
      other -> other

renderTransitionRefusal :: TransitionRefusal -> Text
renderTransitionRefusal = \case
  UnpinnedContext -> "the context has no platform version pin; a transition moves an admitted, pinned context"
  AlreadyAtTarget target -> "the context is already pinned to " <> target <> "; nothing to move"
  UnsupportedSource source target accepted ->
    "this payload (" <> target <> ") accepts transitions from " <> listed accepted <> ", not from the pinned " <> source
  UnsupportedStoreVersion found oldest newest ->
    "the inventory head has wire version " <> showText found <> "; this payload reads versions " <> showText oldest <> " to " <> showText newest
  where
    listed [] = "no release"
    listed versions = T.intercalate ", " versions
    showText = T.pack . show

-- | One kind of state a release transition moves (EP-172 M1).
data TransitionState
  = -- | The per-context payload workspace the CLI runs from.
    PayloadWorkspace
  | -- | The inventory store head: its wire version and the transition marker.
    StoreHead
  | -- | The inventory journal's event wire.
    JournalWire
  | -- | One accepted platform scope's declarations.
    PlatformScope !Text
  | -- | The cloud stages' scopes, which a local context does not have.
    CloudScopes
  | -- | The host's NixOS closure, reached through the host flake's nagare input.
    HostClosure
  | -- | ConfigMap nagare-platform-version in nagare-system (scope bootstrap-stamp).
    ClusterStamp
  | -- | NAGARE_PLATFORM_VERSION in the context file.
    ContextPin
  deriving stock (Eq, Ord, Show)

-- | How a state differs between the source release and this payload, as the
-- transition fixture observes it for v0.4.0.
data TransitionDelta
  = -- | The same at both releases.
    Unchanged
  | -- | Differs only in the payload path its members were declared from.
    SourcePathsOnly
  | -- | Differs in substance.
    Changed
  | -- | A local context, which the fixture records, has no such state.
    NotInLocalContext
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data TransitionRow = TransitionRow
  { state :: !TransitionState
  , truth :: !Text
  -- ^ Where the state lives.
  , step :: !Int
  -- ^ Its place in the transition; 0 when nothing moves it.
  , move :: !Text
  -- ^ The operation that moves it.
  , refusal :: !Text
  -- ^ What refuses, and when.
  , recovery :: !Text
  -- ^ The supported exit from a stop at that step.
  , observed :: !TransitionDelta
  -- ^ What the fixture observes from v0.4.0 to this payload.
  }
  deriving stock (Eq, Show, Generic)

-- | Every state a release transition must move, in the order it moves them:
-- planning prepares the workspace, the first admitted stage opens the marker,
-- the stages move the substrate, host, kubeconfig and platform scopes with the
-- stamp after every member it covers, and the commit writes the pin last.
-- `PlatformTransitionTableSpec` checks each row's 'observed' against the
-- two-release fixture.
transitionTable :: [TransitionRow]
transitionTable =
  [ TransitionRow
      PayloadWorkspace
      "${XDG_STATE_HOME}/nagare/<context>/platform/<payloadId>-<digest>, selected by payload digest"
      1
      "platform transition plan prepares the target payload's workspace beside the source's; local and outside the store"
      "a workspace whose manifest disagrees with the payload refuses before planning; this release refuses the source payload's MinIO and auth-plane manifests (F41), so the workspace moves with the CLI"
      "prepared again from the immutable payload; the source workspace is kept"
      Changed
  , TransitionRow
      StoreHead
      "head.json in the inventory store: wire version and transition marker"
      2
      "admission of the first transition review opens the marker (source, target payload, start); later transition reviews keep it; the commit clears it after the pin"
      "planning refuses a head wire version outside the payload's minimumInventorySchemaVersion to inventorySchemaVersion; while the marker is open, admission refuses any other review and apply, resume, recover and close refuse under a CLI whose payload is not the target"
      "the marker survives every stop; resume, recover and close with the target's nagarectl"
      Unchanged
  , TransitionRow
      JournalWire
      "journal/<sequence>.json in the inventory store"
      0
      "nothing: the target reads the source's events and appends at the same wire version"
      "a release that changes the journal wire ships a reviewed migration step with a model scenario, or does not ship the change"
      "none needed"
      Unchanged
  , platformScope 3 "local-substrate" SourcePathsOnly
  , TransitionRow
      CloudScopes
      "accepted cloud-foundation, cloud, host-image-build, host-image, cache and cache-image scopes"
      4
      "the cloud stages are planned again from the target payload; an accepted host is re-pinned, never re-imaged"
      "planning refuses a cloud context whose cloud foundation is not accepted"
      "inventory resume, recover and close of the stage's transaction"
      NotInLocalContext
  , TransitionRow
      HostClosure
      "the host flake's nagare input, the payload's NixOS source (scope host)"
      5
      "the host stage re-targets the input to the target payload's NixOS source, re-locks it, and applies the reviewed self-reverting activation (ADR 11)"
      "hostLockRepin refuses a lock that leaves the payload; a local context has no host"
      "the activation reverts itself unless confirmed; resume or recover the host operation"
      Unchanged
  , platformScope 6 "kubeconfig" Unchanged
  , -- EP-198: opt in per context with NAGARE_ADMIN_API_ENABLED=1; the
    -- fixture's local context does not enable it.
    platformScope 7 "admin-api" NotInLocalContext
  , platformScope 7 "auth" Unchanged
  , platformScope 7 "cert-manager" Unchanged
  , platformScope 7 "certificate-issuer" Unchanged
  , platformScope 7 "foundation" SourcePathsOnly
  , platformScope 7 "kourier" Unchanged
  , platformScope 7 "local-object-store" Unchanged
  , platformScope 7 "net-certmanager" Unchanged
  , platformScope 7 "net-controller-image" Unchanged
  , platformScope 7 "observability-extra" Unchanged
  , platformScope 7 "observability-otel-collector" SourcePathsOnly
  , platformScope 7 "observability-secrets" Unchanged
  , platformScope 7 "observability-victoria-logs" SourcePathsOnly
  , platformScope 7 "observability-victoria-logs-collector" SourcePathsOnly
  , platformScope 7 "observability-victoria-traces" SourcePathsOnly
  , platformScope 7 "observability-vmks" SourcePathsOnly
  , platformScope 7 "serving" Unchanged
  , TransitionRow
      ClusterStamp
      "ConfigMap nagare-platform-version in nagare-system, accepted as scope bootstrap-stamp"
      8
      "one reviewed update in the platform stage, ordered after every other member of that review"
      "platform transition commit refuses while the cluster marker does not report the target"
      "inventory resume, recover and close; plan the stage again"
      Changed
  , TransitionRow
      ContextPin
      "NAGARE_PLATFORM_VERSION in ${XDG_CONFIG_HOME}/nagare/contexts/<context>.env"
      9
      "platform transition commit writes it last, then clears the marker"
      "planning refuses an unpinned context, a pin equal to the target, and a pin the payload's transitionsFrom does not list; the commit refuses unless the head is idle, the marker names this payload, and payload, host and cluster report the target"
      "until the commit, the context is still pinned to the source and the target's nagarectl owns completion"
      Changed
  ]
  where
    platformScope order name delta =
      TransitionRow
        (PlatformScope name)
        ("accepted scope platform:" <> name)
        order
        ( case delta of
            Unchanged -> "nothing: the planner keeps the accepted revision"
            SourcePathsOnly -> "re-accepted at a new revision with no operation; only its members' payload path differs"
            Changed -> "reviewed update operations in its stage"
            NotInLocalContext -> "planned in its stage when the context has it"
        )
        "admission refuses a review whose base revisions are not the head's accepted ones"
        "inventory resume, recover and close of the stage's transaction"
        delta

-- | The table as Markdown, for the plan and the release notes.
renderTransitionTable :: [TransitionRow] -> Text
renderTransitionTable rows =
  T.unlines
    ( "| Step | State | Source of truth | Moved by | Refuses | Recovery | v0.4.0 to this payload |"
        : "|---|---|---|---|---|---|---|"
        : map row rows
    )
  where
    row r =
      "| "
        <> T.intercalate
          " | "
          [ if r ^. #step == 0 then "-" else T.pack (show (r ^. #step))
          , stateName (r ^. #state)
          , r ^. #truth
          , r ^. #move
          , r ^. #refusal
          , r ^. #recovery
          , T.pack (show (r ^. #observed))
          ]
        <> " |"
    stateName = \case
      PlatformScope name -> "platform scope " <> name
      other -> T.pack (show other)
