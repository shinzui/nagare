{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- A typed accepted application whose namespace is composed from a contribution.
module Main where

import Control.Monad (forM_)
import Data.Aeson (Value, eitherDecodeStrict, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Nagare.Cdn.Cloudflare (buildComposedCacheRulesPayload)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Components.Foundation (compileContributedNamespaces)
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Kubernetes (bindKubernetesObject)
import Nagare.Inventory.Store
import Nagare.Resource.Cdn (compileCloudflareDnsRecord, compileGoogleDnsRecord)
import Nagare.Resource.Inventory
import Nagare.Resource.Kubernetes (KubernetesInput (..))
import Nagare.Resource.Policy (DataPolicy (Stateless), LifecyclePolicy (Retain), Sensitivity (Private))
import Nagare.Resource.Types
import Nagare.Resource.Wire (canonicalValue, encodeCanonicalScope)
import System.Environment (getArgs)
import System.FilePath ((</>))

ok :: (Show e) => Either e a -> a
ok = either (error . show) id

must :: (Show e) => IO (Either e a) -> IO a
must action = either (error . show) id <$> action

main :: IO ()
main = do
  arguments <- getArgs
  let (storePath, output, google, shared) = case arguments of
        [storePath, output] -> (storePath, output, False, True)
        [storePath, output, "google"] -> (storePath, output, True, True)
        [storePath, output, provider, namespaceMode] -> (storePath, output, provider == "google", namespaceMode /= "last")
        _ -> error "expected store output [provider namespace-mode]"
  let context = ok (mkContextId "cdn-purge-fixture")
      binding = ContextBinding context (ok (mkName "project"))
      platformOwner = ok (mkScopeId Platform "cdn")
      owner = ok (mkScopeId Application "demo")
      neighborOwner = ok (mkScopeId Application "neighbor")
      cluster = mintResourceId platformOwner (ok (mkLogicalKey "cluster")) (ok (mkName "cluster"))
      backendOwner = ok (mkScopeId Platform "origin")
      backendId = mintResourceId backendOwner (ok (mkLogicalKey "backend")) (ok (mkName "backend"))
      host = ok (mkName "www.example.test")
      key = ok (mkLogicalKey "www.example.test")
      domainId = mintResourceId owner key (ok (mkName "domain-mapping"))
      source = SourceLocation "scripts/fixtures/CdnPurgePublicFixture.hs" "cdn"
      backend =
        ManagedResource
          backendId
          backendOwner
          PulumiExecutor
          (PulumiUrn "urn:pulumi:stack::project::gcp:compute/backendService:BackendService::backend")
          []
          (NativeObject (contentDigest "backend"))
          Retain
          Stateless
          Private
          []
          []
          source
      domainValue =
        object
          [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
          , "kind" .= ("DomainMapping" :: Text)
          , "metadata" .= object ["name" .= nameText host, "namespace" .= ("demo-namespace" :: Text)]
          , "spec" .= object ["ref" .= object ["apiVersion" .= ("serving.knative.dev/v1" :: Text), "kind" .= ("Service" :: Text), "name" .= ("web" :: Text)]]
          ]
      domainBytes = ok (canonicalValue domainValue)
      domain = ok (bindKubernetesObject (KubernetesInput domainId owner cluster domainValue (contentDigest domainBytes) Retain Stateless Private source))
      zone = ok (mkName "0123456789abcdef0123456789abcdef")
      rulesId = cloudflareRulesResourceId platformOwner zone
      intent = CloudflareCacheIntent host (Just 60) False []
      dns =
        ok
          ( if google
              then compileGoogleDnsRecord owner key (ok (mkName "project")) (ok (mkName "zone")) host "203.0.113.4" domainId backendId source
              else compileCloudflareDnsRecord owner key zone host "203.0.113.4" domainId rulesId source
          )
      platformScope = ok (mkScopeDeclaration platformOwner [ResourceBundle [] [] [] [] [] [NamespaceGrant owner cluster, NamespaceGrant neighborOwner cluster, CloudflareZoneGrant zone CloudflareFullStrict]])
      appScope =
        ok
          ( mkScopeDeclaration
              owner
              [ ResourceBundle
                  [Managed (fst domain)]
                  []
                  []
                  ([RegisterNamespace platformOwner cluster (ok (mkName "demo-namespace")) (ok (mkLogicalKey "namespace"))] <> [RegisterCloudflareCache platformOwner zone intent domainId | not google])
                  []
                  []
              , dns
              ]
          )
      originScope = ok (mkScopeDeclaration backendOwner [ResourceBundle [Managed backend] [] [] [] [] []])
      neighborScope =
        ok
          ( mkScopeDeclaration
              neighborOwner
              [ResourceBundle [] [] [] [RegisterNamespace platformOwner cluster (ok (mkName "demo-namespace")) (ok (mkLogicalKey "namespace")) | shared] [] []]
          )
      scopes = [originScope, platformScope, appScope, neighborScope]
      generation = ok (mkScopeGeneration 1)
      revision scope = ScopeRevision generation (contentDigest (encodeCanonicalScope scope))
      accepted = Map.fromList [(scopeId scope, revision scope) | scope <- scopes]
      snapshot = ok (mkScopeSnapshot binding (Map.fromList [(scopeId scope, (generation, scope)) | scope <- scopes]) Map.empty)
      inventory = ok (composeSnapshot snapshot)
      generated = ok (compileContributedNamespaces (inventoryDeclarations inventory))
      native = Map.insert domainId domain generated
  unless (Map.size generated == 1) (error "fixture must include exactly one generated namespace")
  store <- must (openFilesystemStore storePath)
  initial <- must (initializeStore store binding "cdn-purge-fixture")
  forM_ scopes $ \scope -> do
    let bytes = encodeCanonicalScope scope
    _ <- must (publishIfAbsent store (scopeKey (contentDigest bytes)) bytes)
    pure ()
  forM_ (Map.elems native) $ \(_, bytes) -> do
    _ <- must (publishIfAbsent store (objectKeyFor "native" (contentDigest bytes)) bytes)
    pure ()
  _ <-
    must
      ( replaceHeadIfGenerationMatches
          store
          (Just (headGeneration initial))
          initial
            { headGeneration = headGeneration initial + 1
            , headAccepted = accepted
            , headConverged = accepted
            }
      )
  BS.writeFile
    (output </> "native.json")
    ( BL.toStrict
        ( encode
            [ object ["resource" .= resourceIdText selectedId, "digest" .= digestText (contentDigest bytes), "native" .= (ok (eitherDecodeStrict bytes) :: Value)]
            | (selectedId, (_, bytes)) <- Map.toList native
            ]
        )
    )

  BS.writeFile (output </> "rules.json") (BL.toStrict (encode (buildComposedCacheRulesPayload [intent])))
