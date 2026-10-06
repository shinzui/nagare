-- | Host-bounded Cloudflare requests with durable acceptance receipts. An
-- acceptance is not proof of worldwide cache eviction. Unknown writes never replay.
module Nagare.Inventory.CdnPurge
  ( PurgeBinding
  , PurgeOps (..)
  , purgeBindings
  , withCdnPurge
  , parsePurgeAcceptance
  , purgeReceiptKey
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict', object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (FailureClass (KnownNoEffect))
import Nagare.Resource.Cdn (validateCdnPurgePaths)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (RecoveryClass (OperatorRecovery))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue)

data PurgeBinding = PurgeBinding !ResourceId !Name !(Maybe Name) ![Text]
  deriving stock (Eq, Show)

data PurgeOps = PurgeOps
  { purgeReadReceipt :: !(ContentDigest -> IO (Either Text (Maybe ByteString)))
  , purgeWriteReceipt :: !(ContentDigest -> ByteString -> IO (Either Text ()))
  , purgeSubmit :: !(Name -> Maybe Name -> [Text] -> IO (Either Text Text))
  }

purgeBindings :: [ScopeDeclaration] -> Map ResourceId ManagedResource -> Either Text (Map ContentDigest PurgeBinding)
purgeBindings scopes accepted = do
  entries <-
    traverse
      bind
      [ (scope, op)
      | scope <- scopes
      , bundle <- scopeBundles scope
      , op <- bundle ^. #operations
      , op ^. #operationKind `elem` [PurgeCdnCache, PurgeCdnZone]
      ]
  unless (length entries == Map.size (Map.fromList entries)) (Left "duplicate CDN purge intent")
  pure (Map.fromList entries)
  where
    bind (scope, op) = do
      target <- case NE.toList (op ^. #affects) of
        [single] -> Right single
        _ -> Left "purge must affect one accepted DNS resource"
      resource <- maybe (Left "purge DNS resource has no accepted ownership") Right (Map.lookup target accepted)
      unless
        ( resource ^. #owner == scopeId scope
            && op ^. #recovery == OperatorRecovery
        )
        (Left "purge owner or recovery contract differs")
      (zone, host) <- case (op ^. #operationKind, resource ^. #address, scopeKind (scopeId scope)) of
        (PurgeCdnCache, CloudflareDnsRecord zone host, kind) | kind `elem` [Application, Standalone] -> Right (zone, Just host)
        (PurgeCdnZone, CloudflareRuleset zone, Platform)
          | any (elemZone zone) (scopeBundles scope) -> Right (zone, Nothing)
        _ -> Left "purge requires its accepted workload DNS or explicit platform zone owner"
      paths <- case op ^. #inputs of
        [CdnPathsInput paths] -> do
          normalized <- validateCdnPurgePaths paths
          unless (normalized == paths) (Left "purge paths are not canonical")
          pure paths
        _ -> Left "purge requires only its typed path input"
      when (host == Nothing && not (null paths)) (Left "whole-zone purge cannot contain paths")
      bytes <- canonicalValue (toJSON op)
      pure (contentDigest bytes, PurgeBinding target zone host paths)
    elemZone zone bundle = any (\case CloudflareZoneGrant z _ -> z == zone; _ -> False) (bundle ^. #grants)

purgeReceiptKey :: ContentDigest -> FilePath
purgeReceiptKey digest = "cdn-purge/" <> T.unpack (digestText digest) <> ".json"

withCdnPurge :: Map ContentDigest PurgeBinding -> PurgeOps -> Adapter -> Adapter
withCdnPurge bindings ops base =
  base
    { adapterPrepare = \operation ->
        if isPurge operation
          then case binding operation of
            Left reason -> pure (Left (PrepareRefused (plannedOperationId operation) reason))
            Right (PurgeBinding _ zone host paths) -> do
              prepared <- adapterPrepare base (asVerify operation)
              pure
                ( fmap
                    ( \native ->
                        native
                          { preparedPublicSummary =
                              ( case host of
                                  Nothing -> "request Cloudflare purge of ALL cached content in zone " <> nameText zone
                                  Just hostname ->
                                    "request Cloudflare cache purge for "
                                      <> nameText hostname
                                      <> (if null paths then " (this hostname only)" else " paths " <> T.intercalate ", " paths)
                              )
                                <> "; provider acceptance does not prove global eviction"
                          }
                    )
                    prepared
                )
          else adapterPrepare base operation
    , adapterPreflight = \operation native ->
        if isPurge operation
          then case binding operation of
            Left reason -> pure (Left reason)
            Right _ -> adapterPreflight base (asVerify operation) native
          else adapterPreflight base operation native
    , adapterExecute = \operation native ->
        if isPurge operation
          then execute operation native
          else adapterExecute base operation native
    , adapterVerify = \operation native ->
        if isPurge operation
          then verify operation native
          else adapterVerify base operation native
    , -- E's U2: a purge whose acceptance receipt is missing cannot be
      -- observed after the fact, so it settles unknown and ends only by an
      -- attested close. Every other operation settles as the base adapter's.
      adapterSettle = Just $ \operation native ->
        if isPurge operation
          then
            either
              (\why -> SettledUnknown why "an attested close (inventory close --attest); provider acceptance of a purge cannot be observed later")
              (const (SettledUnknown "the purge is proved accepted" "inventory resume"))
              <$> verify operation native
          else settleOperationWith base operation native
    , adapterRecover = \operation native ->
        if isPurge operation
          then do
            proof <- verify operation native
            pure (either RecoveryUnresolved RecoveryProvedComplete proof)
          else adapterRecover base operation native
    }
  where
    isPurge operation = plannedAction operation == RunDeclaredOperation && Map.member (plannedInputDigest operation) bindings
    asVerify operation = operation {plannedAction = VerifyResource}
    binding operation = do
      selected@(PurgeBinding resource _ _ _) <-
        maybe
          (Left "purge intent is absent")
          Right
          (Map.lookup (plannedInputDigest operation) bindings)
      unless
        (NE.toList (plannedResources operation) == [resource] && plannedRecovery operation == OperatorRecovery)
        (Left "purge operation differs from its typed declaration")
      pure selected
    verify operation native = case binding operation of
      Left reason -> pure (Left reason)
      Right _ -> do
        readback <- purgeReadReceipt ops (plannedInputDigest operation)
        pure $ do
          bytes <- readback >>= maybe (Left "purge acceptance is unresolved; no automatic replay") Right
          value <- first T.pack (eitherDecodeStrict' bytes)
          case value of
            Object fields
              | KM.size fields == 4
              , KM.lookup "schemaVersion" fields == Just (Number 1)
              , KM.lookup "intentDigest" fields == Just (toJSON (plannedInputDigest operation))
              , KM.lookup "nativeDigest" fields == Just (toJSON (contentDigest (preparedNativeBytes native)))
              , Just (String providerId) <- KM.lookup "providerRequestId" fields
              , validProviderId providerId ->
                  Right (contentDigest bytes)
            _ -> Left "purge receipt differs from this exact reviewed request"
    execute operation native = case binding operation of
      Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
      Right (PurgeBinding _ zone host paths) -> do
        existing <- purgeReadReceipt ops (plannedInputDigest operation)
        case existing of
          Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
          Right (Just _) -> do
            verified <- verify operation native
            pure (either (AdapterEffectFailed . KnownNoEffect) (const AdapterEffectCompleted) verified)
          Right Nothing -> do
            checked <- adapterPreflight base (asVerify operation) native
            case checked of
              Left reason -> pure (AdapterEffectFailed (KnownNoEffect reason))
              Right () -> do
                response <- purgeSubmit ops zone host paths
                case response of
                  Left reason -> pure (AdapterEffectAmbiguous reason)
                  Right providerId | validProviderId providerId -> case canonicalValue
                    ( object
                        [ "schemaVersion" .= (1 :: Int)
                        , "intentDigest" .= plannedInputDigest operation
                        , "nativeDigest" .= contentDigest (preparedNativeBytes native)
                        , "providerRequestId" .= providerId
                        ]
                    ) of
                    Left reason -> pure (AdapterEffectAmbiguous reason)
                    Right receipt -> do
                      stored <- purgeWriteReceipt ops (plannedInputDigest operation) receipt
                      pure (either AdapterEffectAmbiguous (const AdapterEffectCompleted) stored)
                  Right _ -> pure (AdapterEffectAmbiguous "provider acceptance lacks a valid request ID")

validProviderId :: Text -> Bool
validProviderId value =
  not (T.null value)
    && T.length value <= 32
    && T.all (\c -> c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-') value

-- | The documented success envelope proves only provider request acceptance.
parsePurgeAcceptance :: (Int, ByteString) -> Either Text Text
parsePurgeAcceptance (status, bytes) = do
  unless (status == 200) (Left "Cloudflare purge acceptance was not confirmed")
  value <- first (const "Cloudflare purge response is invalid JSON") (eitherDecodeStrict' bytes)
  case value of
    Object fields
      | KM.lookup "success" fields == Just (Bool True)
      , KM.lookup "errors" fields == Just (Array mempty)
      , Just (Object result) <- KM.lookup "result" fields
      , Just (String requestId) <- KM.lookup "id" result
      , validProviderId requestId ->
          Right requestId
    _ -> Left "Cloudflare purge response lacks a successful request identity"
