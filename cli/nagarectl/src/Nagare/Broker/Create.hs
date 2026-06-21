-- | @nagarectl broker create redpanda NAME@: build a typed broker from flags or
-- a config-as-program file, render EP-76's manifests, apply them idempotently,
-- and wait for the Redpanda StatefulSet to become ready.
module Nagare.Broker.Create
  ( BrokerCreateParams (..)
  , buildBroker
  , runBrokerCreate
  )
where

import Cradle
import Data.ByteString (ByteString)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Broker.Topic (reconcileBrokerTopics, renderTopicPlan)
import Nagare.Deploy (applyManifests, waitForRollout)
import Nagare.Dsl.Broker
import Nagare.Dsl.Broker.Render (brokerBootstrapServers, brokerStatefulSetName, renderBroker)
import Nagare.Dsl.Load (loadBroker, renderLoadError)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types
  ( Resources (..)
  , mkNamespace
  , mkQuantity
  , namespaceText
  , quantityText
  )
import System.Exit (exitFailure)
import System.IO (stderr)
import "generic-lens" Data.Generics.Labels ()

data BrokerCreateParams = BrokerCreateParams
  { namespace :: !Text
  , version :: !(Maybe Text)
  , size :: !(Maybe Text)
  , cpu :: !(Maybe Text)
  , memory :: !(Maybe Text)
  , config :: !(Maybe FilePath)
  , dryRun :: !Bool
  , redpandaSmp :: !(Maybe Int)
  , redpandaMemory :: !(Maybe Text)
  , topics :: ![Text]
  , topicPartitions :: !(Maybe Int)
  , topicRetentionMs :: !(Maybe Int)
  }
  deriving stock (Generic, Show)

defaultSize :: Text
defaultSize = "5Gi"

buildBroker :: BrokerProvider -> Text -> BrokerCreateParams -> Either Text Broker
buildBroker provider nameT params = do
  name' <- mkBrokerName nameT
  version' <- case params ^. #version of
    Nothing -> Right (defaultBrokerVersion provider)
    Just v -> mkBrokerVersion provider v
  namespace' <- mkNamespace (params ^. #namespace)
  size' <- mkQuantity (fromMaybe defaultSize (params ^. #size))
  resources' <- buildResources (params ^. #cpu) (params ^. #memory)
  redpandaMemory' <- traverse mkQuantity (params ^. #redpandaMemory)
  sizing' <- mkBrokerSizing (Just size') resources' (params ^. #redpandaSmp) redpandaMemory'
  topics' <- traverse (buildTopic params) (params ^. #topics)
  Right
    Broker
      { name = name'
      , provider = provider
      , version = version'
      , namespace = namespace'
      , storageSize = size'
      , sizing = sizing'
      , topics = topics'
      }

buildResources :: Maybe Text -> Maybe Text -> Either Text (Maybe Resources)
buildResources Nothing Nothing = Right Nothing
buildResources mc mm = do
  cl <- traverse mkQuantity mc
  ml <- traverse mkQuantity mm
  Right (Just Resources {cpu = Nothing, memory = Nothing, cpuLimit = cl, memoryLimit = ml})

buildTopic :: BrokerCreateParams -> Text -> Either Text BrokerTopic
buildTopic params topicT = do
  topicName' <- mkTopicName topicT
  mkBrokerTopic topicName' (fromMaybe 1 (params ^. #topicPartitions)) 1 (params ^. #topicRetentionMs)

runBrokerCreate :: BrokerProvider -> Text -> BrokerCreateParams -> IO ()
runBrokerCreate provider nameT params = do
  broker <- case params ^. #config of
    Just path -> do
      eBroker <- loadBroker path
      case eBroker of
        Left err -> dieT (renderLoadError err)
        Right b -> pure b
    Nothing -> orDie (buildBroker provider nameT params)
  let name = brokerNameText (broker ^. #name)
      ns = namespaceText (broker ^. #namespace)
      manifests = renderBroker broker
      bootstrap = brokerBootstrapServers broker
  if params ^. #dryRun
    then do
      mapM_ printManifest manifests
      TIO.putStr (renderTopicPlan broker)
      TIO.putStrLn ("Would create broker " <> name <> " (" <> brokerProviderToken (broker ^. #provider) <> ")")
      TIO.putStrLn ("Bootstrap servers: " <> bootstrap)
      TIO.putStrLn "No cluster changes were applied."
    else do
      applyManifests manifests
      stampMetadata ns name broker
      waitForRollout ns (brokerStatefulSetName name)
      reconcileBrokerTopics broker
      TIO.putStrLn ("Created broker " <> name <> " at " <> bootstrap)

stampMetadata :: Text -> Text -> Broker -> IO ()
stampMetadata ns name broker =
  run_ $
    cmd "kubectl"
      & addArgs
        [ "annotate"
        , "statefulset/" <> T.unpack name
        , "-n"
        , T.unpack ns
        , "--overwrite"
        , "nagare.dev/version=" <> T.unpack (brokerVersionText (broker ^. #version))
        , "nagare.dev/size=" <> T.unpack (quantityText (broker ^. #storageSize))
        ]

printManifest :: ByteString -> IO ()
printManifest m = do
  TIO.putStrLn ("--- " <> manifestKind m <> " manifest ---")
  TIO.putStr (TE.decodeUtf8 m)
  TIO.putStrLn ""

manifestKind :: ByteString -> Text
manifestKind m =
  case [T.strip (T.drop 5 l) | l <- T.lines (TE.decodeUtf8 m), "kind:" `T.isPrefixOf` l] of
    (k : _) -> k
    [] -> "resource"

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("nagarectl: " <> msg)
  exitFailure

orDie :: Either Text a -> IO a
orDie = either dieT pure
