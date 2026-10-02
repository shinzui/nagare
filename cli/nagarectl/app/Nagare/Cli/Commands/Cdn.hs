-- | Commands / Cdn. Executable-private CLI boundary.
module Nagare.Cli.Commands.Cdn
  ( runCdn
  )
where

import Control.Monad (forM_)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Nagare.Cdn.Cloudflare (loadCloudflareCreds, purgeHostname)
import Nagare.Cdn.Provision (googleCdnHostname)
import Nagare.Cdn.Status
  ( CdnDnsTarget (..)
  , CdnRow (..)
  , formatCdnList
  , formatCdnStatus
  , formatCertificateManagerStatus
  , parseCertificateManagerState
  , queryCdnRows
  )
import Nagare.Cli.Application.Cdn (gatherGcpStackRefs)
import Nagare.Cli.Application.Config (appNamespace)
import Nagare.Cli.Inventory.Planning (inventoryPlanRegistryWithNative)
import Nagare.Cli.Options
  ( CdnCommand (..)
  , CdnDisableOpts (..)
  , CdnListOpts (..)
  , CdnPurgeOpts (..)
  , CdnStatusOpts (..)
  )
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Ownership
  ( refuseDirectCdnHostMutationIfOwned
  , refuseDirectCloudflareZoneMutationIfOwned
  , refuseDirectLegacyOperationWhenManaged
  )
import Nagare.Cli.Runtime.ProjectGuard (projectGuardInputsFor)
import Nagare.Cli.Runtime.Pulumi (ensurePulumiForActiveContext, selectReviewedPulumiForContext)
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolveDomainsBaseAt
  )
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command qualified as Inventory
import Nagare.Inventory.Plan qualified as InventoryPlan
import Nagare.Inventory.Status (loadAcceptedNativeSelected)
import Nagare.Ops.ContextGuard (projectGuardVerdict)
import Nagare.Ops.Domains (listNamespaces)
import Nagare.Ops.Probe (captureTool)
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Cdn (compileCdnDisable, compileCdnPurge, compileCdnZonePurge)
import Nagare.Resource.Inventory (Executor (KubernetesExecutor), ScopeChange (ReplaceScope), ScopeDeclaration, ScopeSnapshot, composeInventory, composeSnapshot)
import Nagare.Target (ActiveTarget, contextNameText)

-- | MasterPlan 11 / EP-58: the @nagarectl cdn@ command group dispatcher.
runCdn :: Maybe String -> CdnCommand -> IO ()
runCdn mctx = \case
  CdnList o -> runCdnList mctx o
  CdnStatus o -> runCdnStatus mctx o
  CdnPurge o -> runCdnPurge mctx o
  CdnDisable o -> runCdnDisable mctx o

-- | @cdn list@: enumerate CDN-fronted hostnames and their provider/DNS/cache/
-- readiness. Discovery degrades gracefully to the empty sentinel when the
-- cluster / cloud tools are unavailable (VM off, no token) — see
-- 'Nagare.Cdn.Status.queryCdnRows'.
runCdnList :: Maybe String -> CdnListOpts -> IO ()
runCdnList mctx o = do
  (_, workspace) <- ensurePulumiForActiveContext mctx
  base <- resolveDomainsBaseAt mctx workspace (o ^. #baseDomain)
  ip <- fromMaybe "(unknown)" <$> stackOutput (workspace ^. #pulumiDir) "publicIp"
  nss <-
    if o ^. #allNamespaces
      then listNamespaces
      else pure [appNamespace (o ^. #namespace)]
  rows <- concat <$> traverse (queryCdnRows base ip) nss
  TIO.putStr (formatCdnList rows)

-- | @cdn status HOST@: show one hostname's CDN state, or an "unknown / not
-- discovered" block when the live discovery cannot run yet.
runCdnStatus :: Maybe String -> CdnStatusOpts -> IO ()
runCdnStatus mctx o = do
  (context, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  base <- resolveDomainsBaseAt mctx workspace (o ^. #baseDomain)
  ip <- fromMaybe "(unknown)" <$> stackOutput (workspace ^. #pulumiDir) "publicIp"
  let ns = appNamespace (o ^. #namespace)
      host = T.pack (o ^. #host)
  rows <- queryCdnRows base ip ns
  case filter ((== host) . (^. #host)) rows of
    (r : _) -> TIO.putStr (formatCdnStatus r)
    [] -> TIO.putStr (formatCdnStatus (CdnRow host "unknown" DnsUnknown "(not discovered)" False))
  certificate <- stackOutput (workspace ^. #pulumiDir) "cdnCertificate"
  mode <- fromMaybe "legacy" <$> stackOutput (workspace ^. #pulumiDir) "cdnCertificateMode"
  forM_ certificate $ \name ->
    unless ("(" `T.isPrefixOf` name) $ do
      observed <-
        captureTool
          "gcloud"
          [ "certificate-manager"
          , "certificates"
          , "describe"
          , T.unpack name
          , "--location=global"
          , "--format=json"
          , "--project=" <> T.unpack (tp ^. #project)
          ]
      let state = case observed of
            Nothing -> "unavailable"
            Just bytes -> either ("invalid: " <>) (\stateText -> stateText) (parseCertificateManagerState bytes)
          activation =
            T.unwords
              [ "pulumi"
              , "-C"
              , T.pack (workspace ^. #pulumiDir)
              , "config set --stack"
              , contextNameText context
              , "nagare:cdnCertificateMode certificate-map"
              ]
      TIO.putStr (formatCertificateManagerStatus name mode state activation)

-- | @cdn purge HOST [--path P]...@: purge the Cloudflare edge cache. @--dry-run@
-- prints the planned purge; live needs @CF_API_TOKEN@.
runCdnPurge :: Maybe String -> CdnPurgeOpts -> IO ()
runCdnPurge mctx o | Just output <- o ^. #savePlan = do
  when (o ^. #dryRun) (dieT "--save-plan already plans without effects; omit --dry-run")
  requestId <- maybe (dieT "reviewed purge requires --purge-id ID") (pure . T.pack) (o ^. #purgeId)
  active <- activeTarget mctx
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  when (o ^. #wholeZone && not (null (o ^. #paths))) (dieT "--whole-zone cannot be combined with --path")
  scope <- either dieT pure $
    if o ^. #wholeZone
      then compileCdnZonePurge snapshot (T.pack (o ^. #host)) requestId
      else compileCdnPurge snapshot (T.pack (o ^. #host)) requestId (map T.pack (o ^. #paths))
  workspace <- selectReviewedPulumiForContext (active ^. #contextName) (active ^. #profile)
  planCdnScope active workspace snapshot scope output
runCdnPurge mctx o = do
  when (o ^. #wholeZone) (dieT "--whole-zone requires --save-plan")
  when (isJust (o ^. #purgeId)) (dieT "--purge-id requires --save-plan")
  let host = T.pack (o ^. #host)
      paths = map T.pack (o ^. #paths)
      pathsDesc = if null paths then "this hostname only" else T.intercalate ", " paths
  if o ^. #dryRun
    then TIO.putStrLn ("Would purge Cloudflare edge cache for " <> host <> " (paths: " <> pathsDesc <> ")")
    else do
      refuseDirectLegacyOperationWhenManaged mctx "cdn purge" "save the purge with --save-plan DIR --purge-id ID, then inventory apply DIR --yes"
      refuseDirectCdnHostMutationIfOwned mctx "cdn purge" host
      refuseDirectCloudflareZoneMutationIfOwned mctx "cdn purge"
      ecreds <- loadCloudflareCreds
      case ecreds of
        Left e -> dieT ("cdn purge needs Cloudflare credentials: " <> e)
        Right creds -> do
          r <- purgeHostname creds host paths
          case r of
            Left e -> dieT ("cdn purge failed: " <> e)
            Right () -> TIO.putStrLn ("Purged edge cache for " <> host <> " (paths: " <> pathsDesc <> ")")

-- | @cdn disable HOST@: revert a hostname's DNS to the VM. For the Google
-- provider this deletes the more-specific Cloud DNS A record so the
-- @*.<baseDomain>@ wildcard (which points at the VM) wins again. @--dry-run@
-- prints the planned revert without making it.
runCdnDisable :: Maybe String -> CdnDisableOpts -> IO ()
runCdnDisable mctx o | Just output <- o ^. #savePlan = do
  when (o ^. #dryRun) (dieT "--save-plan already plans without effects; omit --dry-run")
  active <- activeTarget mctx
  snapshot <- Inventory.loadTargetSnapshotReadOnly active
  workspace <- selectReviewedPulumiForContext (active ^. #contextName) (active ^. #profile)
  inputs <- projectGuardInputsFor (active ^. #contextName) (active ^. #profile) workspace
  either dieT pure (projectGuardVerdict inputs)
  origin <-
    stackOutput (workspace ^. #pulumiDir) "publicIp"
      >>= maybe (dieT "reviewed CDN disable requires the accepted platform publicIp") pure
  scope <- either dieT pure (compileCdnDisable snapshot (T.pack (o ^. #host)) origin)
  planCdnScope active workspace snapshot scope output
runCdnDisable mctx o = do
  let host = T.pack (o ^. #host)
  unless (o ^. #dryRun) $
    refuseDirectLegacyOperationWhenManaged mctx "cdn disable" "save the DNS disable with --save-plan DIR, then inventory apply DIR --yes"
  (_, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  base <- resolveDomainsBaseAt mctx workspace Nothing
  when (host == base) $
    dieT
      ( "cdn disable will not delete the Pulumi-owned apex record for "
          <> base
          <> "; change nagare:enableCdn and preview the standing infrastructure instead"
      )
  either (dieT . ("cdn disable: " <>)) pure (googleCdnHostname base host)
  refs <- gatherGcpStackRefs (workspace ^. #pulumiDir) tp
  let gArgs =
        [ "dns"
        , "record-sets"
        , "delete"
        , host <> "."
        , "--type=A"
        , "--zone=" <> refs ^. #dnsZone
        , "--project=" <> tp ^. #project
        ]
  if o ^. #dryRun
    then do
      TIO.putStrLn ("Would revert " <> host <> " DNS to the VM:")
      TIO.putStrLn ("  Google: gcloud " <> T.unwords gArgs)
      TIO.putStrLn "  Cloudflare: re-point the proxied record to DNS-only (un-proxy)"
    else do
      refuseDirectCdnHostMutationIfOwned mctx "cdn disable" host
      m <- captureTool "gcloud" (map T.unpack gArgs)
      case m of
        Just _ -> TIO.putStrLn ("Reverted " <> host <> " to the VM (deleted the more-specific A record).")
        Nothing ->
          dieT
            ( "cdn disable: could not delete the Cloud DNS record for "
                <> host
                <> " (is it a Google-CDN hostname? is gcloud configured for "
                <> tp ^. #project
                <> "?)"
            )

-- | Load only required native members while preserving owner-generated contributions.
planCdnScope :: ActiveTarget -> PlatformWorkspace -> ScopeSnapshot -> ScopeDeclaration -> FilePath -> IO ()
planCdnScope active workspace snapshot scope output = do
  candidate <- either (dieT . T.pack . show) pure (composeInventory snapshot (ReplaceScope scope :| []))
  Inventory.planInventoryCandidateWith
    ( \reviewCandidate history -> do
        inventory <- either (dieT . T.pack . show) pure (composeSnapshot snapshot)
        let required =
              InventoryPlan.requirementsByExecutor
                (InventoryPlan.observationRequirements reviewCandidate history)
            selected = Set.fromList (Map.findWithDefault [] KubernetesExecutor required)
        store <- Inventory.openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
        (native, _) <-
          loadAcceptedNativeSelected selected store history inventory
            >>= either dieT pure
        inventoryPlanRegistryWithNative
          active
          workspace
          (Map.filter ((/= "contribution") . (^. #source . #file) . fst) native)
          reviewCandidate
          history
    )
    active
    candidate
    output
