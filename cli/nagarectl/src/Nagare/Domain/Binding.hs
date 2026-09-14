-- | Fail-closed ownership checks and readiness waits for Knative custom domains.
-- A deployment may create an absent ClusterDomainClaim, but it must never
-- retarget a hostname already claimed by another namespace or routed to another
-- Service.
module Nagare.Domain.Binding
  ( BindingTarget (..)
  , BindingConflict (..)
  , ExistingBinding (..)
  , bindingConflict
  , extractExistingBindings
  , preflightDomainBindings
  , preflightDomainBindingsWith
  , applyAfterPreflight
  , waitForDomainBindings
  , renderBindingTarget
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (traverse_)
import Data.Functor (($>))
import Data.Generics.Labels ()
import Data.List (find)
import Data.Maybe (catMaybes)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Dsl.Prelude
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data BindingTarget = BindingTarget
  { host :: !Text
  , namespace :: !Text
  , service :: !Text
  }
  deriving stock (Generic, Eq, Show)

data BindingConflict
  = ClaimedByNamespace !Text
  | RoutedToService !Text !Text
  deriving stock (Generic, Eq, Show)

data ExistingBinding
  = ExistingClaim !Text !Text
  | ExistingRoute !Text !Text !Text
  deriving stock (Generic, Eq, Show)

bindingConflict :: BindingTarget -> [ExistingBinding] -> Maybe BindingConflict
bindingConflict target bindings =
  claimConflict <|> routeConflict
  where
    claimConflict =
      ClaimedByNamespace . claimNamespace
        <$> find
          (\case ExistingClaim claimHost claimNs -> claimHost == target ^. #host && claimNs /= target ^. #namespace; _ -> False)
          bindings
    routeConflict =
      toRouteConflict
        <$> find
          ( \case
              ExistingRoute routeHost routeNs routeService ->
                routeHost == target ^. #host
                  && (routeNs /= target ^. #namespace || routeService /= target ^. #service)
              _ -> False
          )
          bindings

    claimNamespace (ExistingClaim _ claimNs) = claimNs
    claimNamespace _ = ""
    toRouteConflict (ExistingRoute _ routeNs routeService) = RoutedToService routeNs routeService
    toRouteConflict _ = RoutedToService "" ""

extractExistingBindings :: ByteString -> ByteString -> Either Text [ExistingBinding]
extractExistingBindings claimsJson routesJson =
  (<>) <$> decodeItems "ClusterDomainClaim" claimItem claimsJson <*> decodeItems "DomainMapping" routeItem routesJson
  where
    claimItem item =
      ExistingClaim
        <$> requiredText "ClusterDomainClaim.metadata.name" ["metadata", "name"] item
        <*> requiredText "ClusterDomainClaim.spec.namespace" ["spec", "namespace"] item
    routeItem item =
      ExistingRoute
        <$> requiredText "DomainMapping.metadata.name" ["metadata", "name"] item
        <*> requiredText "DomainMapping.metadata.namespace" ["metadata", "namespace"] item
        <*> requiredText "DomainMapping.spec.ref.name" ["spec", "ref", "name"] item

preflightDomainBindings :: [BindingTarget] -> IO (Either Text ())
preflightDomainBindings [] = pure (Right ())
preflightDomainBindings targets =
  preflightDomainBindingsWith queryExistingBindings targets

preflightDomainBindingsWith :: IO (Either Text [ExistingBinding]) -> [BindingTarget] -> IO (Either Text ())
preflightDomainBindingsWith _ [] = pure (Right ())
preflightDomainBindingsWith query targets = do
  observed <- query
  pure $ do
    bindings <- observed
    traverse_ (ensureAvailable bindings) targets
  where
    ensureAvailable bindings target =
      case bindingConflict target bindings of
        Nothing -> Right ()
        Just (ClaimedByNamespace owner) ->
          Left
            ( "domain "
                <> target ^. #host
                <> " is claimed by namespace "
                <> owner
                <> "; refusing to deploy service "
                <> target ^. #namespace
                <> "/"
                <> target ^. #service
            )
        Just (RoutedToService ownerNamespace ownerService) ->
          Left
            ( "domain "
                <> target ^. #host
                <> " is routed to service "
                <> ownerNamespace
                <> "/"
                <> ownerService
                <> "; refusing to deploy service "
                <> target ^. #namespace
                <> "/"
                <> target ^. #service
            )

-- | Run an apply action only after a successful preflight. This small seam
-- makes the no-mutation-on-conflict guarantee directly testable.
applyAfterPreflight :: IO (Either Text ()) -> IO () -> IO (Either Text ())
applyAfterPreflight preflight apply = do
  checked <- preflight
  case checked of
    Left err -> pure (Left err)
    Right () -> apply $> Right ()

waitForDomainBindings :: Int -> [BindingTarget] -> IO (Either Text ())
waitForDomainBindings timeoutSeconds = go
  where
    go [] = pure (Right ())
    go (target : rest) = do
      waited <-
        kubectl
          [ "wait"
          , "--for=condition=Ready"
          , "--timeout=" <> show timeoutSeconds <> "s"
          , "domainmapping/" <> T.unpack (target ^. #host)
          , "-n"
          , T.unpack (target ^. #namespace)
          ]
      case waited of
        Right _ -> go rest
        Left waitError -> do
          detail <- domainFailureDetail target
          pure . Left $
            "domain mapping "
              <> renderBindingTarget target
              <> " did not become ready: "
              <> waitError
              <> maybe "" ("; " <>) detail

renderBindingTarget :: BindingTarget -> Text
renderBindingTarget target =
  target ^. #host <> " -> " <> target ^. #namespace <> "/" <> target ^. #service

queryExistingBindings :: IO (Either Text [ExistingBinding])
queryExistingBindings = do
  claims <- kubectl ["get", "clusterdomainclaims.networking.internal.knative.dev", "-o", "json"]
  routes <- kubectl ["get", "domainmappings.serving.knative.dev", "-A", "-o", "json"]
  pure $ do
    claimsJson <- first ("could not query domain claims: " <>) claims
    routesJson <- first ("could not query domain mappings: " <>) routes
    extractExistingBindings claimsJson routesJson

domainFailureDetail :: BindingTarget -> IO (Maybe Text)
domainFailureDetail target = do
  mappingResult <-
    kubectl
      [ "get"
      , "domainmapping"
      , T.unpack (target ^. #host)
      , "-n"
      , T.unpack (target ^. #namespace)
      , "-o"
      , "json"
      ]
  certificates <- kubectl ["get", "certificate", "-n", T.unpack (target ^. #namespace), "-o", "json"]
  let mappingDetail = either (const Nothing) (conditionFromSingle "DomainMapping") mappingResult
      certificateDetail = either (const Nothing) (matchingCertificateCondition (target ^. #host)) certificates
  pure (T.intercalate "; " <$> nonEmptyText (catMaybes [mappingDetail, certificateDetail]))

conditionFromSingle :: Text -> ByteString -> Maybe Text
conditionFromSingle kind bytes = do
  value <- either (const Nothing) Just (eitherDecodeStrict bytes)
  conditionSummary kind value

matchingCertificateCondition :: Text -> ByteString -> Maybe Text
matchingCertificateCondition domain bytes = do
  value <- either (const Nothing) Just (eitherDecodeStrict bytes)
  Aeson.Array items <- lookupPath ["items"] value
  certificate <- find (coversDomain domain) (V.toList items)
  conditionSummary "Certificate" certificate
  where
    coversDomain host item = case lookupPath ["spec", "dnsNames"] item of
      Just (Aeson.Array names) -> Aeson.String host `elem` V.toList names
      _ -> False

conditionSummary :: Text -> Aeson.Value -> Maybe Text
conditionSummary kind value = do
  Aeson.Array conditions <- lookupPath ["status", "conditions"] value
  condition <- find (\item -> textAt ["type"] item == Just "Ready") (V.toList conditions)
  let status = fromMaybe "Unknown" (textAt ["status"] condition)
      reason = textAt ["reason"] condition
      message = textAt ["message"] condition
      details = T.intercalate ": " (catMaybes [reason, message])
  pure (kind <> " Ready=" <> status <> if T.null details then "" else " (" <> details <> ")")

decodeItems :: Text -> (Aeson.Value -> Either Text a) -> ByteString -> Either Text [a]
decodeItems kind parseItem bytes = do
  value <- first (\err -> "could not decode " <> kind <> " list JSON: " <> T.pack err) (eitherDecodeStrict bytes)
  case lookupPath ["items"] value of
    Just (Aeson.Array items) -> traverse parseItem (V.toList items)
    _ -> Left (kind <> " list JSON has no items array")

requiredText :: Text -> [Text] -> Aeson.Value -> Either Text Text
requiredText label path value =
  maybe (Left (label <> " is missing or not text")) Right (textAt path value)

lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] value = Just value
lookupPath (key : keys) (Aeson.Object object) = KeyMap.lookup (Key.fromText key) object >>= lookupPath keys
lookupPath _ _ = Nothing

textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path value = case lookupPath path value of
  Just (Aeson.String textValue) -> Just textValue
  _ -> Nothing

nonEmptyText :: [Text] -> Maybe [Text]
nonEmptyText [] = Nothing
nonEmptyText values = Just values

kubectl :: [String] -> IO (Either Text ByteString)
kubectl args = do
  result <- try (readProcessWithExitCode "kubectl" args "") :: IO (Either IOException (ExitCode, String, String))
  pure $ case result of
    Left err -> Left ("kubectl could not start: " <> T.pack (show err))
    Right (ExitSuccess, stdout, _) -> Right (BC.pack stdout)
    Right (ExitFailure code, _, stderr) ->
      Left
        ( "kubectl exited "
            <> T.pack (show code)
            <> if null stderr then "" else ": " <> T.strip (T.pack stderr)
        )
