-- | The @keyset@ commands (EP-286). Executable-private CLI boundary: @plan@
-- builds reviewed key set scopes against the accepted inventory and saves or
-- prints their review; @status@ reads each key set's public ConfigMap.
module Nagare.Cli.Commands.KeySet
  ( runKeySet
  )
where

import Control.Monad (forM, forM_)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Options.KeySet
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Config (provisionGhcEnv)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Target (activeTarget, resolvePlatformWorkspace)
import Nagare.Contract.ReleaseImages (ReleaseImageKey (AdminApiImage), releaseImageKeyText)
import Nagare.Dsl.KeySet
import Nagare.Dsl.Load (loadKeySets, renderLoadError)
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (namespaceText)
import Nagare.Inventory.CollectionPolicy (collectionWaves)
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Command.Effects (planInventoryCandidateWithEffects)
import Nagare.Inventory.Components.ReleaseImage (releaseImagesOwner)
import Nagare.Inventory.DataService (acceptedFoundationNamespace)
import Nagare.Inventory.KeySet
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..), invokeKubectl)
import Nagare.Inventory.ObjectBucket (boundBy)
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status qualified as InventoryStatus
import Nagare.KeySet.Rotator (keySetPublicName, publicFileKey)
import Nagare.Platform.ReleaseImages (renderImageSelectionError, selectImage)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Policy (RetirementIntent (RetainResources))
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (ActiveTarget, Mode (Local), TargetProfile, contextNameText, registryPrefix)
import System.Exit (ExitCode (..))
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory)

runKeySet :: Maybe String -> KeySetCommand -> IO ()
runKeySet mctx = \case
  KeySetPlan o -> do
    provisionGhcEnv Nothing
    keySets <- loadKeySets (o ^. #file) >>= either (dieT . renderLoadError) pure
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshot active
    planKeySets active snapshot (T.pack (o ^. #file)) keySets (o ^. #savePlan)
  KeySetRetire name output -> do
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshot active
    scope <- maybe (dieT ("no accepted key set is named " <> T.pack name)) pure (lookup (T.pack name) [(label, found) | (label, (found, _)) <- acceptedKeySetScopes snapshot])
    case boundBy snapshot scope of
      [] -> pure ()
      consumers -> dieT ("keyset-still-bound: key set " <> T.pack name <> " is bound by " <> T.intercalate ", " (map Resource.resourceIdText consumers) <> "; remove the binding and deploy first")
    accepted <- loadAcceptedNative active snapshot
    let owner = ResourceInventory.scopeId scope
        members = Map.filter ((== owner) . (^. #owner) . fst) accepted
    candidate <- either (dieT . renderErrors) pure (ResourceInventory.composeInventory snapshot (ResourceInventory.RetireScope owner RetainResources NE.:| []))
    (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
    planInventoryCandidateWithEffects (inventoryPlanRegistryWithNative active workspace members) active candidate (Map.keys members) [] output
    TIO.hPutStrLn stderr (collectSteps "the key set's objects, its private keys included," (collectionWaves (map fst (Map.elems members))))
  KeySetStatus selected -> do
    active <- activeTarget mctx
    snapshot <- Inventory.loadTargetSnapshotReadOnly active
    let accepted = [declared | (name, declared) <- acceptedKeySets snapshot, maybe True ((== name) . T.pack) selected]
    when (null accepted) (dieT (maybe "no accepted key set" (\name -> "no accepted key set is named " <> T.pack name) selected))
    context <- either dieT pure (Resource.mkContextId (contextNameText (active ^. #contextName)))
    let clusterGuard = fmap (fmap (const ())) (guardKubernetesContext active)
        runtime = KubernetesRuntimeConfig context (contextNameText (active ^. #contextName)) clusterGuard
    clusterGuard >>= either dieT pure
    forM_ accepted $ \declared -> do
      let label = keySetNameText (declared ^. #name)
      result <- invokeKubectl runtime ["get", "configmap", T.unpack (keySetPublicName (declared ^. #name)), "-n", T.unpack (namespaceText (declared ^. #namespace)), "-o", "json"] ""
      body <- case result of
        Right (ExitSuccess, output, _) -> pure (TE.encodeUtf8 (T.pack output))
        _ -> dieT ("key set " <> label <> ": its public ConfigMap could not be read")
      case publicFile body of
        Nothing -> TIO.putStrLn (label <> "  no keys yet: the rotator has not run")
        Just file -> either (\reason -> dieT ("key set " <> label <> ": " <> reason)) (mapM_ TIO.putStrLn) (keySetStatusLines declared file)

-- | The rotator's file in a ConfigMap read, when it has written one.
publicFile :: ByteString -> Maybe ByteString
publicFile body = case Aeson.decodeStrict body of
  Just (Object root)
    | Just (Object fields) <- KM.lookup "data" root
    , Just (String file) <- KM.lookup (Key.fromText publicFileKey) fields ->
        Just (TE.encodeUtf8 file)
  _ -> Nothing

-- | The accepted key sets by name.
acceptedKeySets :: ResourceInventory.ScopeSnapshot -> [(Text, KeySet)]
acceptedKeySets snapshot = [(label, declared) | (label, (_, declared)) <- acceptedKeySetScopes snapshot]

acceptedKeySetScopes :: ResourceInventory.ScopeSnapshot -> [(Text, (ResourceInventory.ScopeDeclaration, KeySet))]
acceptedKeySetScopes snapshot =
  [ (keySetNameText (declared ^. #name), (scope, declared))
  | (_, scope) <- Map.elems (ResourceInventory.snapshotScopes snapshot)
  , Just declared <- [scopeKeySet scope]
  ]

-- | Every key set becomes its own scope, composed into one candidate. A
-- superseded first-run Job is retired in the same review.
planKeySets :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> Text -> [KeySet] -> Maybe FilePath -> IO ()
planKeySets active snapshot source keySets output = do
  accepted <- loadAcceptedNative active snapshot
  (image, publication) <- rotatorImage active snapshot
  compiled <- forM keySets $ \declared -> do
    (cluster, namespace') <- either dieT pure (acceptedFoundationNamespace snapshot (namespaceText (declared ^. #namespace)))
    either (dieT . renderErrors) pure $
      compileStandaloneKeySet
        KeySetInput
          { keySet = declared
          , image = image
          , imagePublication = publication
          , cluster = cluster
          , namespace = namespace'
          , source = Resource.SourceLocation source (keySetNameText (declared ^. #name))
          }
  changes <- maybe (dieT "no key set to plan") pure (NE.nonEmpty (map (ResourceInventory.ReplaceScope . fst) compiled))
  candidate <- either (dieT . renderErrors) pure (ResourceInventory.composeInventory snapshot changes)
  (_, workspace) <- resolvePlatformWorkspace (active ^. #contextName)
  let native = Map.unions (map snd compiled)
      owners = Set.fromList (map (ResourceInventory.scopeId . fst) compiled)
      leaving = [resource ^. #identity | (resource, _) <- Map.elems accepted, Set.member (resource ^. #owner) owners, Map.notMember (resource ^. #identity) native]
      registry = inventoryPlanRegistryWithNative active workspace native
  case output of
    Just directory -> planInventoryCandidateWithEffects registry active candidate leaving [] directory
    Nothing -> withSystemTempDirectory "nagare-keyset-plan" $ \root -> do
      (bundle, _) <- Inventory.planInventoryCandidateQuiet registry active candidate (root <> "/review")
      case InventoryPlan.reviewOperations (InventoryPlan.reviewBundleDocument bundle) of
        [] -> TIO.putStrLn "no operations"
        operations -> mapM_ (TIO.putStrLn . InventoryPlan.reviewPublicSummary) operations

-- | The image that holds the rotator: the admin API's. An explicit
-- @NAGARE_ADMIN_API_IMAGE@ wins; otherwise the image the context's accepted
-- release-images scope publishes, after whose publication the rotator runs.
rotatorImage :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> IO (Text, Maybe Resource.ResourceId)
rotatorImage active snapshot = do
  let name = releaseImageKeyText AdminApiImage
      published =
        [ (contextImageRegistry (active ^. #profile) <> "/" <> name <> "@sha256:" <> Resource.digestText digest, Resource.mintResourceId releaseImagesOwner logical publish)
        | Just (_, scope) <- [Map.lookup releaseImagesOwner (ResourceInventory.snapshotScopes snapshot)]
        , bundle <- ResourceInventory.scopeBundles scope
        , ResourceInventory.Managed resource <- ResourceInventory.declarations bundle
        , Resource.Artifact artifact digest <- [resource ^. #address]
        , Resource.nameText artifact == name
        , Right logical <- [Resource.mkLogicalKey name]
        , Right publish <- [Resource.mkName "publish"]
        ]
  selected <- selectImage (contextImageRegistry (active ^. #profile)) Nothing AdminApiImage
  case (selected, published) of
    (Right selection, _) -> pure (selection ^. #selected, Nothing)
    (Left _, (image, publication) : _) -> pure (image, Just publication)
    (Left reason, []) ->
      dieT
        ( "keyset-image-unpublished: this context publishes no admin-api image, which holds the rotator; enable the admin API or the lifecycle worker, which publish it, or "
            <> renderImageSelectionError reason
        )

-- | The registry prefix a context's own release images are published under.
contextImageRegistry :: TargetProfile -> Text
contextImageRegistry profile
  | profile ^. #mode == Local = profile ^. #registryHost
  | otherwise = registryPrefix profile

loadAcceptedNative :: ActiveTarget -> ResourceInventory.ScopeSnapshot -> IO (Map.Map Resource.ResourceId (ResourceInventory.ManagedResource, ByteString))
loadAcceptedNative active snapshot = do
  store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
  history <- InventoryPlan.loadInventoryHistory store >>= either (dieT . T.pack . show) pure
  inventory <- either (dieT . T.pack . show) pure (ResourceInventory.composeSnapshot snapshot)
  fst <$> (InventoryStatus.loadAcceptedNative store history inventory >>= either dieT pure)

-- | The collect reviews that delete retired members, one per wave, in order.
collectSteps :: Text -> [[Resource.ResourceId]] -> Text
collectSteps what waves =
  "After this review is applied, delete "
    <> what
    <> " with one collect review per step, each applied before the next:"
    <> T.concat ["\n  nagarectl inventory collect " <> T.unwords ["--resource " <> Resource.resourceIdText resource | resource <- wave] <> " --out DIR-" <> T.show step | (step, wave) <- zip [1 :: Int ..] waves]

renderErrors :: NE.NonEmpty Resource.InventoryError -> Text
renderErrors = T.intercalate "; " . map (\err -> err ^. #code <> ": " <> err ^. #message) . NE.toList
