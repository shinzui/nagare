-- | What the release runner reads from a saved review (EP-229): the action of
-- each operation and the scopes it re-accepts at a new revision. A review with
-- no counted operation that re-accepts no scope other than the bootstrap
-- stamp is the converged state; a review that only re-accepts declarations
-- (a transition re-declares every scope from the target payload) is applied.
module Nagare.Harness.Release.Review
  ( ReviewCounts (..)
  , Counting (..)
  , readReviewCounts
  , reviewCounts
  , operationCount
  , isConverged
  , summaryCounts
  , readPlanSummary
  , ApplyOutcome (..)
  , applyOutcome
  , readApplyOutcome
  , ambiguousTransaction
  , stoppedAmbiguousAt
  )
where

import Data.Aeson (Value (..), eitherDecodeFileStrict, toJSON, withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither)
import Data.Char (isDigit)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Nagare.Contract.Release (TransitionPlanSummary)
import Nagare.Contract.Schema (fromNullable)
import Nagare.Contract.V1 (Outcome (..), TransactionOutcome (..))
import Nagare.Harness.Prelude

-- | The action tag of every operation, in review order, and the number of
-- scopes other than the bootstrap stamp whose desired revision differs from
-- the base, and the validations admission must still prove (EP-228 M1).
data ReviewCounts = ReviewCounts
  { actions :: ![Text]
  , reaccepted :: !Int
  , validations :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | Which operations count toward convergence. A source release before F124's
-- fix plans a check of every member on each bootstrap replan, so its
-- bootstrap loop counts only operations that are not @VerifyResource@.
data Counting = AllOperations | MutatingOperations
  deriving stock (Eq, Show, Generic)

readReviewCounts :: FilePath -> IO (Either Text ReviewCounts)
readReviewCounts directory = do
  decoded <- eitherDecodeFileStrict (directory <> "/review.json")
  pure (first (\reason -> T.pack (directory <> "/review.json: " <> reason)) (decoded >>= parseEither reviewCounts))

reviewCounts :: Value -> Parser ReviewCounts
reviewCounts = withObject "review" $ \review -> do
  operations <- review .: "operations"
  tags <- mapM actionTag operations
  base <- mapM revisionEntry =<< review .: "baseRevisions"
  desired <- mapM revisionEntry =<< review .: "desiredRevisions"
  let moved (scope, revision) = scopeName scope /= Just "bootstrap-stamp" && lookup scope base /= Just revision
  pending <- fromMaybe [] <$> (review .:? "validations" :: Parser (Maybe [Value]))
  pure ReviewCounts {actions = tags, reaccepted = length (filter moved desired), validations = length pending}
  where
    actionTag = withObject "operation" $ \entry -> do
      nested <- entry .:? "operation"
      let operation = fromMaybe (Object entry) nested
      action <- withObject "planned operation" (.:? "action") operation
      case action of
        Just (Object fields) -> fromMaybe "" <$> fields .:? "tag"
        _ -> pure ""
    revisionEntry = withObject "revision entry" $ \entry -> (,) <$> entry .: "scope" <*> (entry .: "revision" :: Parser Value)
    scopeName = \case
      Object fields -> case parseEither (.: "name") fields of
        Right name -> Just (name :: Text)
        Left _ -> Nothing
      _ -> Nothing

operationCount :: Counting -> ReviewCounts -> Int
operationCount counting counts = length (filter counted (counts ^. #actions))
  where
    counted tag = counting == AllOperations || tag /= "VerifyResource"

isConverged :: Counting -> ReviewCounts -> Bool
isConverged counting counts = operationCount counting counts == 0 && counts ^. #reaccepted == 0 && counts ^. #validations == 0

-- | The counts of a @platform transition plan --summary@ document, which
-- nagarectl computes from its own review types.
summaryCounts :: TransitionPlanSummary -> ReviewCounts
summaryCounts summary =
  ReviewCounts
    { actions = concat [replicate count tag | (tag, count) <- Map.toAscList (summary ^. #operations)]
    , reaccepted = length (summary ^. #reaccepted)
    , validations = fromMaybe 0 (summary ^. #validationCount)
    }

readPlanSummary :: FilePath -> IO (Either Text TransitionPlanSummary)
readPlanSummary path = first (\reason -> T.pack (path <> ": " <> reason)) <$> eitherDecodeFileStrict path

-- | How an @inventory apply@ or @inventory resume@ under @--contract 1@ ended,
-- as the release runner acts on it.
data ApplyOutcome
  = AppliedConverged
  | AppliedAmbiguous !Text
  | AppliedStopped !Text
  deriving stock (Eq, Show, Generic)

applyOutcome :: TransactionOutcome -> ApplyOutcome
applyOutcome document = case (document ^. #outcome, fromNullable (document ^. #transaction)) of
  (OutcomeConverged, _) -> AppliedConverged
  (OutcomeAmbiguous, Just transaction) -> AppliedAmbiguous transaction
  (other, transaction) ->
    AppliedStopped
      ( T.unwords
          ( [outcomeText other]
              <> maybe [] pure transaction
              <> maybe [] (\operation -> ["at", operation]) (fromNullable (document ^. #operation))
              <> maybe [] (\reason -> ["(" <> reason <> ")"]) (fromNullable (document ^. #detail))
              <> maybe [] (\problem -> ["(" <> problem ^. #detail <> ")"]) (fromNullable (document ^. #problem))
          )
      )

-- | The outcome document an apply or resume printed on stdout, with its
-- transaction and outcome name; a missing or unreadable one is a stop with
-- its reason.
readApplyOutcome :: FilePath -> IO (ApplyOutcome, Maybe Text, Text)
readApplyOutcome path = do
  decoded <- eitherDecodeFileStrict path
  pure $ case decoded of
    Left reason -> (AppliedStopped (T.pack ("no outcome document in " <> path <> ": " <> reason)), Nothing, "unreadable")
    Right document -> (applyOutcome document, fromNullable (document ^. #transaction), outcomeText (document ^. #outcome))

outcomeText :: Outcome -> Text
outcomeText outcome = case toJSON outcome of
  String text -> text
  _ -> T.pack (show outcome)

-- | The transaction of the last @ambiguous tx-… at …@ line, the stop
-- 'StoppedAmbiguous' renders in @inventory apply@'s human output.
ambiguousTransaction :: Text -> Maybe Text
ambiguousTransaction text = case mapMaybe stopped (T.lines text) of
  [] -> Nothing
  found -> Just (last found)
  where
    stopped line = do
      rest <- T.stripPrefix "ambiguous tx-" line
      let (hex, after) = T.span (\c -> isDigit c || c `elem` ("abcdef" :: String)) rest
      if " at " `T.isPrefixOf` after then Just ("tx-" <> hex) else Nothing

-- | Whether some line is the ambiguous stop of @transaction@.
stoppedAmbiguousAt :: Text -> Text -> Bool
stoppedAmbiguousAt transaction = any (T.isPrefixOf ("ambiguous " <> transaction <> " at ")) . T.lines
