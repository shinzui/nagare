-- | Commands / Domains. Executable-private CLI boundary.
module Nagare.Cli.Commands.Domains
  ( runDomains
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time (getCurrentTime)
import Nagare.Cli.Application.Config (appNamespace)
import Nagare.Cli.Options (DomainsCommand (..), DomainsListOpts (..), DomainsTlsOpts (..))
import Nagare.Cli.Runtime.Cluster (guardKubernetesContext)
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Pulumi (ensurePulumiForActiveContext)
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , activeTarget
  , resolveDomainsBaseAt
  )
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
  , formatDomainList
  , observeNamespaces
  , queryBaseDomainRow
  , queryDomainRows
  , systemToolRunner
  )
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Resource.Types qualified as Resource
import Nagare.Target (Mode (Cloud, Local), contextNameText)
import System.Exit (exitFailure)
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
  base <- resolveDomainsBaseAt mctx workspace (o ^. #baseDomain)
  (publicIp, apexIp, cdnGlobalIp) <- case tp ^. #mode of
    Local -> pure (Just "127.0.0.1", Just "127.0.0.1", Nothing)
    Cloud ->
      (,,)
        <$> stackOutput (workspace ^. #pulumiDir) "publicIp"
        <*> stackOutput (workspace ^. #pulumiDir) "apexIp"
        <*> stackOutput (workspace ^. #pulumiDir) "cdnGlobalIp"
  namespaceObservation <-
    if o ^. #allNamespaces
      then observeNamespaces
      else pure (Observed [appNamespace (o ^. #namespace)])
  let nss = case namespaceObservation of
        Observed namespaces -> namespaces
        _ -> []
  baseRow <- queryBaseDomainRow base apexIp
  observations <- traverse (queryDomainRows base publicIp apexIp cdnGlobalIp) nss
  let rows = baseRow : concat [found | Observed found <- observations]
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
      failures = inventoryFailures <> domainCheckFailures rows
  if o ^. #json
    then LBC.putStrLn (Aeson.encode (domainReportValue inventoryFailures rows))
    else TIO.putStr (formatDomainList rows)
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
