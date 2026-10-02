-- | Metadata-only namespace inspection through the shared Effectful transport.
module Nagare.Inventory.Collection.Runtime (observeCollectionNamespace) where

import Control.Monad (forM)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.List (nub, sort)
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Collection.Authority
import Nagare.Inventory.KubernetesTransport
import System.Exit (ExitCode (..))

observeCollectionNamespace :: KubernetesRuntimeConfig -> Text -> IO (Either Text ([Text], [CollectionNode]))
observeCollectionNamespace config ns = do
  before <- runtimeGuard config
  case before of
    Left reason -> pure (Left reason)
    Right () -> do
      discovery <- request ["api-resources", "--namespaced=true", "--verbs=list", "-o", "name"]
      case discovery of
        Left reason -> pure (Left reason)
        Right output -> do
          let apis = sort (nub (filter (not . T.null) (T.lines output)))
          if null apis || any (T.any (\c -> not (c `elem` (['a' .. 'z'] <> ['0' .. '9'] <> ".-")))) apis
            then pure (Left "namespace API discovery is empty or malformed")
            else do
              lists <- forM apis $ \resource -> do
                response <- request ["get", T.unpack resource, "--namespace", T.unpack ns, "-o", "json"]
                pure $ do
                  json <- response >>= first T.pack . eitherDecodeStrict . TE.encodeUtf8
                  values <-
                    first
                      T.pack
                      ( parseEither
                          ( withObject "namespace list" $ \o -> do
                              metadata <- o .: "metadata"
                              continuation <- withObject "list metadata" (\m -> m .:? "continue" .!= ("" :: Text)) metadata
                              unless (T.null continuation) (fail "incomplete paginated namespace list")
                              o .: "items"
                          )
                          json
                      )
                  nodes <- catMaybes <$> traverse (parseCollectionNode resource) values
                  unless (all ((== ns) . namespace) nodes) (Left "namespace list returned a foreign namespace")
                  pure nodes
              after <- runtimeGuard config
              pure $ do
                after
                nodes <- concat <$> sequence lists
                pure (apis, nodes)
  where
    request args = do
      result <- invokeKubectl config args ""
      pure $ case result of
        -- Kubernetes warning headers (for example Endpoints deprecation) are
        -- printed on stderr even when the complete list succeeds. Exit status
        -- and the parsed continuation metadata determine completeness.
        Right (ExitSuccess, output, _) -> Right (T.pack output)
        _ -> Left "complete namespace discovery/list unavailable; no collection authority"
