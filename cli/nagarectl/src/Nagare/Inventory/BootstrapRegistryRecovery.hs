-- | A bounded replay of accepted host policy, never a replacement review.
module Nagare.Inventory.BootstrapRegistryRecovery
  ( RegistryUnitSnapshot (..)
  , mkBootstrapRegistryRecovery
  , registryReplayRequired
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Host
import Nagare.Inventory.Adapters.Kubernetes
import Nagare.Inventory.Digest
import Nagare.Inventory.Journal
import Nagare.Inventory.Plan
import Nagare.Inventory.Store
import Nagare.Resource.Inventory (Executor (..))
import Nagare.Resource.Inventory qualified as Resource
import Nagare.Resource.Policy (DataPolicy (Stateless))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue, decodeScope)

-- Credential contents never cross the transport boundary.
data RegistryUnitSnapshot = RegistryUnitSnapshot
  { registryUnitStart :: !Integer
  , registryK3sInvocation :: !Text
  , registryNodeUid :: !Text
  , registryTokenFresh :: !Bool
  , registryPullFailure :: !Bool
  , registryBootId :: !Text
  , registryDeploymentReady :: !Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RegistryUnitSnapshot where toJSON = genericToJSON defaultOptions

instance FromJSON RegistryUnitSnapshot where parseJSON = genericParseJSON defaultOptions

data RegistryRecoveryProof = RegistryRecoveryProof
  { registryProofVersion :: !Int
  , registryProofReview :: !ContentDigest
  , registryProofOperation :: !OperationId
  , registryProofNative :: !ContentDigest
  , registryProofDeployment :: !PhysicalIdentity
  , registryProofHostReview :: !ContentDigest
  , registryProofHostRevision :: !ScopeRevision
  , registryProofHostNative :: !ContentDigest
  , registryProofUnits :: !RegistryUnitSnapshot
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON RegistryRecoveryProof where toJSON = genericToJSON defaultOptions

instance FromJSON RegistryRecoveryProof where parseJSON = genericParseJSON defaultOptions

-- Each changed unit stamp is proof of one landed phase. Unknown combinations
-- refuse; observation of fresh credentials alone never permits a restart.
registryReplayRequired ::
  RegistryUnitSnapshot ->
  RegistryUnitSnapshot ->
  Either Text (Bool, Bool)
registryReplayRequired saved current = do
  unless
    ( registryUnitStart saved > 0
        && registryUnitStart current > 0
        && not (T.null (registryK3sInvocation saved))
        && not (T.null (registryK3sInvocation current))
        && not (T.null (registryBootId saved))
        && not (T.null (registryBootId current))
        && registryNodeUid saved == registryNodeUid current
        && not (T.null (registryNodeUid saved))
    )
    (Left "registry recovery unit or node identity is invalid or changed")
  let refreshed = registryUnitStart saved /= registryUnitStart current
      restarted = registryK3sInvocation saved /= registryK3sInvocation current
  -- The transport holds the host lock and refuses pending unit jobs. A ready
  -- original workload makes further prerequisite effects unnecessary, including
  -- after a reboot. Its completion still belongs to the Kubernetes adapter.
  if registryDeploymentReady current
    then Right (False, False)
    else
      if registryBootId saved /= registryBootId current
        then Left "host boot changed; refuse replay of the saved unit recovery"
        else
          if restarted && not refreshed
            then Left "k3s changed without proof of the saved credential recovery"
            else
              if restarted
                then Right (False, False)
                -- Expiry is a changed credential input, not an unknown landed effect.
                -- Renew only that accepted policy before the still-unperformed restart.
                else Right (not refreshed || not (registryTokenFresh current), True)

mkBootstrapRegistryRecovery ::
  InventoryStore ->
  ReviewBundle ->
  Text ->
  (HostActivationPlan -> IO HostActivationState) ->
  ( HostActivationPlan ->
    PhysicalIdentity ->
    Maybe RegistryUnitSnapshot ->
    IO (Either Text RegistryUnitSnapshot)
  ) ->
  (PlannedOperation -> PreparedNative -> IO RecoveryDecision) ->
  AdapterRecovery
mkBootstrapRegistryRecovery store bundle registryHost inspectHost units recoverDeployment =
  AdapterRecovery "bootstrap-registry-credentials" prepare validate executeRecovery
  where
    document = reviewBundleDocument bundle
    prepare operation native = case eligible operation native of
      Left reason -> pure (Left reason)
      Right () -> do
        host <- acceptedHost
        deployment <- recoverDeployment operation native
        case (host, deployment) of
          (Right (hostReview, revision, hostNative, plan), RecoveryAwaitingReadiness physical) -> do
            checked <- committed plan
            snapshot <- case checked of
              Left reason -> pure (Left reason)
              Right () -> units plan physical Nothing
            pure $ do
              before <- snapshot
              _ <- registryReplayRequired before before
              unless
                (registryPullFailure before && not (registryTokenFresh before))
                (Left "bootstrap registry recovery requires an image-pull failure and stale bootstrap credentials")
              canonicalValue
                ( toJSON
                    ( RegistryRecoveryProof
                        1
                        (reviewDigest bundle)
                        (plannedOperationId operation)
                        (contentDigest (preparedNativeBytes native))
                        physical
                        hostReview
                        revision
                        hostNative
                        before
                    )
                )
          (Left reason, _) -> pure (Left reason)
          _ -> pure (Left "bootstrap registry recovery requires the exact unready Deployment")
    validate operation native bytes = do
      result <- checkedProof operation native bytes
      case result of
        Left reason -> pure (Left reason)
        Right (proof, plan) -> do
          observed <- units plan (registryProofDeployment proof) Nothing
          pure $ do
            current <- observed
            required <- registryReplayRequired (registryProofUnits proof) current
            unless
              (required == (False, False) || registryPullFailure current)
              (Left "Deployment no longer has an image-pull failure")
    executeRecovery operation native bytes = do
      result <- checkedProof operation native bytes
      case result of
        Left reason -> pure (Left reason)
        Right (proof, plan) -> do
          recovered <- units plan (registryProofDeployment proof) (Just (registryProofUnits proof))
          host <- committed plan
          pure $ do
            after <- recovered
            _ <- host
            required <- registryReplayRequired (registryProofUnits proof) after
            unless
              (required == (False, False))
              (Left "registry recovery lacks both exact unit completion proofs")
            contentDigest <$> canonicalValue (object ["recovery" .= proof, "observed" .= after])
    checkedProof operation native bytes = case do
      eligible operation native
      proof <- first T.pack (eitherDecodeStrict' bytes)
      canonical <- canonicalValue (toJSON (proof :: RegistryRecoveryProof))
      unless
        ( canonical == bytes
            && registryProofVersion proof == 1
            && registryProofReview proof == reviewDigest bundle
            && registryProofOperation proof == plannedOperationId operation
            && registryProofNative proof == contentDigest (preparedNativeBytes native)
        )
        (Left "registry recovery proof differs from its original review or operation")
      unless
        ( registryPullFailure (registryProofUnits proof)
            && not (registryTokenFresh (registryProofUnits proof))
        )
        (Left "saved registry recovery does not prove the original pull failure and stale credentials")
      pure proof of
      Left reason -> pure (Left reason)
      Right proof -> do
        host <- acceptedHost
        deployment <- recoverDeployment operation native
        let sameDeployment = case deployment of
              RecoveryAwaitingReadiness physical -> registryProofDeployment proof == physical
              -- units independently checks the saved Deployment UID on the
              -- accepted host, under the native lock, before any unit action.
              RecoveryProvedComplete _ -> True
              _ -> False
        case host of
          Right (hostReview, revision, hostNative, plan)
            | registryProofHostReview proof == hostReview
            , registryProofHostRevision proof == revision
            , registryProofHostNative proof == hostNative
            , sameDeployment -> do
                checked <- committed plan
                pure ((proof, plan) <$ checked)
          Left reason -> pure (Left reason)
          _ -> pure (Left "recovery host or Deployment no longer matches its saved proof")
    committed plan = do
      state <- inspectHost plan
      pure $ case state of
        HostCommitted physical closure _
          | physical == hostPlanInstance plan && closure == hostPlanNewClosure plan -> Right ()
        _ -> Left "registry recovery requires the exact accepted committed host with fresh-login proof"
    eligible operation native = do
      unless
        ( "nagare-bootstrap:" `T.isPrefixOf` reviewPayloadIdentity document
            && plannedExecutor operation == KubernetesExecutor
            && plannedAction operation == CreateResource
            && length (NE.toList (plannedResources operation)) == 1
        )
        (Left "registry recovery only supports an original bootstrap Deployment create")
      mutation <- first T.pack (eitherDecodeStrict' (preparedNativeBytes native))
      unless
        ( mutationVersion mutation == 1
            && mutationOperation mutation == plannedOperationId operation
            && mutationInputDigest mutation == plannedInputDigest operation
            && mutationAction mutation == CreateResource
            && [mutationResource mutation] == NE.toList (plannedResources operation)
        )
        (Left "registry recovery Kubernetes native binding differs")
      scopes <- traverse (first showText . decodeScope) (Map.elems (reviewBundleScopes bundle))
      declarations <-
        first
          showText
          ( Resource.composedDeclarations
              (Map.fromList [(Resource.scopeId scope, scope) | scope <- scopes])
          )
      case [ member
           | Resource.Managed member <- declarations
           , member ^. #identity == mutationResource mutation
           ] of
        [member] | member ^. #dataPolicy == Stateless -> Right ()
        _ -> Left "registry recovery requires a reviewed stateless managed member"
      case (mutationAddress mutation, mutationBefore mutation) of
        (Kubernetes _ "apps" kind (Just namespace) name, KubernetesAbsent _)
          | nameText kind == "deployment"
          , nameText namespace == "knative-serving"
          , nameText name == "net-certmanager-controller" ->
              Right ()
        _ -> Left "registry recovery refuses another workload or existing-object update"
      nativeObject <- first T.pack (eitherDecodeStrict' (TE.encodeUtf8 (mutationNativeJson mutation)))
      let images = privateImages nativeObject
      unless
        (not (null images) && all ((registryHost <> "/") `T.isPrefixOf`) images)
        (Left "registry recovery workload does not pull from the bound private registry")
    acceptedHost = do
      snapshot <- readStoreSnapshot store
      case snapshot of
        Left err -> pure (Left (showText err))
        Right state -> do
          let owner = either (error . T.unpack) id (mkScopeId Platform "host")
              revision = Map.lookup owner (reviewBaseRevisions document)
              current = storeSnapshotHead state
          if revision == Nothing || Map.lookup owner (headAccepted current) /= revision
            then pure (Left "accepted bootstrap host revision changed")
            else do
              reviews <-
                traverse
                  (loadPublishedReview store)
                  (Set.toAscList (storeSnapshotReviewDigests state))
              journal <- readJournalPrefix store (headSequence current)
              pure $ do
                published <- traverse (first showText) reviews
                events <- first showText journal >>= traverse decodeJournalEvent >>= validateJournal
                let candidates = do
                      source <- published
                      let sourceDocument = reviewBundleDocument source
                          sourceTransaction =
                            either
                              (error . T.unpack)
                              id
                              (mkTransactionId ("tx-" <> digestText (reviewDigest source)))
                      guard
                        ( reviewContextBinding sourceDocument == reviewContextBinding document
                            && Map.lookup owner (reviewDesiredRevisions sourceDocument) == revision
                        )
                      entry <- reviewOperations sourceDocument
                      let operation = reviewPlannedOperation entry
                      guard
                        ( plannedExecutor operation == HostExecutor
                            && plannedAction operation == RunDeclaredOperation
                            && reviewAdapterIdentity entry == "nixos-safe-activation"
                            && reviewAdapterVersion entry == "1"
                        )
                      case Map.lookup (plannedOperationId operation) (operationStates sourceTransaction events) of
                        Just (Completed _) -> pure ()
                        _ -> []
                      digest <- maybe [] pure (reviewNativeDigest entry)
                      bytes <- maybe [] pure (Map.lookup digest (reviewBundleNative source))
                      plan <- either (const []) pure (eitherDecodeStrict' bytes)
                      guard
                        ( hostPlanVersion plan == 1
                            && hostPlanOperation plan == plannedOperationId operation
                            && hostPlanInputDigest plan == plannedInputDigest operation
                            && hostPlanContext plan == reviewContextBinding document ^. #identity
                        )
                      pure (reviewDigest source, maybe (error "missing host revision") id revision, digest, plan)
                case candidates of
                  [single] -> Right single
                  _ -> Left "accepted host lacks one unique completed immutable activation plan"

-- Read only the containers at the typed Deployment path.
privateImages :: Value -> [Text]
privateImages value = either (const []) id (parseEither parser value)
  where
    parser = withObject "Deployment" $ \o -> do
      spec <- o .: "spec"
      template <- spec .: "template"
      pod <- template .: "spec"
      containers <- pod .: "containers"
      traverse (withObject "Container" (.: "image")) containers

showText :: (Show a) => a -> Text
showText = T.pack . show
