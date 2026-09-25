-- | Context-guarded transport for Redpanda logical topics. Commands target
-- the exact StatefulSet compiled with each reviewed topic declaration.
module Nagare.Inventory.Adapters.BrokerRuntime
  ( TopicRuntimeConfig (..)
  , topicRuntimeOps
  , parseList
  , parseDescription
  ) where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Broker
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Resource.Types
import System.Exit (ExitCode (..))
import System.Process (proc, readCreateProcessWithExitCode)

data TopicRuntimeConfig = TopicRuntimeConfig
  { topicKubectlContext :: !Text
  , topicContextGuard :: !(IO (Either Text ()))
  , topicRuntimeSpecs :: !(Map ResourceId TopicBinding)
  }

topicRuntimeOps :: TopicRuntimeConfig -> TopicAdapterOps
topicRuntimeOps config = TopicAdapterOps
  { topicInspect = inspect
  , topicCreate = create
  , topicAlterRetention = alterRetention
  }
  where
    inspect resource = case Map.lookup resource (topicRuntimeSpecs config) of
      Nothing -> pure (TopicUnavailable "topic is absent from the reviewed declaration")
      Just binding -> case topicDeclaration binding ^. #address of
        BrokerTopic _ name -> do
          listed <- runRpk config binding
            ["topic", "list", nameText name, "--format", "json"]
          case listed >>= parseList name of
            Left reason -> pure (TopicUnavailable reason)
            Right False -> pure TopicMissing
            Right True -> do
              described <- runRpk config binding
                ["topic", "describe", nameText name, "--format", "json"]
              uid <- brokerUid config binding name
              pure $ case (described >>= parseDescription name, uid) of
                (Right (partitions, replicas, retention), Right physical) ->
                  TopicPresent physical partitions replicas retention
                (Left reason, _) -> TopicUnavailable reason
                (_, Left reason) -> TopicUnavailable reason
        _ -> pure (TopicUnavailable "topic has no reviewed broker address")
    create plan = case Map.lookup (topicPlanResource plan) (topicRuntimeSpecs config) of
      Nothing -> pure (AdapterEffectAmbiguous "topic declaration disappeared")
      Just binding -> do
        let args = ["topic", "create", "-p", tshow (topicPlanPartitions plan),
              "-r", tshow (topicPlanReplicas plan)]
              <> maybe [] (\ms -> ["-c", "retention.ms=" <> tshow ms]) (topicPlanRetentionMs plan)
              <> [nameText (topicPlanName plan)]
        result <- runRpk config binding args
        pure (case result of
          Right _ -> AdapterEffectCompleted
          Left reason -> AdapterEffectAmbiguous reason)
    alterRetention plan = case (Map.lookup (topicPlanResource plan) (topicRuntimeSpecs config), topicPlanRetentionMs plan) of
      (Just binding, Just milliseconds) -> do
        result <- runRpk config binding
          ["topic", "alter-config", nameText (topicPlanName plan),
            "--set", "retention.ms=" <> tshow milliseconds]
        pure (case result of
          Right _ -> AdapterEffectCompleted
          Left reason -> AdapterEffectAmbiguous reason)
      _ -> pure (AdapterEffectFailed (KnownNoEffect "reviewed topic retention target is absent"))

runRpk :: TopicRuntimeConfig -> TopicBinding -> [Text] -> IO (Either Text BS.ByteString)
runRpk config binding args = runKubectl config
  (["exec", "-n", nameText (topicNamespace binding),
    "pod/" <> nameText (topicBrokerName binding) <> "-0", "--", "rpk"]
    <> args <> ["-X", "brokers=" <> bootstrap binding])

bootstrap :: TopicBinding -> Text
bootstrap binding = nameText (topicBrokerName binding) <> "."
  <> nameText (topicNamespace binding) <> ".svc.cluster.local:9092"

runKubectl :: TopicRuntimeConfig -> [Text] -> IO (Either Text BS.ByteString)
runKubectl config args = do
  guarded <- topicContextGuard config
  case guarded of
    Left reason -> pure (Left ("broker context guard refused: " <> reason))
    Right () -> do
      let command = proc "kubectl" (map T.unpack
            (["--context", topicKubectlContext config] <> args))
      result <- try (readCreateProcessWithExitCode command "")
      pure $ case result of
        Left (_ :: IOException) -> Left "could not invoke broker topic transport"
        Right (ExitFailure _, _, _) -> Left "broker topic transport failed; inspect the target context before retry"
        Right (ExitSuccess, output, _) -> Right (TE.encodeUtf8 (T.pack output))

brokerUid :: TopicRuntimeConfig -> TopicBinding -> Name -> IO (Either Text PhysicalIdentity)
brokerUid config binding name = do
  result <- runKubectl config ["get", "statefulset", nameText (topicBrokerName binding),
    "-n", nameText (topicNamespace binding), "-o", "json"]
  pure $ do
    bytes <- result
    value <- first (const "broker StatefulSet observation is malformed") (eitherDecodeStrict bytes)
    uid <- first (const "broker StatefulSet has no UID") (parseEither parseUid value)
    mkPhysicalIdentity ("broker-statefulset://" <> uid <> "/topic/" <> nameText name)
  where
    parseUid :: Value -> Parser Text
    parseUid = withObject "StatefulSet" $ \o -> o .: "metadata" >>= withObject "metadata" (.: "uid")

parseList :: Name -> BS.ByteString -> Either Text Bool
parseList wanted bytes = do
  rows <- first (const "rpk topic list response is malformed") (eitherDecodeStrict bytes)
  listed <- first (const "rpk topic list response has invalid entries")
    (traverse (parseEither parseRow) (rows :: [Value]))
  case listed of
    [(name, partitions, replicas)]
      | name == nameText wanted && partitions == 0 && replicas == 0 -> Right False
      | name == nameText wanted && partitions > 0 && replicas > 0 -> Right True
    _ -> Left "rpk topic list did not return one unambiguous named topic"
  where
    parseRow :: Value -> Parser (Text, Int, Int)
    parseRow = withObject "topic list row" $ \o ->
      (,,) <$> o .: "name" <*> o .: "partitions" <*> o .: "replicas"

parseDescription :: Name -> BS.ByteString -> Either Text (Int, Int, Maybe Int)
parseDescription wanted bytes = do
  rows <- first (const "rpk topic description is malformed") (eitherDecodeStrict bytes)
  details <- first (const "rpk topic description has invalid fields")
    (traverse (parseEither parseRow) (rows :: [Value]))
  case details of
    [(name, partitions, replicas, retention)] | name == nameText wanted
      && partitions > 0 && replicas > 0 -> Right (partitions, replicas, retention)
    _ -> Left "rpk topic description differs from the requested topic"
  where
    parseRow :: Value -> Parser (Text, Int, Int, Maybe Int)
    parseRow = withObject "topic description" $ \o -> do
      (name, partitions, replicas) <- o .: "summary" >>= withObject "summary" (\summary ->
        (,,) <$> summary .: "name" <*> summary .: "partitions" <*> summary .: "replicas")
      configs <- o .: "configs" :: Parser [Value]
      entries <- traverse (withObject "topic config" (\entry ->
        (,) <$> entry .: "key" <*> entry .: "value")) configs
      let retention = lookup ("retention.ms" :: Text) entries
      parsedRetention <- traverse (\value -> case reads (T.unpack value) of
        [(number, "")] -> pure number
        _ -> fail "retention.ms is not an integer") retention
      pure (name, partitions, replicas, parsedRetention)

tshow :: Show a => a -> Text
tshow = T.pack . show
