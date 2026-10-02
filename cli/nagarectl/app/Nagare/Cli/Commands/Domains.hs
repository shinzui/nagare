-- | Commands / Domains. Executable-private CLI boundary.
module Nagare.Cli.Commands.Domains
  ( runDomainsCheck
  , runDomainsList
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBC
import Data.Generics.Labels ()
import Data.Text.IO qualified as TIO
import Nagare.Cli.Application.Config (appNamespace)
import Nagare.Cli.Options (DomainsListOpts (..))
import Nagare.Cli.Runtime.Pulumi (ensurePulumiForActiveContext)
import Nagare.Cli.Runtime.Target
  ( activeProfile
  , resolveDomainsBaseAt
  )
import Nagare.Dsl.Prelude
import Nagare.Ops.Domains
  ( DomainRow
  , Observation (NotFound, Observed, Unavailable)
  , domainCheckFailures
  , domainReportValue
  , formatDomainList
  , observeNamespaces
  , queryBaseDomainRow
  , queryDomainRows
  )
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Target (Mode (Cloud, Local))
import System.Exit (exitFailure)
import System.IO (stderr)

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
