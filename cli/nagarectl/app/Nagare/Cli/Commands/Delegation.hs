-- | @delegation create|revoke|show@ and @inventory history@ (EP-247).
-- Executable-private CLI boundary.
module Nagare.Cli.Commands.Delegation
  ( runDelegation
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM_)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Options.Delegation (DelegationCommand (..), DelegationCreateOpts (..))
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Contract.Delegation (ActorSummary (..), SourceSummary (..), TransactionHistory (..), TransactionSummary (..))
import Nagare.Contract.Schema (fromNullable)
import Nagare.Contract.Sink (contractSinkSet, emitDocument, withReadContract)
import Nagare.Dsl.Prelude
import Nagare.Inventory.ClusterSession (kubectlConnectionArguments)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Components.LocalObjectStore (readLocalRegistryDigest, selectLocalMinioImages)
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.DeployerCredentials (CredentialOps (..), CredentialRequest (..), issueCredentials, kubectlStoreKeyOps, randomHexIO)
import Nagare.Inventory.DeployerDelegation
import Nagare.Inventory.DeployerStoreAccess (StoreAccess (..))
import Nagare.Inventory.Store (readHead)
import Nagare.Inventory.Store.S3 (parseS3Endpoint)
import Nagare.Inventory.TransactionHistory (delegationDocument, readTransactionHistory)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types (generationNumber)
import Nagare.Target (ActiveTarget, InventoryStoreKind (InventoryStoreObject), Mode (Local), contextFilePath, contextNameText, effectiveInventoryStore)
import Nagare.Target.Kinds (hostShapeFor)
import System.Environment (lookupEnv)
import System.Process (readProcessWithExitCode)

runDelegation :: Maybe String -> DelegationCommand -> IO ()
runDelegation mctx = \case
  DelegationHistory limit contract -> runInventoryHistory mctx limit contract
  DelegationCreate options -> do
    active <- activeTarget mctx
    kinds <- either dieT pure (traverse (parseDelegatedKind . T.pack) (options ^. #kinds))
    namespaces <- maybe (dieT "a delegation needs at least one --namespace") pure (NE.nonEmpty (map T.pack (options ^. #namespaces)))
    kindList <- maybe (dieT "a delegation needs at least one --kinds") pure (NE.nonEmpty kinds)
    let profile = active ^. #profile
        delegation =
          DeployerDelegation
            { name = T.pack (options ^. #name)
            , state = DelegationActive
            , namespaces = namespaces
            , hostSuffixes = map T.pack (options ^. #hostSuffixes)
            , kinds = kindList
            , imageRepository = T.pack (options ^. #imageRepository)
            , team = T.pack (options ^. #team)
            , buildNamespace = T.pack <$> options ^. #buildNamespace
            , quota =
                DelegationQuota
                  { cpu = maybe (defaultQuota ^. #cpu) T.pack (options ^. #quotaCpu)
                  , memory = maybe (defaultQuota ^. #memory) T.pack (options ^. #quotaMemory)
                  , pods = fromMaybe (defaultQuota ^. #pods) (options ^. #quotaPods)
                  }
            , baseDomain = profile ^. #baseDomain
            , hostShape = hostShapeFor (profile ^. #ingress)
            }
    planDelegation mctx active True delegation (options ^. #savePlan)
  DelegationRevoke deployer output -> do
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshotReadOnly active
    accepted <- maybe (dieT ("no accepted delegation names deployer " <> T.pack deployer)) pure (Map.lookup (T.pack deployer) (acceptedOf snapshot))
    when (accepted ^. #state == DelegationRevoked) (dieT ("delegation " <> T.pack deployer <> " is already revoked"))
    planDelegation mctx active False (accepted & #state .~ DelegationRevoked) output
  DelegationShow deployer contract -> withReadContract contract $ do
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshotReadOnly active
    owner <- either dieT pure (delegationScopeId (T.pack deployer))
    accepted <- maybe (dieT ("no accepted delegation names deployer " <> T.pack deployer)) pure (Map.lookup (T.pack deployer) (acceptedOf snapshot))
    let generation = maybe 0 (generationNumber . fst) (Map.lookup owner (ResourceInventory.snapshotScopes snapshot))
        document = delegationDocument generation accepted
    contractMode <- contractSinkSet
    if contractMode
      then emitDocument document
      else
        TIO.putStr
          ( T.unlines
              [ "delegation " <> accepted ^. #name <> " (" <> delegationStateText (accepted ^. #state) <> ")"
              , "namespaces: " <> T.intercalate ", " (NE.toList (accepted ^. #namespaces))
              , "host suffixes: " <> T.intercalate ", " (accepted ^. #hostSuffixes)
              , "kinds: " <> T.intercalate ", " (map delegatedKindText (NE.toList (accepted ^. #kinds)))
              , "image repository: " <> accepted ^. #imageRepository
              , "team: " <> accepted ^. #team
              , "build namespace: " <> fromMaybe "none" (accepted ^. #buildNamespace)
              ]
          )
  DelegationCredentials deployer out duration contract -> withReadContract contract $ do
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshotReadOnly active
    accepted <- maybe (dieT ("no accepted delegation names deployer " <> T.pack deployer)) pure (Map.lookup (T.pack deployer) (acceptedOf snapshot))
    when (accepted ^. #state /= DelegationActive) (dieT ("delegation " <> T.pack deployer <> " is revoked and issues no credentials"))
    when (active ^. #profile . #mode /= Local) (dieT "deployer credentials on a cloud context need the delegation's cloud principal, which this release does not issue yet")
    store <- delegationStoreAccess active
    when (isNothing store) (dieT "a local deployer reaches the inventory in the in-cluster object store; move it there first with nagarectl inventory store migrate --to object")
    let contextText = contextNameText (active ^. #contextName)
        run arguments input = do
          connection <- kubectlConnectionArguments contextText
          case connection of
            Left reason -> pure (Left reason)
            Right selected -> first (\(_ :: IOException) -> "could not invoke kubectl") <$> try (readProcessWithExitCode "kubectl" (selected <> arguments) input)
    operatorContext <- contextFilePath (active ^. #contextName) >>= TIO.readFile
    issue <- randomHexIO 4
    issued <-
      issueCredentials
        CredentialOps
          { kubectl = run
          , storeKeys = (\access -> kubectlStoreKeyOps run (T.pack deployer) access issue) <$> store
          , randomHex = randomHexIO
          }
        CredentialRequest
          { deployer = T.pack deployer
          , context = contextText
          , out = out
          , duration = maybe "720h" T.pack duration
          , operatorContext = operatorContext
          , buildNamespace = accepted ^. #buildNamespace
          , issue = issue
          }
    document <- either dieT pure issued
    contractMode <- contractSinkSet
    if contractMode
      then emitDocument document
      else
        TIO.putStr
          ( T.unlines
              ( [ "issued deployer " <> document ^. #deployer <> " credentials in " <> document ^. #home
                , "run it with HOME=" <> document ^. #home <> " and XDG_CONFIG_HOME=" <> document ^. #home <> "/.config"
                , "token expires " <> document ^. #tokenExpiresAt
                ]
                  <> ["retired " <> handle | handle <- document ^. #retired]
              )
          )
  where
    acceptedOf snapshot = acceptedDelegations (fmap snd (ResourceInventory.snapshotScopes snapshot))

-- | Compile the delegation scope against the accepted cluster and plan it as
-- one reviewed change. A new delegation refuses namespaces any accepted
-- scope already owns.
planDelegation :: Maybe String -> ActiveTarget -> Bool -> DeployerDelegation -> FilePath -> IO ()
planDelegation mctx active creating delegation output = do
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  (cluster, systemNamespace) <- either dieT pure (acceptedFoundationNamespace snapshot "nagare-system")
  owner <- either dieT pure (delegationScopeId (delegation ^. #name))
  when creating $ do
    when (Map.member owner (ResourceInventory.snapshotScopes snapshot)) (dieT ("a delegation for deployer " <> delegation ^. #name <> " already exists; revoke it or choose another name"))
    let owned = NE.toList (delegation ^. #namespaces) <> maybe [] pure (delegation ^. #buildNamespace)
        others = acceptedDelegations (fmap snd (ResourceInventory.snapshotScopes snapshot))
    forM_ owned $ \ns -> do
      when (isRight' (acceptedFoundationNamespace snapshot ns)) (dieT ("namespace " <> ns <> " belongs to the platform foundation"))
      forM_ (Map.elems others) $ \other ->
        when (ns `elem` (NE.toList (other ^. #namespaces) <> maybe [] pure (other ^. #buildNamespace))) (dieT ("namespace " <> ns <> " belongs to delegation " <> other ^. #name))
  store <- delegationStoreAccess active
  (scope, native) <- either dieT pure (compileDelegationScope cluster systemNamespace store delegation)
  candidate <- either (dieT . T.pack . show) pure (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope NE.:| []))
  _ <- pure mctx
  Inventory.planInventoryCandidateWith (inventoryPlanRegistryWithNative active workspace native) active candidate output
  where
    isRight' = either (const False) (const True)

-- | EP-248 D10: on a local context whose inventory is in the in-cluster
-- object store, the deployer's store identity is administered by the store's
-- own client image, selected as bootstrap selects it.
delegationStoreAccess :: ActiveTarget -> IO (Maybe StoreAccess)
delegationStoreAccess active = do
  let profile = active ^. #profile
  if profile ^. #mode /= Local || effectiveInventoryStore profile /= InventoryStoreObject
    then pure Nothing
    else do
      endpoint <- either dieT pure (parseS3Endpoint (profile ^. #inventoryStoreUrl))
      serverImage <- fmap T.pack <$> lookupEnv "NAGARE_LOCAL_MINIO_IMAGE"
      clientImage <- fmap T.pack <$> lookupEnv "NAGARE_LOCAL_MC_IMAGE"
      images <- selectLocalMinioImages readLocalRegistryDigest (profile ^. #targetPlatform) serverImage clientImage >>= either dieT pure
      pure (Just (StoreAccess (endpoint ^. #base) (endpoint ^. #bucket) (endpoint ^. #prefix) (images ^. #client)))

-- | @inventory history@: transactions newest first with actor and source.
runInventoryHistory :: Maybe String -> Maybe Int -> Maybe Int -> IO ()
runInventoryHistory mctx limit contract = withReadContract contract $ do
  active <- activeTarget mctx
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  headValue <- readHead store >>= either (dieT . T.pack . show) pure >>= maybe (dieT "accepted inventory history is absent") pure
  history <- readTransactionHistory store headValue (fromMaybe 20 limit) >>= either dieT pure
  contractMode <- contractSinkSet
  if contractMode
    then emitDocument history
    else TIO.putStr (T.unlines (map row (history ^. #transactions)))
  where
    row summary =
      T.intercalate
        "  "
        [ summary ^. #transaction
        , summary ^. #state
        , summary ^. #admittedAt
        , actorText' (summary ^. #actor)
        , T.intercalate "," (summary ^. #scopes)
        , maybe "" sourceText (fromNullable (summary ^. #source))
        ]
    actorText' actor = (actor ^. #kind) <> maybe "" (":" <>) (fromNullable (actor ^. #name))
    sourceText source = T.intercalate " " (catMaybes' [fromNullable (source ^. #repository), fromNullable (source ^. #revision), fromNullable (source ^. #run)])
    catMaybes' = foldr (maybe id (:)) []
