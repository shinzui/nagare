-- | EP-225 M1: a scope's deployment meaning ignores where it was compiled from
-- and nothing else.
module DeploymentMeaningSpec (deploymentMeaningTests) where

import Control.Monad (forM_)
import Data.Aeson (Value, object, (.=))
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Resource.Canonical (canonicalValue, contentDigest)
import Nagare.Resource.DeploymentMeaning
import Nagare.Resource.Inventory hiding (cluster)
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types
import Nagare.Resource.Wire (encodeCanonicalScope)
import Test.Tasty
import Test.Tasty.HUnit

deploymentMeaningTests :: TestTree
deploymentMeaningTests =
  testGroup
    "deployment meaning (EP-225 M1)"
    [ testCase "the same declarations from another workspace mean the same deployment" $ do
        let first' = scopeAt "/state/platform/nagare-0.11.0-aaaa/cluster/app.yaml"
            second' = scopeAt "/state/platform/nagare-0.11.1-bbbb/cluster/app.yaml"
        assertBool "fixture sources do not differ" (encodeCanonicalScope first' /= encodeCanonicalScope second')
        assertBool "moved declarations changed meaning" (sameDeploymentMeaning first' second')
    , testCase "every deployment-significant change is visible" $ do
        let base = member "/a/app.yaml"
            changes =
              [ ("desired content", base & #spec .~ NativeObject (digestOf (object ["data" .= object ["key" .= ("other" :: Text)]])))
              , ("a field named source", base & #spec .~ NativeObject (digestOf (object ["data" .= object ["key" .= ("value" :: Text)], "source" .= ("x" :: Text)])))
              , ("address", base & #address .~ configMap "renamed")
              , ("alias", base & #aliases .~ [configMap "alias"])
              , ("retention", base & #lifecycle .~ DeleteWhenUnreferenced)
              , ("data policy", base & #dataPolicy .~ Durable (RecoveryIntent (ok (mkName "backup")) (mkSecretRef (ok (mkName "nagare-system")) (ok (mkName "key")) :| [])))
              , ("sensitivity", base & #sensitivity .~ Private)
              , ("dependency", base & #dependencies .~ [OrderedAfter cluster])
              ]
        forM_ changes $ \(label, changed) ->
          assertBool (label <> " kept its meaning") (not (sameDeploymentMeaning (scopeOf [Managed base]) (scopeOf [Managed changed])))
        let operation = DeclaredOperation (rid "migrate") (rid "config" :| []) [] Idempotent SchemaMigration
            withOperation body = ok (mkScopeDeclaration foundation [ResourceBundle [Managed base] [] [] [] body []])
        assertBool "an operation kept its meaning" (not (sameDeploymentMeaning (withOperation []) (withOperation [operation])))
        assertBool "a configuration digest kept its meaning" (not (sameDeploymentMeaning (scopeOf [Managed base]) (withScopeConfigDigest (digestOf (object [])) (scopeOf [Managed base]))))
        assertBool "an override kept its meaning" (not (sameDeploymentMeaning (scopeOf [Managed base]) (withScopeOverrides (Map.fromList [("tag", "v2")]) (scopeOf [Managed base]))))
    , testCase "a source code reads as data stays significant" $ do
        let at source = scopeOf [Managed (member "/a/app.yaml" & #source .~ source)]
            significant =
              [ (SourceLocation "generated:bootstrap" "platform-version", SourceLocation "generated:auth-credential" "platform-version")
              , (SourceLocation "contribution" "application:a", SourceLocation "/a/app.yaml" "application:a")
              , (SourceLocation "packaged:auth-database" "x", SourceLocation "packaged:other" "x")
              , (SourceLocation "/nix/store/aaaa-image.tar" "oci-archive-v1", SourceLocation "/nix/store/bbbb-image.tar" "oci-archive-v1")
              , (SourceLocation "/a/kubeconfig" "kubeconfig-prepared-v1", SourceLocation "/b/kubeconfig" "kubeconfig-prepared-v1")
              , (SourceLocation "/a/substrate.json" "local-substrate-v1", SourceLocation "/b/substrate.json" "local-substrate-v1")
              ]
        forM_ significant $ \(left, right) ->
          assertBool (show (left, right) <> " was treated as provenance") (not (sameDeploymentMeaning (at left) (at right)))
        assertBool "a diagnostic path was significant" (sameDeploymentMeaning (at (SourceLocation "/a/app.yaml" "spec")) (at (SourceLocation "access" "user@example.com")))
    , testCase "ignoring every source compares the rest of the declaration" $ do
        let at source = scopeOf [Managed (member "/a/app.yaml" & #source .~ source)]
        assertBool "artifact inputs differ only by location" (sameDeclarationsModuloSources (at (SourceLocation "/a/x" "local-substrate-v1")) (at (SourceLocation "/b/x" "local-substrate-v1")))
        assertBool "content was ignored" (not (sameDeclarationsModuloSources (at (SourceLocation "/a/x" "spec")) (scopeOf [Managed (member "/a/x" & #lifecycle .~ DeleteWhenUnreferenced)])))
    ]
  where
    scopeAt path = scopeOf [Managed (member path)]

foundation :: ScopeId
foundation = ok (mkScopeId Platform "foundation")

cluster :: ResourceId
cluster = rid "cluster"

rid :: Text -> ResourceId
rid key = mintResourceId foundation (ok (mkLogicalKey key)) (ok (mkName "resource"))

configMap :: Text -> ProviderAddress
configMap name = Kubernetes cluster "" (ok (mkName "configmap")) (Just (ok (mkName "nagare-system"))) (ok (mkName name))

member :: Text -> ManagedResource
member path =
  ManagedResource
    (rid "config")
    foundation
    KubernetesExecutor
    (configMap "config")
    []
    (NativeObject (digestOf (object ["data" .= object ["key" .= ("value" :: Text)]])))
    Retain
    Stateless
    Public
    []
    []
    (SourceLocation path "spec")

scopeOf :: [Declaration] -> ScopeDeclaration
scopeOf declarations = ok (mkScopeDeclaration foundation [ResourceBundle declarations [] [] [] [] []])

digestOf :: Value -> ContentDigest
digestOf = contentDigest . ok . canonicalValue

ok :: (Show e) => Either e a -> a
ok = either (error . show) id
