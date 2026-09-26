-- | Read-only compatibility rendering for @nagarectl broker create --dry-run@.
-- Live create uses the reviewed standalone broker scope.
module Nagare.Broker.Create
  ( BrokerCreateParams (..)
  , buildBroker
  , resolveBroker
  , runBrokerCreate
  , runBrokerCreateWithGuard
  )
where

import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Broker.Topic (renderTopicPlan)
import Nagare.Cluster.Namespace (NamespacePurpose (..), renderNamespace)
import Nagare.Dsl.Broker
import Nagare.Dsl.Broker.Render (brokerBootstrapServers, renderBroker)
import Nagare.Dsl.Load (loadBroker, renderLoadError)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Types
  ( Resources (..)
  , mkNamespace
  , mkQuantity
  , namespaceText
  )
import System.Exit (exitFailure)
import System.IO (stderr)

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
      , logicalKey = Nothing
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
runBrokerCreate provider nameT params =
  runBrokerCreateWithGuard provider nameT params (const (pure ()))

-- | Guard the resolved typed broker, since Config.hs can differ from argv.
runBrokerCreateWithGuard
  :: BrokerProvider -> Text -> BrokerCreateParams -> (Broker -> IO ()) -> IO ()
runBrokerCreateWithGuard provider nameT params checkOwnership = do
  unless (params ^. #dryRun) $
    dieT "live broker create requires a reviewed standalone broker scope"
  broker <- resolveBroker provider nameT params
  checkOwnership broker
  let name = brokerNameText (broker ^. #name)
      ns = namespaceText (broker ^. #namespace)
      manifests = renderBroker broker
      bootstrap = brokerBootstrapServers broker
  namespaceManifest <- orDie (renderNamespace ApplicationNamespace ns)
  TIO.putStrLn "--- Namespace manifest ---"
  TIO.putStr (TE.decodeUtf8 namespaceManifest)
  TIO.putStrLn ""
  mapM_ printManifest manifests
  TIO.putStr (renderTopicPlan broker)
  TIO.putStrLn ("Would create broker " <> name <> " (" <> brokerProviderToken (broker ^. #provider) <> ")")
  TIO.putStrLn ("Bootstrap servers: " <> bootstrap)
  TIO.putStrLn "No cluster changes were applied."

resolveBroker :: BrokerProvider -> Text -> BrokerCreateParams -> IO Broker
resolveBroker provider nameT params = case params ^. #config of
    Just path -> do
      eBroker <- loadBroker path
      case eBroker of
        Left err -> dieT (renderLoadError err)
        Right b -> pure b
    Nothing -> orDie (buildBroker provider nameT params)

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
