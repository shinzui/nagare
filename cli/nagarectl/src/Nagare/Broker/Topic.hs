-- | Topic reconciliation for @nagarectl broker create@.
--
-- Redpanda topic management is provider-specific, but this module consumes the
-- provider-neutral 'BrokerTopic' declarations from @nagare-dsl@ and keeps the
-- command construction testable.
module Nagare.Broker.Topic
  ( TopicStatus (..)
  , renderTopicPlan
  , rpkTopicCreateArgs
  , parseTopicDescription
  , reconcileBrokerTopics
  )
where

import Control.Monad (forM_)
import Cradle
import Data.ByteString (ByteString)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Dsl.Broker
import Nagare.Dsl.Broker.Render (brokerBootstrapServers, brokerStatefulSetName)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (namespaceText)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (stderr)
import "generic-lens" Data.Generics.Labels ()

data TopicStatus = TopicStatus
  { name :: !Text
  , partitions :: !Int
  , replicationFactor :: !Int
  , retentionMs :: !(Maybe Int)
  }
  deriving stock (Generic, Eq, Show)

renderTopicPlan :: Broker -> Text
renderTopicPlan broker
  | null (broker ^. #topics) = "No topics declared.\n"
  | otherwise =
      T.unlines $
        "Would reconcile topics:" : map (("  " <>) . renderTopic) (broker ^. #topics)
  where
    renderTopic topic =
      T.concat
        [ topicNameText (topic ^. #name)
        , " partitions="
        , tshow (topic ^. #partitions)
        , " replicationFactor="
        , tshow (topic ^. #replicationFactor)
        , maybe "" ((" retentionMs=" <>) . tshow) (topic ^. #retentionMs)
        ]

rpkTopicCreateArgs :: Text -> BrokerTopic -> [Text]
rpkTopicCreateArgs bootstrap topic =
  [ "topic"
  , "create"
  , "--if-not-exists"
  , "-p"
  , tshow (topic ^. #partitions)
  , "-r"
  , tshow (topic ^. #replicationFactor)
  ]
    <> maybe [] (\ms -> ["-c", "retention.ms=" <> tshow ms]) (topic ^. #retentionMs)
    <> [ topicNameText (topic ^. #name)
       , "-X"
       , "brokers=" <> bootstrap
       ]

rpkTopicDescribeArgs :: Text -> BrokerTopic -> [Text]
rpkTopicDescribeArgs bootstrap topic =
  [ "topic"
  , "describe"
  , topicNameText (topic ^. #name)
  , "-X"
  , "brokers=" <> bootstrap
  ]

parseTopicDescription :: ByteString -> Either Text TopicStatus
parseTopicDescription raw = do
  name' <- findSummary "NAME"
  partitions' <- parseIntField "PARTITIONS" =<< findSummary "PARTITIONS"
  replicas' <- parseIntField "REPLICAS" =<< findSummary "REPLICAS"
  retention' <- traverse (parseIntField "retention.ms") (findConfig "retention.ms")
  Right
    TopicStatus
      { name = name'
      , partitions = partitions'
      , replicationFactor = replicas'
      , retentionMs = retention'
      }
  where
    ls = map T.words (T.lines (TE.decodeUtf8 raw))
    findSummary key =
      case [v | [k, v] <- ls, k == key] of
        v : _ -> Right v
        [] -> Left ("rpk topic describe output missing " <> key)
    findConfig key =
      case [v | (k : v : _) <- ls, k == key] of
        v : _ -> Just v
        [] -> Nothing
    parseIntField field t =
      case reads (T.unpack t) of
        [(n, "")] -> Right n
        _ -> Left ("could not parse " <> field <> " as an integer: " <> t)

reconcileBrokerTopics :: Broker -> IO ()
reconcileBrokerTopics broker =
  forM_ (broker ^. #topics) $ \topic -> do
    _ <- runRpk broker (rpkTopicCreateArgs (brokerBootstrapServers broker) topic)
    status <- describeTopic broker topic
    case topicMatches topic status of
      Right () ->
        TIO.putStrLn ("Reconciled topic " <> topicNameText (topic ^. #name))
      Left err -> dieT err

describeTopic :: Broker -> BrokerTopic -> IO TopicStatus
describeTopic broker topic = do
  out <- runRpk broker (rpkTopicDescribeArgs (brokerBootstrapServers broker) topic)
  case parseTopicDescription out of
    Right status -> pure status
    Left err -> dieT err

topicMatches :: BrokerTopic -> TopicStatus -> Either Text ()
topicMatches desired actual
  | topicNameText (desired ^. #name) /= actual ^. #name =
      Left
        ( "rpk described topic "
            <> actual
              ^. #name
            <> " while reconciling "
            <> topicNameText (desired ^. #name)
        )
  | desired ^. #partitions /= actual ^. #partitions =
      mismatch "partitions" (tshow (desired ^. #partitions)) (tshow (actual ^. #partitions))
  | desired ^. #replicationFactor /= actual ^. #replicationFactor =
      mismatch "replication factor" (tshow (desired ^. #replicationFactor)) (tshow (actual ^. #replicationFactor))
  | Just expected <- desired ^. #retentionMs
  , Just observed <- actual ^. #retentionMs
  , expected /= observed =
      mismatch "retention.ms" (tshow expected) (tshow observed)
  | Just expected <- desired ^. #retentionMs
  , Nothing <- actual ^. #retentionMs =
      Left
        ( "topic "
            <> topicNameText (desired ^. #name)
            <> " has no reported retention.ms; expected "
            <> tshow expected
        )
  | otherwise = Right ()
  where
    mismatch field expected observed =
      Left
        ( "topic "
            <> topicNameText (desired ^. #name)
            <> " has incompatible "
            <> field
            <> ": expected "
            <> expected
            <> ", observed "
            <> observed
        )

runRpk :: Broker -> [Text] -> IO ByteString
runRpk broker rpkArgs = do
  let ns = namespaceText (broker ^. #namespace)
      pod = brokerStatefulSetName (brokerNameText (broker ^. #name)) <> "-0"
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs
          ( [ "exec"
            , "-n"
            , T.unpack ns
            , "pod/" <> T.unpack pod
            , "--"
            , "rpk"
            ]
              <> map T.unpack rpkArgs
          )
  case code of
    ExitSuccess -> pure out
    ExitFailure n ->
      dieT
        ( "rpk command failed with exit "
            <> tshow n
            <> ": rpk "
            <> T.unwords rpkArgs
        )

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure

tshow :: (Show a) => a -> Text
tshow = T.pack . show
