-- | Shared broker discovery for @nagarectl broker@ commands.
module Nagare.Broker.Discover
  ( brokerLabelSelector
  , BrokerRow (..)
  , extractBrokerRows
  , listBrokers
  , getBroker
  , checkBrokerTopic
  , formatBrokerTable
  )
where

import Cradle
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.List (find)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Dsl.Broker (TopicName, topicNameText)
import Nagare.Dsl.Prelude
import System.Exit (ExitCode (..))
import "generic-lens" Data.Generics.Labels ()

brokerLabelSelector :: Text
brokerLabelSelector = "nagare.dev/managed-by=nagarectl,nagare.dev/broker"

data BrokerRow = BrokerRow
  { name :: !Text
  , provider :: !Text
  , version :: !Text
  , size :: !Text
  , bootstrap :: !Text
  , ready :: !Bool
  }
  deriving stock (Generic, Eq, Show)

extractBrokerRows :: ByteString -> Either Text [BrokerRow]
extractBrokerRows bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode statefulset list JSON: " <> T.pack e)
    Right v -> case lookupPath ["items"] v of
      Just (Aeson.Array items) -> Right (foldr step [] (V.toList items))
      _ -> Right []
  where
    step item acc = case rowFromItem item of
      Just r -> r : acc
      Nothing -> acc

rowFromItem :: Aeson.Value -> Maybe BrokerRow
rowFromItem item = do
  name' <- textAt ["metadata", "name"] item
  let ns = fromMaybe "personal" (textAt ["metadata", "namespace"] item)
  pure
    BrokerRow
      { name = name'
      , provider = fromMaybe "?" (labelAt "nagare.dev/broker-provider" item)
      , version = fromMaybe (versionFromImage item) (annotationAt "nagare.dev/version" item)
      , size = fromMaybe "?" (annotationAt "nagare.dev/size" item)
      , bootstrap = name' <> "." <> ns <> ".svc.cluster.local:9092"
      , ready = readyReplicas item >= 1
      }

versionFromImage :: Aeson.Value -> Text
versionFromImage item =
  case firstContainerImage item of
    Just img | T.elem ':' img -> T.takeWhileEnd (/= ':') img
    _ -> "?"

firstContainerImage :: Aeson.Value -> Maybe Text
firstContainerImage item =
  case lookupPath ["spec", "template", "spec", "containers"] item of
    Just (Aeson.Array cs) | not (V.null cs) -> textAt ["image"] (V.head cs)
    _ -> Nothing

readyReplicas :: Aeson.Value -> Int
readyReplicas item =
  case lookupPath ["status", "readyReplicas"] item of
    Just (Aeson.Number n) -> truncate n
    _ -> 0

listBrokers :: Text -> IO (Either Text [BrokerRow])
listBrokers ns = do
  (code, StdoutRaw out) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "get"
          , "statefulset"
          , "-n"
          , T.unpack ns
          , "-l"
          , T.unpack brokerLabelSelector
          , "-o"
          , "json"
          ]
        & silenceStderr
  pure $ case code of
    ExitFailure _ -> Right []
    ExitSuccess -> extractBrokerRows out

getBroker :: Text -> Text -> IO (Either Text BrokerRow)
getBroker ns name' = do
  rows <- listBrokers ns
  pure $ case rows of
    Left e -> Left e
    Right rs -> case find ((== name') . name) rs of
      Just r -> Right r
      Nothing -> Left ("no managed broker named '" <> name' <> "' in namespace " <> ns)

checkBrokerTopic :: Text -> BrokerRow -> TopicName -> IO (Either Text ())
checkBrokerTopic ns row topic = do
  (code, StdoutRaw _out) <-
    run $
      cmd "kubectl"
        & addArgs
          [ "exec"
          , "-n"
          , T.unpack ns
          , "pod/" <> T.unpack (row ^. #name <> "-0")
          , "--"
          , "rpk"
          , "topic"
          , "describe"
          , T.unpack (topicNameText topic)
          , "-X"
          , T.unpack ("brokers=" <> row ^. #bootstrap)
          ]
        & silenceStderr
  pure $ case code of
    ExitSuccess -> Right ()
    ExitFailure _ ->
      Left
        ( "broker '"
            <> row
              ^. #name
            <> "' has no reachable topic '"
            <> topicNameText topic
            <> "'"
        )

formatBrokerTable :: [BrokerRow] -> Text
formatBrokerTable [] = "(no managed brokers)\n"
formatBrokerTable rows = T.unlines (header : map line rows)
  where
    header =
      "  "
        <> pad 16 "NAME"
        <> pad 12 "PROVIDER"
        <> pad 12 "VERSION"
        <> pad 8 "SIZE"
        <> pad 8 "STATUS"
        <> "BOOTSTRAP"
    line r =
      T.concat
        [ "  "
        , pad 16 (r ^. #name)
        , pad 12 (r ^. #provider)
        , pad 12 (r ^. #version)
        , pad 8 (r ^. #size)
        , pad 8 (if r ^. #ready then "Ready" else "Pending")
        , r ^. #bootstrap
        ]
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (k : ks) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String s) -> Just s
  _ -> Nothing

labelAt :: Text -> Aeson.Value -> Maybe Text
labelAt key = textAt ["metadata", "labels", key]

annotationAt :: Text -> Aeson.Value -> Maybe Text
annotationAt key = textAt ["metadata", "annotations", key]
