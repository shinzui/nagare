-- | Commands / Domains. Executable-private CLI boundary.
module Nagare.Cli.Commands.Domains
  ( runDomains
  )
where

import Control.Concurrent.Async (concurrently, mapConcurrently)
import Control.Monad (forM, forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Nagare.Cli.Application.Config (appNamespace)
import Nagare.Cli.Move.Observe (describeZoneNameServers, observeResolverNameServers)
import Nagare.Cli.Options (DomainsCommand (..), DomainsListOpts (..), DomainsTlsOpts (..))
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Pulumi (ensurePulumiForActiveContext)
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolveBaseDomain
  )
import Nagare.Dsl.ContentDomain (contentDomainText)
import Nagare.Dsl.Prelude
import Nagare.Ops.CertificateChain
  ( chainReportValue
  , readChainWith
  , renderChainReport
  , renewChainWith
  , renewDecision
  )
import Nagare.Ops.Domains
  ( DomainRow
  , Observation (NotFound, Observed, Unavailable)
  , domainCheckFailures
  , domainReportValue
  , edgeCertificateStateWith
  , formatDomainList
  , newProbeSlots
  , observeNamespaces
  , queryBaseDomainRow
  , queryDomainRows
  , queryTunnelBaseRowsIn
  , queryTunnelDomainRowsIn
  , systemToolRunner
  )
import Nagare.Ops.Pulumi (stackOutputs)
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (IngressMode (..), Mode (Cloud, Local), contextNameText)
import Nagare.Target.ContentDomains (contentDelegationProblem, contentDomainZoneName, servedContentHosts)
import System.Exit (exitFailure, exitSuccess)
import System.IO (stderr)

runDomains :: Maybe String -> DomainsCommand -> IO ()
runDomains mctx = \case
  DomainsList o -> runDomainsList mctx o
  DomainsCheck o -> runDomainsCheck mctx o
  DomainsTls o -> runDomainsTls mctx o

-- | @domains list@: show partial evidence successfully. @domains check@ uses
-- the same inventory, but treats unavailable probes and unhealthy configured
-- routes as a non-zero operations/CI gate.
runDomainsList :: Maybe String -> DomainsListOpts -> IO ()
runDomainsList mctx o = void (runDomainsInventory False mctx o)

runDomainsCheck :: Maybe String -> DomainsListOpts -> IO ()
runDomainsCheck mctx o = void (runDomainsInventory True mctx o)

runDomainsInventory :: Bool -> Maybe String -> DomainsListOpts -> IO [DomainRow]
runDomainsInventory checking mctx o = do
  (_, workspace) <- ensurePulumiForActiveContext mctx
  tp <- activeProfile mctx
  -- One Pulumi process for every output this command reads (EP-245 D5).
  outputs <- stackOutputs (workspace ^. #pulumiDir)
  let output name = Map.lookup name outputs
  base <- case (o ^. #baseDomain, output "baseDomain") of
    (Just flag, _) -> pure (T.pack flag)
    (Nothing, Just recorded) | not (T.null recorded) -> pure recorded
    _ -> resolveBaseDomain mctx Nothing
  let (publicIp, apexIp, cdnGlobalIp) = case tp ^. #mode of
        Local -> (Just "127.0.0.1", Just "127.0.0.1", Nothing)
        Cloud -> (output "publicIp", output "apexIp", output "cdnGlobalIp")
  namespaceObservation <-
    if o ^. #allNamespaces
      then observeNamespaces
      else pure (Observed [appNamespace (o ^. #namespace)])
  let nss = case namespaceObservation of
        Observed namespaces -> namespaces
        _ -> []
  (baseRows, observations) <- case tp ^. #ingress of
    IngressDirect ->
      (,)
        <$> (pure <$> queryBaseDomainRow base apexIp)
        <*> traverse (queryDomainRows base publicIp apexIp cdnGlobalIp) nss
    IngressCloudflareTunnel -> do
      -- The zone rows and every namespace's rows probe together, eight at a time in all.
      slots <- newProbeSlots
      concurrently
        (queryTunnelBaseRowsIn slots systemToolRunner base publicIp)
        (mapConcurrently (queryTunnelDomainRowsIn slots systemToolRunner base publicIp) nss)
  let rows = baseRows <> concat [found | Observed found <- observations]
      namespaceFailures = case namespaceObservation of
        Observed _ -> []
        NotFound -> ["namespace inventory was not found"]
        Unavailable detail -> ["namespace inventory unavailable: " <> detail]
      inventoryFailures =
        namespaceFailures
          <> [ namespace <> ": DomainMapping inventory was not found"
             | (namespace, NotFound) <- zip nss observations
             ]
          <> [namespace <> ": " <> detail | (namespace, Unavailable detail) <- zip nss observations]
  -- EP-285: a cloud context's content domains are delegated by the operator at a registrar; report
  -- whether public DNS sends each one to its zone. A local or tunnel context owns no content zone.
  delegations <-
    if tp ^. #mode == Cloud && tp ^. #ingress == IngressDirect
      then forM (tp ^. #contentDomains) $ \domain -> do
        zone <- describeZoneNameServers (tp ^. #project) (contentDomainZoneName domain)
        resolvers <- observeResolverNameServers (contentDomainText domain)
        pure (contentDomainText domain, zone, contentDelegationProblem zone resolvers)
      else pure []
  -- EP-285: the hosts each content route serves, from the cluster's content Ingresses.
  routes <-
    if null (tp ^. #contentDomains)
      then pure []
      else
        systemToolRunner "kubectl" ["get", "ingresses.networking.internal.knative.dev", "--all-namespaces", "-l", "nagare.dev/content-domain", "-o", "json"] <&> \case
          Observed bytes -> maybe [] servedContentHosts (Aeson.decodeStrict bytes)
          _ -> []
  let delegationFailures = [domain <> ": " <> problem | (domain, _, Just problem) <- delegations]
      failures = inventoryFailures <> domainCheckFailures rows <> delegationFailures
  if o ^. #json
    then LBC.putStrLn (Aeson.encode (domainReportValue inventoryFailures rows))
    else do
      TIO.putStr (formatDomainList rows)
      unless (null routes) $ do
        TIO.putStrLn "Content routes:"
        forM_ routes $ \(domain, ingress, hosts) ->
          TIO.putStrLn ("  " <> domain <> "  served by " <> ingress <> "  hosts: " <> T.intercalate ", " hosts)
      unless (null delegations) $ do
        TIO.putStrLn "Content domains:"
        forM_ delegations $ \(domain, zone, problem) ->
          TIO.putStrLn
            ( "  "
                <> domain
                <> "  zone name servers: "
                <> either id (T.intercalate ", ") zone
                <> "  delegation: "
                <> maybe "matches" ("does not match: " <>) problem
            )
  unless (checking || null inventoryFailures) $ do
    TIO.hPutStrLn stderr "Domain inventory is partial:"
    mapM_ (TIO.hPutStrLn stderr . ("  " <>)) inventoryFailures
  if checking && not (null failures)
    then do
      TIO.hPutStrLn stderr "Domain check failed:"
      mapM_ (TIO.hPutStrLn stderr . ("  " <>)) failures
      exitFailure
    else pure rows

-- | @domains tls HOST [--json] [--renew --yes]@ (EP-191). Every kubectl call
-- names the context's own Kubernetes context, as the inventory runtime does.
runDomainsTls :: Maybe String -> DomainsTlsOpts -> IO ()
runDomainsTls mctx o = do
  active <- activeTarget mctx
  context <- either dieT (pure . Resource.contextIdText) (Resource.mkContextId (contextNameText (active ^. #contextName)))
  let hostName = T.pack (o ^. #host)
      kubeContext = T.unpack (contextNameText (active ^. #contextName))
      runner executable args
        | executable == "kubectl" = systemToolRunner executable (["--context", kubeContext, "--request-timeout=10s"] <> args)
        | otherwise = systemToolRunner executable args
  when (active ^. #profile . #ingress == IngressCloudflareTunnel) $ do
    when (o ^. #renew) (dieT "this context requests no origin certificate: Cloudflare ends TLS, and its edge certificate renews itself")
    edge <- edgeCertificateStateWith systemToolRunner hostName
    TIO.putStrLn ("Cloudflare ends TLS for " <> hostName <> ", and this context requests no origin certificate.")
    TIO.putStrLn ("edge certificate: " <> T.pack (show edge))
    exitSuccess
  if o ^. #renew
    then do
      unless (o ^. #yes) (dieT "domains tls --renew triggers a re-issuance; confirm with --yes")
      when (o ^. #json) (dieT "domains tls --renew prints a human report; drop --json")
      now <- getCurrentTime
      renewChainWith runner (guardKubernetesContext active) context now hostName (TIO.putStrLn . T.stripEnd)
        >>= either dieT pure
    else do
      report <- readChainWith runner hostName >>= either dieT pure
      if o ^. #json
        then LBC.putStrLn (Aeson.encode (chainReportValue (renewDecision context report) report))
        else TIO.putStr (renderChainReport report)
