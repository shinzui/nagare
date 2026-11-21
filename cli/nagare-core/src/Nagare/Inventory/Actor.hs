-- | Who a review says applied it, and where its change came from (EP-247).
-- The actor is asserted by the client from its context, not proved
-- (ADR 35). An unnamed operator is the default and is never written to a
-- review, so every operator review keeps its earlier bytes and digest.
module Nagare.Inventory.Actor
  ( Actor (..)
  , actorText
  , actorKindText
  , actorName
  , anonymousOperator
  , validActorName
  , actorFromNames
  , ReviewSource (..)
  , emptyReviewSource
  , nonEmptySource
  , setReviewSource
  , currentReviewSource
  )
where

import Control.Monad (forM_)
import Data.Aeson
  ( FromJSON (parseJSON)
  , ToJSON (toJSON)
  , Value (Null)
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.KeyMap qualified as KM
import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import System.IO.Unsafe (unsafePerformIO)

-- | An operator, optionally named so several operators later need no wire
-- change, or a named delegated deployer.
data Actor = OperatorActor !(Maybe Text) | DeployerActor !Text
  deriving stock (Eq, Ord, Show, Generic)

anonymousOperator :: Actor
anonymousOperator = OperatorActor Nothing

actorKindText :: Actor -> Text
actorKindText = \case
  OperatorActor _ -> "operator"
  DeployerActor _ -> "deployer"

actorName :: Actor -> Maybe Text
actorName = \case
  OperatorActor name -> name
  DeployerActor name -> Just name

-- | @operator@, @operator:NAME@ or @deployer:NAME@.
actorText :: Actor -> Text
actorText actor = actorKindText actor <> maybe "" (":" <>) (actorName actor)

-- | A DNS label: lowercase letters, digits and inner hyphens, 1 to 63 bytes.
validActorName :: Text -> Bool
validActorName name =
  not (T.null name)
    && T.length name <= 63
    && T.all (\c -> isAsciiLower c || isDigit c || c == '-') name
    && T.head name /= '-'
    && T.last name /= '-'

-- | The actor a context asserts from @NAGARE_DEPLOYER@ and @NAGARE_OPERATOR@.
-- A context that names both is refused.
actorFromNames :: Maybe Text -> Maybe Text -> Either Text Actor
actorFromNames deployer operator = case (deployer, operator) of
  (Just _, Just _) -> Left "a context sets both NAGARE_DEPLOYER and NAGARE_OPERATOR; a deployer context names no operator"
  (Just name, Nothing)
    | validActorName name -> Right (DeployerActor name)
    | otherwise -> Left "NAGARE_DEPLOYER must be a DNS label"
  (Nothing, Just name)
    | validActorName name -> Right (OperatorActor (Just name))
    | otherwise -> Left "NAGARE_OPERATOR must be a DNS label"
  (Nothing, Nothing) -> Right anonymousOperator

instance ToJSON Actor where
  toJSON actor = object ["kind" .= actorKindText actor, "name" .= maybe Null toJSON (actorName actor)]

instance FromJSON Actor where
  parseJSON = withObject "Actor" $ \o -> do
    unless (all (`elem` ["kind", "name"]) (KM.keys o)) (fail "actor has an unknown field")
    kind <- o .: "kind"
    name <- o .:? "name"
    forM_ name $ \value -> unless (validActorName value) (fail "actor name is not a DNS label")
    case (kind :: Text, name) of
      ("operator", _) -> pure (OperatorActor name)
      ("deployer", Just value) -> pure (DeployerActor value)
      ("deployer", Nothing) -> fail "a deployer actor requires a name"
      _ -> fail "actor kind must be operator or deployer"

-- | The repository, commit and CI run a change came from. Each part is
-- optional; a source with no part is not recorded.
data ReviewSource = ReviewSource
  { repository :: !(Maybe Text)
  , revision :: !(Maybe Text)
  , run :: !(Maybe Text)
  }
  deriving stock (Eq, Ord, Show, Generic)

emptyReviewSource :: ReviewSource
emptyReviewSource = ReviewSource Nothing Nothing Nothing

nonEmptySource :: ReviewSource -> Maybe ReviewSource
nonEmptySource source
  | source == emptyReviewSource = Nothing
  | otherwise = Just source

instance ToJSON ReviewSource where
  toJSON source =
    object
      ( ["repository" .= value | Just value <- [source ^. #repository]]
          <> ["revision" .= value | Just value <- [source ^. #revision]]
          <> ["run" .= value | Just value <- [source ^. #run]]
      )

instance FromJSON ReviewSource where
  parseJSON = withObject "ReviewSource" $ \o -> do
    unless (all (`elem` ["repository", "revision", "run"]) (KM.keys o)) (fail "review source has an unknown field")
    source <- ReviewSource <$> o .:? "repository" <*> o .:? "revision" <*> o .:? "run"
    when (source == emptyReviewSource) (fail "review source names nothing")
    when (any (maybe False T.null) [source ^. #repository, source ^. #revision, source ^. #run]) (fail "review source has an empty part")
    pure source

-- | The command's source, set once from its options before planning. A
-- process plans at most one review per command, so a process-wide value
-- reaches the one preparation path without threading every caller.
reviewSourceRef :: IORef ReviewSource
reviewSourceRef = unsafePerformIO (newIORef emptyReviewSource)
{-# NOINLINE reviewSourceRef #-}

-- | Merge the given parts over the current ones; an absent part keeps its value.
setReviewSource :: ReviewSource -> IO ()
setReviewSource next = do
  current <- readIORef reviewSourceRef
  writeIORef
    reviewSourceRef
    ReviewSource
      { repository = (next ^. #repository) <|> (current ^. #repository)
      , revision = (next ^. #revision) <|> (current ^. #revision)
      , run = (next ^. #run) <|> (current ^. #run)
      }

currentReviewSource :: IO (Maybe ReviewSource)
currentReviewSource = nonEmptySource <$> readIORef reviewSourceRef
