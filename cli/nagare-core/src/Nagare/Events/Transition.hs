{-# LANGUAGE OverloadedStrings #-}

-- | @platform.upgraded@ (EP-276): the context finished moving to a new
-- Nagare release.
--
-- Every review of a release transition carries the payload identity
-- @nagare-transition:SOURCE->TARGET@, and only the target release applies
-- it. Its convergence commits one control fact on the @platform-transition@
-- channel naming the two releases, so the fact exists even when the worker
-- it replaces recorded nothing. The worker keeps the newest such control in
-- its own object, @worker-transition.json@ under the lifecycle prefix, and
-- publishes the event once the inventory head holds no transition marker
-- and no active transaction: only @platform transition commit@ clears the
-- marker, as its last step, so a committed control and no marker mean the
-- transition committed. A later release's control replaces the waiting one,
-- so a retargeted transition is one event, for the release it committed. A
-- release that moves no scope has no review and publishes no event.
module Nagare.Events.Transition
  ( transitionChannel
  , transitionProducer
  , WaitingTransition (..)
  , transitionsIn
  , waitingObject
  , readWaiting
  , writeWaiting
  , upgradeKey
  , upgradeCandidate
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.Char (toLower)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Events.Source
import Nagare.Events.Store (FeedError (..), FeedStore, feedStoreOps)
import Nagare.Inventory.Journal (transactionIdText)
import Nagare.Inventory.Store.Manifest (parseTransitionReviewIdentity)
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

transitionChannel :: ControlChannel
transitionChannel = either (error . T.unpack) id (mkControlChannel "platform-transition")

-- | One control per converged transition review: version 1, body
-- @{from, to}@. Any other review commits none. It reads no member and no
-- scope.
transitionProducer :: SourceProducer
transitionProducer = sourceProducer $ \input -> case parseTransitionReviewIdentity (input ^. #payloadIdentity) of
  Just (source, target)
    | Right key <- mkSourceKey ("platform.transition:" <> transactionIdText (input ^. #transaction)) ->
        [Control (ControlFact key transitionChannel 1 (object ["from" .= source, "to" .= target]))]
  _ -> []

-- | The transition the worker waits on: its releases and the review whose
-- convergence named them.
data WaitingTransition = WaitingTransition
  { from :: !Text
  , to :: !Text
  , review :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)

-- | The transition controls of a batch's sources, oldest first. A control
-- whose version the worker does not read stops the batch before its
-- source: the checkpoint there, and why.
transitionsIn :: SourceBatch -> ([WaitingTransition], Maybe (SourceCheckpoint, Text))
transitionsIn batch = go [] (batch ^. #sources)
  where
    go kept [] = (reverse kept, Nothing)
    go kept (source : rest) =
      case traverse (decodeControl (source ^. #facts . #review)) [control | control <- source ^. #facts . #controls, control ^. #channel == transitionChannel] of
        Left reason -> (reverse kept, Just (SourceCheckpoint (source ^. #journalSequence) (source ^. #previous), reason))
        Right found -> go (reverse found <> kept) rest
    decodeControl digest control
      | control ^. #version /= 1 = Left ("the platform transition control " <> sourceKeyText (control ^. #key) <> " has an unsupported version")
      | otherwise = case parseEither (body digest) (control ^. #body) of
          Left reason -> Left ("the platform transition control " <> sourceKeyText (control ^. #key) <> " is invalid: " <> T.pack reason)
          Right value -> Right value
    body :: ContentDigest -> Value -> Parser WaitingTransition
    body digest = withObject "platform transition" $ \o -> do
      unless (all (`elem` ["from", "to"]) (KM.keys o)) (fail "unknown field")
      WaitingTransition <$> o .: "from" <*> o .: "to" <*> pure digest

waitingObject :: ObjectName
waitingObject = ObjectName "worker-transition.json"

-- | The waiting transition, if any, and the generation of the object that
-- holds it, if it exists.
readWaiting :: FeedStore -> IO (Either FeedError (Maybe Generation, Maybe WaitingTransition))
readWaiting store = do
  outcome <- getObject (feedStoreOps store) waitingObject
  pure $ case outcome of
    GetUnknown reason -> Left (FeedTransport reason)
    ObjectAbsent -> Right (Nothing, Nothing)
    ObjectFound generation bytes -> (,) (Just generation) <$> decodeWaiting bytes

-- | Replace the object read at @generation@. 'False' when another writer
-- replaced it first.
writeWaiting :: FeedStore -> Maybe Generation -> Maybe WaitingTransition -> IO (Either FeedError Bool)
writeWaiting store generation waiting = do
  let bytes = encodeWaiting waiting
  outcome <- putObject (feedStoreOps store) (maybe IfAbsent IfGenerationMatches generation) waitingObject bytes
  case outcome of
    PutWritten _ -> pure (Right True)
    PutPreconditionFailed -> pure (Right False)
    PutNoEffect reason -> pure (Left (FeedTransport reason))
    PutUnknown reason -> do
      reread <- getObject (feedStoreOps store) waitingObject
      pure $ case reread of
        ObjectFound _ found | found == bytes -> Right True
        ObjectFound _ _ -> Right False
        _ -> Left (FeedTransport reason)

encodeWaiting :: Maybe WaitingTransition -> ByteString
encodeWaiting waiting =
  either (error . T.unpack) id . canonicalValue $
    object
      [ "version" .= (1 :: Int)
      , "transition" .= fmap (\value -> object ["from" .= (value ^. #from), "to" .= (value ^. #to), "review" .= (value ^. #review)]) waiting
      ]

decodeWaiting :: ByteString -> Either FeedError (Maybe WaitingTransition)
decodeWaiting bytes = first (FeedInvalid "worker-transition.json" . T.pack) $ do
  value <- eitherDecodeStrict' bytes
  flip parseEither value $ withObject "worker transition" $ \o -> do
    unless (all (`elem` ["version", "transition"]) (KM.keys o)) (fail "the worker transition has an unknown field")
    version <- o .: "version"
    unless (version == (1 :: Int)) (fail "unsupported worker transition version")
    o .: "transition" >>= \case
      Null -> pure Nothing
      found ->
        Just
          <$> withObject
            "transition"
            ( \t -> do
                unless (all (`elem` ["from", "to", "review"]) (KM.keys t)) (fail "the transition has an unknown field")
                WaitingTransition <$> t .: "from" <*> t .: "to" <*> t .: "review"
            )
            found

-- | One key per pair of releases; each release lowercased, with any
-- character a source key does not allow replaced by @-@.
upgradeKey :: WaitingTransition -> Either Text SourceKey
upgradeKey waiting = mkSourceKey ("platform.upgraded:" <> keyPart (waiting ^. #from) <> ":" <> keyPart (waiting ^. #to))
  where
    keyPart = T.map (\c -> let lower = toLower c in if (lower >= 'a' && lower <= 'z') || (lower >= '0' && lower <= '9') || lower `elem` ("-._/" :: String) then lower else '-')

upgradeCandidate :: WaitingTransition -> Either Text EventCandidate
upgradeCandidate waiting = do
  key <- upgradeKey waiting
  pure
    EventCandidate
      { key
      , resource = ResourceRef contextScope Nothing Nothing Nothing
      , occurredAt = Nothing
      , evidence = [Evidence "review" (waiting ^. #review)]
      , payload = PlatformUpgradedPayload (PlatformUpgrade (waiting ^. #from) (waiting ^. #to))
      }
