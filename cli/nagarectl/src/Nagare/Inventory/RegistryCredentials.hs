-- | Exact host-owned credential footprints and the Serving account grant.
-- These names do not grant deletion or adoption of a preexisting Secret.
module Nagare.Inventory.RegistryCredentials
  ( registryCredentialAliases
  , registryControllerAccountIdentity
  , registryCredentialHost
  , registryControllerDelegation
  , registryCredentialModuleFields
  , registryCredentialModuleEnabled
  , registryClusterIdentity
  , registryHostIdentity
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Kubernetes (kubernetesObjectIdentity)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types

registryClusterIdentity :: ResourceId
registryClusterIdentity = knownId "platform:cluster/cluster/cluster"

registryHostIdentity :: ResourceId
registryHostIdentity = knownId "platform:host/nixos-system/system"

registryCredentialAliases :: ResourceId -> Either Text [ProviderAddress]
registryCredentialAliases cluster =
  traverse
    ( \namespace ->
        kubernetesAddress cluster "v1" "Secret" (Just namespace) "nagare-registry-pull"
    )
    ["personal", "nagare-system", "knative-serving"]

registryControllerAccountIdentity :: ResourceId -> Either Text ResourceId
registryControllerAccountIdentity cluster = do
  owner <- mkScopeId Platform "serving"
  key <- mkLogicalKey "serving"
  address <- kubernetesAddress cluster "v1" "ServiceAccount" (Just "knative-serving") "controller"
  kubernetesObjectIdentity owner key address

-- | Legacy accepted hosts retain their original footprint. Partial grants
-- cannot enable the new controller target.
registryCredentialHost :: ScopeSnapshot -> ResourceId -> Either Text (Maybe ResourceId)
registryCredentialHost snapshot cluster = do
  required <- Set.fromList <$> registryCredentialAliases cluster
  let members =
        [ resource
        | (_, scope) <- Map.elems (snapshotScopes snapshot)
        , bundle <- scopeBundles scope
        , Managed resource <- declarations bundle
        , resource ^. #identity == registryHostIdentity
        ]
  case members of
    [] -> Right Nothing
    [resource]
      | resource ^. #executor /= HostExecutor -> Left "registry credential footprint requires the host executor"
      | not (hostAddress (resource ^. #address)) -> Left "registry credential footprint requires a host address"
      | Set.null (Set.intersection required (Set.fromList (resource ^. #aliases))) -> Right Nothing
      | required == Set.fromList (resource ^. #aliases) -> Right (Just registryHostIdentity)
      | otherwise -> Left "accepted host has an incomplete registry credential footprint"
    _ -> Left "accepted registry credential host identity is ambiguous"
  where
    hostAddress (Host _ _) = True
    hostAddress _ = False

-- These field names denote the bounded domain roles implemented by the host
-- timer: one pull reference and its two dynamic registry annotations.
registryControllerDelegation :: ResourceId -> Delegation
registryControllerDelegation host =
  Delegation
    host
    (knownName "registry-pull-reference" :| [knownName "registry-credential-metadata"])
    (RefreshCredential :| [])

registryCredentialModuleFields :: ResourceId -> Either Text [(Text, Text)]
registryCredentialModuleFields cluster = do
  account <- registryControllerAccountIdentity cluster
  pure
    [ ("registryCredentialOwner", resourceIdText registryHostIdentity)
    , ("registryServingControllerOwner", resourceIdText account)
    ]

-- The generated, digest-bound module opts into the exact footprint. A legacy
-- module stays legacy, and a partial or changed generated binding refuses.
registryCredentialModuleEnabled :: ResourceId -> ByteString -> Either Text Bool
registryCredentialModuleEnabled cluster bytes = do
  fields <- registryCredentialModuleFields cluster
  let present key = TE.encodeUtf8 key `BS.isInfixOf` bytes
      linesWith key = filter (BS.isInfixOf (TE.encodeUtf8 key)) (BC.lines bytes)
      bound (key, value) =
        linesWith key
          == [TE.encodeUtf8 ("    " <> key <> " = \"" <> value <> "\";")]
  if not (any (present . fst) fields)
    then Right False
    else
      if all bound fields
        then Right True
        else Left "host registry credential binding differs from the typed controller and footprint"

knownId :: Text -> ResourceId
knownId = either (error . show) id . mkResourceId

knownName :: Text -> Name
knownName = either (error . show) id . mkName
