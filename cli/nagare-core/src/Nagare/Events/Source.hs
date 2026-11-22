-- | Lifecycle source facts (EP-231): what a converged inventory transaction
-- commits for lifecycle consumers, and how consumers read it back.
--
-- A converged release that produced facts publishes one immutable facts
-- object and appends one convergence journal event naming it, in the head
-- replacement that clears its claim. The journal sequence is every
-- consumer's checkpoint. Producers are pure: they see the converging
-- transaction and return typed candidates; they never write the store.
module Nagare.Events.Source
  ( -- * Source identity
    SourceKey
  , mkSourceKey
  , sourceKeyText

    -- * Public event candidates
  , EventKind (..)
  , eventKindText
  , parseEventKind
  , ResourceRef (..)
  , Evidence (..)
  , DeploymentSubject (..)
  , DeploymentAction (..)
  , AppDeployment (..)
  , BackupOrigin (..)
  , StoredVersion (..)
  , BackupCompletion (..)
  , BackupAcceptance (..)
  , ChangeSource (..)
  , changeSource
  , ScopeChangeKind (..)
  , ScopeChange (..)
  , ActionCount (..)
  , ChangeApplication (..)
  , FailureOutcome (..)
  , NextStep (..)
  , ChangeFailure (..)
  , ClosedDisposition (..)
  , ClosedScope (..)
  , ChangeClosure (..)
  , AppDeletion (..)
  , AppStop (..)
  , AppRestart (..)
  , RestoreTargetKind (..)
  , DatabaseRestore (..)
  , BackupFailureReason (..)
  , BackupFailure (..)
  , FreshnessGrade (..)
  , freshnessGradeText
  , BackupObjective (..)
  , FreshnessChange (..)
  , PlatformUpgrade (..)
  , contextScope
  , releaseSubject
  , primaryScopeOf
  , EventPayload (..)
  , payloadKind
  , payloadData
  , parsePayload
  , EventCandidate (..)

    -- * Internal control facts
  , ControlChannel
  , mkControlChannel
  , controlChannelText
  , ControlFact (..)

    -- * Producers and the facts object
  , SourceItem (..)
  , SourceInput (..)
  , OperationView (..)
  , SourceProducer (..)
  , sourceProducer
  , MemberView (..)
  , ScopeView (..)
  , SourceFacts (..)
  , factsSchemaVersion
  , assembleFacts
  , encodeSourceFacts
  , decodeSourceFacts
  , factsDigest
  , factsKey

    -- * Reading committed sources
  , SourceCheckpoint (..)
  , initialCheckpoint
  , CommittedSource (..)
  , StopKind (..)
  , CommittedStop (..)
  , JournalSource (..)
  , journalSources
  , SourceBatch (..)
  , SourceChainError (..)
  , readSourceChain
  , tipCheckpoint
  , ControlStep (..)
  , consumeControls
  )
where

import Nagare.Dsl.Prelude ()
import Nagare.Events.Source.Chain
import Nagare.Events.Source.Facts
